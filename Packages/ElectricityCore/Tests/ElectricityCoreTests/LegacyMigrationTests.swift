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
