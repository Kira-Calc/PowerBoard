import Foundation

/// Moves data from the identifiers used before the rename to PowerBoard: the support folder, the app's
/// preferences, and the Keychain items. Runs once, before anything reads settings or opens the database.
/// Existing data under the new identifiers is never overwritten.
public enum LegacyMigration {
    public struct Result: Sendable, Equatable {
        public var movedSupportDirectory = false
        public var copiedPreferences = false
        public var copiedKeychainItems = 0
    }

    public static let keychainAccounts = ["watttime.password", "electricitymaps.key"]
    /// Set in the new preferences once the migration has run, so later launches do not touch the Keychain.
    public static let doneKey = "migration.legacyDone"

    @discardableResult
    public static func run(
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        defaults: UserDefaults = .standard,
        legacyDomain: String = AppIdentity.legacyBundleID,
        domain: String = AppIdentity.bundleID,
        includeKeychain: Bool = true
    ) -> Result {
        var result = Result()
        if defaults.persistentDomain(forName: domain)?[doneKey] as? Bool == true { return result }
        let fileManager = FileManager.default
        let old = applicationSupport.appendingPathComponent(AppIdentity.legacySupportDirName, isDirectory: true)
        let new = applicationSupport.appendingPathComponent(AppIdentity.supportDirName, isDirectory: true)
        if fileManager.fileExists(atPath: old.path), !fileManager.fileExists(atPath: new.path) {
            result.movedSupportDirectory = (try? fileManager.moveItem(at: old, to: new)) != nil
        }

        let oldDomain = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        let newDomain = defaults.persistentDomain(forName: domain) ?? [:]
        if !oldDomain.isEmpty, newDomain.isEmpty {
            defaults.setPersistentDomain(oldDomain, forName: domain)
            result.copiedPreferences = true
        }

        // Only an install that had the old app can have old Keychain items.
        if includeKeychain, !oldDomain.isEmpty {
            for account in keychainAccounts where Keychain.get(account: account) == nil {
                if let value = Keychain.get(account: account, service: AppIdentity.legacyBundleID),
                   (try? Keychain.set(value, account: account)) != nil {
                    result.copiedKeychainItems += 1
                }
            }
        }
        var finished = defaults.persistentDomain(forName: domain) ?? [:]
        finished[doneKey] = true
        defaults.setPersistentDomain(finished, forName: domain)
        return result
    }
}
