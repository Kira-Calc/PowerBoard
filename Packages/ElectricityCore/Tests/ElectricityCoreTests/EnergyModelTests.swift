import Foundation
import Testing
@testable import ElectricityCore

@Suite struct EnergyModelTests {
    private let million = 1_000_000

    private func isClose(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
        abs(a - b) <= tolerance * max(1, abs(b))
    }

    @Test(arguments: [
        ("claude-haiku-test", 70.0, 1439.0),
        ("claude-sonnet-test", 136.0, 2878.0),
        ("claude-opus-test", 272.0, 5756.0),
        ("claude-fable-test", 544.0, 11512.0),
    ])
    func knownValuesPerTier(model: String, inputFactor: Double, outputFactor: Double) throws {
        let calculator = try TestSupport.calculator()
        let result = calculator.estimate(model: model, tokens: TokenCounts(inputUncached: million, output: million))
        let mid = inputFactor + outputFactor
        #expect(isClose(result.energyWh.mid, mid))
        #expect(isClose(result.energyWh.low, mid * 0.5))
        #expect(isClose(result.energyWh.high, mid * 2.0))
        #expect(isClose(result.co2Grams.mid, mid / 1000 * 287))
        #expect(result.factorVersion == "2026.10-2")
        #expect(result.grid == .cloudAverageDefault)
    }

    @Test func defaultCacheRatios() throws {
        let calculator = try TestSupport.calculator()
        #expect(calculator.cacheWriteRatio == 1.0)
        #expect(calculator.cacheReadRatio == 0.08)
        let read = calculator.estimate(model: "sonnet", tokens: TokenCounts(cacheRead: million))
        #expect(isClose(read.energyWh.mid, 136 * 0.08))
        let write = calculator.estimate(model: "sonnet", tokens: TokenCounts(cacheWrite: million))
        #expect(isClose(write.energyWh.mid, 136))
    }

    @Test func cacheRatioSettingsApply() throws {
        let calculator = try TestSupport.calculator(cacheWriteRatio: 0.5, cacheReadRatio: 0)
        let result = calculator.estimate(model: "sonnet", tokens: TokenCounts(cacheWrite: million, cacheRead: million))
        #expect(isClose(result.energyWh.mid, 68))
    }

    @Test func reasoningIsNotCountedTwice() throws {
        let calculator = try TestSupport.calculator()
        let with = calculator.estimate(model: "sonnet", tokens: TokenCounts(output: million, reasoning: million / 2))
        let without = calculator.estimate(model: "sonnet", tokens: TokenCounts(output: million))
        #expect(with.energyWh == without.energyWh)
    }

    @Test func customGridIntensity() throws {
        let calculator = try TestSupport.calculator()
        let grid = GridIntensity(gramsPerKWh: 100, basis: .regionStatic, region: "TEST")
        let result = calculator.estimate(model: "sonnet", tokens: TokenCounts(output: million), grid: grid)
        #expect(isClose(result.co2Grams.mid, 2878 / 1000 * 100))
        #expect(result.grid == grid)
    }

    @Test func rejectsTierWithoutFactors() throws {
        var table = try ModelTierTable.bundled()
        table.rules.append(.init(match: "x", tier: "galactic", confidence: .assumed))
        #expect(throws: EnergyModelError.unknownTier("galactic")) {
            try EnergyCalculator(factors: .bundled(), tierTable: table)
        }
    }
}

@Suite struct ModelTierTests {
    @Test(arguments: [
        ("claude-opus-5", "large", TierConfidence.extrapolated),
        ("claude-mythos-5", "xlarge", .extrapolated),
        ("claude-fable-5-1", "xlarge", .extrapolated),
        ("claude-sonnet-5-5", "medium", .measured),
        ("claude-haiku-5-5", "small", .extrapolated),
        ("gpt-6-mini", "small", .assumed),
        ("gemini-3.8-flash-high", "small", .assumed),
        ("gemini-3.7-pro", "medium", .assumed),
        ("gpt-6-astra", "medium", .assumed),
        ("codex-latest", "medium", .assumed),
        ("some-new-model", "medium", .unmapped),
        ("unknown", "medium", .unmapped),
    ])
    func eachRule(model: String, tier: String, confidence: TierConfidence) throws {
        let table = try ModelTierTable.bundled()
        #expect(table.classify(model: model) == TierAssignment(tier: tier, confidence: confidence))
    }

    @Test func matchingIgnoresCase() throws {
        let table = try ModelTierTable.bundled()
        #expect(table.classify(model: "Claude-OPUS-Test").tier == "large")
        #expect(table.classify(model: "GPT-Mini").tier == "small")
    }

    @Test func firstMatchingRuleWins() throws {
        let table = try ModelTierTable.bundled()
        // Contains both "opus" and "mini"; "opus" comes first.
        #expect(table.classify(model: "opus-mini").tier == "large")
        // "gpt-codex-mini": "mini" precedes "gpt" and "codex".
        #expect(table.classify(model: "gpt-codex-mini").tier == "small")
    }
}
