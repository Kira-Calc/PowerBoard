import Foundation

/// Report periods (SPEC 9.2).
public enum ReportPeriod: String, Sendable, Hashable, CaseIterable, Codable {
    case day
    case week
    case month
    case year

    var localPeriod: LocalPeriod {
        switch self {
        case .day: .day
        case .week: .week
        case .month: .month
        case .year: .year
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    public func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        localPeriod.interval(containing: date, calendar: calendar)
    }

    /// The same kind of period, `offset` periods away (negative for earlier).
    public func shifted(_ interval: DateInterval, by offset: Int, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.date(byAdding: component, value: offset, to: interval.start) ?? interval.start
        return self.interval(containing: start, calendar: calendar)
    }

    /// Trend buckets: hours of a day, days of a week or month, months of a year.
    public func trendBoundaries(_ interval: DateInterval, calendar: Calendar = .current) -> [Date] {
        let step: Calendar.Component = switch self {
        case .day: .hour
        case .week, .month: .day
        case .year: .month
        }
        var dates: [Date] = []
        var cursor = interval.start
        while cursor < interval.end {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: step, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return dates + [interval.end]
    }
}

/// Totals for one item of a breakdown (a tool, a model or a project).
public struct ReportBreakdownItem: Sendable, Hashable, Codable {
    public var key: String
    public var source: UsageSource?
    public var tierConfidence: TierConfidence?
    public var eventCount: Int
    public var tokens: TokenCounts
    public var energyWh: Estimate
    public var co2GramsMid: Double
}

/// Everything shown in a report and written by the exporters.
public struct Report: Sendable, Hashable {
    public var period: ReportPeriod
    public var interval: DateInterval
    public var generatedAt: Date
    public var totals: UsageTotals
    public var previousTotals: UsageTotals
    public var bySource: [ReportBreakdownItem]
    public var byModel: [ReportBreakdownItem]
    /// Keyed by full project path; empty key for records without one.
    public var byProject: [ReportBreakdownItem]
    public var trend: [SeriesBucket]
    /// The trend bucket with the most energy, if any energy was used.
    public var peak: SeriesBucket?
    public var sessionCount: Int
    /// Grid intensity values used by the records (usually one).
    public var gridIntensities: [Double]
    public var factorVersions: [String]

    /// Change of mid energy compared with the previous period, or nil when the previous period had none.
    public var energyChange: Double? {
        guard previousTotals.energyWh.mid > 0 else { return nil }
        return totals.energyWh.mid / previousTotals.energyWh.mid - 1
    }

    public var isEmpty: Bool { totals.eventCount == 0 }
}

/// Year in review (SPEC 9.2).
public struct YearSummary: Sendable, Hashable {
    public struct TopDay: Sendable, Hashable {
        public var day: Date
        public var energyWhMid: Double
        public var tokens: Int
    }

    public struct LongestSession: Sendable, Hashable {
        public var sessionID: String
        public var source: UsageSource
        public var projectPath: String?
        public var start: Date
        public var end: Date
        public var energyWhMid: Double

        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    public var year: Int
    public var interval: DateInterval
    public var totals: UsageTotals
    /// First record in the year, when the data does not cover the whole year.
    public var dataStart: Date?
    /// Days covered by data: from `dataStart` (or 1 January) to the end of the year or today.
    public var daysCovered: Int
    public var topDay: TopDay?
    public var topModel: ReportBreakdownItem?
    public var longestSession: LongestSession?
    public var months: [SeriesBucket]
}

public enum ReportBuilder {
    public static func build(
        store: UsageStore,
        period: ReportPeriod,
        containing date: Date,
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> Report {
        let interval = period.interval(containing: date, calendar: calendar)
        let previous = period.shifted(interval, by: -1, calendar: calendar)
        let totals = try store.totals(from: interval.start, to: interval.end)
        let trend = try store.series(boundaries: period.trendBoundaries(interval, calendar: calendar), includeLocal: false)

        let bySource = try store.totalsBySource(from: interval.start, to: interval.end)
            .sorted { $0.value.energyWh.mid > $1.value.energyWh.mid }
            .map { source, totals in
                ReportBreakdownItem(key: source.rawValue, source: source, tierConfidence: nil, eventCount: totals.eventCount,
                                    tokens: totals.tokens, energyWh: totals.energyWh, co2GramsMid: totals.co2GramsMid)
            }
        let models = try store.groupedUsage(by: .model, from: interval.start, to: interval.end)
        let projects = try store.groupedUsage(by: .project, from: interval.start, to: interval.end)
        let sessions = try store.groupedUsage(by: .session, from: interval.start, to: interval.end)
        let context = try store.calculationContext(from: interval.start, to: interval.end)

        return Report(
            period: period,
            interval: interval,
            generatedAt: now,
            totals: totals,
            previousTotals: try store.totals(from: previous.start, to: previous.end),
            bySource: bySource,
            byModel: merge(models, keepSource: true),
            byProject: merge(projects, keepSource: false),
            trend: trend,
            peak: trend.filter { $0.serverWh > 0 }.max { $0.serverWh < $1.serverWh },
            sessionCount: sessions.count,
            gridIntensities: context.grids,
            factorVersions: context.versions
        )
    }

    /// Combines groups with the same key across sources, largest energy first.
    static func merge(_ groups: [UsageGroup], keepSource: Bool) -> [ReportBreakdownItem] {
        var items: [String: ReportBreakdownItem] = [:]
        for group in groups {
            var item = items[group.key] ?? ReportBreakdownItem(
                key: group.key, source: group.source, tierConfidence: group.tierConfidence,
                eventCount: 0, tokens: .zero, energyWh: .zero, co2GramsMid: 0
            )
            if item.source != group.source { item.source = keepSource ? item.source : nil }
            item.eventCount += group.eventCount
            item.tokens = item.tokens + group.tokens
            item.energyWh = item.energyWh + group.energyWh
            item.co2GramsMid += group.co2GramsMid
            items[group.key] = item
        }
        return items.values.sorted { $0.energyWh.mid > $1.energyWh.mid }
    }

    public static func yearSummary(store: UsageStore, containing date: Date, calendar: Calendar = .current, now: Date = Date()) throws -> YearSummary {
        let interval = ReportPeriod.year.interval(containing: date, calendar: calendar)
        let totals = try store.totals(from: interval.start, to: interval.end)
        let first = try store.firstEventDate(from: interval.start, to: interval.end)
        let dataStart = first.flatMap { calendar.isDate($0, inSameDayAs: interval.start) ? nil : calendar.startOfDay(for: $0) }
        let coverageEnd = min(interval.end, LocalPeriod.day.interval(containing: now, calendar: calendar).end)
        let daysCovered = max(0, calendar.dateComponents([.day], from: dataStart ?? interval.start, to: coverageEnd).day ?? 0)

        let dayBoundaries = ReportPeriod.month.trendBoundaries(DateInterval(start: interval.start, end: interval.end), calendar: calendar)
        let days = try store.series(boundaries: dayBoundaries, includeLocal: false)
        let topDay = days.filter { $0.serverWh > 0 }.max { $0.serverWh < $1.serverWh }
            .map { YearSummary.TopDay(day: $0.start, energyWhMid: $0.serverWh, tokens: $0.tokens.total) }

        let models = merge(try store.groupedUsage(by: .model, from: interval.start, to: interval.end), keepSource: true)
        return YearSummary(
            year: calendar.component(.year, from: interval.start),
            interval: interval,
            totals: totals,
            dataStart: dataStart,
            daysCovered: daysCovered,
            topDay: topDay,
            topModel: models.max { $0.tokens.total < $1.tokens.total },
            longestSession: try store.longestSession(from: interval.start, to: interval.end),
            months: try store.series(boundaries: ReportPeriod.year.trendBoundaries(interval, calendar: calendar), includeLocal: false)
        )
    }
}
