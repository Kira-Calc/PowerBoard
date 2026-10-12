// Development tool: ingests local logs into a database and prints aggregate token totals.
// Prints only counts, never log content. Not shipped with the app.
//
// Usage: swift run --package-path Packages/ElectricityCore ElectricityDev <database-path>
import ElectricityCore
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: ElectricityDev <database-path>\n".utf8))
    exit(2)
}

let store = try UsageStore(url: URL(fileURLWithPath: arguments[1]))
let service = IngestService(store: store, calculator: try .bundled(), locations: .standard())

let started = Date()
let summary = await service.scan()
let elapsed = Date().timeIntervalSince(started)

for source in UsageSource.allCases {
    let scan = summary.bySource[source] ?? SourceScanSummary()
    let totals = try store.totals(source: source)
    print("""
        [\(source.rawValue)]
          files found \(scan.filesFound), read \(scan.filesRead), errors \(scan.fileErrors)
          lines read \(scan.linesRead), skipped \(scan.linesSkipped), new events \(scan.eventsInserted)
          stored events \(totals.eventCount)
          input (uncached) \(totals.tokens.inputUncached)
          output \(totals.tokens.output) (reasoning \(totals.tokens.reasoning))
          cache write \(totals.tokens.cacheWrite)
          cache read \(totals.tokens.cacheRead)
          total tokens \(totals.tokens.total)
          energy Wh low \(String(format: "%.1f", totals.energyWh.low)) mid \(String(format: "%.1f", totals.energyWh.mid)) high \(String(format: "%.1f", totals.energyWh.high))
          co2 g mid \(String(format: "%.1f", totals.co2GramsMid))
        """)
}
print(String(format: "scan took %.2f s", elapsed))
