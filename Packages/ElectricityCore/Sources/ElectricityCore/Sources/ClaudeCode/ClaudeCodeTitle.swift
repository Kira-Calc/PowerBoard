import Foundation

/// Reads a display title for a Claude Code conversation from its log, at the user's request:
/// the AI-generated title (`"type": "ai-title"`, field `aiTitle`) when there is one, otherwise the first line of
/// the latest prompt (`"type": "last-prompt"`, field `lastPrompt`). Shown in the active conversations list only;
/// never stored or logged.
public enum ClaudeCodeTitle {
    public static let maxLength = 80

    /// Reads backwards in chunks and stops after `searchLimit` bytes, so long logs are not read whole.
    public static func latest(inLogAt url: URL, chunkSize: Int = 1 << 20, searchLimit: Int = 4 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard var end = try? handle.seekToEnd() else { return nil }
        let fileEnd = end
        let titleMarker = Data(#""ai-title""#.utf8)
        let promptMarker = Data(#""last-prompt""#.utf8)
        var prompt: String?
        var carry = Data()
        while end > 0, fileEnd - end < UInt64(searchLimit) {
            let start = end > UInt64(chunkSize) ? end - UInt64(chunkSize) : 0
            try? handle.seek(toOffset: start)
            guard var chunk = try? handle.read(upToCount: Int(end - start)) else { break }
            chunk.append(carry)
            // Lines in this chunk, newest first. The first line may be partial unless the chunk starts the file.
            var lines = chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            carry = start > 0 ? Data(lines.removeFirst()) : Data()
            for line in lines.reversed() {
                if line.range(of: titleMarker) != nil, let title = field(in: line, type: "ai-title", key: "aiTitle") {
                    return title
                }
                if prompt == nil, line.range(of: promptMarker) != nil {
                    prompt = field(in: line, type: "last-prompt", key: "lastPrompt")
                }
            }
            end = start
        }
        return prompt
    }

    private static func field(in line: Data.SubSequence, type: String, key: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == type,
              let value = object[key] as? String
        else { return nil }
        return clean(value)
    }

    /// First non-empty line, whitespace collapsed, shortened to `maxLength` characters.
    static func clean(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") })
            .first(where: { !$0.isEmpty })
        else { return nil }
        return line.count > maxLength ? String(line.prefix(maxLength - 1)) + "\u{2026}" : line
    }

    /// Finds `<sessionID>.jsonl` under the Claude Code project folders.
    public static func logURL(sessionID: String, roots: [URL]) -> URL? {
        for root in roots {
            guard let projects = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for project in projects {
                let candidate = project.appendingPathComponent("\(sessionID).jsonl")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}
