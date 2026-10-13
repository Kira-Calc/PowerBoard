import AppKit
import Foundation
@testable import ElectricityCore
@testable import ElectricityReceipt

/// Hand-written receipt data. Model names and numbers are made up.
enum ReceiptFixtures {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }

    static func date(_ string: String) -> Date {
        try! Date(string, strategy: Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "Asia/Shanghai")!))
    }

    static let printedAt = date("2026-10-14T23:58:00+08:00")

    struct Line {
        var source: UsageSource
        var model: String
        var tokens: TokenCounts
        var wh: Double
    }

    static let standardLines: [Line] = [
        Line(source: .claudeCode, model: "opus-test", tokens: TokenCounts(inputUncached: 120_000, cacheWrite: 300_000, cacheRead: 1_300_000, output: 100_000), wh: 18.9),
        Line(source: .claudeCode, model: "haiku-test", tokens: TokenCounts(inputUncached: 50_000, cacheWrite: 40_000, cacheRead: 300_000, output: 20_000), wh: 1.2),
        Line(source: .codex, model: "gpt-test-codex", tokens: TokenCounts(inputUncached: 40_000, cacheWrite: 0, cacheRead: 600_000, output: 30_000), wh: 3.5),
    ]

    static func lines(count: Int) -> [Line] {
        (0..<count).map { index in
            Line(source: index.isMultiple(of: 2) ? .claudeCode : .codex, model: "model-\(index)",
                 tokens: TokenCounts(inputUncached: 1000 * (index + 1), output: 500), wh: Double(20 - index))
        }
    }

    /// Shares of the energy at each grid level in fixtures that record levels.
    static let gridShares: [GridLevel?: Double] = [.cleaner: 0.3, .typical: 0.45, .lessClean: 0.15, nil: 0.1]

    static func report(period: ReportPeriod, lines: [Line] = standardLines, projects: [String] = [], rolling: Bool = false,
                       gridLevels: Bool = true) -> Report {
        let interval = period.interval(containing: date("2026-10-14T12:00:00+08:00"), calendar: calendar)
        func item(_ key: String, _ source: UsageSource?, _ lines: [Line]) -> ReportBreakdownItem {
            let wh = lines.reduce(0) { $0 + $1.wh }
            return ReportBreakdownItem(key: key, source: source, tierConfidence: .measured, eventCount: lines.count,
                                       tokens: lines.reduce(TokenCounts.zero) { $0 + $1.tokens },
                                       energyWh: Estimate(low: wh * 0.5, mid: wh, high: wh * 1.75), co2GramsMid: wh * 0.4)
        }
        let total = item("", nil, lines)
        let sources = UsageSource.allCases.compactMap { source -> ReportBreakdownItem? in
            let mine = lines.filter { $0.source == source }
            return mine.isEmpty ? nil : item(source.rawValue, source, mine)
        }.sorted { $0.energyWh.mid > $1.energyWh.mid }
        let models = lines.map { item($0.model, $0.source, [$0]) }
        let boundaries = period.trendBoundaries(interval, calendar: calendar)
        let trend = zip(boundaries, boundaries.dropFirst()).enumerated().map { index, pair in
            SeriesBucket(start: pair.0, end: pair.1, serverWh: lines.isEmpty ? 0 : Double((index * 7) % 11 + 1),
                         localWh: 0, tokens: .zero, serverWhBySource: [:], tokensBySource: [:])
        }
        return Report(
            period: period, rolling: rolling, interval: interval, generatedAt: printedAt,
            totals: UsageTotals(eventCount: lines.count, tokens: total.tokens, energyWh: total.energyWh, co2GramsMid: total.co2GramsMid),
            previousTotals: .zero, bySource: sources, byModel: models, byToolModel: models,
            byProject: projects.map { item($0, nil, lines) }, trend: trend, peak: trend.max { $0.serverWh < $1.serverWh },
            sessionCount: 2, gridIntensities: [384], factorVersions: ["test"], energyMix: nil,
            energyByGridLevel: gridLevels && !lines.isEmpty ? gridShares.mapValues { $0 * total.energyWh.mid } : [:]
        )
    }

    static func model(_ report: Report, language: CLILanguageCode, items: [EquivalentItem]? = nil, customer: String? = nil) -> ReceiptModel {
        ReceiptModel(report: report, equivalents: items ?? (try! EquivalentCatalog.bundled().items), language: language,
                     serialNumber: 3, customer: customer, printedAt: printedAt, calendar: calendar)
    }

    static let logo = ReceiptLogo.placeholder(symbol: "bolt.fill")
}
