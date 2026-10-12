import Foundation

/// Time scales for usage charts, as in the battery view of System Settings.
public enum ChartScale: String, Sendable, Hashable, CaseIterable {
    /// Today, one bucket per hour.
    case hour
    /// The last 14 days including today, one bucket per day.
    case day
    /// The last 12 weeks including this week, one bucket per week.
    case week

    /// Bucket boundaries in local time; `count + 1` dates, ascending. DST-safe.
    public func boundaries(now: Date, calendar: Calendar = .current) -> [Date] {
        switch self {
        case .hour:
            let day = LocalPeriod.day.interval(containing: now, calendar: calendar)
            var dates: [Date] = []
            var cursor = day.start
            while cursor < day.end {
                dates.append(cursor)
                cursor = calendar.date(byAdding: .hour, value: 1, to: cursor) ?? day.end
            }
            return dates + [day.end]
        case .day:
            return Self.steps(back: 13, component: .day, period: .day, now: now, calendar: calendar)
        case .week:
            return Self.steps(back: 11, component: .weekOfYear, period: .week, now: now, calendar: calendar)
        }
    }

    private static func steps(back: Int, component: Calendar.Component, period: LocalPeriod, now: Date, calendar: Calendar) -> [Date] {
        let current = period.interval(containing: now, calendar: calendar)
        return (0...(back + 1)).compactMap { offset in
            calendar.date(byAdding: component, value: offset - back, to: current.start)
        }
    }
}

/// Usage in one chart bucket.
public struct SeriesBucket: Sendable, Hashable, Identifiable {
    public var start: Date
    public var end: Date
    /// Server energy, mid estimate, Wh.
    public var serverWh: Double
    /// Measured energy of this Mac, Wh (zero when not recorded).
    public var localWh: Double
    public var tokens: TokenCounts
    /// Server energy (mid, Wh) per source. Sources without usage in the bucket are absent.
    public var serverWhBySource: [UsageSource: Double]
    /// Tokens per source. Sources without usage in the bucket are absent.
    public var tokensBySource: [UsageSource: TokenCounts]

    public var id: Date { start }
}

extension UsageStore {
    /// Usage per bucket between consecutive boundaries.
    public func series(boundaries: [Date], includeLocal: Bool) throws -> [SeriesBucket] {
        guard boundaries.count >= 2 else { return [] }
        return try zip(boundaries, boundaries.dropFirst()).map { start, end in
            let bySource = try totalsBySource(from: start, to: end)
            let tokens = bySource.values.reduce(TokenCounts.zero) { $0 + $1.tokens }
            return SeriesBucket(
                start: start,
                end: end,
                serverWh: bySource.values.reduce(0) { $0 + $1.energyWh.mid },
                localWh: includeLocal ? try localEnergy(from: start, to: end) : 0,
                tokens: tokens,
                serverWhBySource: bySource.mapValues(\.energyWh.mid),
                tokensBySource: bySource.mapValues(\.tokens)
            )
        }
    }
}
