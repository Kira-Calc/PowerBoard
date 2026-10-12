import Foundation

/// Directories that hold AI tool logs (SPEC 4.1, 4.2).
public struct LogLocations: Sendable, Hashable {
    public var claudeCode: [URL]
    public var codex: [URL]
    /// Antigravity conversation directories (SQLite databases, not JSONL).
    public var antigravity: [URL]

    public init(claudeCode: [URL], codex: [URL], antigravity: [URL] = []) {
        self.claudeCode = claudeCode
        self.codex = codex
        self.antigravity = antigravity
    }

    /// Default Antigravity data roots. Each may hold a `conversations` folder or be one.
    static let antigravityRoots = [
        ".gemini/antigravity", ".gemini/antigravity-cli", ".gemini/antigravity-ide",
        ".gemini/antigravity-backup", ".gemini/antigravity-acp", ".config/antigravity",
    ]

    /// Default locations, in scan order. Duplicates are removed.
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        extraClaudeCode: [URL] = [],
        extraCodex: [URL] = [],
        extraAntigravity: [URL] = []
    ) -> LogLocations {
        var claude: [URL] = []
        if let configDirs = environment["CLAUDE_CONFIG_DIR"] {
            for part in configDirs.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                claude.append(URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).appendingPathComponent("projects"))
            }
        }
        claude.append(home.appendingPathComponent(".claude/projects"))
        claude.append(home.appendingPathComponent(".config/claude/projects"))

        var codex: [URL] = []
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            codex.append(URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath).appendingPathComponent("sessions"))
        }
        codex.append(home.appendingPathComponent(".codex/sessions"))

        var antigravityRoots: [URL]
        if let dataDirs = environment["ANTIGRAVITY_DATA_DIR"], !dataDirs.isEmpty {
            antigravityRoots = dataDirs.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        } else {
            antigravityRoots = Self.antigravityRoots.map { home.appendingPathComponent($0) }
        }
        let antigravity = (antigravityRoots + extraAntigravity).map { root in
            let nested = root.appendingPathComponent("conversations")
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory) && isDirectory.boolValue ? nested : root
        }

        return LogLocations(
            claudeCode: unique(claude + extraClaudeCode),
            codex: unique(codex + extraCodex),
            antigravity: unique(antigravity)
        )
    }

    public func roots(for source: UsageSource) -> [URL] {
        switch source {
        case .claudeCode: claudeCode
        case .codex: codex
        case .antigravity: antigravity
        }
    }

    /// Lists every log file under the roots of `source`, recursively, including subagent logs:
    /// `*.jsonl` for Claude Code and Codex, `*.db` for Antigravity.
    /// Files reachable through more than one root are listed once.
    public func logFiles(for source: UsageSource) -> [String] {
        let fileExtension = source == .antigravity ? "db" : "jsonl"
        var seen = Set<String>()
        var files: [String] = []
        for root in roots(for: source) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == fileExtension {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let path = url.resolvingSymlinksInPath().path
                if seen.insert(path).inserted { files.append(path) }
            }
        }
        return files.sorted()
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }
}
