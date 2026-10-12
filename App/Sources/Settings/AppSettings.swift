import ElectricityCore
import Foundation
import Observation

enum MenuBarSplit: String, CaseIterable, Identifiable {
    /// One status item showing energy.
    case combined
    /// Separate status items for energy, tokens and carbon.
    case separate

    var id: String { rawValue }
}

/// What the single combined status item shows.
enum CombinedDisplay: String, CaseIterable, Identifiable {
    case energy
    case tokens
    case energyAndTokens

    var id: String { rawValue }

    var metrics: [MenuBarMetric] {
        switch self {
        case .energy: [.energy]
        case .tokens: [.tokens]
        case .energyAndTokens: [.energy, .tokens]
        }
    }
}

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case energy
    case tokens
    case carbon

    var id: String { rawValue }
}

enum MenuBarContent: String, CaseIterable, Identifiable {
    case iconOnly
    case iconAndValue
    case valueOnly
    /// Graph of the last hour. Available for energy only.
    case sparkline

    var id: String { rawValue }

    static func options(for metric: MenuBarMetric) -> [MenuBarContent] {
        metric == .energy ? allCases : [.iconOnly, .iconAndValue, .valueOnly]
    }
}

/// Decimal places for energy numbers. `nil` means automatic.
enum DecimalsSetting: Int, CaseIterable, Identifiable {
    case automatic = -1
    case zero = 0
    case one = 1
    case two = 2

    var id: Int { rawValue }
    var places: Int? { self == .automatic ? nil : rawValue }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
}

/// Language of the `powerboard` command. Stored where the CLI can read it (SPEC 8.3).
enum CLILanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh"

    var id: String { rawValue }
}

enum DataRetention: String, CaseIterable, Identifiable {
    case forever
    case oneYear
    case twoYears

    var id: String { rawValue }

    var years: Int? {
        switch self {
        case .forever: nil
        case .oneYear: 1
        case .twoYears: 2
        }
    }
}

/// User settings stored in UserDefaults (SPEC 6.1: settings are not stored in the database).
@MainActor
@Observable
final class AppSettings {
    enum Key {
        static let split = "menuBar.split"
        static let combined = "menuBar.combinedDisplay"
        static let unit = "menuBar.energyUnit"
        static let decimals = "menuBar.decimals"
        static func content(_ metric: MenuBarMetric) -> String { "menuBar.content.\(metric.rawValue)" }
        static let appLanguage = "general.appLanguage"
        /// Read by the CLI through `UserDefaults(suiteName: AppIdentity.bundleID)`.
        static let cliLanguage = "cli.language"
        static let cliFormat = "cli.format"
        static let cacheWriteRatio = "energy.cacheWriteRatio"
        static let cacheReadRatio = "energy.cacheReadRatio"
        static let gridGramsPerKWh = "grid.gramsPerKWh"
        static let includeLocalEnergy = "energy.includeLocal"
        static let dayWindow = "general.dayWindow"
        static let disabledEquivalents = "equivalents.disabled"
        static func customPaths(_ source: UsageSource) -> String { "sources.customPaths.\(source.rawValue)" }
        static let retention = "data.retention"
        static let dailyEnabled = "notifications.daily.enabled"
        static let dailyMinutes = "notifications.daily.minutes"
        static let weeklyEnabled = "notifications.weekly.enabled"
        static let thresholdEnabled = "notifications.threshold.enabled"
        static let thresholdWh = "notifications.threshold.wh"
        static let completionAlert = "notifications.completion.menuBar"
        static let completionPopover = "notifications.completion.popover"
        static let completionNotification = "notifications.completion.system"
    }

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let factorDefaults: EnergyFactors?
    /// Language in effect for this run; a change applies at the next launch.
    @ObservationIgnored let appLanguageAtLaunch: AppLanguage

    // MARK: Menu bar

    var menuBarSplit: MenuBarSplit {
        didSet { defaults.set(menuBarSplit.rawValue, forKey: Key.split) }
    }

    var combinedDisplay: CombinedDisplay {
        didSet { defaults.set(combinedDisplay.rawValue, forKey: Key.combined) }
    }

    var energyUnit: EnergyUnit {
        didSet { defaults.set(energyUnit.rawValue, forKey: Key.unit) }
    }

    var decimals: DecimalsSetting {
        didSet { defaults.set(decimals.rawValue, forKey: Key.decimals) }
    }

    private(set) var contents: [MenuBarMetric: MenuBarContent]

    // MARK: General

    var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Key.appLanguage)
            // Takes effect at the next launch.
            if appLanguage == .system {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([appLanguage.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    var cliLanguage: CLILanguage {
        didSet { defaults.set(cliLanguage.rawValue, forKey: Key.cliLanguage) }
    }

    /// Status line format, read by the CLI when no `--format` is given.
    var cliFormat: StatusLineFormat {
        didSet { defaults.set(cliFormat.rawValue, forKey: Key.cliFormat) }
    }

    // MARK: Calculation

    var cacheWriteRatio: Double {
        didSet { defaults.set(cacheWriteRatio, forKey: Key.cacheWriteRatio) }
    }

    var cacheReadRatio: Double {
        didSet { defaults.set(cacheReadRatio, forKey: Key.cacheReadRatio) }
    }

    /// Fixed grid carbon intensity, gCO2e/kWh (SPEC 5.4).
    var gridGramsPerKWh: Double {
        didSet { defaults.set(gridGramsPerKWh, forKey: Key.gridGramsPerKWh) }
    }

    /// Measure this Mac's own power use and add it to displayed energy (off by default).
    /// What the "today" figures cover: the calendar day, or the last 24 hours so they do not reset at midnight.
    var dayWindow: DayWindow = .calendarDay {
        didSet { defaults.set(dayWindow.rawValue, forKey: Key.dayWindow) }
    }

    /// A string key for the current day window: keys that say "today" have a ".24h" variant.
    func dayKey(_ key: String) -> String {
        dayWindow == .last24Hours ? key + ".24h" : key
    }

    func dayText(_ key: String) -> String {
        Bundle.main.localizedString(forKey: dayKey(key), value: nil, table: nil)
    }

    var includeLocalEnergy: Bool {
        didSet { defaults.set(includeLocalEnergy, forKey: Key.includeLocalEnergy) }
    }

    var disabledEquivalents: Set<String> {
        didSet { defaults.set(disabledEquivalents.sorted(), forKey: Key.disabledEquivalents) }
    }

    // MARK: Data sources

    private(set) var customPaths: [UsageSource: [String]]

    var retention: DataRetention {
        didSet { defaults.set(retention.rawValue, forKey: Key.retention) }
    }

    // MARK: Notifications

    var dailyReportEnabled: Bool {
        didSet { defaults.set(dailyReportEnabled, forKey: Key.dailyEnabled) }
    }

    /// Minutes after local midnight.
    var dailyReportMinutes: Int {
        didSet { defaults.set(dailyReportMinutes, forKey: Key.dailyMinutes) }
    }

    var weeklyReportEnabled: Bool {
        didSet { defaults.set(weeklyReportEnabled, forKey: Key.weeklyEnabled) }
    }

    var thresholdEnabled: Bool {
        didSet { defaults.set(thresholdEnabled, forKey: Key.thresholdEnabled) }
    }

    var thresholdWh: Double {
        didSet { defaults.set(thresholdWh, forKey: Key.thresholdWh) }
    }

    /// Show an alert icon in the menu bar when a conversation finishes a turn.
    var completionAlertEnabled: Bool {
        didSet { defaults.set(completionAlertEnabled, forKey: Key.completionAlert) }
    }

    /// Send a system notification when a conversation finishes a turn.
    var completionNotificationEnabled: Bool {
        didSet { defaults.set(completionNotificationEnabled, forKey: Key.completionNotification) }
    }

    /// Open the menu bar panel when a conversation finishes a turn.
    var completionOpensPopover: Bool {
        didSet { defaults.set(completionOpensPopover, forKey: Key.completionPopover) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        factorDefaults = try? EnergyFactors.bundled()

        menuBarSplit = defaults.string(forKey: Key.split).flatMap(MenuBarSplit.init) ?? .combined
        combinedDisplay = defaults.string(forKey: Key.combined).flatMap(CombinedDisplay.init) ?? .energy
        energyUnit = defaults.string(forKey: Key.unit).flatMap(EnergyUnit.init) ?? .auto
        decimals = DecimalsSetting(rawValue: defaults.object(forKey: Key.decimals) as? Int ?? -1) ?? .automatic
        var contents: [MenuBarMetric: MenuBarContent] = [:]
        for metric in MenuBarMetric.allCases {
            let stored = defaults.string(forKey: Key.content(metric)).flatMap(MenuBarContent.init)
            let value = stored.flatMap { MenuBarContent.options(for: metric).contains($0) ? $0 : nil }
            contents[metric] = value ?? .iconAndValue
        }
        self.contents = contents

        dayWindow = defaults.string(forKey: Key.dayWindow).flatMap(DayWindow.init) ?? .calendarDay
        let language = defaults.string(forKey: Key.appLanguage).flatMap(AppLanguage.init) ?? .system
        appLanguage = language
        appLanguageAtLaunch = language
        cliLanguage = defaults.string(forKey: Key.cliLanguage).flatMap(CLILanguage.init) ?? .english
        cliFormat = defaults.string(forKey: Key.cliFormat).flatMap(StatusLineFormat.init) ?? .default

        cacheWriteRatio = defaults.object(forKey: Key.cacheWriteRatio) as? Double ?? factorDefaults?.cacheWriteRatio ?? 1.0
        cacheReadRatio = defaults.object(forKey: Key.cacheReadRatio) as? Double ?? factorDefaults?.cacheReadRatio ?? 0.08
        gridGramsPerKWh = defaults.object(forKey: Key.gridGramsPerKWh) as? Double ?? GridIntensity.cloudAverageDefault.gramsPerKWh
        disabledEquivalents = Set(defaults.stringArray(forKey: Key.disabledEquivalents) ?? [])
        includeLocalEnergy = defaults.bool(forKey: Key.includeLocalEnergy)

        var paths: [UsageSource: [String]] = [:]
        for source in UsageSource.allCases {
            paths[source] = defaults.stringArray(forKey: Key.customPaths(source)) ?? []
        }
        customPaths = paths
        retention = defaults.string(forKey: Key.retention).flatMap(DataRetention.init) ?? .forever

        dailyReportEnabled = defaults.bool(forKey: Key.dailyEnabled)
        dailyReportMinutes = defaults.object(forKey: Key.dailyMinutes) as? Int ?? 18 * 60
        weeklyReportEnabled = defaults.bool(forKey: Key.weeklyEnabled)
        thresholdEnabled = defaults.bool(forKey: Key.thresholdEnabled)
        thresholdWh = defaults.object(forKey: Key.thresholdWh) as? Double ?? 1000
        completionAlertEnabled = defaults.object(forKey: Key.completionAlert) as? Bool ?? true
        completionOpensPopover = defaults.object(forKey: Key.completionPopover) as? Bool ?? true
        completionNotificationEnabled = defaults.object(forKey: Key.completionNotification) as? Bool ?? true
    }

    // MARK: Menu bar helpers

    func content(for metric: MenuBarMetric) -> MenuBarContent {
        contents[metric] ?? .iconAndValue
    }

    func setContent(_ content: MenuBarContent, for metric: MenuBarMetric) {
        guard MenuBarContent.options(for: metric).contains(content) else { return }
        contents[metric] = content
        defaults.set(content.rawValue, forKey: Key.content(metric))
    }

    /// Metrics shown in the menu bar, in order from left to right.
    var visibleMetrics: [MenuBarMetric] {
        menuBarSplit == .combined ? combinedDisplay.metrics : MenuBarMetric.allCases
    }

    func formatEnergy(_ wh: Double) -> FormattedValue {
        ValueFormatting.energy(wh: wh, unit: energyUnit, decimals: decimals.places)
    }

    /// Low, mid and high in one unit.
    func formatEnergy(_ estimate: Estimate) -> (low: FormattedValue, mid: FormattedValue, high: FormattedValue) {
        ValueFormatting.energy(estimate, unit: energyUnit, decimals: decimals.places)
    }

    // MARK: Energy display

    /// Server energy for today plus this Mac's measured energy when included.
    func displayedEnergy(_ today: Snapshot.Today) -> DisplayedEnergy {
        let local = includeLocalEnergy ? today.localEnergyWh : nil
        let added = local ?? 0
        return DisplayedEnergy(
            total: Estimate(low: today.energyWh.low + added, mid: today.energyWh.mid + added, high: today.energyWh.high + added),
            server: today.energyWh,
            local: local
        )
    }

    // MARK: Calculation helpers

    var grid: GridIntensity {
        GridIntensity(gramsPerKWh: gridGramsPerKWh, basis: .cloudAverage)
    }

    func makeCalculator() throws -> EnergyCalculator {
        try EnergyCalculator.bundled(cacheWriteRatio: cacheWriteRatio, cacheReadRatio: cacheReadRatio, grid: grid)
    }

    func resetCalculationDefaults() {
        cacheWriteRatio = factorDefaults?.cacheWriteRatio ?? 1.0
        cacheReadRatio = factorDefaults?.cacheReadRatio ?? 0.08
        gridGramsPerKWh = GridIntensity.cloudAverageDefault.gramsPerKWh
    }

    func enabledEquivalents(from items: [EquivalentItem]) -> [EquivalentItem] {
        items.filter { !disabledEquivalents.contains($0.id) }
    }

    func setEquivalent(_ id: String, enabled: Bool) {
        if enabled { disabledEquivalents.remove(id) } else { disabledEquivalents.insert(id) }
    }

    // MARK: Data source helpers

    func customPaths(for source: UsageSource) -> [String] {
        customPaths[source] ?? []
    }

    func addCustomPath(_ path: String, for source: UsageSource) {
        var list = customPaths(for: source)
        guard !list.contains(path) else { return }
        list.append(path)
        customPaths[source] = list
        defaults.set(list, forKey: Key.customPaths(source))
    }

    func removeCustomPath(_ path: String, for source: UsageSource) {
        let list = customPaths(for: source).filter { $0 != path }
        customPaths[source] = list
        defaults.set(list, forKey: Key.customPaths(source))
    }

    var logLocations: LogLocations {
        LogLocations.standard(
            extraClaudeCode: customPaths(for: .claudeCode).map { URL(fileURLWithPath: $0) },
            extraCodex: customPaths(for: .codex).map { URL(fileURLWithPath: $0) },
            extraAntigravity: customPaths(for: .antigravity).map { URL(fileURLWithPath: $0) }
        )
    }
}

/// Energy as shown to the user: the server estimate, optionally plus this Mac's measured energy.
struct DisplayedEnergy {
    var total: Estimate
    var server: Estimate
    /// Nil when local energy is not included.
    var local: Double?

    var includesLocal: Bool { local != nil }
}
