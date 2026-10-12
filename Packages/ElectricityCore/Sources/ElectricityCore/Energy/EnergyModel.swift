import Foundation

/// Energy factors per model tier (`energy-factors.json`).
public struct EnergyFactors: Sendable, Decodable, Equatable {
    public struct TierFactors: Sendable, Decodable, Equatable {
        /// Wh per million effective input tokens.
        public var input: Double
        /// Wh per million output tokens.
        public var output: Double
    }

    public struct Uncertainty: Sendable, Decodable, Equatable {
        public var low: Double
        public var high: Double
    }

    public var version: String
    public var unit: String
    public var source: String
    public let cacheReadRatio: Double
    public let cacheWriteRatio: Double
    public var uncertainty: Uncertainty
    public var tiers: [String: TierFactors]

    enum CodingKeys: String, CodingKey {
        case version, unit, source, uncertainty, tiers
        case cacheReadRatio = "cache_read_ratio"
        case cacheWriteRatio = "cache_write_ratio"
    }

    public static func bundled() throws -> EnergyFactors {
        try JSONDecoder().decode(EnergyFactors.self, from: BundledResource.energyFactors.data())
    }
}

/// How confident the tier assignment for a model is.
public enum TierConfidence: String, Sendable, Codable, CaseIterable {
    case measured
    case extrapolated
    case assumed
    case unmapped
}

public struct TierAssignment: Sendable, Hashable {
    public var tier: String
    public var confidence: TierConfidence
}

/// Model-name to tier rules (`model-tiers.json`). First matching rule wins; matching ignores case.
public struct ModelTierTable: Sendable, Decodable, Equatable {
    public struct Rule: Sendable, Decodable, Equatable {
        public var match: String
        public var tier: String
        public var confidence: TierConfidence
    }

    public struct Fallback: Sendable, Decodable, Equatable {
        public var tier: String
        public var confidence: TierConfidence
    }

    public var rules: [Rule]
    public var fallback: Fallback

    public static func bundled() throws -> ModelTierTable {
        try JSONDecoder().decode(ModelTierTable.self, from: BundledResource.modelTiers.data())
    }

    public func classify(model: String) -> TierAssignment {
        let lowered = model.lowercased()
        for rule in rules where lowered.contains(rule.match.lowercased()) {
            return TierAssignment(tier: rule.tier, confidence: rule.confidence)
        }
        return TierAssignment(tier: fallback.tier, confidence: fallback.confidence)
    }
}

/// Basis of a grid carbon intensity value (SPEC 6.1 `grid_basis`).
public enum GridBasis: String, Sendable, Codable {
    case cloudAverage = "cloud_average"
    case regionStatic = "region_static"
    case regionLive = "region_live"
}

public struct GridIntensity: Sendable, Hashable {
    public var gramsPerKWh: Double
    public var basis: GridBasis
    public var region: String?

    public init(gramsPerKWh: Double, basis: GridBasis, region: String? = nil) {
        self.gramsPerKWh = gramsPerKWh
        self.basis = basis
        self.region = region
    }

    /// Cloud provider grid average (AWS), matching claude-carbon (SPEC 5.4).
    public static let cloudAverageDefault = GridIntensity(gramsPerKWh: 287, basis: .cloudAverage)
}

/// The computed energy and carbon for one usage record, with the context used to compute it (SPEC 5.5).
public struct EnergyResult: Sendable, Hashable {
    public var tier: TierAssignment
    public var energyWh: Estimate
    public var co2Grams: Estimate
    public var factorVersion: String
    public let grid: GridIntensity
}

public enum EnergyModelError: Error, Equatable {
    case unknownTier(String)
}

/// Computes energy and carbon estimates (SPEC 5.1).
public struct EnergyCalculator: Sendable {
    public let factors: EnergyFactors
    public let tierTable: ModelTierTable
    public let cacheWriteRatio: Double
    public let cacheReadRatio: Double
    public let grid: GridIntensity

    /// Fails if any tier referenced by the tier table has no factors.
    public init(
        factors: EnergyFactors,
        tierTable: ModelTierTable,
        cacheWriteRatio: Double? = nil,
        cacheReadRatio: Double? = nil,
        grid: GridIntensity = .cloudAverageDefault
    ) throws {
        let referenced = tierTable.rules.map(\.tier) + [tierTable.fallback.tier]
        if let missing = referenced.first(where: { factors.tiers[$0] == nil }) {
            throw EnergyModelError.unknownTier(missing)
        }
        self.factors = factors
        self.tierTable = tierTable
        self.cacheWriteRatio = cacheWriteRatio ?? factors.cacheWriteRatio
        self.cacheReadRatio = cacheReadRatio ?? factors.cacheReadRatio
        self.grid = grid
    }

    public static func bundled(
        cacheWriteRatio: Double? = nil,
        cacheReadRatio: Double? = nil,
        grid: GridIntensity = .cloudAverageDefault
    ) throws -> EnergyCalculator {
        try EnergyCalculator(
            factors: .bundled(),
            tierTable: .bundled(),
            cacheWriteRatio: cacheWriteRatio,
            cacheReadRatio: cacheReadRatio,
            grid: grid
        )
    }

    public func estimate(model: String, tokens: TokenCounts, grid: GridIntensity? = nil) -> EnergyResult {
        let assignment = tierTable.classify(model: model)
        // The initializer guarantees every reachable tier has factors.
        let tierFactors = factors.tiers[assignment.tier]!
        let effectiveInput = Double(tokens.inputUncached)
            + Double(tokens.cacheWrite) * cacheWriteRatio
            + Double(tokens.cacheRead) * cacheReadRatio
        let midWh = effectiveInput / 1e6 * tierFactors.input + Double(tokens.output) / 1e6 * tierFactors.output
        let energy = Estimate(
            low: midWh * factors.uncertainty.low,
            mid: midWh,
            high: midWh * factors.uncertainty.high
        )
        let usedGrid = grid ?? self.grid
        return EnergyResult(
            tier: assignment,
            energyWh: energy,
            co2Grams: energy.scaled(by: usedGrid.gramsPerKWh / 1000),
            factorVersion: factors.version,
            grid: usedGrid
        )
    }
}
