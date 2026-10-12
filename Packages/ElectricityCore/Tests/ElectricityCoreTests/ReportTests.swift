import Foundation
import Testing
@testable import ElectricityCore

@Suite struct ReportTests {
    private func utc(_ string: String) -> Date { try! Date(string, strategy: Date.ISO8601FormatStyle()) }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func row(_ key: String, _ date: String, session: String = "s1", source: UsageSource = .claudeCode,
                     model: String = "claude-sonnet-test", project: String? = "/tmp/example/alpha", output: Int = 1_000_000) throws -> UsageEventRow {
        let usage = ParsedUsage(dedupeKey: key, source: source, sessionID: session, projectPath: project, model: model,
                                timestamp: utc(date), tokens: TokenCounts(inputUncached: 10, output: output))
        return UsageEventRow(usage: usage, result: try TestSupport.calculator().estimate(model: model, tokens: usage.tokens))
    }

    private func makeStore() throws -> UsageStore {
        let store = try UsageStore()
        try store.insert([
            row("a", "2026-10-11T10:00:00Z", session: "s0", output: 500_000),        // previous day
            row("b", "2026-10-12T09:00:00Z"),
            row("c", "2026-10-12T15:30:00Z", model: "claude-opus-test"),
            row("d", "2026-10-12T15:45:00Z", session: "s2", source: .codex, model: "gpt-test", project: "/tmp/example/beta"),
            row("e", "2026-03-01T08:00:00Z", session: "s9", project: nil),
        ], cursor: nil)
        return store
    }

    @Test func periodsAndShifting() {
        let date = utc("2026-10-12T12:00:00Z")
        let week = ReportPeriod.week.interval(containing: date, calendar: calendar)
        #expect(week.start == utc("2026-10-12T00:00:00Z"))
        #expect(ReportPeriod.week.shifted(week, by: -1, calendar: calendar).start == utc("2026-10-05T00:00:00Z"))
        let month = ReportPeriod.month.interval(containing: date, calendar: calendar)
        #expect(ReportPeriod.month.trendBoundaries(month, calendar: calendar).count == 32)
        let year = ReportPeriod.year.interval(containing: date, calendar: calendar)
        #expect(ReportPeriod.year.trendBoundaries(year, calendar: calendar).count == 13)
        #expect(ReportPeriod.day.trendBoundaries(ReportPeriod.day.interval(containing: date, calendar: calendar), calendar: calendar).count == 25)
    }

    @Test func dayReportTotalsBreakdownsAndPeak() throws {
        let report = try ReportBuilder.build(store: makeStore(), period: .day, containing: utc("2026-10-12T12:00:00Z"), calendar: calendar)
        #expect(report.totals.eventCount == 3)
        #expect(report.sessionCount == 2)
        #expect(report.previousTotals.eventCount == 1)
        #expect(report.energyChange != nil)
        #expect(report.bySource.map(\.source) == [.claudeCode, .codex])
        #expect(report.byModel.first?.key == "claude-opus-test")
        #expect(Set(report.byProject.map(\.key)) == ["/tmp/example/alpha", "/tmp/example/beta"])
        // Two records at 15:xx make 15:00 the busiest hour.
        #expect(report.peak?.start == utc("2026-10-12T15:00:00Z"))
        #expect(report.trend.count == 24)
        #expect(report.gridIntensities == [287])
    }

    @Test func emptyPeriod() throws {
        let report = try ReportBuilder.build(store: makeStore(), period: .day, containing: utc("2026-01-01T12:00:00Z"), calendar: calendar)
        #expect(report.isEmpty)
        #expect(report.peak == nil)
        #expect(report.energyChange == nil)
        let markdown = ReportExporter.markdown(report, options: ExportOptions(language: .en), calendar: calendar)
        #expect(markdown.contains("No usage in this period."))
    }

    @Test func yearSummary() throws {
        let summary = try ReportBuilder.yearSummary(store: makeStore(), containing: utc("2026-10-12T12:00:00Z"), calendar: calendar,
                                                    now: utc("2026-10-12T12:00:00Z"))
        #expect(summary.year == 2026)
        #expect(summary.totals.eventCount == 5)
        #expect(summary.dataStart == utc("2026-03-01T00:00:00Z"))
        #expect(summary.daysCovered == 226)
        #expect(summary.topDay?.day == utc("2026-10-12T00:00:00Z"))
        #expect(summary.months.count == 12)
        #expect(summary.longestSession?.sessionID == "s1")
        #expect(summary.longestSession?.duration == 6.5 * 3600)
        #expect(summary.topModel != nil)
    }

    @Test func csvHasBOMEscapingAndHiddenProjects() throws {
        let store = try makeStore()
        var records = try store.events(from: utc("2026-10-12T00:00:00Z"), to: utc("2026-10-13T00:00:00Z"))
        records[0].projectPath = "/tmp/example/a,\"b\""
        let data = ReportExporter.csv(records, options: ExportOptions(language: .en))
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        let lines = text.split(separator: "\r\n")
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("timestamp_utc,source,session_id,project_path"))
        #expect(lines[1].contains(#""/tmp/example/a,""b""""#))
        let hidden = String(decoding: ReportExporter.csv(records, options: ExportOptions(language: .zh, hideProjects: true)), as: UTF8.self)
        #expect(!hidden.contains("/tmp/example"))
        #expect(hidden.contains("项目 1"))
    }

    @Test func jsonContainsSummaryAndRecords() throws {
        let store = try makeStore()
        let day = utc("2026-10-12T12:00:00Z")
        let report = try ReportBuilder.build(store: store, period: .day, containing: day, calendar: calendar)
        let records = try store.events(from: report.interval.start, to: report.interval.end)
        let data = try ReportExporter.json(report, records: records, options: ExportOptions(language: .en, hideProjects: true))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let summary = try #require(object["summary"] as? [String: Any])
        #expect(summary["events"] as? Int == 3)
        #expect((object["records"] as? [Any])?.count == 3)
        #expect(!String(decoding: data, as: UTF8.self).contains("/tmp/example"))
    }

    @Test func markdownInBothLanguages() throws {
        let report = try ReportBuilder.build(store: makeStore(), period: .day, containing: utc("2026-10-12T12:00:00Z"), calendar: calendar)
        let en = ReportExporter.markdown(report, options: ExportOptions(language: .en), calendar: calendar)
        #expect(en.hasPrefix("# Daily report: "))
        #expect(en.contains("| Claude Code |"))
        #expect(en.contains("| alpha |"))
        #expect(!en.contains("/tmp/example"))
        #expect(en.contains("METHODOLOGY.md"))
        let zh = ReportExporter.markdown(report, options: ExportOptions(language: .zh, hideProjects: true), calendar: calendar)
        #expect(zh.hasPrefix("# 日报："))
        #expect(zh.contains("项目 1"))
        #expect(zh.contains("估算值"))
    }
}
