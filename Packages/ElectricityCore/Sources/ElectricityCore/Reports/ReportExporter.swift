import Foundation

/// Options shared by all export formats (SPEC 12, 13).
public struct ExportOptions: Sendable, Hashable {
    public var language: CLILanguageCode
    /// Replaces project paths with "Project 1", "Project 2" and so on.
    public var hideProjects: Bool

    public init(language: CLILanguageCode, hideProjects: Bool = false) {
        self.language = language
        self.hideProjects = hideProjects
    }
}

/// Text exports: CSV of raw records, JSON of records and summary, and a Markdown report.
public enum ReportExporter {
    // MARK: CSV

    static let csvColumns = [
        "timestamp_utc", "source", "session_id", "project_path", "model", "tier", "tier_confidence",
        "input_uncached", "cache_write", "cache_read", "output", "reasoning",
        "energy_wh_low", "energy_wh_mid", "energy_wh_high", "co2_g_mid",
        "grid_g_per_kwh", "grid_basis", "grid_region", "factor_version",
    ]

    /// UTF-8 with a byte order mark, so Excel reads non-ASCII text correctly (SPEC 12).
    public static func csv(_ records: [UsageEventRow], options: ExportOptions) -> Data {
        let names = ProjectNames(hide: options.hideProjects, strings: ReportStrings(options.language))
        var lines = [csvColumns.joined(separator: ",")]
        let iso = Date.ISO8601FormatStyle()
        for record in records {
            let fields: [String] = [
                record.timestamp.formatted(iso), record.source, record.sessionId, names.name(record.projectPath) ?? "",
                record.model, record.tier, record.tierConfidence,
                String(record.inputUncached), String(record.cacheWrite), String(record.cacheRead), String(record.output), String(record.reasoning),
                number(record.energyWhLow), number(record.energyWhMid), number(record.energyWhHigh), number(record.co2GMid),
                number(record.gridGPerKwh), record.gridBasis, record.gridRegion ?? "", record.factorVersion,
            ]
            lines.append(fields.map(csvField).joined(separator: ","))
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func number(_ value: Double) -> String {
        String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // MARK: JSON

    private struct JSONExport: Encodable {
        struct Summary: Encodable {
            var period: String
            var start: Date
            var end: Date
            var events: Int
            var sessions: Int
            var tokens: Snapshot.Tokens
            var energyWh: Estimate
            var co2GMid: Double
            var previousEnergyWhMid: Double
            var bySource: [ReportBreakdownItem]
            var byModel: [ReportBreakdownItem]
            var byProject: [ReportBreakdownItem]

            enum CodingKeys: String, CodingKey {
                case period, start, end, events, sessions, tokens
                case energyWh = "energy_wh"
                case co2GMid = "co2_g_mid"
                case previousEnergyWhMid = "previous_energy_wh_mid"
                case bySource = "by_source"
                case byModel = "by_model"
                case byProject = "by_project"
            }
        }

        var generatedAt: Date
        var note: String
        var summary: Summary
        var records: [UsageEventRow]

        enum CodingKeys: String, CodingKey {
            case generatedAt = "generated_at"
            case note, summary, records
        }
    }

    public static func json(_ report: Report, records: [UsageEventRow], options: ExportOptions) throws -> Data {
        let strings = ReportStrings(options.language)
        let names = ProjectNames(hide: options.hideProjects, strings: strings)
        var records = records
        for index in records.indices { records[index].projectPath = names.name(records[index].projectPath) }
        let projects = report.byProject.map { item -> ReportBreakdownItem in
            var item = item
            item.key = names.name(item.key.isEmpty ? nil : item.key) ?? ""
            return item
        }
        let export = JSONExport(
            generatedAt: report.generatedAt,
            note: strings(.footer),
            summary: .init(
                period: report.period.rawValue, start: report.interval.start, end: report.interval.end,
                events: report.totals.eventCount, sessions: report.sessionCount,
                tokens: Snapshot.Tokens(report.totals.tokens), energyWh: report.totals.energyWh,
                co2GMid: report.totals.co2GramsMid, previousEnergyWhMid: report.previousTotals.energyWh.mid,
                bySource: report.bySource, byModel: report.byModel, byProject: projects
            ),
            records: records
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(export)
    }

    // MARK: Markdown

    public static func markdown(_ report: Report, options: ExportOptions, calendar: Calendar = .current) -> String {
        let t = ReportStrings(options.language)
        // Reports show folder names only (SPEC 13); raw CSV and JSON records keep full paths unless hidden.
        let names = ProjectNames(hide: options.hideProjects, strings: t, folderOnly: true)
        let energy = ValueFormatting.energy(report.totals.energyWh)
        var lines: [String] = []
        let colon = options.language == .zh ? "：" : ": "
        lines.append("# \(t(.title(report.period)))\(colon)\(t.periodLabel(report.period, report.interval, calendar: calendar))")
        lines.append("")
        guard !report.isEmpty else {
            lines += [t(.noUsage), "", "---", "", t(.footer)]
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("## \(t(.summary))")
        lines.append("")
        // Chinese text uses full-width punctuation.
        let zh = options.language == .zh
        let sep = zh ? "：" : ": "
        let comma = zh ? "，" : ", "
        func paren(_ text: String) -> String { zh ? "（\(text)）" : " (\(text))" }
        lines.append("- \(t(.energy))\(sep)\(energy.mid.text)" + paren("\(t(.range)) \(energy.low.text) – \(energy.high.text)"))
        lines.append("- \(t(.carbon))\(sep)\(ValueFormatting.carbon(grams: report.totals.co2GramsMid).text) CO2e")
        let tokens = report.totals.tokens
        let tokenParts = [
            "\(t(.input)) \(ValueFormatting.tokens(tokens.inputUncached))",
            "\(t(.output)) \(ValueFormatting.tokens(tokens.output))",
            "\(t(.cacheWrite)) \(ValueFormatting.tokens(tokens.cacheWrite))",
            "\(t(.cacheRead)) \(ValueFormatting.tokens(tokens.cacheRead))",
        ].joined(separator: comma)
        lines.append("- \(t(.tokens))\(sep)\(ValueFormatting.tokens(tokens.total))" + paren(tokenParts))
        lines.append("- \(t(.sessions))\(sep)\(report.sessionCount)")
        if let change = report.energyChange {
            lines.append("- \(t(.comparedWithPrevious))\(sep)\(change >= 0 ? "+" : "")\(String(format: "%.0f", change * 100))%")
        } else {
            lines.append("- \(t(.comparedWithPrevious))\(sep)\(t(.noPrevious))")
        }
        if let peak = report.peak {
            lines.append("- \(t(.peak))\(sep)\(peakLabel(peak, period: report.period, strings: t, calendar: calendar))"
                         + paren(ValueFormatting.energy(wh: peak.serverWh).text))
        }

        func table(_ title: String, _ header: [String], _ rows: [[String]]) {
            lines += ["", "## \(title)", "", "| " + header.joined(separator: " | ") + " |", "|" + header.map { _ in " --- " }.joined(separator: "|") + "|"]
            lines += rows.map { "| " + $0.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |" }
        }
        func values(_ item: ReportBreakdownItem) -> [String] {
            [ValueFormatting.energy(wh: item.energyWh.mid).text, ValueFormatting.carbon(grams: item.co2GramsMid).text, ValueFormatting.tokens(item.tokens.total)]
        }
        let columns = [t(.energyColumn), t(.carbonColumn), t(.tokensColumn)]
        table(t(.byTool), [t(.tool)] + columns, report.bySource.map { [t.sourceName($0.source)] + values($0) })
        table(t(.byModel), [t(.model), t(.tool), t(.confidence)] + columns,
              report.byModel.map { [$0.key, t.sourceName($0.source), t.confidence($0.tierConfidence)] + values($0) })
        table(t(.byProject), [t(.project)] + columns,
              report.byProject.map { [names.name($0.key.isEmpty ? nil : $0.key) ?? t(.unknownProject)] + values($0) })

        lines += ["", "## \(t(.method))", ""]
        lines += report.gridIntensities.map { t(.gridBasis(String(format: "%.0f", $0))) }
        lines += report.factorVersions.map { t(.factorVersion($0)) }
        lines += ["", "---", "", t(.footer)]
        return lines.joined(separator: "\n") + "\n"
    }

    public static func peakLabel(_ bucket: SeriesBucket, period: ReportPeriod, strings: ReportStrings, calendar: Calendar) -> String {
        var calendar = calendar
        calendar.locale = strings.locale
        let base = Date.FormatStyle(locale: strings.locale, calendar: calendar, timeZone: calendar.timeZone)
        switch period {
        case .day: return "\(bucket.start.formatted(base.hour().minute())) – \(bucket.end.formatted(base.hour().minute()))"
        case .week, .month: return bucket.start.formatted(base.month().day().weekday())
        case .year: return bucket.start.formatted(base.year().month(.wide))
        }
    }

    /// Hides project paths behind stable numbered names when requested; otherwise shows the folder name.
    final class ProjectNames {
        private let hide: Bool
        private let folderOnly: Bool
        private let strings: ReportStrings
        private var numbers: [String: Int] = [:]

        init(hide: Bool, strings: ReportStrings, folderOnly: Bool = false) {
            self.hide = hide
            self.folderOnly = folderOnly
            self.strings = strings
        }

        func name(_ path: String?) -> String? {
            guard let path, !path.isEmpty else { return nil }
            guard hide else { return folderOnly ? URL(fileURLWithPath: path).lastPathComponent : path }
            if numbers[path] == nil { numbers[path] = numbers.count + 1 }
            return "\(strings(.hiddenProject)) \(numbers[path]!)"
        }
    }
}
