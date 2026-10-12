import Foundation
import GRDB

extension UsageStore {
    /// Distinct grid intensities and factor versions used by records in the range.
    public func calculationContext(from start: Date, to end: Date) throws -> (grids: [Double], versions: [String]) {
        try read { db in
            let arguments: StatementArguments = [Self.milliseconds(start), Self.milliseconds(end)]
            let grids = try Double.fetchAll(db, sql: "SELECT DISTINCT grid_g_per_kwh FROM usage_event WHERE ts_utc >= ? AND ts_utc < ? ORDER BY 1", arguments: arguments)
            let versions = try String.fetchAll(db, sql: "SELECT DISTINCT factor_version FROM usage_event WHERE ts_utc >= ? AND ts_utc < ? ORDER BY 1", arguments: arguments)
            return (grids, versions)
        }
    }

    public func firstEventDate(from start: Date, to end: Date) throws -> Date? {
        try read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(ts_utc) FROM usage_event WHERE ts_utc >= ? AND ts_utc < ?",
                               arguments: [Self.milliseconds(start), Self.milliseconds(end)])
                .map { Date(timeIntervalSince1970: Double($0) / 1000) }
        }
    }

    /// The session with the longest span between its first and last record in the range.
    public func longestSession(from start: Date, to end: Date) throws -> YearSummary.LongestSession? {
        try read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT session_id, source, MIN(ts_utc), MAX(ts_utc), SUM(energy_wh_mid),
                       (SELECT project_path FROM usage_event e2 WHERE e2.session_id = e.session_id AND project_path IS NOT NULL LIMIT 1)
                FROM usage_event e WHERE ts_utc >= ? AND ts_utc < ?
                GROUP BY session_id, source
                ORDER BY MAX(ts_utc) - MIN(ts_utc) DESC
                LIMIT 1
                """, arguments: [Self.milliseconds(start), Self.milliseconds(end)]),
                let source = UsageSource(rawValue: row[1])
            else { return nil }
            let first: Int64 = row[2]
            let last: Int64 = row[3]
            return YearSummary.LongestSession(
                sessionID: row[0], source: source, projectPath: row[5],
                start: Date(timeIntervalSince1970: Double(first) / 1000),
                end: Date(timeIntervalSince1970: Double(last) / 1000),
                energyWhMid: row[4]
            )
        }
    }

    /// Records with `start <= ts < end`, oldest first.
    public func events(from start: Date, to end: Date) throws -> [UsageEventRow] {
        try read { db in
            try UsageEventRow
                .filter(Column("ts_utc") >= Self.milliseconds(start) && Column("ts_utc") < Self.milliseconds(end))
                .order(Column("ts_utc"))
                .fetchAll(db)
        }
    }
}
