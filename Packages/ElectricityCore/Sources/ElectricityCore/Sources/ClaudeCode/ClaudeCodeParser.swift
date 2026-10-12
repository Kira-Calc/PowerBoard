import Foundation

/// Parses Claude Code session logs (SPEC 4.1). Stateless: every line is self-contained.
public enum ClaudeCodeParser {
    static let syntheticModel = "<synthetic>"

    public static func parse(line: Data) -> ParseOutcome {
        guard let object = ParsingSupport.jsonObject(line) else { return .skipped(.invalidJSON) }
        guard object["type"] as? String == "assistant" else { return .ignored }
        guard let message = object["message"] as? [String: Any] else { return .ignored }
        guard let usageValue = message["usage"] else { return .ignored }
        guard let usage = usageValue as? [String: Any] else { return .skipped(.unexpectedStructure) }

        guard let model = message["model"] as? String, !model.isEmpty else { return .skipped(.missingField) }
        if model == syntheticModel { return .ignored }

        guard
            let input = ParsingSupport.tokenCount(usage, "input_tokens"),
            let output = ParsingSupport.tokenCount(usage, "output_tokens"),
            let cacheWrite = ParsingSupport.tokenCount(usage, "cache_creation_input_tokens"),
            let cacheRead = ParsingSupport.tokenCount(usage, "cache_read_input_tokens")
        else { return .skipped(.unexpectedStructure) }

        let tokens = TokenCounts(inputUncached: input, cacheWrite: cacheWrite, cacheRead: cacheRead, output: output)
        if tokens.isZero { return .ignored }

        guard let timestamp = ParsingSupport.parseTimestamp(object["timestamp"]) else { return .skipped(.missingField) }
        guard let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else { return .skipped(.missingField) }

        let dedupeKey: String
        if let messageID = message["id"] as? String, !messageID.isEmpty,
           let requestID = object["requestId"] as? String, !requestID.isEmpty {
            dedupeKey = "\(messageID):\(requestID)"
        } else {
            dedupeKey = "sha256:" + ParsingSupport.sha256Hex(line)
        }

        return .usage(ParsedUsage(
            dedupeKey: dedupeKey,
            source: .claudeCode,
            sessionID: sessionID,
            projectPath: object["cwd"] as? String,
            model: model,
            timestamp: timestamp,
            tokens: tokens
        ))
    }
}
