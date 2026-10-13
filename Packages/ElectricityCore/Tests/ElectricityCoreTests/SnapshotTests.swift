import Foundation
import Testing
@testable import ElectricityCore

@Suite struct SnapshotTests {
    private func utc(_ string: String) -> Date {
        try! Date(string, strategy: Date.ISO8601FormatStyle())
    }

    private func calendar(_ id: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: id)!
        return calendar
    }

    private func insert(_ store: UsageStore, key: String, session: String, source: UsageSource = .claudeCode, at date: Date, output: Int = 1_000_000) throws {
        let usage = ParsedUsage(dedupeKey: key, source: source, sessionID: session, projectPath: nil, model: "sonnet", timestamp: date, tokens: TokenCounts(inputUncached: 10, output: output))
        try store.insert([UsageEventRow(usage: usage, result: TestSupport.calculator().estimate(model: "sonnet", tokens: usage.tokens))], cursor: nil)
    }

    @Test func buildsTodaySessionsAndSparkline() throws {
        let store = try UsageStore()
        let now = utc("2026-10-12T02:17:00Z") // 10:17 in Shanghai
        try insert(store, key: "yesterday-local", session: "old", at: utc("2026-10-11T15:59:00Z")) // 23:59 local, previous day
        try insert(store, key: "a", session: "s1", at: utc("2026-10-11T16:01:00Z"))
        try insert(store, key: "b", session: "s1", at: utc("2026-10-12T02:16:00Z"))
        try insert(store, key: "c", session: "s2", source: .codex, at: utc("2026-10-12T01:20:00Z"))
        try insert(store, key: "ancient", session: "gone", at: utc("2026-10-01T00:00:00Z"))

        let snapshot = try SnapshotBuilder.build(store: store, now: now, calendar: calendar("Asia/Shanghai"))
        #expect(snapshot.today.date == "2026-10-12")
        #expect(snapshot.today.tokens.output == 3_000_000)
        #expect(snapshot.today.tokens.input == 30)
        let perEvent = 2878 + 10.0 / 1e6 * 136
        #expect(abs(snapshot.today.energyWh.mid - 3 * perEvent) < 1e-6)
        #expect(abs(snapshot.today.energyWhMid(for: .claudeCode) - 2 * perEvent) < 1e-6)
        #expect(abs(snapshot.today.energyWhMid(for: .codex) - perEvent) < 1e-6)
        #expect(snapshot.today.cleanShare == nil)

        // Sessions active in the last 24 hours, with whole-session totals.
        #expect(Set(snapshot.sessions.keys) == ["old", "s1", "s2"])
        #expect(snapshot.sessions["s1"]?.tokensTotal == 2_000_020)
        #expect(snapshot.sessions["s2"]?.source == "codex")
        #expect(snapshot.sessions["s1"]?.lastTs == utc("2026-10-12T02:16:00Z"))

        // 12 buckets of 5 minutes ending with the bucket in progress (02:15-02:20).
        #expect(snapshot.lastHourSparklineWh.count == 12)
        #expect(abs(snapshot.lastHourSparklineWh[11] - perEvent) < 1e-6)
        #expect(abs(snapshot.lastHourSparklineWh[0] - perEvent) < 1e-6) // 01:20-01:25
        #expect(snapshot.lastHourSparklineWh[1..<11].allSatisfy { $0 == 0 })
    }

    @Test func emptyDatabase() throws {
        let snapshot = try SnapshotBuilder.build(store: UsageStore(), now: utc("2026-10-12T02:00:00Z"), calendar: calendar("UTC"))
        #expect(snapshot.today.energyWh == .zero)
        #expect(snapshot.today.bySource.keys.sorted() == ["antigravity", "claude_code", "claude_desktop", "codex"])
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.lastHourSparklineWh == Array(repeating: 0, count: 12))
    }

    @Test func encodesSpecFieldNames() throws {
        let snapshot = try SnapshotBuilder.build(store: UsageStore(), now: utc("2026-10-12T02:15:30Z"), calendar: calendar("UTC"))
        let object = try #require(JSONSerialization.jsonObject(with: SnapshotFile.encoder().encode(snapshot)) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        #expect(object["generated_at"] as? String == "2026-10-12T02:15:30Z")
        #expect(object["app_running"] as? Bool == true)
        let today = try #require(object["today"] as? [String: Any])
        #expect(today["clean_share"] is NSNull)
        #expect((today["energy_wh"] as? [String: Any])?.keys.sorted() == ["high", "low", "mid"])
        #expect((today["tokens"] as? [String: Any])?.keys.sorted() == ["cache_read", "cache_write", "input", "output"])
        #expect(object["last_hour_sparkline_wh"] is [Any])
    }

    @Test func staleness() throws {
        var snapshot = try SnapshotBuilder.build(store: UsageStore(), now: utc("2026-10-12T02:00:00Z"), calendar: calendar("UTC"))
        #expect(!snapshot.isStale(now: utc("2026-10-12T02:05:00Z")))
        #expect(snapshot.isStale(now: utc("2026-10-12T02:05:01Z")))
        snapshot.appRunning = false
        #expect(snapshot.isStale(now: utc("2026-10-12T02:00:00Z")))
    }

    @Test func fileRoundTripAndMissingFile() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("sub/snapshot.json")
        #expect(try SnapshotFile.read(from: url) == nil)
        let snapshot = try SnapshotBuilder.build(store: UsageStore(), now: utc("2026-10-12T02:00:00Z"), calendar: calendar("UTC"))
        try SnapshotFile.write(snapshot, to: url)
        #expect(try SnapshotFile.read(from: url) == snapshot)
    }

    @Test func readersNeverSeePartialFiles() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("snapshot.json")
        let base = try SnapshotBuilder.build(store: UsageStore(), now: utc("2026-10-12T02:00:00Z"), calendar: calendar("UTC"))
        try SnapshotFile.write(base, to: url)

        // A large snapshot makes a torn read likely if writes were not atomic.
        var sessions: [String: Snapshot.Session] = [:]
        for index in 0..<2000 {
            sessions["session-\(index)"] = Snapshot.Session(source: "codex", energyWhMid: Double(index), co2G: 1, tokensTotal: index, lastTs: base.generatedAt)
        }
        let big = Snapshot(generatedAt: base.generatedAt, appRunning: true, today: base.today, sessions: sessions, lastHourSparklineWh: base.lastHourSparklineWh)

        let writer = Task.detached {
            for index in 0..<100 {
                try SnapshotFile.write(index.isMultiple(of: 2) ? big : base, to: url)
            }
        }
        let reader = Task.detached { () -> Int in
            var failures = 0
            for _ in 0..<500 {
                do { _ = try SnapshotFile.read(from: url) } catch { failures += 1 }
            }
            return failures
        }
        try await writer.value
        #expect(await reader.value == 0)
    }
}

@Suite struct EquivalentTests {
    private let appliance = EquivalentItem(id: "app", kind: .appliance, wh: 10)
    private let food = EquivalentItem(id: "food", kind: .food, wh: 100)

    @Test func countBoundariesAreInPreferredRange() {
        #expect(EquivalentSelector.score(1) <= 1)
        #expect(EquivalentSelector.score(100) <= 1)
        #expect(EquivalentSelector.score(0.99) > 10)
        #expect(EquivalentSelector.score(100.1) > 10)
    }

    @Test func picksOneApplianceAndOneFoodFirst() {
        let items = [
            appliance,
            EquivalentItem(id: "app2", kind: .appliance, wh: 1),
            food,
        ]
        let matches = EquivalentSelector.select(energyWh: 100, items: items)
        // app: 10 (ideal), app2: 100 (in range), food: 1 (in range).
        #expect(matches.map(\.item.id) == ["app", "food", "app2"])
        #expect(EquivalentSelector.select(energyWh: 100, items: items, limit: 2).map(\.item.id) == ["app", "food"])
    }

    @Test func prefersInRangeOverOutOfRange() {
        let tiny = EquivalentItem(id: "tiny", kind: .appliance, wh: 0.001)
        let matches = EquivalentSelector.select(energyWh: 50, items: [tiny, appliance], limit: 1)
        #expect(matches.first?.item.id == "app")
    }

    @Test func respectsEnabledItems() {
        let matches = EquivalentSelector.select(energyWh: 100, items: [appliance, food], enabledIDs: ["food"])
        #expect(matches.map(\.item.id) == ["food"])
    }

    @Test func zeroEnergyGivesNothing() {
        #expect(EquivalentSelector.select(energyWh: 0, items: [appliance, food]).isEmpty)
    }

    @Test func outOfRangeStillPicksClosest() {
        // Very large energy: every count exceeds 100; the smallest count is closest.
        let matches = EquivalentSelector.select(energyWh: 1e9, items: [appliance, EquivalentItem(id: "big", kind: .appliance, wh: 1000)], limit: 1)
        #expect(matches.first?.item.id == "big")
        // Very small energy: every count is below 1; the largest count is closest.
        let small = EquivalentSelector.select(energyWh: 0.5, items: [appliance, EquivalentItem(id: "small", kind: .appliance, wh: 1)], limit: 1)
        #expect(small.first?.item.id == "small")
    }

    @Test func amountExpressions() {
        #expect(EquivalentAmount(count: 1, durationSeconds: nil) == .count(1))
        #expect(EquivalentAmount(count: 2.345, durationSeconds: nil) == .count(2.3))
        #expect(EquivalentAmount(count: 1e7, durationSeconds: nil) == .count(1e7))
        // Below 1 for a time-based item: a duration ("about 20 seconds of microwave").
        #expect(EquivalentAmount(count: 1.0 / 3, durationSeconds: 60) == .duration(seconds: 20))
        #expect(EquivalentAmount(count: 0.25, durationSeconds: nil) == .fraction(denominator: 4))
        #expect(EquivalentAmount(count: 0.7, durationSeconds: nil) == .fraction(denominator: 2))
        #expect(EquivalentAmount(count: 0.001, durationSeconds: nil) == .lessThanHundredth)
    }

    @Test func bundledCatalogLoads() throws {
        let catalog = try EquivalentCatalog.bundled()
        #expect(catalog.items.count == 16)
        #expect(catalog.items.first { $0.id == "microwave_minute" }?.durationSeconds == 60)
    }

    @Test func rotationIsStablePerSeedAndVaries() {
        let items = (0..<12).map { EquivalentItem(id: "i\($0)", kind: $0 % 3 == 0 ? .food : .digital, wh: Double($0 + 1) * 10) }
        let a = EquivalentSelector.rotating(energyWh: 1000, items: items, limit: 3, seed: 1)
        #expect(a == EquivalentSelector.rotating(energyWh: 1000, items: items, limit: 3, seed: 1))
        #expect(a.count == 3)
        #expect(a.contains { $0.item.kind == .food })
        #expect(a.contains { $0.item.kind != .food })
        let sets = Set((0..<20).map { seed in EquivalentSelector.rotating(energyWh: 1000, items: items, limit: 3, seed: UInt64(seed)).map(\.item.id) })
        #expect(sets.count > 3)
    }

    @Test func rotationSkipsUnreadableCounts() {
        let items = [
            EquivalentItem(id: "tiny", kind: .digital, wh: 0.000_001),
            EquivalentItem(id: "huge", kind: .household, wh: 1_000_000),
        ] + (0..<5).map { EquivalentItem(id: "ok\($0)", kind: .food, wh: 100 + Double($0)) }
        for seed in 0..<20 {
            let ids = EquivalentSelector.rotating(energyWh: 1000, items: items, limit: 2, seed: UInt64(seed)).map(\.item.id)
            #expect(!ids.contains("tiny") && !ids.contains("huge"))
        }
    }

    @Test func bundledItemsHaveSources() throws {
        let catalog = try EquivalentCatalog.bundled()
        #expect(catalog.items.count >= 12)
        for item in catalog.items {
            #expect(!item.source.isEmpty, "\(item.id) has no source")
            #expect(!item.basis.isEmpty)
        }
    }
}

@Suite struct ValueFormattingTests {
    @Test func energyAuto() {
        #expect(ValueFormatting.energy(wh: 0).text == "0.00 Wh")
        #expect(ValueFormatting.energy(wh: 0.0404).text == "0.04 Wh")
        #expect(ValueFormatting.energy(wh: 3.44).text == "3.4 Wh")
        #expect(ValueFormatting.energy(wh: 82.4).text == "82 Wh")
        #expect(ValueFormatting.energy(wh: 999.4).text == "999 Wh")
        #expect(ValueFormatting.energy(wh: 1240).text == "1.24 kWh")
        #expect(ValueFormatting.energy(wh: 41_773).text == "41.8 kWh")
        #expect(ValueFormatting.energy(wh: 123_456).text == "123 kWh")
    }

    @Test func energyFixedUnitAndDecimals() {
        #expect(ValueFormatting.energy(wh: 1240, unit: .wh).text == "1240 Wh")
        #expect(ValueFormatting.energy(wh: 82, unit: .kwh).text == "0.08 kWh")
        #expect(ValueFormatting.energy(wh: 82, unit: .kwh, decimals: 3).text == "0.082 kWh")
        #expect(ValueFormatting.energy(wh: 82.46, unit: .wh, decimals: 1).text == "82.5 Wh")
    }

    @Test func estimateSharesTheMidUnit() {
        let range = ValueFormatting.energy(Estimate(low: 598, mid: 1195, high: 2390))
        #expect(range.low.text == "0.60 kWh")
        #expect(range.mid.text == "1.20 kWh")
        #expect(range.high.text == "2.39 kWh")
        let small = ValueFormatting.energy(Estimate(low: 41, mid: 82, high: 164))
        #expect([small.low.text, small.mid.text, small.high.text] == ["41 Wh", "82 Wh", "164 Wh"])
    }

    @Test func carbonAndTokens() {
        #expect(ValueFormatting.carbon(grams: 356.2).text == "356 g")
        #expect(ValueFormatting.carbon(grams: 4.25).text == "4.2 g")
        #expect(ValueFormatting.carbon(grams: 11_989).text == "12.0 kg")
        #expect(ValueFormatting.tokens(950) == "950")
        #expect(ValueFormatting.tokens(12_345) == "12.3K")
        #expect(ValueFormatting.tokens(966_201_476) == "966M")
        #expect(ValueFormatting.tokens(1_200_000_000) == "1.2B")
    }
}
