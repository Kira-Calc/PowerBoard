import Foundation
import Testing
@testable import ElectricityCore

@Suite struct TimeSeriesTests {
    private func utc(_ string: String) -> Date { try! Date(string, strategy: Date.ISO8601FormatStyle()) }

    private func calendar(_ id: String, firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: id)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    @Test func hourScaleCoversTodayIncludingDST() {
        let normal = ChartScale.hour.boundaries(now: utc("2026-10-12T05:00:00Z"), calendar: calendar("Asia/Shanghai"))
        #expect(normal.count == 25)
        #expect(normal.first == utc("2026-10-11T16:00:00Z"))
        let dst = ChartScale.hour.boundaries(now: utc("2026-11-01T15:00:00Z"), calendar: calendar("America/New_York"))
        #expect(dst.count == 26)
    }

    @Test func dayAndWeekScales() {
        let now = utc("2026-10-12T05:00:00Z") // Monday
        let days = ChartScale.day.boundaries(now: now, calendar: calendar("UTC"))
        #expect(days.count == 15)
        #expect(days.first == utc("2026-09-29T00:00:00Z"))
        #expect(days.last == utc("2026-10-13T00:00:00Z"))
        let weeks = ChartScale.week.boundaries(now: now, calendar: calendar("UTC"))
        #expect(weeks.count == 13)
        #expect(weeks[11] == utc("2026-10-12T00:00:00Z"))
        #expect(weeks.first == utc("2026-07-27T00:00:00Z"))
    }

    @Test func seriesSumsEachBucket() throws {
        let store = try UsageStore()
        let calc = try TestSupport.calculator()
        func row(_ key: String, _ date: String, output: Int, source: UsageSource = .claudeCode) -> UsageEventRow {
            let usage = ParsedUsage(dedupeKey: key, source: source, sessionID: "s", projectPath: nil, model: "sonnet",
                                    timestamp: utc(date), tokens: TokenCounts(inputUncached: 1, output: output))
            return UsageEventRow(usage: usage, result: calc.estimate(model: usage.model, tokens: usage.tokens))
        }
        try store.insert([
            row("a", "2026-10-11T10:00:00Z", output: 100),
            row("b", "2026-10-12T01:00:00Z", output: 200),
            row("c", "2026-10-12T02:00:00Z", output: 50, source: .codex),
        ], cursor: nil)
        try store.addLocalEnergy([UsageStore.milliseconds(utc("2026-10-12T01:00:00Z")): 2])
        let boundaries = ChartScale.day.boundaries(now: utc("2026-10-12T05:00:00Z"), calendar: calendar("UTC"))
        let series = try store.series(boundaries: boundaries, includeLocal: true)
        #expect(series.count == 14)
        #expect(series[12].tokens.output == 100)
        #expect(series[13].tokens.output == 250)
        #expect(series[13].tokensBySource[.codex]?.output == 50)
        #expect(series[13].tokensBySource[.antigravity] == nil)
        #expect(abs((series[13].serverWhBySource[.claudeCode] ?? 0) + (series[13].serverWhBySource[.codex] ?? 0) - series[13].serverWh) < 1e-9)
        #expect(series[13].localWh == 2)
        #expect(try store.series(boundaries: boundaries, includeLocal: false)[13].localWh == 0)
    }
}
