import Foundation

/// JSON files bundled with the core package.
public enum BundledResource: String, CaseIterable, Sendable {
    case energyFactors = "energy-factors"
    case modelTiers = "model-tiers"
    case gridRegions = "grid-regions"
    case equivalents = "equivalents"

    public enum LoadError: Error, Equatable {
        case missing(String)
    }

    public func data() throws -> Data {
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: "json") else {
            throw LoadError.missing(rawValue)
        }
        return try Data(contentsOf: url)
    }
}
