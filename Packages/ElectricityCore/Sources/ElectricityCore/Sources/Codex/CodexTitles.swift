import Foundation

/// Conversation titles from Codex's `session_index.jsonl`, the names shown in the Codex sidebar.
/// Only `id` and `thread_name` are read; renames append a new line, so the last one wins.
public enum CodexTitles {
    /// The index next to each Codex `sessions` folder.
    public static func indexURLs(sessionRoots: [URL]) -> [URL] {
        // `sessions` and `archived_sessions` share one index.
        var seen = Set<URL>()
        return sessionRoots.map { $0.deletingLastPathComponent().appendingPathComponent("session_index.jsonl") }
            .filter { seen.insert($0.standardizedFileURL).inserted }
    }

    public static func read(_ data: Data) -> [String: String] {
        struct Line: Decodable {
            var id: String
            var thread_name: String?
        }
        var titles: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONDecoder().decode(Line.self, from: Data(line)) else { continue }
            let name = entry.thread_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { titles[entry.id] = name }
        }
        return titles
    }
}
