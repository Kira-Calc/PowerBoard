import Foundation
@testable import ElectricityCore

enum TestSupport {
    static var fixturesURL: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    static func fixture(_ relativePath: String) -> URL {
        fixturesURL.appendingPathComponent(relativePath)
    }

    static func line(_ json: String) -> Data { Data(json.utf8) }

    /// A fresh temporary directory, removed by the caller with `cleanup`.
    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElectricityCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    static func calculator(cacheWriteRatio: Double? = nil, cacheReadRatio: Double? = nil) throws -> EnergyCalculator {
        try EnergyCalculator.bundled(cacheWriteRatio: cacheWriteRatio, cacheReadRatio: cacheReadRatio)
    }

    static func usage(of outcome: ParseOutcome) -> ParsedUsage? {
        if case .usage(let usage) = outcome { return usage }
        return nil
    }
}
