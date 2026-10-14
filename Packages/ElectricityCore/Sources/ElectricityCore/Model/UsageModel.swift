import Foundation

/// An estimated quantity with its uncertainty range. Estimates are never passed as a bare Double.
public struct Estimate: Sendable, Hashable, Codable {
    public var low: Double
    public var mid: Double
    public var high: Double

    public init(low: Double, mid: Double, high: Double) {
        self.low = low
        self.mid = mid
        self.high = high
    }

    public static let zero = Estimate(low: 0, mid: 0, high: 0)

    public static func + (lhs: Estimate, rhs: Estimate) -> Estimate {
        Estimate(low: lhs.low + rhs.low, mid: lhs.mid + rhs.mid, high: lhs.high + rhs.high)
    }

    /// Applies the same factor to all three values.
    public func scaled(by factor: Double) -> Estimate {
        Estimate(low: low * factor, mid: mid * factor, high: high * factor)
    }
}

/// The AI tool that produced a usage record.
public enum UsageSource: String, Sendable, Codable, CaseIterable {
    case claudeCode = "claude_code"
    /// Claude desktop app: Cowork (local agent mode) and, when it writes its own logs, the Code tab.
    case claudeDesktop = "claude_desktop"
    case codex = "codex"
    case antigravity = "antigravity"
}

/// Which client of a tool wrote a record, from the log's own metadata. Shown as a plain label, the same in every
/// language: "CLI", "Desktop", "VS Code", "SDK", and for the Claude desktop app "Code" (its Code tab) and "Cowork".
public enum UsageClient {
    public static let cli = "CLI"
    public static let desktop = "Desktop"
    public static let vscode = "VS Code"
    public static let sdk = "SDK"
    public static let cowork = "Cowork"
    /// The Code tab of the Claude desktop app.
    public static let desktopCode = "Code"
    /// Ordinary chat in the Claude desktop app. It writes no usage records; only its activity is shown.
    public static let chat = "Chat"

    /// Claude Code `entrypoint`: "cli", "sdk-ts", "claude-vscode", "local-agent" (Cowork), "claude-desktop" (Code tab), …
    public static func claude(entrypoint: String?) -> String? {
        guard let value = entrypoint?.lowercased(), !value.isEmpty else { return nil }
        if value == "local-agent" { return cowork }
        if value.contains("desktop") { return desktopCode }
        if value.contains("vscode") || value.contains("ide") { return vscode }
        if value.hasPrefix("sdk") { return sdk }
        if value == "cli" { return cli }
        return nil
    }

    /// Codex `session_meta.originator`: "codex_cli_rs", "codex_exec", "Codex Desktop", "codex_work_desktop",
    /// "codex_vscode", "codex_sdk_ts", …
    public static func codex(originator: String?) -> String? {
        guard let value = originator?.lowercased(), !value.isEmpty else { return nil }
        if value.contains("desktop") { return desktop }
        if value.contains("vscode") { return vscode }
        if value.contains("sdk") { return sdk }
        return cli
    }

    /// Claude records from the desktop app belong to the Claude Desktop source, wherever their file is.
    public static func claudeSource(entrypoint: String?, default fallback: UsageSource) -> UsageSource {
        switch claude(entrypoint: entrypoint) {
        case cowork, desktopCode: .claudeDesktop
        default: fallback
        }
    }
}

/// Token counts for one record, normalized so that each token is counted once.
public struct TokenCounts: Sendable, Hashable, Codable {
    /// Input tokens that were neither read from nor written to the cache.
    public var inputUncached: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    /// All output tokens, including reasoning tokens.
    public var output: Int
    /// Reasoning tokens. Already included in `output`; kept for display only.
    public var reasoning: Int

    public init(inputUncached: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0, reasoning: Int = 0) {
        self.inputUncached = inputUncached
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
        self.reasoning = reasoning
    }

    public static let zero = TokenCounts()

    public var isZero: Bool {
        inputUncached == 0 && cacheWrite == 0 && cacheRead == 0 && output == 0
    }

    public var total: Int { inputUncached + cacheWrite + cacheRead + output }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            inputUncached: lhs.inputUncached + rhs.inputUncached,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }
}

/// One usage record extracted from a log line. Contains no conversation content.
public struct ParsedUsage: Sendable, Hashable {
    public var dedupeKey: String
    public var source: UsageSource
    public var sessionID: String
    public var projectPath: String?
    public var model: String
    public var timestamp: Date
    public var tokens: TokenCounts
    /// Client that wrote the record (`UsageClient`), when the log says.
    public var client: String?

    public init(dedupeKey: String, source: UsageSource, sessionID: String, projectPath: String?, model: String, timestamp: Date, tokens: TokenCounts,
                client: String? = nil) {
        self.client = client
        self.dedupeKey = dedupeKey
        self.source = source
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.model = model
        self.timestamp = timestamp
        self.tokens = tokens
    }
}

/// Result of parsing one log line.
public enum ParseOutcome: Sendable, Equatable {
    /// The line carried usage.
    case usage(ParsedUsage)
    /// The line is valid but carries no usage we count (other event types, synthetic models, zero usage, duplicates).
    case ignored
    /// The line could not be understood. Counted and shown to the user as skipped.
    case skipped(SkipReason)
}

public enum SkipReason: String, Sendable, Equatable {
    case invalidJSON
    case missingField
    case unexpectedStructure
}
