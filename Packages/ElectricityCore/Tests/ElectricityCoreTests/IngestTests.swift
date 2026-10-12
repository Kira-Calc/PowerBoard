import Foundation
import Testing
@testable import ElectricityCore

@Suite struct IngestTests {
    /// Copies fixtures into a temporary home-like layout and returns the service, store and paths.
    private func makeEnvironment() throws -> (dir: URL, store: UsageStore, service: IngestService, claudeDir: URL, codexDir: URL) {
        let dir = try TestSupport.makeTempDirectory()
        let claudeDir = dir.appendingPathComponent("claude/projects/project-alpha/subagents", isDirectory: true)
        let codexDir = dir.appendingPathComponent("codex/sessions/2026/10/12", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        for name in ["session-a.jsonl", "session-b-resumed.jsonl"] {
            try FileManager.default.copyItem(at: TestSupport.fixture("claude/\(name)"), to: claudeDir.appendingPathComponent(name))
        }
        try FileManager.default.copyItem(at: TestSupport.fixture("codex/rollout-sample.jsonl"), to: codexDir.appendingPathComponent("rollout-sample.jsonl"))

        let store = try UsageStore()
        let locations = LogLocations(
            claudeCode: [dir.appendingPathComponent("claude/projects")],
            codex: [dir.appendingPathComponent("codex/sessions")]
        )
        let service = IngestService(store: store, calculator: try TestSupport.calculator(), locations: locations)
        return (dir, store, service, claudeDir, codexDir)
    }

    @Test func backfillDeduplicatesAndCountsSkippedLines() async throws {
        let env = try makeEnvironment()
        defer { TestSupport.cleanup(env.dir) }

        let summary = await env.service.scan()
        let claude = try #require(summary.bySource[.claudeCode])
        #expect(claude.filesFound == 2)
        // msg_001 twice in one file, msg_002 copied into the resumed file: 4 unique events.
        #expect(claude.eventsInserted == 4)
        #expect(claude.linesSkipped == 0)

        let totals = try env.store.totals(source: .claudeCode)
        #expect(totals.eventCount == 4)
        #expect(totals.tokens == TokenCounts(inputUncached: 116, cacheWrite: 1003, cacheRead: 25004, output: 1202))

        let codex = try #require(summary.bySource[.codex])
        #expect(codex.eventsInserted == 2)
        #expect(codex.linesSkipped == 1)
        let codexTotals = try env.store.totals(source: .codex)
        #expect(codexTotals.tokens == TokenCounts(inputUncached: 700, cacheRead: 1000, output: 100, reasoning: 20))

        let codexEvents = try env.store.events(source: .codex)
        #expect(codexEvents.map(\.model) == ["gpt-test-model", "gpt-test-mini"])
        #expect(codexEvents.allSatisfy { $0.sessionId == "codex-sess-1" && $0.projectPath == "/tmp/example/project-gamma" })
        #expect(codexEvents.map(\.tier) == ["medium", "small"])
    }

    @Test func incompleteLastLineIsReadAfterItCompletes() async throws {
        let env = try makeEnvironment()
        defer { TestSupport.cleanup(env.dir) }
        _ = await env.service.scan()

        // The fixture ends with a broken line that has no newline yet: it must not be counted.
        let file = env.claudeDir.appendingPathComponent("session-a.jsonl")
        let cursor = try #require(try env.store.cursor(forPath: file.resolvingSymlinksInPath().path))
        #expect(cursor.skippedLines == 0)

        // Completing it with a newline makes it a broken line, which is skipped and counted.
        try TestSupport.append("\n", to: file)
        let summary = await env.service.scan()
        #expect(summary.bySource[.claudeCode]?.linesSkipped == 1)
        #expect(summary.bySource[.claudeCode]?.eventsInserted == 0)
    }

    @Test func appendedLinesAreReadIncrementally() async throws {
        let env = try makeEnvironment()
        defer { TestSupport.cleanup(env.dir) }
        _ = await env.service.scan()

        let file = env.claudeDir.appendingPathComponent("session-b-resumed.jsonl")
        try TestSupport.append(#"{"type":"assistant","timestamp":"2026-10-12T02:05:00.000Z","sessionId":"sess-b","requestId":"req_011","message":{"id":"msg_011","model":"claude-sonnet-test","usage":{"input_tokens":7,"output_tokens":8}}}"# + "\n", to: file)
        let summary = await env.service.scan()
        #expect(summary.bySource[.claudeCode]?.filesRead == 2)
        #expect(summary.bySource[.claudeCode]?.eventsInserted == 1)
        #expect(try env.store.totals(source: .claudeCode).eventCount == 5)

        // Nothing new: unchanged files are not read again.
        let idle = await env.service.scan()
        #expect(idle.bySource[.codex]?.filesRead == 0)
        #expect(idle.eventsInserted == 0)
    }

    @Test func codexStateSurvivesIncrementalReads() async throws {
        let env = try makeEnvironment()
        defer { TestSupport.cleanup(env.dir) }
        _ = await env.service.scan()

        let file = env.codexDir.appendingPathComponent("rollout-sample.jsonl")
        try TestSupport.append(#"{"timestamp":"2026-10-12T03:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0},"total_token_usage":{"input_tokens":2000,"cached_input_tokens":1000,"output_tokens":110,"reasoning_output_tokens":20}}}}"# + "\n", to: file)
        _ = await env.service.scan()
        let events = try env.store.events(source: .codex)
        #expect(events.count == 3)
        let last = try #require(events.last)
        // Increase of the total since the previous event, with the model and session kept from earlier reads.
        #expect(last.tokens == TokenCounts(inputUncached: 300, output: 10))
        #expect(last.model == "gpt-test-mini")
        #expect(last.sessionId == "codex-sess-1")
    }

    @Test func truncatedFileIsReadAgainWithoutDoubleCounting() async throws {
        let env = try makeEnvironment()
        defer { TestSupport.cleanup(env.dir) }
        _ = await env.service.scan()

        let file = env.claudeDir.appendingPathComponent("session-b-resumed.jsonl")
        let original = try Data(contentsOf: file)
        // Truncate in place (same inode), then write back a shorter version of the same content.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: original.prefix(through: original.firstIndex(of: UInt8(ascii: "\n"))!))
        try handle.close()

        _ = await env.service.scan()
        #expect(try env.store.totals(source: .claudeCode).eventCount == 4)
        let cursor = try #require(try env.store.cursor(forPath: file.resolvingSymlinksInPath().path))
        #expect(cursor.lineCount == 1)
    }

    @Test func replacedFileIsReadFromStart() async throws {
        let env = try makeEnvironment()
        defer { TestSupport.cleanup(env.dir) }
        _ = await env.service.scan()

        let file = env.claudeDir.appendingPathComponent("session-b-resumed.jsonl")
        let path = file.resolvingSymlinksInPath().path
        let before = try #require(try env.store.cursor(forPath: path))
        let content = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        let extra = #"{"type":"assistant","timestamp":"2026-10-12T02:10:00.000Z","sessionId":"sess-b","requestId":"req_012","message":{"id":"msg_012","model":"claude-sonnet-test","usage":{"input_tokens":1,"output_tokens":1}}}"# + "\n"
        try (content + Data(extra.utf8)).write(to: file)

        _ = await env.service.scan()
        let after = try #require(try env.store.cursor(forPath: path))
        #expect(after.inode != before.inode)
        #expect(after.lineCount == 3)
        #expect(try env.store.totals(source: .claudeCode).eventCount == 5)
    }

    @Test func recalculateUsesNewFactors() async throws {
        let env = try makeEnvironment()
        defer { TestSupport.cleanup(env.dir) }
        _ = await env.service.scan()
        let before = try env.store.totals()

        let updated = try env.store.recalculateAll(with: TestSupport.calculator(cacheReadRatio: 0), batchSize: 2)
        #expect(updated == 6)
        let after = try env.store.totals()
        #expect(after.tokens == before.tokens)
        #expect(after.energyWh.mid < before.energyWh.mid)
    }
}

@Suite struct UsageStoreTests {
    private func row(key: String, ms: Int64, source: UsageSource = .claudeCode) throws -> UsageEventRow {
        let usage = ParsedUsage(
            dedupeKey: key, source: source, sessionID: "s", projectPath: nil, model: "sonnet",
            timestamp: Date(timeIntervalSince1970: Double(ms) / 1000), tokens: TokenCounts(inputUncached: 1, output: 1)
        )
        return UsageEventRow(usage: usage, result: try TestSupport.calculator().estimate(model: usage.model, tokens: usage.tokens))
    }

    @Test func duplicateKeysAreIgnored() throws {
        let store = try UsageStore()
        #expect(try store.insert([row(key: "a", ms: 1), row(key: "a", ms: 2), row(key: "b", ms: 3)], cursor: nil) == 2)
        #expect(try store.insert([row(key: "b", ms: 4)], cursor: nil) == 0)
        #expect(try store.totals().eventCount == 2)
    }

    @Test func cursorRoundTrip() throws {
        let store = try UsageStore()
        let cursor = FileCursor(path: "/x", inode: UInt64.max, offset: 42, mtime: 1.5, skippedLines: 2, lineCount: 9, parserState: "{}")
        try store.insert([], cursor: cursor)
        #expect(try store.cursor(forPath: "/x") == cursor)
        #expect(try store.allCursors() == [cursor])
    }

    @Test func totalsFilterByTimeAndSource() throws {
        let store = try UsageStore()
        try store.insert([
            row(key: "a", ms: 1_000),
            row(key: "b", ms: 2_000),
            row(key: "c", ms: 3_000, source: .codex),
        ], cursor: nil)
        #expect(try store.totals(from: Date(timeIntervalSince1970: 2), to: Date(timeIntervalSince1970: 3)).eventCount == 1)
        #expect(try store.totals(source: .codex).eventCount == 1)
        #expect(try store.totals(source: .claudeCode, from: Date(timeIntervalSince1970: 1.5)).eventCount == 1)
    }

    @Test func onDiskDatabaseMigrates() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("nested/data.sqlite")
        do {
            let store = try UsageStore(url: url)
            try store.insert([row(key: "a", ms: 1)], cursor: nil)
        }
        let reopened = try UsageStore(url: url)
        #expect(try reopened.totals().eventCount == 1)
        try reopened.deleteAll()
        #expect(try reopened.totals().eventCount == 0)
    }
}

@Suite struct LogLocationsTests {
    @Test func standardLocationsOrderAndDedupe() {
        let home = URL(fileURLWithPath: "/tmp/example-home")
        let locations = LogLocations.standard(
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/a, /tmp/example-home/.claude", "CODEX_HOME": "/tmp/codex"],
            home: home
        )
        #expect(locations.claudeCode.map(\.path) == [
            "/tmp/a/projects",
            "/tmp/example-home/.claude/projects",
            "/tmp/example-home/.config/claude/projects",
        ])
        #expect(locations.codex.map(\.path) == ["/tmp/codex/sessions", "/tmp/example-home/.codex/sessions"])
    }

    @Test func noEnvironment() {
        let locations = LogLocations.standard(environment: [:], home: URL(fileURLWithPath: "/tmp/h"))
        #expect(locations.claudeCode.count == 2)
        #expect(locations.codex.map(\.path) == ["/tmp/h/.codex/sessions"])
    }
}
