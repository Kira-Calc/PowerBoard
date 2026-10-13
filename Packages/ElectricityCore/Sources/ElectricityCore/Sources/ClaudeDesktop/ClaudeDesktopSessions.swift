import Foundation

/// Sessions of the Claude desktop app's Code tab, from its index files
/// (`~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json`).
/// Only these fields are read: the Claude Code session ID, title, working folder, last activity and archived flag.
public struct ClaudeDesktopSession: Sendable, Hashable {
    /// Claude Code session ID; its log is `~/.claude/projects/*/<id>.jsonl`.
    public var sessionID: String
    public var title: String?
    public var cwd: String?
    public var lastActivityAt: Date?
    public var isArchived: Bool

    public static var standardDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// Bundle identifier of the Claude desktop app, to bring it forward.
    public static let appBundleID = "com.anthropic.claudefordesktop"

    public static func read(directory: URL = standardDirectory) -> [ClaudeDesktopSession] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var sessions: [ClaudeDesktopSession] = []
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let session = parse(data) else { continue }
            sessions.append(session)
        }
        return sessions
    }

    static func parse(_ data: Data) -> ClaudeDesktopSession? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = object["cliSessionId"] as? String, !sessionID.isEmpty
        else { return nil }
        let activity = (object["lastActivityAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
        return ClaudeDesktopSession(sessionID: sessionID, title: title, cwd: object["cwd"] as? String,
                                    lastActivityAt: activity, isArchived: object["isArchived"] as? Bool ?? false)
    }
}
