import ElectricityCore
import Foundation
import os

/// Runs log ingestion in the background: a backfill at launch, then a scan whenever FSEvents reports
/// a change, plus a fallback scan every 60 seconds (SPEC 4.3). After each scan the snapshot is rebuilt.
@MainActor
final class IngestCoordinator {
    private static let fallbackInterval: Duration = .seconds(60)
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "ingest")
    private let model: AppModel
    private let settings: AppSettings

    private var store: UsageStore?
    private var service: IngestService?
    private var watcher: LogWatcher?
    private var triggers: AsyncStream<Void>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var lastRetentionRun: Date?
    private var publisher: SnapshotPublisher?
    private var localSampler: Task<Void, Never>?
    private var activityReset: Task<Void, Never>?

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
    }

    func start() {
        guard tasks.isEmpty else { return }
        let store: UsageStore
        let calculator: EnergyCalculator
        do {
            store = try UsageStore(url: AppPaths.database)
            calculator = try settings.makeCalculator()
        } catch {
            logger.error("Could not open the database: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.store = store
        model.store = store
        model.disabledSources = settings.disabledSources
        let locations = settings.logLocations
        let service = IngestService(store: store, calculator: calculator, locations: locations)
        self.service = service
        let publisher = SnapshotPublisher(store: store, url: AppPaths.snapshot)
        self.publisher = publisher
        let includeLocal = settings.includeLocalEnergy
        let dayWindow = settings.dayWindow
        Task {
            await publisher.setIncludeLocalEnergy(includeLocal)
            await publisher.setDayWindow(dayWindow)
        }

        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        triggers = continuation

        // Scans run one at a time; triggers that arrive during a scan collapse into one follow-up scan.
        // Parsing and database work run on the `IngestService` and `SnapshotPublisher` actors.
        tasks.append(Task { [weak self, logger] in
            for await _ in stream {
                await self?.applyRetentionIfDue(store: store)
                let summary = await service.scan { progress in
                    Task { @MainActor in self?.model.scanProgress = progress }
                }
                if summary.eventsInserted > 0 {
                    logger.info("Recorded \(summary.eventsInserted) new usage events")
                }
                let snapshot: Snapshot?
                do {
                    snapshot = try await publisher.refresh()
                } catch {
                    logger.error("Could not update the snapshot: \(error.localizedDescription, privacy: .public)")
                    snapshot = nil
                }
                let stats = await Task.detached { try? store.sourceStats() }.value
                guard let self else { return }
                self.finishScan(summary: summary, snapshot: snapshot, stats: stats ?? [:])
            }
        })
        tasks.append(Task { [continuation] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.fallbackInterval)
                continuation.yield()
            }
        })

        startWatcher(locations: locations)
        applyLocalEnergySetting()
        continuation.yield()
    }

    /// Switches the "today" figures between the calendar day and the last 24 hours.
    func applyDayWindowSetting() {
        guard let publisher else { return }
        let window = settings.dayWindow
        Task {
            await publisher.setDayWindow(window)
            await self.refreshSnapshot()
            self.model.dataVersion += 1
        }
    }

    // MARK: Local energy

    /// Starts or stops sampling this Mac's power, and updates the snapshot accordingly.
    func applyLocalEnergySetting() {
        let include = settings.includeLocalEnergy
        if let publisher {
            Task {
                await publisher.setIncludeLocalEnergy(include)
                await self.refreshSnapshot()
            }
        }
        localSampler?.cancel()
        localSampler = nil
        model.localWatts = nil
        guard include, let store else { return }

        // Every 10 seconds: read the system load and add the energy since the last reading.
        localSampler = Task { [weak self] in
            var integrator = LocalEnergyIntegrator()
            var refreshCount = 0
            while !Task.isCancelled {
                let now = Date()
                let watts = await Task.detached { SystemPowerReader.currentWatts() }.value
                guard let self else { return }
                self.model.localWatts = watts
                self.model.localPowerAvailable = watts != nil
                if let watts {
                    let minutes = integrator.add(watts: watts, at: now)
                    await Task.detached { try? store.addLocalEnergy(minutes) }.value
                }
                // The snapshot is rebuilt every 30 seconds so the local share stays current between scans.
                refreshCount += 1
                if refreshCount % 3 == 0 { await self.refreshSnapshot() }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func refreshSnapshot() async {
        guard let publisher, let snapshot = try? await publisher.refresh() else { return }
        model.snapshot = snapshot
    }

    private func finishScan(summary: ScanSummary, snapshot: Snapshot?, stats: [UsageSource: SourceStats]) {
        if let snapshot {
            if let previous = model.snapshot, previous.today.date == snapshot.today.date,
               snapshot.today.tokens.total > previous.today.tokens.total {
                markIncreasing()
            }
            model.snapshot = snapshot
        }
        model.scanProgress = nil
        model.isBackfilling = false
        if summary.eventsInserted > 0 || model.dataVersion == 0 { model.dataVersion += 1 }

        let locations = settings.logLocations
        for source in UsageSource.allCases {
            var status = model.sourceStatuses[source] ?? SourceStatus(roots: [], existingRoots: [], stats: SourceStats())
            status.roots = locations.roots(for: source)
            status.existingRoots = Set(status.roots.filter { FileManager.default.fileExists(atPath: $0.path) })
            status.stats = stats[source] ?? SourceStats()
            if (summary.bySource[source]?.filesRead ?? 0) > 0 {
                status.lastRead = Date()
            } else if status.lastRead == nil {
                status.lastRead = status.stats.latestRead
            }
            model.sourceStatuses[source] = status
        }
    }

    /// Shows the activity bar until 4 seconds after the last increase.
    private func markIncreasing() {
        model.isIncreasing = true
        activityReset?.cancel()
        activityReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.model.isIncreasing = false
        }
    }

    private func startWatcher(locations: LogLocations) {
        watcher?.stop()
        let continuation = triggers
        let watcher = LogWatcher(paths: (locations.claudeCode + locations.claudeDesktop + locations.codex + locations.antigravity).map(\.path), latency: 0.3) {
            continuation?.yield()
        }
        watcher.start()
        self.watcher = watcher
    }

    /// New grid state for records written from now on and for the snapshot.
    func setGrid(_ statuses: [GridProvider: GridStatus]) async {
        await service?.setGrid(statuses)
        guard let publisher else { return }
        await publisher.setGrid(statuses)
        await refreshSnapshot()
    }

    // MARK: Actions from settings

    func rescan() {
        triggers?.yield()
    }

    /// Applies new cache ratios or grid intensity to records written from now on.
    func applyCalculationSettings() {
        guard let service, let calculator = try? settings.makeCalculator() else { return }
        Task { await service.setCalculator(calculator) }
    }

    /// Applies added or removed custom paths and scans them.
    func applySourcePaths() {
        model.disabledSources = settings.disabledSources
        guard let service else { return }
        let locations = settings.logLocations
        Task {
            await service.setLocations(locations)
            self.startWatcher(locations: locations)
            self.rescan()
        }
    }

    /// Recomputes all stored records with the current factors and settings (SPEC 5.5).
    func recalculateAll() async {
        guard let store, let calculator = try? settings.makeCalculator() else { return }
        model.isRecalculating = true
        applyCalculationSettings()
        do {
            try await Task.detached { _ = try store.recalculateAll(with: calculator) }.value
        } catch {
            logger.error("Recalculation failed: \(error.localizedDescription, privacy: .public)")
        }
        model.isRecalculating = false
        model.dataVersion += 1
        rescan()
    }

    /// Deletes all stored records. Log files already read are not imported again; only new usage is recorded.
    func clearAllData() async {
        guard let store else { return }
        do {
            try await Task.detached {
                _ = try store.deleteEvents(before: .distantFuture)
                try store.deleteLocalEnergy()
            }.value
        } catch {
            logger.error("Could not clear data: \(error.localizedDescription, privacy: .public)")
        }
        model.dataVersion += 1
        rescan()
    }

    func applyRetention() {
        lastRetentionRun = nil
        rescan()
    }

    /// Deletes records older than the retention period, at most once per hour.
    private func applyRetentionIfDue(store: UsageStore) async {
        guard let years = settings.retention.years else { return }
        if let lastRetentionRun, Date().timeIntervalSince(lastRetentionRun) < 3600 { return }
        lastRetentionRun = Date()
        guard let cutoff = Calendar.current.date(byAdding: .year, value: -years, to: Date()) else { return }
        let deleted = await Task.detached { (try? store.deleteEvents(before: cutoff)) ?? 0 }.value
        if deleted > 0 { model.dataVersion += 1 }
    }

    /// Stops background work and marks the snapshot as no longer updated, so the CLI can show it as stale.
    func stop() {
        localSampler?.cancel()
        watcher?.stop()
        triggers?.finish()
        tasks.forEach { $0.cancel() }
        tasks = []
        if var snapshot = model.snapshot {
            snapshot.appRunning = false
            try? SnapshotFile.write(snapshot, to: AppPaths.snapshot)
        }
    }
}
