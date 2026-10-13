import Foundation

/// Chooses the receipt's "equivalent to" lines (appendix R6): the anchor item first (the microwave), then up to
/// two more by the usual rule, one appliance and one food when possible. Without an anchor item it falls back to
/// the usual rule for all three.
public enum ReceiptEquivalents {
    public static func select(energyWh: Double, items: [EquivalentItem], enabledIDs: Set<String>? = nil) -> [EquivalentMatch] {
        guard energyWh > 0 else { return [] }
        guard let anchor = items.first(where: { $0.receiptAnchor && $0.wh > 0 }) else {
            return EquivalentSelector.select(energyWh: energyWh, items: items, enabledIDs: enabledIDs, limit: 3)
        }
        let rest = EquivalentSelector.select(energyWh: energyWh, items: items.filter { $0.id != anchor.id },
                                             enabledIDs: enabledIDs, limit: 2)
        return [EquivalentMatch(item: anchor, count: energyWh / anchor.wh)] + rest
    }
}

/// Everything a receipt shows, already worded and formatted for one language (appendix R3.2).
/// Built from a report; the view only lays it out.
public struct ReceiptModel: Sendable, Hashable {
    public struct Row: Sendable, Hashable {
        public var name: String
        public var tokens: String
        public var energyWh: String

        public init(name: String, tokens: String, energyWh: String) {
            self.name = name
            self.tokens = tokens
            self.energyWh = energyWh
        }
    }

    public struct Group: Sendable, Hashable {
        public var tool: String
        public var rows: [Row]
    }

    /// A line in "equivalent to": the text on the left, the number and unit on the right.
    public struct Equivalent: Sendable, Hashable {
        public var label: String
        public var value: String
        public var isFood: Bool
    }

    public struct TokenMix: Sendable, Hashable {
        public var input: String
        public var output: String
        public var cacheWrite: String
        public var cacheRead: String
        /// Shares of input, output, cache write and cache read; all zero when there were no tokens.
        public var shares: [Double]
    }

    public struct Bars: Sendable, Hashable {
        public var title: String
        /// Mid energy per bar, in Wh.
        public var values: [Double]
        public var firstLabel: String
        public var lastLabel: String
        public var peakLabel: String
    }

    /// Rows shown in the detail before the rest are folded into "N others".
    public static let maxDetailRows = 8
    /// Longest name the customer line takes (appendix R2.2).
    public static let maxCustomerLength = 16

    public var language: CLILanguageCode
    public var strings: ReceiptStrings { ReceiptStrings(language) }

    // Header and document information.
    public var productName: String
    public var customer: String?
    public var serial: String
    public var kind: String
    public var period: String
    public var timeZone: String
    public var printed: String
    public var cashier: String

    /// Nil on a year receipt, which lists only the months and the total.
    public var groups: [Group]?
    public var others: Row?
    public var tokenMix: TokenMix?
    public var energy: Estimate
    public var energySubtotal: String
    public var energyRange: String
    public var carbon: String
    public var basis: String
    /// Grid cleanliness (M7): the level most of the energy ran at, or the clean share of the estimated mix.
    public var cleanliness: String?
    public var bars: Bars?
    /// Nil on a year receipt.
    public var equivalents: [Equivalent]?
    /// Shown instead of the equivalents when nothing was used.
    public var emptyNote: String?
    public var totalEnergy: String
    public var totalCarbon: String
    public var showsFoodNote: Bool
    /// Encoded in the QR code. Only the repository address, never usage data (appendix R9). Nil hides the code.
    public var qrPayload: String?

    public var isEmpty: Bool { energy.mid <= 0 }

    public init(
        report: Report,
        equivalents items: [EquivalentItem],
        enabledEquivalentIDs: Set<String>? = nil,
        language: CLILanguageCode,
        serialNumber: Int,
        customer: String? = nil,
        showsQRCode: Bool = true,
        printedAt: Date,
        calendar: Calendar = .current
    ) {
        let strings = ReceiptStrings(language)
        let reportStrings = ReportStrings(language)
        self.language = language
        productName = AppIdentity.displayName.uppercased()
        let name = customer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.customer = name.isEmpty ? nil : String(name.prefix(Self.maxCustomerLength))
        serial = Self.serial(serialNumber, at: printedAt, calendar: calendar)
        kind = reportStrings.title(report)
        period = Self.periodText(report, calendar: calendar)
        timeZone = calendar.timeZone.abbreviation(for: report.interval.start) ?? calendar.timeZone.identifier
        printed = Self.format(printedAt, "yyyy-MM-dd HH:mm", calendar: calendar)
        cashier = "\(AppIdentity.cliName) \(AppIdentity.version)"

        let isYear = report.period == .year
        energy = report.totals.energyWh
        let formatted = ValueFormatting.energy(report.totals.energyWh)
        energySubtotal = formatted.mid.text
        energyRange = "\(formatted.low.number)–\(formatted.high.number) \(formatted.mid.unit)"
        let carbonValue = ValueFormatting.carbon(grams: report.totals.co2GramsMid)
        carbon = carbonValue.text
        basis = strings(.basisGridAverage)
        cleanliness = Self.cleanliness(report, strings: strings, reportStrings: reportStrings)
        totalEnergy = formatted.mid.text
        totalCarbon = "\(carbonValue.text) CO2"
        qrPayload = showsQRCode ? AppIdentity.repositoryURL : nil

        if isYear {
            groups = nil
            others = nil
            tokenMix = nil
            equivalents = nil
            emptyNote = nil
            showsFoodNote = false
        } else {
            (groups, others) = Self.detail(report, strings: strings)
            tokenMix = Self.tokenMix(report.totals.tokens)
            let matches = ReceiptEquivalents.select(energyWh: report.totals.energyWh.mid, items: items, enabledIDs: enabledEquivalentIDs)
            let lines = matches.map { Self.equivalent($0, language: language) }
            equivalents = lines
            emptyNote = lines.isEmpty ? strings(report.period == .day ? .noUsageToday : .noUsagePeriod) : nil
            showsFoodNote = lines.contains { $0.isFood }
        }
        bars = Self.bars(report, strings: strings, calendar: calendar)
    }

    // MARK: Building

    /// "2026-1014-0003": the print date and a number counted per day.
    static func serial(_ number: Int, at date: Date, calendar: Calendar) -> String {
        format(date, "yyyy-MMdd", calendar: calendar) + "-" + String(format: "%04d", max(0, number) % 10_000)
    }

    static func periodText(_ report: Report, calendar: Calendar) -> String {
        let start = report.interval.start
        // The last moment inside the period, so a day reads 00:00–23:59 and a week ends on its last day.
        let last = report.interval.end.addingTimeInterval(-60)
        if report.rolling {
            if report.period == .day || report.period == .week {
                return format(start, "MM-dd HH:mm", calendar: calendar) + "–" + format(report.interval.end, "MM-dd HH:mm", calendar: calendar)
            }
            return format(start, "yyyy-MM-dd", calendar: calendar) + " – " + format(report.interval.end, "yy-MM-dd", calendar: calendar)
        }
        switch report.period {
        case .day:
            return format(start, "yyyy-MM-dd HH:mm", calendar: calendar) + "–" + format(last, "HH:mm", calendar: calendar)
        case .week, .month, .year:
            // Spaces around the dash, or "2026-10-12–10-18" reads as one date.
            return format(start, "yyyy-MM-dd", calendar: calendar) + " – " + format(last, "MM-dd", calendar: calendar)
        }
    }

    /// The models with the most energy, grouped under their tools; the rest folded into one row.
    static func detail(_ report: Report, strings: ReceiptStrings) -> ([Group], Row?) {
        let items = report.byToolModel.sorted { $0.energyWh.mid > $1.energyWh.mid }
        let shown = items.prefix(maxDetailRows)
        let toolOrder = report.bySource.compactMap(\.source)
        var groups: [Group] = []
        for source in toolOrder + UsageSource.allCases.filter({ !toolOrder.contains($0) }) {
            let rows = shown.filter { $0.source == source }.map { row($0, language: strings.language) }
            if !rows.isEmpty { groups.append(Group(tool: strings.report.sourceName(source), rows: rows)) }
        }
        let rest = items.dropFirst(maxDetailRows)
        guard !rest.isEmpty else { return (groups, nil) }
        let tokens = rest.reduce(0) { $0 + $1.tokens.total }
        let wh = rest.reduce(0) { $0 + $1.energyWh.mid }
        return (groups, Row(name: strings(.others(rest.count)), tokens: ValueFormatting.tokens(tokens),
                            energyWh: energyWh(wh, language: strings.language)))
    }

    static func row(_ item: ReportBreakdownItem, language: CLILanguageCode) -> Row {
        Row(name: item.key.isEmpty ? "-" : item.key, tokens: ValueFormatting.tokens(item.tokens.total),
            energyWh: energyWh(item.energyWh.mid, language: language))
    }

    /// The detail column is always in Wh, as its heading says, with the language's thousands separator.
    static func energyWh(_ wh: Double, language: CLILanguageCode) -> String {
        let decimals = wh < 1 ? 2 : wh < 10 ? 1 : 0
        let locale = Locale(identifier: language == .zh ? "zh-Hans" : "en")
        return wh.formatted(.number.locale(locale).precision(.fractionLength(decimals)).grouping(.automatic))
    }

    static func tokenMix(_ tokens: TokenCounts) -> TokenMix {
        let parts = [tokens.inputUncached, tokens.output, tokens.cacheWrite, tokens.cacheRead].map(Double.init)
        let total = parts.reduce(0, +)
        return TokenMix(
            input: ValueFormatting.tokens(tokens.inputUncached),
            output: ValueFormatting.tokens(tokens.output),
            cacheWrite: ValueFormatting.tokens(tokens.cacheWrite),
            cacheRead: ValueFormatting.tokens(tokens.cacheRead),
            shares: parts.map { total > 0 ? $0 / total : 0 }
        )
    }

    static func cleanliness(_ report: Report, strings: ReceiptStrings, reportStrings: ReportStrings) -> String? {
        if report.hasGridLevels,
           let level = report.energyByGridLevel.filter({ $0.key != nil }).max(by: { $0.value < $1.value })?.key {
            return reportStrings(.gridLevel(level))
        }
        if let mix = report.energyMix, mix.totalWh > 0 {
            return strings(.cleanShare(Int((mix.cleanShare * 100).rounded())))
        }
        return nil
    }

    /// Daily bars on week and month receipts, monthly bars on year receipts; none on a day receipt.
    static func bars(_ report: Report, strings: ReceiptStrings, calendar: Calendar) -> Bars? {
        guard report.period != .day, let first = report.trend.first, let last = report.trend.last else { return nil }
        let values = report.trend.map(\.serverWh)
        let isYear = report.period == .year
        let labelFormat = isYear ? (strings.language == .zh ? "M月" : "MMM") : "MM-dd"
        let peak = ValueFormatting.energy(wh: values.max() ?? 0).text
        return Bars(
            title: strings(isYear ? .monthlyEnergy : .dailyEnergy),
            values: values,
            firstLabel: format(first.start, labelFormat, calendar: calendar, language: strings.language),
            lastLabel: format(last.start, labelFormat, calendar: calendar, language: strings.language),
            peakLabel: strings(.peakDay(peak))
        )
    }

    static func equivalent(_ match: EquivalentMatch, language: CLILanguageCode) -> Equivalent {
        let template = match.item.receiptLabel?[language.rawValue] ?? "\(match.item.id) %@"
        let parts = template.components(separatedBy: "%@")
        let label = parts[0].trimmingCharacters(in: .whitespaces)
        let suffix = parts.count > 1 ? parts[1] : ""
        return Equivalent(label: label, value: ReceiptText.amount(match.count, language: language) + suffix,
                          isFood: match.item.kind == .food)
    }

    static func format(_ date: Date, _ pattern: String, calendar: Calendar, language: CLILanguageCode = .en) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: language == .zh ? "zh_Hans" : "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
