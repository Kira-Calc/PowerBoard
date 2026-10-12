import Foundation
import GRDB

/// Usage totals for one session.
public struct SessionSummary: Sendable, Hashable {
    public var sessionID: String
    public var source: UsageSource
    public var projectPath: String?
    /// Model of the most recent record in the session.
    public var model: String
    public var energyWhMid: Double
    public var co2GramsMid: Double
    public var tokensTotal: Int
    public var lastTimestamp: Date
}

/// Records and skipped lines per source, for the data source settings page.
public struct SourceStats: Sendable, Hashable {
    public var eventCount: Int = 0
    public var skippedLines: Int = 0
    public var filesTracked: Int = 0
    /// Modification time of the most recently changed log file that has been read completely.
    public var latestRead: Date?

    public init(eventCount: Int = 0, skippedLines: Int = 0, filesTracked: Int = 0, latestRead: Date? = nil) {
        self.eventCount = eventCount
        self.skippedLines = skippedLines
        self.filesTracked = filesTracked
        self.latestRead = latestRead
    }
}

/// How the details table groups records (SPEC 9.3).
public enum UsageGrouping: String, Sendable, Hashable, CaseIterable {
    case session
    case project
    case model

    var column: String {
        switch self {
        case .session: "session_id"
        case .project: "COALESCE(project_path, '')"
        case .model: "model"
        }
    }
}

/// Aggregated usage for one group in the details table.
public struct UsageGroup: Sendable, Hashable, Identifiable {
    public var id: String { "\(source.rawValue)|\(key)" }
    /// Session ID, project path or model name. Empty for records without a project path.
    public var key: String
    public var source: UsageSource
    /// Model of the most recent record in the group.
    public var model: String
    public var tierConfidence: TierConfidence
    public var projectPath: String?
    public var eventCount: Int
    public var tokens: TokenCounts
    public var energyWh: Estimate
    public var co2GramsMid: Double
    public var firstTimestamp: Date
    public var lastTimestamp: Date
}

extension UsageStore {
    /// Totals per source for records with `start <= ts < end`. Sources without records are omitted.
    public func totalsBySource(from start: Date, to end: Date) throws -> [UsageSource: UsageTotals] {
        var result: [UsageSource: UsageTotals] = [:]
        for source in UsageSource.allCases {
            let totals = try totals(source: source, from: start, to: end)
            if totals.eventCount > 0 { result[source] = totals }
        }
        return result
    }

    /// Sessions with at least one record at or after `since`, most recent first.
    /// Totals cover the whole session, not only the window.
    public func sessions(activeSince since: Date, limit: Int? = nil) throws -> [SessionSummary] {
        try read { db in
            // SQLite returns bare columns (model, project_path) from the row that holds MAX(ts_utc).
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, source, SUM(energy_wh_mid), SUM(co2_g_mid),
                       SUM(input_uncached + cache_write + cache_read + output), MAX(ts_utc), model, project_path
                FROM usage_event
                WHERE session_id IN (SELECT DISTINCT session_id FROM usage_event WHERE ts_utc >= ?)
                GROUP BY session_id, source
                ORDER BY MAX(ts_utc) DESC
                \(limit.map { "LIMIT \($0)" } ?? "")
                """, arguments: [Self.milliseconds(since)])
            return rows.compactMap { row -> SessionSummary? in
                guard let source = UsageSource(rawValue: row[1]) else { return nil }
                let lastMs: Int64 = row[5]
                return SessionSummary(
                    sessionID: row[0],
                    source: source,
                    projectPath: row[7],
                    model: row[6],
                    energyWhMid: row[2],
                    co2GramsMid: row[3],
                    tokensTotal: row[4],
                    lastTimestamp: Date(timeIntervalSince1970: Double(lastMs) / 1000)
                )
            }
        }
    }

    /// Mid energy (Wh) per bucket of `bucketSeconds`, for `count` consecutive buckets starting at `start`.
    public func energyBuckets(from start: Date, bucketSeconds: Int, count: Int) throws -> [Double] {
        let startMs = Self.milliseconds(start)
        let bucketMs = Int64(bucketSeconds) * 1000
        let endMs = startMs + bucketMs * Int64(count)
        return try read { db in
            var buckets = Array(repeating: 0.0, count: count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT (ts_utc - ?) / ?, SUM(energy_wh_mid)
                FROM usage_event
                WHERE ts_utc >= ? AND ts_utc < ?
                GROUP BY 1
                """, arguments: [startMs, bucketMs, startMs, endMs])
            for row in rows {
                let index: Int = row[0]
                if buckets.indices.contains(index) { buckets[index] = row[1] }
            }
            return buckets
        }
    }

    /// Energy per local hour of the day containing `date`. Days with a daylight saving change have 23 or 25 hours.
    public func hourlyEnergy(dayContaining date: Date, calendar: Calendar = .current) throws -> [(start: Date, wh: Double)] {
        let day = LocalPeriod.day.interval(containing: date, calendar: calendar)
        let hours = Int((day.duration / 3600).rounded())
        let buckets = try energyBuckets(from: day.start, bucketSeconds: 3600, count: hours)
        return buckets.enumerated().map { (day.start.addingTimeInterval(Double($0.offset) * 3600), $0.element) }
    }

    public func sourceStats() throws -> [UsageSource: SourceStats] {
        try read { db in
            var result: [UsageSource: SourceStats] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT source, COUNT(*) FROM usage_event GROUP BY source") {
                guard let source = UsageSource(rawValue: row[0]) else { continue }
                result[source, default: SourceStats()].eventCount = row[1]
            }
            for row in try Row.fetchAll(db, sql: "SELECT source, SUM(skipped_lines), COUNT(*), MAX(mtime) FROM file_cursor WHERE source IS NOT NULL GROUP BY source") {
                guard let source = UsageSource(rawValue: row[0]) else { continue }
                result[source, default: SourceStats()].skippedLines = row[1]
                result[source, default: SourceStats()].filesTracked = row[2]
                let mtime: Double = row[3]
                if mtime > 0 { result[source, default: SourceStats()].latestRead = Date(timeIntervalSince1970: mtime) }
            }
            return result
        }
    }

    /// Records grouped for the details table, most recent first. Nil bounds are open.
    public func groupedUsage(by grouping: UsageGrouping, from start: Date? = nil, to end: Date? = nil) throws -> [UsageGroup] {
        try read { db in
            var conditions: [String] = []
            var arguments: StatementArguments = []
            if let start {
                conditions.append("ts_utc >= ?")
                arguments += [Self.milliseconds(start)]
            }
            if let end {
                conditions.append("ts_utc < ?")
                arguments += [Self.milliseconds(end)]
            }
            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            // SQLite returns bare columns (model, tier_confidence, project_path) from the row holding MAX(ts_utc)
            // only when MAX is the sole MIN/MAX aggregate, so first timestamps come from a second query.
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(grouping.column), source, MAX(ts_utc), model, tier_confidence, project_path, COUNT(*),
                       SUM(input_uncached), SUM(cache_write), SUM(cache_read), SUM(output), SUM(reasoning),
                       SUM(energy_wh_low), SUM(energy_wh_mid), SUM(energy_wh_high), SUM(co2_g_mid)
                FROM usage_event \(whereClause)
                GROUP BY 1, source
                ORDER BY MAX(ts_utc) DESC
                """, arguments: arguments)
            var firstSeen: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT \(grouping.column), source, MIN(ts_utc) FROM usage_event \(whereClause) GROUP BY 1, source
                """, arguments: arguments) {
                let key: String = row[0]
                let source: String = row[1]
                firstSeen["\(source)|\(key)"] = row[2]
            }
            return rows.compactMap { row -> UsageGroup? in
                guard let source = UsageSource(rawValue: row[1]) else { return nil }
                let key: String = row[0]
                let lastMs: Int64 = row[2]
                let firstMs = firstSeen["\(source.rawValue)|\(key)"] ?? lastMs
                return UsageGroup(
                    key: key,
                    source: source,
                    model: row[3],
                    tierConfidence: TierConfidence(rawValue: row[4]) ?? .unmapped,
                    projectPath: row[5],
                    eventCount: row[6],
                    tokens: TokenCounts(inputUncached: row[7], cacheWrite: row[8], cacheRead: row[9], output: row[10], reasoning: row[11]),
                    energyWh: Estimate(low: row[12], mid: row[13], high: row[14]),
                    co2GramsMid: row[15],
                    firstTimestamp: Date(timeIntervalSince1970: Double(firstMs) / 1000),
                    lastTimestamp: Date(timeIntervalSince1970: Double(lastMs) / 1000)
                )
            }
        }
    }

    /// Models that matched no tier rule, with their record counts (SPEC 5.3).
    public func unmappedModels() throws -> [(model: String, eventCount: Int)] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT model, COUNT(*) FROM usage_event WHERE tier_confidence = ? GROUP BY model ORDER BY COUNT(*) DESC
                """, arguments: [TierConfidence.unmapped.rawValue])
                .map { ($0[0], $0[1]) }
        }
    }

    /// Deletes records older than `date` (SPEC 6.2 retention). File cursors are kept so old lines are not read again.
    @discardableResult
    public func deleteEvents(before date: Date) throws -> Int {
        try write { db in
            try db.execute(sql: "DELETE FROM usage_event WHERE ts_utc < ?", arguments: [Self.milliseconds(date)])
            return db.changesCount
        }
    }
}
