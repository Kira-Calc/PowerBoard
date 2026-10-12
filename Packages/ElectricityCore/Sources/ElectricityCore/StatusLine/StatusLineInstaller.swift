import Foundation

/// Installs and removes the status line command in Claude Code's `settings.json` (SPEC 8.3).
/// Only the `statusLine` key is changed; the rest of the file is kept byte for byte.
/// A backup is written before every change, and the original value is saved so it can be restored.
public struct StatusLineInstaller: Sendable {
    public enum Existing: Equatable, Sendable {
        /// No `statusLine` in the settings, or no settings file.
        case none
        /// Our command is installed. `chained` is the original command run before ours, if combined.
        case ours(chained: String?)
        /// Another status line. `command` is nil when it is not a shell command and cannot be combined.
        case other(command: String?)
    }

    public enum Mode: Sendable {
        /// Use only our status line.
        case replace
        /// Run the existing command first and append our text after " | ".
        case combine
    }

    public enum InstallError: Error, Equatable {
        case settingsNotAnObject
        case cannotCombine
        case notInstalled
    }

    public let settingsURL: URL
    /// Where the original `statusLine` value is kept for uninstalling.
    public let stateURL: URL
    /// Absolute path of the `powerboard` executable.
    public let executablePath: String

    public init(settingsURL: URL, stateURL: URL, executablePath: String) {
        self.settingsURL = settingsURL
        self.stateURL = stateURL
        self.executablePath = executablePath
    }

    /// Default locations: `~/.claude/settings.json` (or `CLAUDE_CONFIG_DIR`), and the app support directory.
    public static func standard(executablePath: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> StatusLineInstaller {
        let configDir = environment["CLAUDE_CONFIG_DIR"]?
            .split(separator: ",").first
            .map { URL(fileURLWithPath: (String($0).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return StatusLineInstaller(
            settingsURL: configDir.appendingPathComponent("settings.json"),
            stateURL: AppPaths.supportDirectory.appendingPathComponent("statusline-original.json"),
            executablePath: executablePath
        )
    }

    // MARK: Inspect

    public func inspect() throws -> Existing {
        guard let text = try readSettings() else { return .none }
        let editor = try editor(for: text)
        guard let raw = try editor.rawValue(of: "statusLine") else { return .none }
        let command = Self.command(inRawValue: raw)
        if let command, isOurs(command) {
            return .ours(chained: Self.chainedCommand(in: command))
        }
        return .other(command: command)
    }

    // MARK: Install

    /// Installs our command. Returns the backup file, or nil when there was no settings file.
    @discardableResult
    public func install(mode: Mode, now: Date = Date()) throws -> URL? {
        let existingText = try readSettings()
        var editor = try editor(for: existingText ?? "{}\n")
        let existingRaw = try editor.rawValue(of: "statusLine")

        // The value to restore on uninstall: keep the saved one when reinstalling over our own command.
        var original = existingRaw
        var chain: String?
        if let existingRaw, let command = Self.command(inRawValue: existingRaw), isOurs(command) {
            original = try loadOriginal()
            chain = mode == .combine ? Self.chainedCommand(in: command) : nil
        } else if mode == .combine {
            guard let existingRaw, let command = Self.command(inRawValue: existingRaw) else { throw InstallError.cannotCombine }
            chain = command
        }

        let backup = try existingText.map { try writeBackup($0, now: now) }
        try saveOriginal(original)
        try editor.set("statusLine", rawValue: statusLineValue(chain: chain))
        try write(editor.text)
        return backup
    }

    /// Restores the original `statusLine`, or removes the key if there was none. Returns the backup file.
    @discardableResult
    public func uninstall(now: Date = Date()) throws -> URL? {
        guard let text = try readSettings() else { throw InstallError.notInstalled }
        var editor = try editor(for: text)
        guard let raw = try editor.rawValue(of: "statusLine"),
              let command = Self.command(inRawValue: raw), isOurs(command)
        else { throw InstallError.notInstalled }

        let backup = try writeBackup(text, now: now)
        if let original = try loadOriginal() {
            // The saved value is the original text, already indented for this file.
            try editor.set("statusLine", rawValue: original, reindent: false)
        } else {
            try editor.remove("statusLine")
        }
        try write(editor.text)
        try? FileManager.default.removeItem(at: stateURL)
        return backup
    }

    // MARK: Helpers

    /// The command string for our status line, optionally chaining an existing command.
    public func commandLine(chain: String?) -> String {
        var line = "\(Self.shellQuote(executablePath)) statusline"
        if let chain { line += " --chain \(Self.shellQuote(chain))" }
        return line
    }

    func statusLineValue(chain: String?) -> String {
        """
        {
          "type": "command",
          "command": \(JSONTextEditor.quote(commandLine(chain: chain))),
          "padding": 0
        }
        """
    }

    private func isOurs(_ command: String) -> Bool {
        command.contains("statusline") && (command.contains(executablePath) || command.contains("/Contents/Helpers/\(AppIdentity.cliName)"))
    }

    private func readSettings() throws -> String? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        return try String(contentsOf: settingsURL, encoding: .utf8)
    }

    private func editor(for text: String) throws -> JSONTextEditor {
        do {
            return try JSONTextEditor(text: text)
        } catch {
            throw InstallError.settingsNotAnObject
        }
    }

    private func writeBackup(_ text: String, now: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        let directory = settingsURL.deletingLastPathComponent()
        var url = directory.appendingPathComponent("settings.json.\(AppIdentity.cliName)-backup-\(stamp)")
        var counter = 1
        // Never overwrite an earlier backup made in the same second.
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("settings.json.\(AppIdentity.cliName)-backup-\(stamp)-\(counter)")
            counter += 1
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    private func saveOriginal(_ raw: String?) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let object: [String: Any] = ["original": raw ?? NSNull()]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: stateURL, options: .atomic)
    }

    private func loadOriginal() throws -> String? {
        guard let data = try? Data(contentsOf: stateURL),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["original"] as? String
    }

    static func command(inRawValue raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "command" || object["type"] == nil
        else { return nil }
        return object["command"] as? String
    }

    /// The command passed to `--chain` in one of our command lines.
    static func chainedCommand(in command: String) -> String? {
        guard let range = command.range(of: " --chain ") else { return nil }
        return shellUnquote(String(command[range.upperBound...]))
    }

    /// Single-quotes a string for POSIX shells.
    public static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func shellUnquote(_ string: String) -> String {
        guard string.hasPrefix("'"), string.hasSuffix("'"), string.count >= 2 else { return string }
        return String(string.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }
}
