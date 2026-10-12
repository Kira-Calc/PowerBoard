import Foundation

/// Builds snapshots from the database and writes the snapshot file at most once per `minInterval` (SPEC 7).
/// A refresh that arrives too soon is written when the interval has passed, so the last state is never lost.
public actor SnapshotPublisher {
    private let store: UsageStore
    private let url: URL
    private let minInterval: TimeInterval
    private let calendar: @Sendable () -> Calendar

    private var includeLocalEnergy = false
    private var dayWindow: DayWindow = .calendarDay
    private var grid: [GridProvider: GridStatus] = [:]
    private var lastWrite: Date?
    private var latest: Snapshot?
    private var trailingWrite: Task<Void, Never>?

    public init(store: UsageStore, url: URL, minInterval: TimeInterval = 1, calendar: @escaping @Sendable () -> Calendar = { .current }) {
        self.store = store
        self.url = url
        self.minInterval = minInterval
        self.calendar = calendar
    }

    public func setIncludeLocalEnergy(_ include: Bool) {
        includeLocalEnergy = include
    }

    public func setDayWindow(_ window: DayWindow) {
        dayWindow = window
    }

    public func setGrid(_ statuses: [GridProvider: GridStatus]) {
        grid = statuses
    }

    /// Rebuilds the snapshot, writes it (now or after the throttle interval) and returns it.
    @discardableResult
    public func refresh(now: Date = Date()) throws -> Snapshot {
        let snapshot = try SnapshotBuilder.build(store: store, now: now, calendar: calendar(), includeLocalEnergy: includeLocalEnergy, grid: grid,
                                                  dayWindow: dayWindow)
        latest = snapshot
        if let lastWrite, now.timeIntervalSince(lastWrite) < minInterval {
            if trailingWrite == nil {
                let delay = minInterval - now.timeIntervalSince(lastWrite)
                trailingWrite = Task {
                    try? await Task.sleep(for: .seconds(delay))
                    self.flush()
                }
            }
        } else {
            try write(snapshot)
        }
        return snapshot
    }

    private func flush() {
        trailingWrite = nil
        if let latest { try? write(latest) }
    }

    private func write(_ snapshot: Snapshot) throws {
        try SnapshotFile.write(snapshot, to: url)
        lastWrite = Date()
    }
}
