import Foundation
import Testing
@testable import ElectricityCore

/// Clients and the Claude Desktop source. All log lines are hand-written.
@Suite struct ClientTests {
    private func claudeLine(id: String, entrypoint: String?) -> String {
        let entry = entrypoint.map { #""entrypoint": "\#($0)", "# } ?? ""
        return #"{"type": "assistant", \#(entry)"sessionId": "s-\#(id)", "requestId": "r-\#(id)", "timestamp": "2026-10-13T01:00:00Z", "cwd": "/tmp/example", "message": {"id": "m-\#(id)", "model": "claude-sonnet-test", "usage": {"input_tokens": 10, "output_tokens": 100, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}"#
    }

    @Test func clientLabels() {
        #expect(UsageClient.claude(entrypoint: "cli") == "CLI")
        #expect(UsageClient.claude(entrypoint: "local-agent") == "Cowork")
        #expect(UsageClient.claude(entrypoint: "claude-desktop") == "Code")
        #expect(UsageClient.claudeSource(entrypoint: "claude-desktop", default: .claudeCode) == .claudeDesktop)
        #expect(UsageClient.claude(entrypoint: "sdk-ts") == "SDK")
        #expect(UsageClient.claude(entrypoint: nil) == nil)
        #expect(UsageClient.codex(originator: "Codex Desktop") == "Desktop")
        #expect(UsageClient.codex(originator: "codex_work_desktop") == "Desktop")
        #expect(UsageClient.codex(originator: "codex_vscode") == "VS Code")
        #expect(UsageClient.codex(originator: "codex_sdk_ts") == "SDK")
        #expect(UsageClient.codex(originator: "codex_cli_rs") == "CLI")
    }

    @Test func desktopRecordsGoToClaudeDesktop() {
        guard case .usage(let cli) = ClaudeCodeParser.parse(line: Data(claudeLine(id: "1", entrypoint: "cli").utf8)) else {
            Issue.record("no usage"); return
        }
        #expect(cli.source == .claudeCode)
        #expect(cli.client == "CLI")
        guard case .usage(let cowork) = ClaudeCodeParser.parse(line: Data(claudeLine(id: "2", entrypoint: "local-agent").utf8)) else {
            Issue.record("no usage"); return
        }
        #expect(cowork.source == .claudeDesktop)
        #expect(cowork.client == "Cowork")
    }

    @Test func codexClientComesFromSessionMeta() {
        var state = CodexParserState()
        let meta = #"{"type": "session_meta", "payload": {"id": "c1", "cwd": "/tmp/example", "originator": "Codex Desktop"}}"#
        _ = CodexParser.parse(line: Data(meta.utf8), filePath: "/tmp/x.jsonl", lineNumber: 1, state: &state)
        let usage = #"{"type": "event_msg", "timestamp": "2026-10-13T01:00:00Z", "payload": {"type": "token_count", "info": {"last_token_usage": {"input_tokens": 100, "cached_input_tokens": 0, "output_tokens": 50, "reasoning_output_tokens": 0, "total_tokens": 150}, "total_token_usage": {"input_tokens": 100, "cached_input_tokens": 0, "output_tokens": 50, "reasoning_output_tokens": 0, "total_tokens": 150}}}}"#
        guard case .usage(let parsed) = CodexParser.parse(line: Data(usage.utf8), filePath: "/tmp/x.jsonl", lineNumber: 2, state: &state) else {
            Issue.record("no usage"); return
        }
        #expect(parsed.client == "Desktop")
    }

    @Test func desktopFolderScanAndCodexBackfill() async throws {
        let root = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(root) }
        let fm = FileManager.default
        // Cowork layout: a hidden .claude/projects folder inside a session folder, next to an audit log.
        let projects = root.appendingPathComponent("desktop/org/user/agent/session/.claude/projects/-tmp-example")
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data((claudeLine(id: "3", entrypoint: "local-agent") + "\n").utf8).write(to: projects.appendingPathComponent("a.jsonl"))
        try Data("{\"audit\": true}\n".utf8).write(to: root.appendingPathComponent("desktop/org/user/agent/session/audit.jsonl"))
        // A Codex log whose records were read before clients existed.
        let codex = root.appendingPathComponent("codex")
        try fm.createDirectory(at: codex, withIntermediateDirectories: true)
        let meta = #"{"type": "session_meta", "payload": {"id": "c9", "originator": "codex_work_desktop"}}"#
        try Data((meta + "\n").utf8).write(to: codex.appendingPathComponent("rollout.jsonl"))

        let locations = LogLocations(claudeCode: [], codex: [codex], claudeDesktop: [root.appendingPathComponent("desktop")])
        #expect(locations.logFiles(for: .claudeDesktop).count == 1)

        let store = try UsageStore()
        let old = ParsedUsage(dedupeKey: "old", source: .codex, sessionID: "c9", projectPath: nil, model: "gpt-test",
                              timestamp: Date(), tokens: TokenCounts(inputUncached: 1, output: 1))
        try store.insert([UsageEventRow(usage: old, result: try TestSupport.calculator().estimate(model: old.model, tokens: old.tokens))], cursor: nil)
        #expect(try store.sessionsWithoutClient(source: .codex) == ["c9"])

        let service = IngestService(store: store, calculator: try TestSupport.calculator(), locations: locations)
        _ = await service.scan()
        #expect(try store.totals(source: .claudeDesktop).eventCount == 1)
        #expect(try store.sessionsWithoutClient(source: .codex).isEmpty)
        #expect(try store.clientCounts()[.codex]?["Desktop"] == 1)
        #expect(try store.clientCounts()[.claudeDesktop]?["Cowork"] == 1)
    }
}
