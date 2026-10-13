import Foundation
import GRDB

/// Latest known task state of a session, from its log.
public struct SessionActivity: Sendable, Hashable {
    public var sessionID: String
    public var source: UsageSource
    public var projectPath: String?
    public var logPath: String
    public var running: Bool
    public var eventAt: Date

    public init(sessionID: String, source: UsageSource, projectPath: String?, logPath: String, running: Bool, eventAt: Date) {
        self.sessionID = sessionID
        self.source = source
        self.projectPath = projectPath
        self.logPath = logPath
        self.running = running
        self.eventAt = eventAt
    }
}

extension UsageStore {
    /// Saves the state unless a newer one is already stored.
    public func saveActivity(_ activity: SessionActivity) throws {
        try write { db in
            try db.execute(sql: """
                INSERT INTO session_activity (session_id, source, project_path, log_path, running, event_utc)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    source = excluded.source, project_path = excluded.project_path, log_path = excluded.log_path,
                    running = excluded.running, event_utc = excluded.event_utc
                WHERE excluded.event_utc >= session_activity.event_utc
                """, arguments: [
                    activity.sessionID, activity.source.rawValue, activity.projectPath, activity.logPath,
                    activity.running, Self.milliseconds(activity.eventAt),
                ])
        }
    }

    /// States with an event at or after `since`, most recent first.
    public func activities(since: Date) throws -> [SessionActivity] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT session_id, source, project_path, log_path, running, event_utc FROM session_activity
                WHERE event_utc >= ? ORDER BY event_utc DESC
                """, arguments: [Self.milliseconds(since)]).compactMap { row in
                guard let source = UsageSource(rawValue: row[1]) else { return nil }
                let ms: Int64 = row[5]
                return SessionActivity(sessionID: row[0], source: source, projectPath: row[2], logPath: row[3],
                                       running: row[4], eventAt: Date(timeIntervalSince1970: Double(ms) / 1000))
            }
        }
    }

    /// Client of each session ("CLI", "Desktop", "VS Code", …), for the sessions that have one.
    public func sessionClients(_ sessionIDs: [String]) throws -> [String: String] {
        guard !sessionIDs.isEmpty else { return [:] }
        return try read { db in
            let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
            var result: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT session_id, MAX(client) FROM usage_event WHERE session_id IN (\(placeholders)) AND client IS NOT NULL GROUP BY session_id",
                                        arguments: StatementArguments(sessionIDs)) {
                result[row[0]] = row[1]
            }
            return result
        }
    }

    /// Mid energy (Wh) per session for the given IDs.
    public func sessionEnergy(_ sessionIDs: [String]) throws -> [String: Double] {
        guard !sessionIDs.isEmpty else { return [:] }
        return try read { db in
            let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
            var result: [String: Double] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT session_id, SUM(energy_wh_mid) FROM usage_event WHERE session_id IN (\(placeholders)) GROUP BY session_id",
                                        arguments: StatementArguments(sessionIDs)) {
                result[row[0]] = row[1]
            }
            return result
        }
    }
}
