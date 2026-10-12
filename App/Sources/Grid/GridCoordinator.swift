import ElectricityCore
import Foundation
import Observation

/// Grid data settings. Passwords and API keys live in the keychain (SPEC 10.3).
@MainActor
@Observable
final class GridSettings {
    private enum Key {
        static let username = "grid.watttime.username"
        static let cleanerBelow = "grid.thresholds.cleanerBelow"
        static let lessCleanAbove = "grid.thresholds.lessCleanAbove"
        static let regions = "grid.watttime.regions"
        /// Whether an Electricity Maps key is in the Keychain, so launch does not have to read the Keychain.
        static let hasEmapsKey = "grid.emaps.present"
    }
    static let watttimePasswordAccount = "watttime.password"
    static let electricityMapsAccount = "electricitymaps.key"

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var watttimeUsername: String?
    private(set) var hasElectricityMapsKey: Bool
    var cleanerBelow: Double { didSet { defaults.set(cleanerBelow, forKey: Key.cleanerBelow) } }
    var lessCleanAbove: Double { didSet { defaults.set(lessCleanAbove, forKey: Key.lessCleanAbove) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        watttimeUsername = defaults.string(forKey: Key.username)
        hasElectricityMapsKey = defaults.bool(forKey: Key.hasEmapsKey)
        cleanerBelow = defaults.object(forKey: Key.cleanerBelow) as? Double ?? 100.0 / 3
        lessCleanAbove = defaults.object(forKey: Key.lessCleanAbove) as? Double ?? 200.0 / 3
    }

    var thresholds: GridThresholds {
        GridThresholds(cleanerBelow: min(cleanerBelow, lessCleanAbove), lessCleanAbove: max(cleanerBelow, lessCleanAbove))
    }

    /// Reads the password and key from the Keychain off the main thread. macOS may ask the user to allow access
    /// (for example after an update changes the app's signature); the app keeps running while it waits.
    func loadConfiguration() async -> GridService.Configuration {
        let username = watttimeUsername
        let thresholds = thresholds
        let (passwordAccount, keyAccount) = (Self.watttimePasswordAccount, Self.electricityMapsAccount)
        let (password, key) = await Task.detached {
            (username == nil ? nil : Keychain.get(account: passwordAccount), Keychain.get(account: keyAccount))
        }.value
        updateElectricityMapsKeyPresence(key != nil)
        var credentials: WattTimeCredentials?
        if let username, let password { credentials = WattTimeCredentials(username: username, password: password) }
        return GridService.Configuration(watttime: credentials, electricityMapsKey: key, thresholds: thresholds)
    }

    private func updateElectricityMapsKeyPresence(_ present: Bool) {
        hasElectricityMapsKey = present
        defaults.set(present, forKey: Key.hasEmapsKey)
    }

    var isConfigured: Bool { watttimeUsername != nil || hasElectricityMapsKey }

    func signIn(username: String, password: String) throws {
        try Keychain.set(password, account: Self.watttimePasswordAccount)
        defaults.set(username, forKey: Key.username)
        watttimeUsername = username
    }

    func signOut() {
        Keychain.delete(account: Self.watttimePasswordAccount)
        defaults.removeObject(forKey: Key.username)
        defaults.removeObject(forKey: Key.regions)
        watttimeUsername = nil
    }

    func setElectricityMapsKey(_ key: String?) throws {
        if let key, !key.isEmpty {
            try Keychain.set(key, account: Self.electricityMapsAccount)
        } else {
            Keychain.delete(account: Self.electricityMapsAccount)
        }
        updateElectricityMapsKeyPresence(key?.isEmpty == false)
    }

    var savedRegions: [String: String] {
        get { defaults.dictionary(forKey: Key.regions) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.regions) }
    }
}

/// Refreshes grid data every 5 minutes (each location is fetched at most every 15 minutes)
/// and hands it to the display layers, new records and the snapshot.
@MainActor
final class GridCoordinator {
    private let model: AppModel
    let settings = GridSettings()
    private let ingest: IngestCoordinator
    private var service: GridService?
    private var task: Task<Void, Never>?

    init(model: AppModel, ingest: IngestCoordinator) {
        self.model = model
        self.ingest = ingest
    }

    func start() {
        guard let table = try? GridRegionTable.bundled() else { return }
        model.gridConfigured = settings.isConfigured
        task = Task { [weak self] in
            guard let self else { return }
            let configuration = await settings.loadConfiguration()
            service = GridService(table: table, configuration: configuration, regions: settings.savedRegions)
            await refresh()
            // A second pass picks up EIA data, which loads in the background after the first.
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    /// Applies changed accounts, keys or thresholds and refreshes now.
    func reconfigure() {
        guard let service else { return }
        Task {
            await service.configure(await settings.loadConfiguration())
            await refresh()
        }
    }

    func refresh() async {
        guard let service else { return }
        let statuses = await service.statuses()
        settings.savedRegions = await service.regions
        model.gridStatuses = statuses
        model.gridConfigured = settings.isConfigured
        model.gridLoading = false
        model.gridError = await service.lastError
        await ingest.setGrid(statuses)
    }
}
