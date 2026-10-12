import Foundation
import Testing
@testable import ElectricityCore

@Suite struct QueryTests {
    private func utc(_ string: String) -> Date {
        try! Date(string, strategy: Date.ISO8601FormatStyle())
    }

    private func calendar(_ id: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: id)!
        return calendar
    }

    private func row(
        _ key: String, session: String = "s", source: UsageSource = .claudeCode, project: String? = "/tmp/example/p",
        model: String = "claude-sonnet-test", at date: Date, output: Int = 1000, calculator: EnergyCalculator? = nil
    ) throws -> UsageEventRow {
        let usage = ParsedUsage(dedupeKey: key, source: source, sessionID: session, projectPath: project, model: model, timestamp: date, tokens: TokenCounts(inputUncached: 1, output: output))
        let calc = try calculator ?? TestSupport.calculator()
        return UsageEventRow(usage: usage, result: calc.estimate(model: model, tokens: usage.tokens))
    }

    @Test func sessionsIncludeLatestModelAndProject() throws {
        let store = try UsageStore()
        try store.insert([
            row("a", session: "s1", project: "/tmp/example/one", model: "claude-opus-test", at: utc("2026-10-12T01:00:00Z")),
            row("b", session: "s1", project: "/tmp/example/two", model: "claude-sonnet-test", at: utc("2026-10-12T02:00:00Z")),
            row("c", session: "s2", at: utc("2026-10-12T03:00:00Z")),
        ], cursor: nil)
        let sessions = try store.sessions(activeSince: utc("2026-10-12T00:00:00Z"))
        #expect(sessions.map(\.sessionID) == ["s2", "s1"])
        #expect(sessions[1].model == "claude-sonnet-test")
        #expect(sessions[1].projectPath == "/tmp/example/two")
        #expect(try store.sessions(activeSince: utc("2026-10-12T00:00:00Z"), limit: 1).count == 1)
    }

    @Test func hourlyEnergyFollowsLocalDay() throws {
        let store = try UsageStore()
        try store.insert([
            row("a", at: utc("2026-10-11T16:30:00Z")), // 00:30 Shanghai
            row("b", at: utc("2026-10-12T15:59:00Z")), // 23:59 Shanghai
            row("c", at: utc("2026-10-12T16:00:00Z")), // next day
        ], cursor: nil)
        let hours = try store.hourlyEnergy(dayContaining: utc("2026-10-12T04:00:00Z"), calendar: calendar("Asia/Shanghai"))
        #expect(hours.count == 24)
        #expect(hours[0].start == utc("2026-10-11T16:00:00Z"))
        #expect(hours[0].wh > 0)
        #expect(hours[23].wh > 0)
        #expect(hours[1..<23].allSatisfy { $0.wh == 0 })

        let dstDay = try store.hourlyEnergy(dayContaining: utc("2026-11-01T12:00:00Z"), calendar: calendar("America/New_York"))
        #expect(dstDay.count == 25)
    }

    @Test func groupedUsageBySessionProjectAndModel() throws {
        let store = try UsageStore()
        try store.insert([
            row("a", session: "s1", project: "/tmp/example/one", model: "claude-opus-test", at: utc("2026-10-12T01:00:00Z")),
            row("b", session: "s1", project: "/tmp/example/one", model: "claude-sonnet-test", at: utc("2026-10-12T02:00:00Z")),
            row("c", session: "s2", source: .codex, project: nil, model: "brand-new-model", at: utc("2026-10-12T03:00:00Z")),
        ], cursor: nil)

        let bySession = try store.groupedUsage(by: .session)
        #expect(bySession.map(\.key) == ["s2", "s1"])
        #expect(bySession[1].eventCount == 2)
        #expect(bySession[1].tokens.output == 2000)
        #expect(bySession[1].model == "claude-sonnet-test")
        #expect(bySession[1].firstTimestamp == utc("2026-10-12T01:00:00Z"))
        #expect(bySession[0].tierConfidence == .unmapped)

        let byProject = try store.groupedUsage(by: .project)
        #expect(Set(byProject.map(\.key)) == ["/tmp/example/one", ""])

        let byModel = try store.groupedUsage(by: .model, from: utc("2026-10-12T01:30:00Z"))
        #expect(Set(byModel.map(\.key)) == ["claude-sonnet-test", "brand-new-model"])

        #expect(try store.unmappedModels().map(\.model) == ["brand-new-model"])
    }

    @Test func sourceStatsCountEventsAndSkippedLines() throws {
        let store = try UsageStore()
        try store.insert([row("a", at: utc("2026-10-12T01:00:00Z"))], cursor: FileCursor(path: "/a", inode: 1, mtime: 1000, skippedLines: 3, source: .claudeCode))
        try store.insert([row("b", source: .codex, at: utc("2026-10-12T01:00:00Z"))], cursor: FileCursor(path: "/b", inode: 2, skippedLines: 1, source: .codex))
        try store.insert([], cursor: FileCursor(path: "/c", inode: 3, skippedLines: 2, source: .codex))
        let stats = try store.sourceStats()
        #expect(stats[.claudeCode] == SourceStats(eventCount: 1, skippedLines: 3, filesTracked: 1, latestRead: Date(timeIntervalSince1970: 1000)))
        #expect(stats[.codex] == SourceStats(eventCount: 1, skippedLines: 3, filesTracked: 2))
    }

    @Test func retentionDeletesOldRecordsOnly() throws {
        let store = try UsageStore()
        try store.insert([
            row("old", at: utc("2024-01-01T00:00:00Z")),
            row("new", at: utc("2026-10-12T00:00:00Z")),
        ], cursor: FileCursor(path: "/a", inode: 1))
        #expect(try store.deleteEvents(before: utc("2025-10-12T00:00:00Z")) == 1)
        #expect(try store.totals().eventCount == 1)
        #expect(try store.cursor(forPath: "/a") != nil)
    }

    @Test func recalculationAppliesCurrentCloudAverageOnly() throws {
        let store = try UsageStore()
        let regional = GridIntensity(gramsPerKWh: 100, basis: .regionLive, region: "TEST")
        var live = try row("live", at: utc("2026-10-12T00:00:00Z"))
        live.apply(try TestSupport.calculator().estimate(model: live.model, tokens: live.tokens, grid: regional))
        try store.insert([row("cloud", at: utc("2026-10-12T00:00:00Z")), live], cursor: nil)

        let newGrid = GridIntensity(gramsPerKWh: 500, basis: .cloudAverage)
        try store.recalculateAll(with: EnergyCalculator.bundled(grid: newGrid))
        let rows = try store.events()
        let cloud = try #require(rows.first { $0.dedupeKey == "cloud" })
        let kept = try #require(rows.first { $0.dedupeKey == "live" })
        #expect(cloud.gridGPerKwh == 500)
        #expect(abs(cloud.co2GMid - cloud.energyWhMid / 1000 * 500) < 1e-9)
        #expect(kept.gridGPerKwh == 100)
        #expect(kept.gridBasis == "region_live")
    }

    @Test func ingestRecordsCursorSource() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let claude = dir.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: TestSupport.fixture("claude/session-b-resumed.jsonl"), to: claude.appendingPathComponent("b.jsonl"))
        let store = try UsageStore()
        let service = IngestService(store: store, calculator: try TestSupport.calculator(), locations: LogLocations(claudeCode: [claude], codex: []))
        _ = await service.scan()
        #expect(try store.allCursors().map(\.source) == [.claudeCode])
        #expect(try store.sourceStats()[.claudeCode]?.filesTracked == 1)
    }
}
