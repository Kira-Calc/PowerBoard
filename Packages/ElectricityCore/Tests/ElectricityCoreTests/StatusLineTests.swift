import Foundation
import Testing
@testable import ElectricityCore

@Suite struct StatusLineFormatterTests {
    private let now = Date(timeIntervalSince1970: 1_791_766_800)

    private func snapshot(generatedAt: Date, appRunning: Bool = true) -> Snapshot {
        Snapshot(
            generatedAt: generatedAt,
            appRunning: appRunning,
            today: .init(
                date: "2026-10-12",
                tokens: .init(input: 1, output: 2, cacheWrite: 3, cacheRead: 4),
                energyWh: Estimate(low: 620, mid: 1240, high: 2480),
                co2G: 356,
                cleanShare: nil,
                bySource: [:]
            ),
            sessions: ["s1": .init(source: "claude_code", energyWhMid: 82, co2G: 23.5, tokensTotal: 10, lastTs: generatedAt)],
            lastHourSparklineWh: []
        )
    }

    @Test func missingSnapshot() {
        let en = StatusLineFormatter.render(snapshot: nil, sessionID: nil, language: .en, format: .default, color: false, now: now)
        #expect(en == "powerboard: open the app to start tracking")
        let zh = StatusLineFormatter.render(snapshot: nil, sessionID: nil, language: .zh, format: .default, color: false, now: now)
        #expect(zh.hasPrefix("powerboard："))
    }

    @Test func normalOutputMatchesSpecExamples() {
        let fresh = snapshot(generatedAt: now.addingTimeInterval(-10))
        #expect(StatusLineFormatter.render(snapshot: fresh, sessionID: "s1", language: .en, format: .default, color: false, now: now)
                == "82 Wh session | 1.24 kWh today | 356 g CO2e")
        #expect(StatusLineFormatter.render(snapshot: fresh, sessionID: "s1", language: .zh, format: .default, color: false, now: now)
                == "本会话 82 Wh | 今日 1.24 kWh | 356 g CO2e")
        #expect(StatusLineFormatter.render(snapshot: fresh, sessionID: "s1", language: .en, format: .compact, color: false, now: now)
                == "1.24 kWh | 356 g")
    }

    @Test func unknownSessionOmitsSessionPart() {
        let fresh = snapshot(generatedAt: now)
        #expect(StatusLineFormatter.render(snapshot: fresh, sessionID: "other", language: .en, format: .default, color: false, now: now)
                == "1.24 kWh today | 356 g CO2e")
    }

    @Test func staleOutput() {
        let old = snapshot(generatedAt: now.addingTimeInterval(-301))
        #expect(StatusLineFormatter.render(snapshot: old, sessionID: nil, language: .en, format: .compact, color: false, now: now)
                == "1.24 kWh | 356 g (stale)")
        #expect(StatusLineFormatter.render(snapshot: old, sessionID: nil, language: .zh, format: .compact, color: false, now: now)
                == "1.24 kWh | 356 g（未更新）")
        let stopped = snapshot(generatedAt: now, appRunning: false)
        #expect(StatusLineFormatter.render(snapshot: stopped, sessionID: nil, language: .en, format: .compact, color: false, now: now).hasSuffix("(stale)"))
    }

    @Test func colorUsesANSIOnlyWhenEnabled() {
        let fresh = snapshot(generatedAt: now)
        let colored = StatusLineFormatter.render(snapshot: fresh, sessionID: nil, language: .en, format: .compact, color: true, now: now)
        #expect(colored.contains("\u{1B}["))
        let plain = StatusLineFormatter.render(snapshot: fresh, sessionID: nil, language: .en, format: .compact, color: false, now: now)
        #expect(!plain.contains("\u{1B}"))
    }
}

@Suite struct JSONTextEditorTests {
    @Test func replacesValueAndKeepsFormatting() throws {
        let text = """
        {
            "model": "opus",
            "statusLine": { "type": "command", "command": "old" },
            "hooks": {"a": [1, "}", {"b": "\\"x\\""}]}
        }

        """
        var editor = try JSONTextEditor(text: text)
        #expect(try editor.rawValue(of: "statusLine") == #"{ "type": "command", "command": "old" }"#)
        try editor.set("statusLine", rawValue: #"{"type": "command", "command": "new"}"#)
        #expect(editor.text == text.replacingOccurrences(of: #"{ "type": "command", "command": "old" }"#, with: #"{"type": "command", "command": "new"}"#))
    }

    @Test func replacementIsIndentedLikeItsKey() throws {
        var editor = try JSONTextEditor(text: "{\n    \"statusLine\": 1\n}\n")
        try editor.set("statusLine", rawValue: "{\n  \"a\": 1\n}")
        #expect(editor.text == "{\n    \"statusLine\": {\n      \"a\": 1\n    }\n}\n")
    }

    @Test func addsKeyWithDetectedIndent() throws {
        var editor = try JSONTextEditor(text: "{\n    \"model\": \"opus\"\n}\n")
        try editor.set("statusLine", rawValue: "{\n  \"a\": 1\n}")
        #expect(editor.text == "{\n    \"model\": \"opus\",\n    \"statusLine\": {\n      \"a\": 1\n    }\n}\n")
        let object = try JSONSerialization.jsonObject(with: Data(editor.text.utf8)) as? [String: Any]
        #expect(object?["model"] as? String == "opus")
    }

    @Test func addsToEmptyObjectAndRemoves() throws {
        var editor = try JSONTextEditor(text: "{}")
        try editor.set("statusLine", rawValue: "1")
        #expect(editor.text == "{\n  \"statusLine\": 1\n}")
        try editor.remove("statusLine")
        #expect(editor.text == "{}")

        var middle = try JSONTextEditor(text: #"{"a": 1, "statusLine": 2, "b": 3}"#)
        try middle.remove("statusLine")
        #expect(middle.text == #"{"a": 1, "b": 3}"#)
        var first = try JSONTextEditor(text: #"{"statusLine": 2, "b": 3}"#)
        try first.remove("statusLine")
        #expect(first.text == #"{"b": 3}"#)
    }

    @Test func rejectsNonObjects() {
        #expect(throws: JSONTextEditor.EditError.notAnObject) { try JSONTextEditor(text: "[1]") }
        #expect(throws: JSONTextEditor.EditError.notAnObject) { try JSONTextEditor(text: "{broken") }
    }
}

@Suite struct StatusLineInstallerTests {
    private let executable = "/Applications/PowerBoard.app/Contents/Helpers/powerboard"
    private let now = Date(timeIntervalSince1970: 1_791_766_800)

    private func makeInstaller() throws -> (StatusLineInstaller, URL) {
        let dir = try TestSupport.makeTempDirectory()
        let installer = StatusLineInstaller(
            settingsURL: dir.appendingPathComponent("claude/settings.json"),
            stateURL: dir.appendingPathComponent("support/statusline-original.json"),
            executablePath: executable
        )
        return (installer, dir)
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func backups(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("claude").path).filter { $0.contains("backup") }
    }

    @Test func installCreatesMissingSettingsAndUninstallRemovesKey() throws {
        let (installer, dir) = try makeInstaller()
        defer { TestSupport.cleanup(dir) }
        #expect(try installer.inspect() == .none)
        #expect(try installer.install(mode: .replace, now: now) == nil)
        #expect(try installer.inspect() == .ours(chained: nil))
        let text = try read(installer.settingsURL)
        #expect(text.contains(#""command": "'/Applications/PowerBoard.app/Contents/Helpers/powerboard' statusline""#))

        try installer.uninstall(now: now)
        #expect(try installer.inspect() == .none)
        #expect(try read(installer.settingsURL) == "{}\n")
        #expect(try backups(in: dir).count == 1)
    }

    @Test func replaceKeepsOtherContentAndRestoresOriginal() throws {
        let (installer, dir) = try makeInstaller()
        defer { TestSupport.cleanup(dir) }
        let original = """
        {
          "theme": "dark",
          "statusLine": {
            "type": "command",
            "command": "~/bin/my-status"
          },
          "permissions": { "allow": ["Bash(ls:*)"] }
        }

        """
        try FileManager.default.createDirectory(at: installer.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: installer.settingsURL, atomically: true, encoding: .utf8)
        #expect(try installer.inspect() == .other(command: "~/bin/my-status"))

        let backup = try #require(try installer.install(mode: .replace, now: now))
        #expect(try read(backup) == original)
        let installed = try read(installer.settingsURL)
        #expect(installed.hasPrefix("{\n  \"theme\": \"dark\",\n  \"statusLine\": {"))
        #expect(installed.hasSuffix("},\n  \"permissions\": { \"allow\": [\"Bash(ls:*)\"] }\n}\n"))

        // Same second as the install: the second backup must not overwrite the first.
        try installer.uninstall(now: now)
        #expect(try read(installer.settingsURL) == original)
        #expect(try backups(in: dir).count == 2)
    }

    @Test func combineChainsTheOriginalCommand() throws {
        let (installer, dir) = try makeInstaller()
        defer { TestSupport.cleanup(dir) }
        try FileManager.default.createDirectory(at: installer.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = #"{"statusLine": {"type": "command", "command": "echo 'it''s' | cat"}}"#
        try original.write(to: installer.settingsURL, atomically: true, encoding: .utf8)

        try installer.install(mode: .combine, now: now)
        #expect(try installer.inspect() == .ours(chained: "echo 'it''s' | cat"))
        // Reinstalling keeps the saved original, so uninstall still restores it.
        try installer.install(mode: .replace, now: now)
        #expect(try installer.inspect() == .ours(chained: nil))
        try installer.uninstall(now: now)
        #expect(try read(installer.settingsURL) == original)
    }

    @Test func refusesToCombineWithoutCommandOrToTouchBrokenSettings() throws {
        let (installer, dir) = try makeInstaller()
        defer { TestSupport.cleanup(dir) }
        try FileManager.default.createDirectory(at: installer.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: installer.settingsURL, atomically: true, encoding: .utf8)
        #expect(throws: StatusLineInstaller.InstallError.cannotCombine) { try installer.install(mode: .combine, now: now) }
        #expect(throws: StatusLineInstaller.InstallError.notInstalled) { try installer.uninstall(now: now) }

        try "{ not json".write(to: installer.settingsURL, atomically: true, encoding: .utf8)
        #expect(throws: StatusLineInstaller.InstallError.settingsNotAnObject) { try installer.install(mode: .replace, now: now) }
        #expect(try read(installer.settingsURL) == "{ not json")
    }

    @Test func shellQuoting() {
        #expect(StatusLineInstaller.shellQuote("a b") == "'a b'")
        #expect(StatusLineInstaller.shellQuote("it's") == #"'it'\''s'"#)
        #expect(StatusLineInstaller.shellUnquote(StatusLineInstaller.shellQuote("x 'y' z")) == "x 'y' z")
    }
}
