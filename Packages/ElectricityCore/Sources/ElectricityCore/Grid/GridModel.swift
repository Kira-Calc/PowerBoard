import Foundation
import GRDB

/// AI provider whose servers run a tool's requests.
public enum GridProvider: String, Sendable, Hashable, CaseIterable, Codable {
    case anthropic
    case openai
    case google

    public init(source: UsageSource) {
        switch source {
        case .claudeCode: self = .anthropic
        case .codex: self = .openai
        case .antigravity: self = .google
        }
    }
}

/// A possible inference location (`grid-regions.json`, SPEC 10.2).
public struct GridCandidate: Sendable, Hashable, Decodable, Identifiable {
    public var id: String
    public var nameEn: String
    public var nameZh: String
    public var latitude: Double
    public var longitude: Double
    public var weight: Double
    /// WattTime region code. Empty means it is looked up from the coordinates.
    public var watttimeRegion: String
    public var emapsZone: String
    /// EIA-930 balancing authority, for the recent fuel mix shown without an account.
    public var eiaBalancingAuthority: String?
    /// Annual average grid carbon intensity, gCO2e/kWh, used when no live data is connected.
    public var staticGramsPerKWh: Double?
    public var staticBasis: String?
    public var note: String

    enum CodingKeys: String, CodingKey {
        case id, latitude, longitude, weight, note
        case nameEn = "name_en"
        case nameZh = "name_zh"
        case watttimeRegion = "watttime_region"
        case emapsZone = "emaps_zone"
        case eiaBalancingAuthority = "eia_ba"
        case staticGramsPerKWh = "static_g_per_kwh"
        case staticBasis = "static_basis"
    }
}

public struct GridRegionTable: Sendable, Hashable, Decodable {
    struct Provider: Sendable, Hashable, Decodable {
        var candidates: [GridCandidate]
    }

    public var version: String
    var providers: [String: Provider]

    public static func bundled() throws -> GridRegionTable {
        try JSONDecoder().decode(GridRegionTable.self, from: BundledResource.gridRegions.data())
    }

    /// Candidates with a positive weight. Empty when the provider has none (location unknown).
    public func candidates(for provider: GridProvider) -> [GridCandidate] {
        (providers[provider.rawValue]?.candidates ?? []).filter { $0.weight > 0 }
    }
}

/// Grid level relative to the grid's own recent range (SPEC 10.1).
public enum GridLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case cleaner
    case typical
    case lessClean
}

/// Maps a WattTime CO2 percentile to a level. The percentile ranks the current marginal emissions of a region
/// against its forecast for the next 24 hours, 0 cleanest to 100 dirtiest (WattTime API spec); the default
/// splits it into equal thirds (SPEC 10.3).
public struct GridThresholds: Sendable, Hashable, Codable {
    /// Percentiles below this are "cleaner".
    public var cleanerBelow: Double
    /// Percentiles above this are "less clean".
    public var lessCleanAbove: Double

    public init(cleanerBelow: Double = 100.0 / 3, lessCleanAbove: Double = 200.0 / 3) {
        self.cleanerBelow = cleanerBelow
        self.lessCleanAbove = lessCleanAbove
    }

    public func level(percentile: Double) -> GridLevel {
        if percentile < cleanerBelow { return .cleaner }
        if percentile > lessCleanAbove { return .lessClean }
        return .typical
    }
}

public enum GridDataSource: String, Sendable, Hashable, Codable {
    case watttime
    case electricitymaps
    case `static`
}

public enum LocationCertainty: String, Sendable, Hashable, Codable {
    /// Known from the request, such as a regional endpoint.
    case known
    /// Estimated from the candidate table.
    case estimated
    /// No candidates are configured.
    case unknown
}

/// Live or static data for one candidate.
public struct CandidateReading: Sendable, Hashable, Codable {
    public var candidateID: String
    /// WattTime CO2 percentile, 0 cleanest to 100 dirtiest.
    public var percentile: Double?
    public var gramsPerKWh: Double?
    /// Share of fossil-free electricity, 0 to 1.
    public var cleanShare: Double?
    public var source: GridDataSource
    public var observedAt: Date?
    public var region: String?
    /// Fossil-free share over the latest 24 hours EIA has published (often a day old).
    public var recentMix: RecentFuelMix?

    public init(candidateID: String, percentile: Double? = nil, gramsPerKWh: Double? = nil, cleanShare: Double? = nil,
                source: GridDataSource, observedAt: Date? = nil, region: String? = nil, recentMix: RecentFuelMix? = nil) {
        self.candidateID = candidateID
        self.percentile = percentile
        self.gramsPerKWh = gramsPerKWh
        self.cleanShare = cleanShare
        self.source = source
        self.observedAt = observedAt
        self.region = region
        self.recentMix = recentMix
    }
}

/// Fossil-free share of generation over a past 24-hour window (EIA-930). Not a statement about now.
public struct RecentFuelMix: Sendable, Hashable, Codable {
    public var balancingAuthority: String
    public var cleanShare: Double
    public var start: Date
    public var end: Date
}

/// Combined grid state for one provider.
public struct GridStatus: Sendable, Hashable, Codable {
    public var provider: GridProvider
    /// Nil when there is no live percentile (static data or unknown location).
    public var level: GridLevel?
    public var percentile: Double?
    public var gramsPerKWh: Double?
    public var cleanShare: Double?
    public var source: GridDataSource?
    public var certainty: LocationCertainty
    public var updatedAt: Date?
    /// True when candidates with live data are at different levels.
    public var mixed: Bool
    public var candidates: [CandidateReading]
    public var candidateLevels: [String: GridLevel]
    /// Weighted fossil-free share of the latest published day, with the end of its window.
    public var recentCleanShare: Double?
    public var recentMixEnd: Date?

    public static func unknown(_ provider: GridProvider) -> GridStatus {
        GridStatus(provider: provider, level: nil, percentile: nil, gramsPerKWh: nil, cleanShare: nil, source: nil,
                   certainty: .unknown, updatedAt: nil, mixed: false, candidates: [], candidateLevels: [:],
                   recentCleanShare: nil, recentMixEnd: nil)
    }
}

public enum GridCombiner {
    /// Weighted combination of candidate readings (SPEC 10.2). Weights are renormalized over candidates with data.
    public static func combine(provider: GridProvider, candidates: [GridCandidate], readings: [CandidateReading],
                               thresholds: GridThresholds) -> GridStatus {
        guard !candidates.isEmpty else { return .unknown(provider) }
        let weights = Dictionary(candidates.map { ($0.id, $0.weight) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(readings.map { ($0.candidateID, $0) }, uniquingKeysWith: { first, _ in first })
        let present = candidates.compactMap { byID[$0.id] }

        func weighted(_ value: (CandidateReading) -> Double?) -> Double? {
            let pairs = present.compactMap { reading in value(reading).map { ($0, weights[reading.candidateID] ?? 0) } }
            let total = pairs.reduce(0) { $0 + $1.1 }
            guard total > 0 else { return nil }
            return pairs.reduce(0) { $0 + $1.0 * $1.1 } / total
        }

        let percentile = weighted(\.percentile)
        var levels: [String: GridLevel] = [:]
        for reading in present {
            if let value = reading.percentile { levels[reading.candidateID] = thresholds.level(percentile: value) }
        }
        let source: GridDataSource? = if present.contains(where: { $0.percentile != nil }) {
            .watttime
        } else if present.contains(where: { $0.source == .electricitymaps }) {
            .electricitymaps
        } else if present.isEmpty {
            nil
        } else {
            .static
        }
        return GridStatus(
            provider: provider,
            level: percentile.map { thresholds.level(percentile: $0) },
            percentile: percentile,
            gramsPerKWh: weighted(\.gramsPerKWh),
            cleanShare: weighted(\.cleanShare),
            source: source,
            certainty: .estimated,
            updatedAt: present.compactMap(\.observedAt).max(),
            mixed: Set(levels.values).count > 1,
            candidates: present,
            candidateLevels: levels,
            recentCleanShare: weighted { $0.recentMix?.cleanShare },
            recentMixEnd: present.compactMap { $0.recentMix?.end }.max()
        )
    }
}

extension UsageStore {
    /// Mid energy (Wh) per recorded grid level for `start <= ts < end`. Records without a level use the nil key.
    public func energyByGridLevel(from start: Date, to end: Date) throws -> [GridLevel?: Double] {
        try read { db in
            var result: [GridLevel?: Double] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT clean_level, SUM(energy_wh_mid) FROM usage_event WHERE ts_utc >= ? AND ts_utc < ? GROUP BY clean_level
                """, arguments: [Self.milliseconds(start), Self.milliseconds(end)]) {
                let raw: String? = row[0]
                result[raw.flatMap(GridLevel.init)] = row[1]
            }
            return result
        }
    }
}
