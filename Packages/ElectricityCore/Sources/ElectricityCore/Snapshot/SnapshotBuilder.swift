import Foundation

/// Builds a `Snapshot` from the database.
public enum SnapshotBuilder {
    public static func build(
        store: UsageStore,
        now: Date = Date(),
        calendar: Calendar = .current,
        appRunning: Bool = true,
        includeLocalEnergy: Bool = false,
        grid: [GridProvider: GridStatus] = [:],
        dayWindow: DayWindow = .calendarDay
    ) throws -> Snapshot {
        // For the last 24 hours the end is a little past now, so records written this second are included.
        let window = dayWindow.interval(now: now, calendar: calendar)
        let day = dayWindow == .calendarDay ? window : DateInterval(start: window.start, end: now.addingTimeInterval(60))
        let totals = try store.totals(from: day.start, to: day.end)
        let bySource = try store.totalsBySource(from: day.start, to: day.end)

        var shares: [String: Snapshot.SourceShare] = [:]
        for source in UsageSource.allCases {
            shares[source.rawValue] = Snapshot.SourceShare(energyWhMid: bySource[source]?.energyWh.mid ?? 0)
        }

        var sessions: [String: Snapshot.Session] = [:]
        for summary in try store.sessions(activeSince: now.addingTimeInterval(-24 * 3600)) {
            sessions[summary.sessionID] = Snapshot.Session(
                source: summary.source.rawValue,
                energyWhMid: summary.energyWhMid,
                co2G: summary.co2GramsMid,
                tokensTotal: summary.tokensTotal,
                lastTs: summary.lastTimestamp
            )
        }

        // Buckets end at the current 5-minute boundary, so the last bucket is the one in progress.
        let bucketSeconds = 300
        let bucketEnd = (now.timeIntervalSince1970 / Double(bucketSeconds)).rounded(.down) * Double(bucketSeconds) + Double(bucketSeconds)
        let sparklineStart = Date(timeIntervalSince1970: bucketEnd - Double(bucketSeconds * Snapshot.sparklineBuckets))
        let sparkline = try store.energyBuckets(from: sparklineStart, bucketSeconds: bucketSeconds, count: Snapshot.sparklineBuckets)

        return Snapshot(
            generatedAt: now,
            appRunning: appRunning,
            today: Snapshot.Today(
                date: localDateString(now, calendar: calendar),
                tokens: Snapshot.Tokens(totals.tokens),
                energyWh: totals.energyWh,
                co2G: totals.co2GramsMid,
                cleanShare: nil,
                bySource: shares,
                localEnergyWh: includeLocalEnergy ? try store.localEnergy(from: day.start, to: day.end) : nil,
                grid: mainProvider(bySource: bySource).flatMap { grid[$0] }.map(Snapshot.Grid.init),
                window: dayWindow
            ),
            sessions: sessions,
            lastHourSparklineWh: sparkline
        )
    }

    /// The provider behind the tool that used the most energy today, or Anthropic when there is no usage.
    static func mainProvider(bySource: [UsageSource: UsageTotals]) -> GridProvider? {
        let top = bySource.max { $0.value.energyWh.mid < $1.value.energyWh.mid }?.key
        return GridProvider(source: top ?? .claudeCode)
    }

    static func localDateString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
