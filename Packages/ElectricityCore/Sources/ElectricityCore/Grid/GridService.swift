import Foundation

/// Fetches grid data for each provider's candidate locations, at most every 15 minutes per location,
/// and falls back to the last good reading or to static annual averages when a request fails (SPEC 10.3).
public actor GridService {
    public struct Configuration: Sendable {
        public var watttime: WattTimeCredentials?
        public var electricityMapsKey: String?
        public var thresholds: GridThresholds

        public init(watttime: WattTimeCredentials? = nil, electricityMapsKey: String? = nil, thresholds: GridThresholds = GridThresholds()) {
            self.watttime = watttime
            self.electricityMapsKey = electricityMapsKey
            self.thresholds = thresholds
        }

        public var hasLiveSource: Bool { watttime != nil || electricityMapsKey != nil }
    }

    public static let refreshInterval: TimeInterval = 15 * 60
    /// EIA publishes about a day late, so its mix is fetched at most every 6 hours per balancing authority.
    public static let recentMixInterval: TimeInterval = 6 * 3600

    private let table: GridRegionTable
    private let transport: HTTPTransport
    private var configuration: Configuration
    private var watttime: WattTimeClient?
    private var cache: [String: CandidateReading] = [:]
    private var lastFetch: [String: Date] = [:]
    /// Candidate ID to WattTime region, found once from coordinates.
    public private(set) var regions: [String: String]
    public private(set) var lastError: GridAPIError?
    private var recentMixes: [String: RecentFuelMix] = [:]
    private var recentMixFetched: [String: Date] = [:]

    public init(table: GridRegionTable, configuration: Configuration, regions: [String: String] = [:],
                transport: HTTPTransport = URLSessionTransport()) {
        self.table = table
        self.configuration = configuration
        self.regions = regions
        self.transport = transport
        watttime = configuration.watttime.map { WattTimeClient(credentials: $0, transport: transport) }
    }

    public func configure(_ configuration: Configuration) {
        if configuration.watttime != self.configuration.watttime {
            watttime = configuration.watttime.map { WattTimeClient(credentials: $0, transport: transport) }
            cache = [:]
            lastFetch = [:]
        }
        if configuration.electricityMapsKey != self.configuration.electricityMapsKey {
            lastFetch = [:]
        }
        self.configuration = configuration
    }

    /// Current status for every provider.
    public func statuses(now: Date = Date()) async -> [GridProvider: GridStatus] {
        await withTaskGroup(of: (GridProvider, GridStatus).self) { group in
            for provider in GridProvider.allCases {
                group.addTask { (provider, await self.status(for: provider, now: now)) }
            }
            var result: [GridProvider: GridStatus] = [:]
            for await (provider, status) in group { result[provider] = status }
            return result
        }
    }

    public func status(for provider: GridProvider, now: Date = Date()) async -> GridStatus {
        let candidates = table.candidates(for: provider)
        // Locations are fetched concurrently; the actor interleaves them while each waits on the network.
        let readings = await withTaskGroup(of: CandidateReading.self) { group in
            for candidate in candidates {
                group.addTask { await self.reading(for: candidate, now: now) }
            }
            var result: [CandidateReading] = []
            for await reading in group { result.append(reading) }
            return result
        }
        return GridCombiner.combine(provider: provider, candidates: candidates, readings: readings, thresholds: configuration.thresholds)
    }

    private func reading(for candidate: GridCandidate, now: Date) async -> CandidateReading {
        var reading = await liveReading(for: candidate, now: now)
        reading.recentMix = recentMix(for: candidate, now: now)
        return reading
    }

    /// Latest published day from EIA (no account needed), from the cache. EIA is slow, so a fetch runs in the
    /// background and its result appears in the next status; it never delays live WattTime data.
    private func recentMix(for candidate: GridCandidate, now: Date) -> RecentFuelMix? {
        guard let ba = candidate.eiaBalancingAuthority, !ba.isEmpty else { return nil }
        if recentMixFetched[ba].map({ now.timeIntervalSince($0) >= Self.recentMixInterval }) ?? true {
            recentMixFetched[ba] = now
            let transport = self.transport
            Task {
                if let mix = try? await EIAFuelMixClient(transport: transport).recentMix(balancingAuthority: ba, now: now) {
                    self.storeRecentMix(mix)
                }
            }
        }
        return recentMixes[ba]
    }

    private func storeRecentMix(_ mix: RecentFuelMix) {
        recentMixes[mix.balancingAuthority] = mix
    }

    private func liveReading(for candidate: GridCandidate, now: Date) async -> CandidateReading {
        let fallback = CandidateReading(candidateID: candidate.id, gramsPerKWh: candidate.staticGramsPerKWh, source: .static)
        guard configuration.hasLiveSource else { return fallback }
        if let cached = cache[candidate.id], let fetched = lastFetch[candidate.id], now.timeIntervalSince(fetched) < Self.refreshInterval {
            return cached
        }
        lastFetch[candidate.id] = now

        var reading = CandidateReading(candidateID: candidate.id, gramsPerKWh: candidate.staticGramsPerKWh, source: .static)
        var gotLive = false
        if let watttime {
            do {
                let region = try await watttimeRegion(for: candidate, client: watttime)
                let index = try await watttime.signalIndex(region: region)
                reading.percentile = index.percentile
                reading.observedAt = index.at ?? now
                reading.region = region
                reading.source = .watttime
                gotLive = true
                lastError = nil
            } catch {
                lastError = error as? GridAPIError ?? .badResponse
            }
        }
        if let key = configuration.electricityMapsKey, !candidate.emapsZone.isEmpty {
            do {
                let latest = try await ElectricityMapsClient(apiKey: key, transport: transport).latest(zone: candidate.emapsZone)
                reading.gramsPerKWh = latest.gramsPerKWh ?? reading.gramsPerKWh
                reading.cleanShare = latest.cleanShare
                reading.observedAt = reading.observedAt ?? latest.at ?? now
                if !gotLive { reading.source = .electricitymaps }
                gotLive = true
            } catch {
                lastError = error as? GridAPIError ?? .badResponse
            }
        }
        if gotLive {
            cache[candidate.id] = reading
            return reading
        }
        // Keep showing the last good reading (with its time) rather than dropping to static data.
        return cache[candidate.id] ?? fallback
    }

    private func watttimeRegion(for candidate: GridCandidate, client: WattTimeClient) async throws -> String {
        if !candidate.watttimeRegion.isEmpty { return candidate.watttimeRegion }
        if let region = regions[candidate.id] { return region }
        let region = try await client.region(latitude: candidate.latitude, longitude: candidate.longitude)
        regions[candidate.id] = region
        return region
    }
}
