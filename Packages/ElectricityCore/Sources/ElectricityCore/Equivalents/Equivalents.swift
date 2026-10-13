import Foundation

/// One everyday comparison (`equivalents.json`, SPEC 9.6).
public struct EquivalentItem: Sendable, Hashable, Decodable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Decodable {
        /// How long the energy would run an appliance.
        case appliance
        /// Food with the same energy content. Compares energy, not the energy used to produce the food.
        case food
        /// Published per-use energy of digital services, such as an AI prompt or an hour of video.
        case digital
        /// Household electricity use over a period.
        case household
    }

    public var id: String
    public var kind: Kind
    /// Energy of one unit, in Wh.
    public var wh: Double
    public var basis: String
    public var source: String
    /// For items measured in time: the duration of one unit, in seconds.
    public var durationSeconds: Double?
    /// The item the receipt always lists first (appendix R6.1). At most one item should set it.
    public var receiptAnchor: Bool
    /// Receipt text per language code ("zh", "en"), with `%@` where the number goes (appendix R6.4).
    public var receiptLabel: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, kind, wh, basis, source, receiptAnchor, receiptLabel
        case durationSeconds = "duration_seconds"
    }

    public init(id: String, kind: Kind, wh: Double, basis: String = "", source: String = "", durationSeconds: Double? = nil,
                receiptAnchor: Bool = false, receiptLabel: [String: String]? = nil) {
        self.id = id
        self.kind = kind
        self.wh = wh
        self.basis = basis
        self.source = source
        self.durationSeconds = durationSeconds
        self.receiptAnchor = receiptAnchor
        self.receiptLabel = receiptLabel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        wh = try container.decode(Double.self, forKey: .wh)
        basis = try container.decode(String.self, forKey: .basis)
        source = try container.decode(String.self, forKey: .source)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        receiptAnchor = try container.decodeIfPresent(Bool.self, forKey: .receiptAnchor) ?? false
        receiptLabel = try container.decodeIfPresent([String: String].self, forKey: .receiptLabel)
    }
}

public struct EquivalentCatalog: Sendable, Hashable, Decodable {
    public var version: String
    public var items: [EquivalentItem]

    public static func bundled() throws -> EquivalentCatalog {
        try JSONDecoder().decode(EquivalentCatalog.self, from: BundledResource.equivalents.data())
    }
}

/// An item and how many units of it the energy corresponds to.
public struct EquivalentMatch: Sendable, Hashable {
    public var item: EquivalentItem
    public var count: Double

    /// How to express `count` (SPEC 9.6: never "0.0x times").
    public var amount: EquivalentAmount { EquivalentAmount(count: count, durationSeconds: item.durationSeconds) }
}

public enum EquivalentAmount: Sendable, Hashable {
    /// A count of at least 1, already rounded to one decimal place.
    case count(Double)
    /// Below one unit of a time-based item: the equivalent duration, in seconds.
    case duration(seconds: Double)
    /// Below one unit: about 1/n of a unit.
    case fraction(denominator: Int)
    /// Below 1/100 of a unit.
    case lessThanHundredth

    public init(count: Double, durationSeconds: Double?) {
        if count >= 1 {
            self = .count((count * 10).rounded() / 10)
        } else if let durationSeconds {
            self = .duration(seconds: count * durationSeconds)
        } else if count >= 0.01 {
            self = .fraction(denominator: max(2, Int((1 / count).rounded())))
        } else {
            self = .lessThanHundredth
        }
    }
}

public enum EquivalentSelector {
    public static let preferredRange: ClosedRange<Double> = 1...100

    /// Chooses up to `limit` comparisons: one appliance and one food first, preferring counts between 1 and 100,
    /// then further items whose count is in that range. `enabledIDs` nil means all items are enabled.
    public static func select(energyWh: Double, items: [EquivalentItem], enabledIDs: Set<String>? = nil, limit: Int = 3) -> [EquivalentMatch] {
        guard energyWh > 0, limit > 0 else { return [] }
        let candidates = items
            .filter { $0.wh > 0 && (enabledIDs?.contains($0.id) ?? true) }
            .map { EquivalentMatch(item: $0, count: energyWh / $0.wh) }
            .sorted { score($0.count) < score($1.count) }

        var chosen: [EquivalentMatch] = []
        for kind in [EquivalentItem.Kind.appliance, .food] {
            if let best = candidates.first(where: { $0.item.kind == kind }) { chosen.append(best) }
        }
        for match in candidates where chosen.count < limit {
            if preferredRange.contains(match.count) && !chosen.contains(where: { $0.item.id == match.item.id }) {
                chosen.append(match)
            }
        }
        return Array(chosen.prefix(limit))
    }

    /// Counts that read naturally in rotation, for example "about 40 hamburgers" or "about 3,800 prompts".
    public static let rotationRange: ClosedRange<Double> = 1...100_000

    /// A random set of up to `limit` comparisons for rotation. The same `seed` gives the same set, so views stay
    /// stable between redraws; change the seed to rotate. Prefers one food and one other item, and only items whose
    /// count is in `rotationRange`. Falls back to `select` when too few items qualify.
    public static func rotating(energyWh: Double, items: [EquivalentItem], limit: Int, seed: UInt64) -> [EquivalentMatch] {
        guard energyWh > 0, limit > 0 else { return [] }
        let pool = items
            .filter { $0.wh > 0 }
            .map { EquivalentMatch(item: $0, count: energyWh / $0.wh) }
            .filter { rotationRange.contains($0.count) }
        guard pool.count > limit else { return select(energyWh: energyWh, items: items, limit: limit) }

        var generator = SeededGenerator(seed: seed)
        let shuffled = pool.sorted { $0.item.id < $1.item.id }.shuffled(using: &generator)
        var chosen: [EquivalentMatch] = []
        if let food = shuffled.first(where: { $0.item.kind == .food }) { chosen.append(food) }
        if let other = shuffled.first(where: { $0.item.kind != .food }) { chosen.append(other) }
        for match in shuffled where chosen.count < limit && !chosen.contains(where: { $0.item.id == match.item.id }) {
            chosen.append(match)
        }
        // Keep a fixed order inside one set: non-food first, as before.
        return Array(chosen.prefix(limit)).sorted { ($0.item.kind == .food ? 1 : 0) < ($1.item.kind == .food ? 1 : 0) }
    }

    /// Lower is better. Counts inside 1...100 score from 0 to 1, closest to 10 best; counts outside score by distance to the range.
    static func score(_ count: Double) -> Double {
        let logCount = log10(count)
        if preferredRange.contains(count) { return abs(logCount - 1) }
        return 10 + (count < preferredRange.lowerBound ? -logCount : logCount - 2)
    }
}

/// SplitMix64, so a rotation seed always gives the same shuffle.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
