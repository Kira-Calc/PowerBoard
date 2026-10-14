import Foundation

/// Raw cumulative or per-turn token usage as written by Codex.
public struct CodexTokenUsage: Sendable, Hashable, Codable {
    public var input: Int
    public var cachedInput: Int
    public var cacheWriteInput: Int
    public var output: Int
    public var reasoningOutput: Int

    public init(input: Int, cachedInput: Int, cacheWriteInput: Int = 0, output: Int, reasoningOutput: Int) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.output = output
        self.reasoningOutput = reasoningOutput
    }

    init?(_ dict: [String: Any]) {
        guard
            let input = ParsingSupport.tokenCount(dict, "input_tokens"),
            let cached = ParsingSupport.tokenCount(dict, "cached_input_tokens"),
            let cacheWrite = ParsingSupport.tokenCount(dict, "cache_write_input_tokens"),
            let output = ParsingSupport.tokenCount(dict, "output_tokens"),
            let reasoning = ParsingSupport.tokenCount(dict, "reasoning_output_tokens")
        else { return nil }
        self.init(input: input, cachedInput: cached, cacheWriteInput: cacheWrite, output: output, reasoningOutput: reasoning)
    }

    var isZero: Bool { input == 0 && output == 0 }

    /// True when any field is smaller than in `other`, which means the counter was reset.
    func hasDecrease(from other: CodexTokenUsage) -> Bool {
        input < other.input || cachedInput < other.cachedInput || cacheWriteInput < other.cacheWriteInput
            || output < other.output || reasoningOutput < other.reasoningOutput
    }

    static func - (lhs: CodexTokenUsage, rhs: CodexTokenUsage) -> CodexTokenUsage {
        CodexTokenUsage(
            input: lhs.input - rhs.input,
            cachedInput: lhs.cachedInput - rhs.cachedInput,
            cacheWriteInput: lhs.cacheWriteInput - rhs.cacheWriteInput,
            output: lhs.output - rhs.output,
            reasoningOutput: lhs.reasoningOutput - rhs.reasoningOutput
        )
    }

    /// Normalizes to `TokenCounts`. Cached and cache-write inputs are subsets of `input`;
    /// reasoning tokens are already included in `output` (verified against local logs, see DECISIONS.md).
    var tokenCounts: TokenCounts {
        TokenCounts(
            inputUncached: max(0, input - cachedInput - cacheWriteInput),
            cacheWrite: cacheWriteInput,
            cacheRead: cachedInput,
            output: output,
            reasoning: reasoningOutput
        )
    }
}

/// Per-file state carried between lines and persisted between incremental reads.
public struct CodexParserState: Sendable, Hashable, Codable {
    public var sessionID: String?
    public var cwd: String?
    public var model: String?
    /// The last `total_token_usage` seen in this file.
    public var lastTotal: CodexTokenUsage?
    /// Whether the latest task in this file is still running (`task_started` without `task_complete`).
    public var taskRunning: Bool?
    /// Time of the latest task event, as written in the log.
    public var taskEventAt: Date?
    /// Client from `session_meta.originator` (`UsageClient`).
    public var client: String?

    public init(sessionID: String? = nil, cwd: String? = nil, model: String? = nil, lastTotal: CodexTokenUsage? = nil) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.model = model
        self.lastTotal = lastTotal
    }
}

/// Parses Codex rollout logs (SPEC 4.2).
///
/// Usage for each `token_count` event is the increase of `total_token_usage` since the previous
/// event in the same file. Events whose total did not change are duplicates and are ignored.
/// The first event in a file, and any event after a counter reset, uses `last_token_usage` instead,
/// so that history inherited by a forked session is not counted again. See DECISIONS.md.
public enum CodexParser {
    static let unknownModel = "unknown"

    public static func parse(line: Data, filePath: String, lineNumber: Int, state: inout CodexParserState) -> ParseOutcome {
        guard let object = ParsingSupport.jsonObject(line) else { return .skipped(.invalidJSON) }
        guard let type = object["type"] as? String else { return .skipped(.missingField) }
        let payload = object["payload"] as? [String: Any]

        switch type {
        case "session_meta":
            guard let payload else { return .skipped(.unexpectedStructure) }
            if let id = (payload["id"] as? String) ?? (payload["session_id"] as? String) {
                state.sessionID = id
            }
            if let cwd = payload["cwd"] as? String { state.cwd = cwd }
            if let client = UsageClient.codex(originator: payload["originator"] as? String) { state.client = client }
            return .ignored

        case "turn_context":
            guard let payload else { return .skipped(.unexpectedStructure) }
            if let model = payload["model"] as? String, !model.isEmpty { state.model = model }
            if let cwd = payload["cwd"] as? String { state.cwd = cwd }
            return .ignored

        case "event_msg":
            guard let payload else { return .skipped(.unexpectedStructure) }
            switch payload["type"] as? String {
            case "task_started":
                state.taskRunning = true
                state.taskEventAt = ParsingSupport.parseTimestamp(object["timestamp"])
                return .ignored
            case "task_complete", "turn_aborted":
                state.taskRunning = false
                state.taskEventAt = ParsingSupport.parseTimestamp(object["timestamp"])
                return .ignored
            case "token_count":
                break
            default:
                return .ignored
            }
            return parseTokenCount(object: object, payload: payload, filePath: filePath, lineNumber: lineNumber, state: &state)

        default:
            // Other line types (messages, tool calls, reasoning) carry no usage we count.
            return .ignored
        }
    }

    private static func parseTokenCount(
        object: [String: Any],
        payload: [String: Any],
        filePath: String,
        lineNumber: Int,
        state: inout CodexParserState
    ) -> ParseOutcome {
        // `info` is null before the first model response of a session.
        guard let infoValue = payload["info"], !(infoValue is NSNull) else { return .ignored }
        guard
            let info = infoValue as? [String: Any],
            let lastDict = info["last_token_usage"] as? [String: Any],
            let totalDict = info["total_token_usage"] as? [String: Any],
            let last = CodexTokenUsage(lastDict),
            let total = CodexTokenUsage(totalDict)
        else { return .skipped(.unexpectedStructure) }

        let increment: CodexTokenUsage
        if let previous = state.lastTotal {
            if total == previous { return .ignored }
            increment = total.hasDecrease(from: previous) ? last : total - previous
        } else {
            increment = last
        }
        state.lastTotal = total

        if increment.isZero { return .ignored }
        guard let timestampString = object["timestamp"] as? String,
              let timestamp = ParsingSupport.parseTimestamp(timestampString)
        else { return .skipped(.missingField) }

        let sessionID = state.sessionID ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        return .usage(ParsedUsage(
            dedupeKey: "codex:" + ParsingSupport.sha256Hex("\(filePath)\n\(lineNumber)\n\(timestampString)"),
            source: .codex,
            sessionID: sessionID,
            projectPath: state.cwd,
            model: state.model ?? unknownModel,
            timestamp: timestamp,
            tokens: increment.tokenCounts,
            client: state.client
        ))
    }
}

/// The state of the latest task in the end of a Codex log, for showing a session as running or finished as soon as
/// the log changes, before the records reach the database.
///
/// Only the first bytes of each line are looked at: the line type and timestamp come before the payload, and a
/// `task_complete` line also carries the last reply, which is not read.
public enum CodexTaskState {
    static let prefixLength = 200

    /// Running or not, and when, from the last `task_started`, `task_complete` or `turn_aborted` line in `tail`.
    /// `tail` may start in the middle of a line; that line is skipped. Nil when no task event is found.
    public static func latest(inTail tail: Data) -> (running: Bool, at: Date?)? {
        let lines = tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated().reversed() {
            if index == 0 && tail.first != UInt8(ascii: "{") { continue }
            let head = String(decoding: line.prefix(prefixLength), as: UTF8.self)
            guard head.contains("\"type\":\"event_msg\"") else { continue }
            let running: Bool
            if head.contains("\"payload\":{\"type\":\"task_started\"") {
                running = true
            } else if head.contains("\"payload\":{\"type\":\"task_complete\"") || head.contains("\"payload\":{\"type\":\"turn_aborted\"") {
                running = false
            } else {
                continue
            }
            return (running, timestamp(in: head))
        }
        return nil
    }

    /// The value of `"timestamp":"…"` at the start of a line.
    private static func timestamp(in head: String) -> Date? {
        guard let key = head.range(of: "\"timestamp\":\""),
              let end = head[key.upperBound...].firstIndex(of: "\"") else { return nil }
        return ParsingSupport.parseTimestamp(String(head[key.upperBound..<end]))
    }
}
