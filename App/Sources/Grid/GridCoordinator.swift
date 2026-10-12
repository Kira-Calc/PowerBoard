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
        /// An account that was created but whose email is not verified yet, so WattTime does not accept it.
        static let pendingUsername = "grid.watttime.pending"
        static let pendingEmail = "grid.watttime.pendingEmail"
    }
    static let watttimePasswordAccount = "watttime.password"
    static let electricityMapsAccount = "electricitymaps.key"

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var watttimeUsername: String?
    private(set) var hasElectricityMapsKey: Bool
    private(set) var pendingUsername: String?
    private(set) var pendingEmail: String?
    var cleanerBelow: Double { didSet { defaults.set(cleanerBelow, forKey: Key.cleanerBelow) } }
    var lessCleanAbove: Double { didSet { defaults.set(lessCleanAbove, forKey: Key.lessCleanAbove) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        watttimeUsername = defaults.string(forKey: Key.username)
        hasElectricityMapsKey = defaults.bool(forKey: Key.hasEmapsKey)
        pendingUsername = defaults.string(forKey: Key.pendingUsername)
        pendingEmail = defaults.string(forKey: Key.pendingEmail)
        #if DEBUG
        // Development aid: `-previewSignedOut` or `-previewPending` shows those states for this launch only,
        // without changing saved settings.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-previewSignedOut") || arguments.contains("-previewPending") { watttimeUsername = nil }
        if arguments.contains("-previewPending") { (pendingUsername, pendingEmail) = ("preview", "you@example.com") }
        #endif
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

    /// Keeps a new account until its email is verified; the password waits in the Keychain.
    func savePending(username: String, password: String, email: String) throws {
        try Keychain.set(password, account: Self.watttimePasswordAccount)
        defaults.set(username, forKey: Key.pendingUsername)
        defaults.set(email, forKey: Key.pendingEmail)
        pendingUsername = username
        pendingEmail = email
    }

    /// Credentials of the account waiting for verification, read off the main thread.
    func loadPendingCredentials() async -> WattTimeCredentials? {
        guard let username = pendingUsername else { return nil }
        let account = Self.watttimePasswordAccount
        let password = await Task.detached { Keychain.get(account: account) }.value
        return password.map { WattTimeCredentials(username: username, password: $0) }
    }

    func completePending() {
        guard let username = pendingUsername else { return }
        defaults.set(username, forKey: Key.username)
        watttimeUsername = username
        clearPending()
    }

    func cancelPending() {
        Keychain.delete(account: Self.watttimePasswordAccount)
        clearPending()
    }

    private func clearPending() {
        defaults.removeObject(forKey: Key.pendingUsername)
        defaults.removeObject(forKey: Key.pendingEmail)
        pendingUsername = nil
        pendingEmail = nil
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
    private var verificationTask: Task<Void, Never>?
    /// Seconds between sign-in attempts while waiting for the user to verify their email.
    static let verificationInterval: Duration = .seconds(20)

    init(model: AppModel, ingest: IngestCoordinator) {
        self.model = model
        self.ingest = ingest
    }

    func start() {
        guard let table = try? GridRegionTable.bundled() else { return }
        model.gridConfigured = settings.isConfigured
        startVerificationPolling()
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
        verificationTask?.cancel()
    }

    /// While a new account waits for email verification, tries to sign in every 20 seconds for up to an hour,
    /// and connects as soon as WattTime accepts it, so the user does not have to come back and sign in.
    func startVerificationPolling() {
        verificationTask?.cancel()
        guard settings.pendingUsername != nil else { return }
        verificationTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(3600)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: Self.verificationInterval)
                guard let self, !Task.isCancelled else { return }
                if await self.checkPendingNow() { return }
            }
        }
    }

    /// One sign-in attempt for the account waiting for verification. Returns true when it is now connected.
    @discardableResult
    func checkPendingNow() async -> Bool {
        guard let credentials = await settings.loadPendingCredentials() else { return false }
        guard (try? await WattTimeClient(credentials: credentials).login()) != nil,
              settings.pendingUsername == credentials.username else { return false }
        settings.completePending()
        verificationTask?.cancel()
        reconfigure()
        return true
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
