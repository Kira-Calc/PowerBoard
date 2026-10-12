import Foundation
import Testing
@testable import ElectricityCore

@Suite struct LegacyMigrationTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func movesSupportFolderOnce() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent(AppIdentity.legacySupportDirName)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: old.appendingPathComponent("data.sqlite"))

        let result = LegacyMigration.run(applicationSupport: root, legacyDomain: "test.none.\(UUID())", domain: "test.none.\(UUID())", includeKeychain: false)
        #expect(result.movedSupportDirectory)
        let new = root.appendingPathComponent(AppIdentity.supportDirName)
        #expect(try String(contentsOf: new.appendingPathComponent("data.sqlite"), encoding: .utf8) == "db")
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func keepsExistingNewFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in [AppIdentity.legacySupportDirName, AppIdentity.supportDirName] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let result = LegacyMigration.run(applicationSupport: root, legacyDomain: "test.none.\(UUID())", domain: "test.none.\(UUID())", includeKeychain: false)
        #expect(!result.movedSupportDirectory)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(AppIdentity.legacySupportDirName).path))
    }

    @Test func copiesPreferencesOnlyIntoEmptyDomain() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = "test.legacy.\(UUID())", new = "test.new.\(UUID())", taken = "test.taken.\(UUID())"
        let defaults = UserDefaults.standard
        defaults.setPersistentDomain(["menuBar.split": true], forName: old)
        defaults.setPersistentDomain(["menuBar.split": false], forName: taken)
        defer { [old, new, taken].forEach { defaults.removePersistentDomain(forName: $0) } }

        #expect(LegacyMigration.run(applicationSupport: root, legacyDomain: old, domain: new, includeKeychain: false).copiedPreferences)
        #expect(defaults.persistentDomain(forName: new)?["menuBar.split"] as? Bool == true)
        #expect(!LegacyMigration.run(applicationSupport: root, legacyDomain: old, domain: taken, includeKeychain: false).copiedPreferences)
        #expect(defaults.persistentDomain(forName: taken)?["menuBar.split"] as? Bool == false)
        // Runs once: a second run does nothing, even if old data reappears.
        #expect(defaults.persistentDomain(forName: new)?[LegacyMigration.doneKey] as? Bool == true)
        defaults.removePersistentDomain(forName: new)
        defaults.setPersistentDomain([LegacyMigration.doneKey: true], forName: new)
        #expect(!LegacyMigration.run(applicationSupport: root, legacyDomain: old, domain: new, includeKeychain: false).copiedPreferences)
    }
}

@Suite struct DayWindowTests {
    @Test func last24HoursDoesNotResetAtMidnight() throws {
        let store = try UsageStore()
        let calc = try TestSupport.calculator()
        func row(_ key: String, _ date: Date) throws -> UsageEventRow {
            let usage = ParsedUsage(dedupeKey: key, source: .claudeCode, sessionID: "s", projectPath: nil, model: "claude-sonnet-test",
                                    timestamp: date, tokens: TokenCounts(inputUncached: 0, output: 1_000_000))
            return UsageEventRow(usage: usage, result: try calc.estimate(model: usage.model, tokens: usage.tokens))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = try Date("2026-10-13T00:00:00Z", strategy: .iso8601)
        try store.insert([row("a", midnight.addingTimeInterval(-3600)), row("b", midnight.addingTimeInterval(600))], cursor: nil)
        let now = midnight.addingTimeInterval(1200)

        let calendarDay = try SnapshotBuilder.build(store: store, now: now, calendar: calendar)
        let rolling = try SnapshotBuilder.build(store: store, now: now, calendar: calendar, dayWindow: .last24Hours)
        #expect(rolling.today.energyWh.mid > calendarDay.today.energyWh.mid * 1.99)
        #expect(rolling.today.window == .last24Hours)
        let line = StatusLineFormatter.render(snapshot: rolling, sessionID: nil, language: .en, format: .default, color: false, now: now)
        #expect(line.contains("24h"))

        let hours = ChartScale.hour.boundaries(now: now, calendar: calendar, dayWindow: .last24Hours)
        #expect(hours.count == 25)
        #expect(hours.last == midnight.addingTimeInterval(3600))
    }
}
