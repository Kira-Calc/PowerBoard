import ElectricityCore
import Foundation
import Observation

/// Status of one data source, for the data source settings page.
struct SourceStatus: Hashable {
    var roots: [URL]
    var existingRoots: Set<URL>
    var stats: SourceStats
    /// Last time a scan read new lines from this source, or the latest log change read before launch.
    var lastRead: Date?

    var isFound: Bool { !existingRoots.isEmpty }
}

/// State shown by the display layers. Updated on the main actor from background work.
@MainActor
@Observable
final class AppModel {
    /// Latest snapshot, nil until the first scan finishes.
    var snapshot: Snapshot?
    /// Progress of the running scan, nil when idle.
    var scanProgress: IngestProgress?
    /// True until the first scan after launch has finished.
    var isBackfilling = true
    /// Incremented whenever stored data changes, so pages reload their queries.
    var dataVersion = 0
    var sourceStatuses: [UsageSource: SourceStatus] = [:]
    /// Estimated generation mix per provider over an interval, for reports. Set by the grid coordinator.
    @ObservationIgnored var energyMixProvider: (@MainActor (DateInterval) async -> [GridProvider: EnergyMix])?

    func energyMixes(for interval: DateInterval) async -> [GridProvider: EnergyMix] {
        await energyMixProvider?(interval) ?? [:]
    }

    /// Tools that have usage records. Lists in the UI show only these, so someone who uses one tool sees only that
    /// tool. Until the first records are read, every tool is listed.
    var usedSources: [UsageSource] {
        let enabled = UsageSource.allCases.filter { !disabledSources.contains($0) }
        let used = enabled.filter { (sourceStatuses[$0]?.stats.eventCount ?? 0) > 0 }
        return used.isEmpty ? enabled : used
    }

    /// Tools turned off on the integrations page (mirrors `AppSettings.disabledSources`).
    var disabledSources: Set<UsageSource> = []

    /// Providers behind the tools in use, in the same order.
    var usedProviders: [GridProvider] {
        usedSources.map(GridProvider.init(source:)).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    var isRecalculating = false
    /// True for a few seconds after today's token count went up. Drives the menu bar activity bar.
    var isIncreasing = false
    /// Conversations whose agent process is running.
    var activeSessions: [ActiveSession] = []
    /// Set for a few seconds after a conversation finishes a turn.
    var completionAlert: CompletionAlert?
    /// Grid state per provider (SPEC 10).
    var gridStatuses: [GridProvider: GridStatus] = [:]
    /// True when WattTime or Electricity Maps is set up.
    var gridConfigured = false
    /// True until the first grid refresh after launch has finished.
    var gridLoading = true
    var gridError: GridAPIError?

    /// Grid state for the servers used most today, as written to the snapshot.
    var mainGridStatus: GridStatus? {
        let provider = snapshot?.today.grid?.provider ?? usedProviders.first ?? .anthropic
        return gridStatuses[provider]
    }
    /// Latest whole-system power reading in watts, nil when unavailable or not sampled.
    var localWatts: Double?
    /// False when this Mac does not report system power.
    var localPowerAvailable = SystemPowerReader.currentWatts() != nil

    /// The database, available once the coordinator has started. Queries run off the main thread.
    var store: UsageStore?

    let equivalents: [EquivalentItem]
    let factors: EnergyFactors?
    let tierTable: ModelTierTable?

    init() {
        equivalents = (try? EquivalentCatalog.bundled().items) ?? []
        factors = try? EnergyFactors.bundled()
        tierTable = try? ModelTierTable.bundled()
    }
}
