import Foundation

/// File locations derived from `AppIdentity`.
public enum AppPaths {
    /// `~/Library/Application Support/<supportDirName>/`
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.supportDirName, isDirectory: true)
    }

    public static var database: URL { supportDirectory.appendingPathComponent("data.sqlite") }

    public static var snapshot: URL { supportDirectory.appendingPathComponent("snapshot.json") }
}
