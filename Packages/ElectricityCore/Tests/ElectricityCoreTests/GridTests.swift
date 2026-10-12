import Foundation
import Testing
@testable import ElectricityCore

/// Answers requests from a table of path -> (status, JSON) and records them.
private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [String: (Int, String)]) {
        self.responses = responses
    }

    func set(_ path: String, _ status: Int, _ body: String) {
        lock.lock(); defer { lock.unlock() }
        responses[path] = (status, body)
    }

    /// WattTime requests only; EIA requests run in the background and finish at any time.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { !($0.url?.path.contains("930-api") ?? false) }.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = lock.withLock {
            requests.append(request)
            return responses[request.url!.path]
        }
        guard let (status, body) = response else { throw URLError(.cannotConnectToHost) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct GridTests {
    private func candidate(_ id: String, weight: Double, staticValue: Double? = 300) -> GridCandidate {
        GridCandidate(id: id, nameEn: id, nameZh: id, latitude: 1, longitude: 2, weight: weight, watttimeRegion: "",
                      emapsZone: "ZONE-\(id)", staticGramsPerKWh: staticValue, staticBasis: "test", note: "")
    }

    @Test func thresholdsSplitPercentilesIntoThirds() {
        let thresholds = GridThresholds()
        #expect(thresholds.level(percentile: 0) == .cleaner)
        #expect(thresholds.level(percentile: 33) == .cleaner)
        #expect(thresholds.level(percentile: 34) == .typical)
        #expect(thresholds.level(percentile: 66) == .typical)
        #expect(thresholds.level(percentile: 67) == .lessClean)
        #expect(thresholds.level(percentile: 100) == .lessClean)
        #expect(GridThresholds(cleanerBelow: 20, lessCleanAbove: 80).level(percentile: 50) == .typical)
    }

    @Test func combinerWeightsAndFlagsMixedLevels() {
        let candidates = [candidate("a", weight: 0.75), candidate("b", weight: 0.25)]
        let readings = [
            CandidateReading(candidateID: "a", percentile: 10, source: .watttime, observedAt: Date(timeIntervalSince1970: 100)),
            CandidateReading(candidateID: "b", percentile: 90, source: .watttime, observedAt: Date(timeIntervalSince1970: 200)),
        ]
        let status = GridCombiner.combine(provider: .anthropic, candidates: candidates, readings: readings, thresholds: GridThresholds())
        #expect(status.percentile == 30)
        #expect(status.level == .cleaner)
        #expect(status.mixed)
        #expect(status.candidateLevels == ["a": .cleaner, "b": .lessClean])
        #expect(status.source == .watttime)
        #expect(status.certainty == .estimated)
        #expect(status.updatedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func staticReadingsGiveValuesButNoLevel() {
        let candidates = [candidate("a", weight: 0.5, staticValue: 200), candidate("b", weight: 0.5, staticValue: 400)]
        let readings = candidates.map { CandidateReading(candidateID: $0.id, gramsPerKWh: $0.staticGramsPerKWh, source: .static) }
        let status = GridCombiner.combine(provider: .openai, candidates: candidates, readings: readings, thresholds: GridThresholds())
        #expect(status.level == nil)
        #expect(status.gramsPerKWh == 300)
        #expect(status.source == .static)
        #expect(!status.mixed)
        #expect(GridCombiner.combine(provider: .google, candidates: [], readings: [], thresholds: GridThresholds()).certainty == .unknown)
    }

    @Test func bundledRegionsHaveWeightsSummingToOne() throws {
        let table = try GridRegionTable.bundled()
        for provider in GridProvider.allCases {
            let candidates = table.candidates(for: provider)
            #expect(!candidates.isEmpty)
            #expect(abs(candidates.reduce(0) { $0 + $1.weight } - 1) < 1e-9)
            #expect(candidates.allSatisfy { $0.staticGramsPerKWh != nil })
        }
    }

    @Test func wattTimeClientLogsInLooksUpRegionAndReadsIndex() async throws {
        let transport = FakeTransport([
            "/login": (200, #"{"token": "abc"}"#),
            "/v3/region-from-loc": (200, #"{"region": "PJM_DOM", "region_full_name": "PJM Dominion"}"#),
            "/v3/signal-index": (200, #"{"data": [{"point_time": "2026-10-12T03:00:00+00:00", "value": 12.5}], "meta": {}}"#),
        ])
        let client = WattTimeClient(credentials: WattTimeCredentials(username: "u", password: "p"), transport: transport)
        #expect(try await client.region(latitude: 1, longitude: 2) == "PJM_DOM")
        let index = try await client.signalIndex(region: "PJM_DOM")
        #expect(index.percentile == 12.5)
        #expect(index.at == Date(timeIntervalSince1970: 1_791_766_800 + 2 * 3600))
        // The token is reused: one login for two data requests.
        #expect(transport.requests.filter { $0.url!.path == "/login" }.count == 1)
        let auth = transport.requests.first { $0.url!.path == "/login" }?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Basic " + Data("u:p".utf8).base64EncodedString())
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
    }

    @Test func concurrentRequestsShareOneLogin() async throws {
        let transport = FakeTransport([
            "/login": (200, #"{"token": "abc"}"#),
            "/v3/signal-index": (200, #"{"data": [{"point_time": "2026-10-12T03:00:00Z", "value": 50}]}"#),
        ])
        let client = WattTimeClient(credentials: WattTimeCredentials(username: "u", password: "p"), transport: transport)
        await withTaskGroup(of: Void.self) { group in
            for region in ["A", "B", "C", "D", "E"] {
                group.addTask { _ = try? await client.signalIndex(region: region) }
            }
        }
        #expect(transport.requests.filter { $0.url!.path == "/login" }.count == 1)
        #expect(transport.requests.filter { $0.url!.path == "/v3/signal-index" }.count == 5)
    }

    @Test func wattTimeAccountRules() {
        #expect(!WattTimeAccountRules.isValidPassword("b"))
        #expect(!WattTimeAccountRules.isValidPassword("abcdefgh1"))
        #expect(WattTimeAccountRules.isValidPassword("abcdef1!"))
        #expect(WattTimeAccountRules.passes(.special, "a_b"))
        #expect(!WattTimeAccountRules.passes(.special, "a b"))
        #expect(WattTimeAccountRules.isPlausibleEmail("me@example.com"))
        #expect(!WattTimeAccountRules.isPlausibleEmail("not-an-email"))
        #expect(!WattTimeAccountRules.isPlausibleEmail("me@example"))
        #expect(!WattTimeAccountRules.isPlausibleEmail("me@.com"))
    }

    @Test func wattTimeErrors() async throws {
        let transport = FakeTransport(["/login": (401, "{}"), "/register": (400, #"{"message": "username taken"}"#)])
        let client = WattTimeClient(credentials: WattTimeCredentials(username: "u", password: "bad"), transport: transport)
        await #expect(throws: GridAPIError.unauthorized) { try await client.login() }
        await #expect(throws: GridAPIError.http(400, "username taken")) {
            try await WattTimeClient.register(username: "u", password: "p", email: "e@example.com", organization: "o", transport: transport)
        }
    }

    @Test func serviceCachesFallsBackAndUsesStaticWithoutAccounts() async throws {
        let table = try GridRegionTable.bundled()
        let noAccount = GridService(table: table, configuration: .init(), transport: FakeTransport([:]))
        let offline = await noAccount.status(for: .anthropic)
        #expect(offline.source == .static)
        #expect(offline.level == nil)
        #expect(offline.gramsPerKWh != nil)

        let transport = FakeTransport([
            "/login": (200, #"{"token": "abc"}"#),
            "/v3/region-from-loc": (200, #"{"region": "R"}"#),
            "/v3/signal-index": (200, #"{"data": [{"point_time": "2026-10-12T03:00:00Z", "value": 80}]}"#),
        ])
        let service = GridService(table: table, configuration: .init(watttime: WattTimeCredentials(username: "u", password: "p")), transport: transport)
        let now = Date()
        let live = await service.status(for: .openai, now: now)
        #expect(live.level == .lessClean)
        #expect(live.source == .watttime)
        let requests = transport.count

        // Within 15 minutes nothing is fetched again.
        _ = await service.status(for: .openai, now: now.addingTimeInterval(60))
        #expect(transport.count == requests)

        // After 15 minutes a failing request keeps the last good reading.
        transport.set("/v3/signal-index", 500, "{}")
        let later = await service.status(for: .openai, now: now.addingTimeInterval(16 * 60))
        #expect(later.level == .lessClean)
        #expect(await service.regions.values.allSatisfy { $0 == "R" })
    }

    @Test func electricityMapsAddsAbsoluteValues() async throws {
        let transport = FakeTransport([
            "/v3/carbon-intensity/latest": (200, #"{"carbonIntensity": 210, "datetime": "2026-10-12T03:00:00Z"}"#),
            "/v3/power-breakdown/latest": (200, #"{"fossilFreePercentage": 62}"#),
        ])
        let latest = try await ElectricityMapsClient(apiKey: "k", transport: transport).latest(zone: "US-TEX-ERCO")
        #expect(latest.gramsPerKWh == 210)
        #expect(latest.cleanShare == 0.62)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "auth-token") == "k")
    }

    @Test func statusLineShowsGridOnlyWithLiveLevel() {
        let base = Snapshot(
            generatedAt: Date(), appRunning: true,
            today: .init(date: "2026-10-12", tokens: .init(input: 0, output: 0, cacheWrite: 0, cacheRead: 0),
                         energyWh: Estimate(low: 5, mid: 10, high: 20), co2G: 3, cleanShare: nil, bySource: [:]),
            sessions: [:], lastHourSparklineWh: []
        )
        var live = base
        live.today.grid = Snapshot.Grid(status: GridStatus(provider: .anthropic, level: .cleaner, percentile: 10, gramsPerKWh: nil, cleanShare: nil,
                                                           source: .watttime, certainty: .estimated, updatedAt: Date(), mixed: false,
                                                           candidates: [], candidateLevels: [:]))
        #expect(StatusLineFormatter.render(snapshot: live, sessionID: nil, language: .en, format: .compact, color: false).hasSuffix("| grid: cleaner (est.)"))
        #expect(StatusLineFormatter.render(snapshot: live, sessionID: nil, language: .zh, format: .compact, color: false).hasSuffix("| 电网：较清洁（推测）"))
        var staticOnly = base
        staticOnly.today.grid = Snapshot.Grid(status: .unknown(.anthropic))
        #expect(!StatusLineFormatter.render(snapshot: staticOnly, sessionID: nil, language: .en, format: .compact, color: false).contains("grid"))
    }

    @Test func recentRecordsGetGridLevelOldOnesDoNot() async throws {
        let store = try UsageStore()
        let service = IngestService(store: store, calculator: try TestSupport.calculator(), locations: LogLocations(claudeCode: [], codex: []))
        let status = GridStatus(provider: .anthropic, level: .typical, percentile: 50, gramsPerKWh: nil, cleanShare: 0.4, source: .watttime,
                                certainty: .estimated, updatedAt: Date(), mixed: false, candidates: [], candidateLevels: [:])
        await service.setGrid([.anthropic: status])
        func usage(_ minutesAgo: Double) -> ParsedUsage {
            ParsedUsage(dedupeKey: "k\(minutesAgo)", source: .claudeCode, sessionID: "s", projectPath: nil, model: "sonnet",
                        timestamp: Date().addingTimeInterval(-minutesAgo * 60), tokens: TokenCounts(output: 1000))
        }
        let recent = await service.row(for: usage(1))
        #expect(recent.cleanLevel == "typical")
        #expect(recent.cleanShare == 0.4)
        #expect(recent.gridSource == "watttime")
        let old = await service.row(for: usage(60))
        #expect(old.cleanLevel == nil)
        #expect(old.gridSource == nil)

        try store.insert([recent, old], cursor: nil)
        let byLevel = try store.energyByGridLevel(from: .distantPast, to: .distantFuture)
        #expect(byLevel[.typical] != nil)
        #expect(byLevel[nil] != nil)
    }

    @Test func eiaRecentMixUsesLatestTwentyFourHoursAndSkipsBatteries() throws {
        func row(_ fuel: String, _ values: [Any]) -> String {
            let dates = (0..<values.count).map { String(format: "\"10/%02d/2026 %02d:00:00\"", 10 + ($0 / 24), $0 % 24) }.joined(separator: ",")
            let data = values.map { "\($0)" }.joined(separator: ",")
            return #"{"FUEL_TYPE_ID": "\#(fuel)", "VALUES": {"DATES": [\#(dates)], "DATA": [\#(data)]}}"#
        }
        // 30 hours: the first 6 are older than the latest 24-hour window and are ignored.
        let wind: [Any] = Array(repeating: 1000, count: 6) + Array(repeating: 300, count: 24)
        let gas: [Any] = Array(repeating: 0, count: 6) + Array(repeating: 700, count: 23) + ["null"]
        let battery: [Any] = Array(repeating: 500, count: 30)
        let json = "[{\"data\": [\(row("WND", wind)), \(row("NG", gas)), \(row("BAT", battery))]}]"
        let mix = try EIAFuelMixClient.parse(Data(json.utf8), balancingAuthority: "TEST")
        // Last hour has wind only; the other 23 hours are 300 clean of 1000.
        #expect(abs(mix.cleanShare - (300.0 * 24) / (300.0 * 24 + 700 * 23)) < 1e-9)
        #expect(mix.end.timeIntervalSince(mix.start) == 24 * 3600)
        #expect(throws: GridAPIError.missingData) { try EIAFuelMixClient.parse(Data("[{\"data\": []}]".utf8), balancingAuthority: "TEST") }
    }

    @Test func bundledCandidatesHaveBalancingAuthorities() throws {
        let table = try GridRegionTable.bundled()
        for provider in GridProvider.allCases {
            #expect(table.candidates(for: provider).allSatisfy { ($0.eiaBalancingAuthority ?? "").isEmpty == false })
        }
    }
}
