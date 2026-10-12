import Foundation

/// A running Claude Code process and its current state, from `~/.claude/sessions/<pid>.json`.
/// Reads process ID, session ID, working directory and status. The `name` field is not used: it is a short
/// label derived from the folder, not the conversation title (see `ClaudeCodeTitle`).
public struct LiveClaudeSession: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        /// Claude is working on a turn.
        case busy
        /// The turn is finished and Claude is waiting for the user.
        case idle
        /// Any other state Claude Code reports, such as waiting for permission.
        case other(String)
    }

    public var pid: Int32
    public var sessionID: String
    public var cwd: String?
    public var status: Status
    public var statusChangedAt: Date?

    /// Reads all session files in `directory`. Unreadable or unknown files are skipped.
    public static func read(directory: URL) -> [LiveClaudeSession] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            return parse(data)
        }
    }

    static func parse(_ data: Data) -> LiveClaudeSession? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value,
              let sessionID = object["sessionId"] as? String, !sessionID.isEmpty
        else { return nil }
        let status: Status
        switch object["status"] as? String {
        case "busy": status = .busy
        case "idle", nil: status = .idle
        case let other?: status = .other(other)
        }
        let changedMs = (object["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? (object["updatedAt"] as? NSNumber)?.doubleValue
        return LiveClaudeSession(
            pid: pid,
            sessionID: sessionID,
            cwd: object["cwd"] as? String,
            status: status,
            statusChangedAt: changedMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    public static var standardDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["CLAUDE_CONFIG_DIR"]?.split(separator: ",").first
            .map { URL(fileURLWithPath: (String($0).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent("sessions")
    }
}
