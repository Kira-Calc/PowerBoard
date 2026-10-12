import Foundation
import Testing
@testable import ElectricityCore

@Suite struct LocalPowerTests {
    private func t(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_791_766_800 + seconds) } // a minute boundary

    @Test func integratesTrapezoidsIntoMinutes() {
        var integrator = LocalEnergyIntegrator()
        #expect(integrator.add(watts: 10, at: t(0)).isEmpty)
        let first = integrator.add(watts: 30, at: t(30))
        // 20 W average for 30 s.
        #expect(abs((first[Int64(t(0).timeIntervalSince1970 * 1000)] ?? 0) - 20.0 * 30 / 3600) < 1e-12)
        // A reading across the minute boundary is split by time.
        let split = integrator.add(watts: 30, at: t(70))
        #expect(split.count == 2)
        #expect(abs((split[Int64(t(0).timeIntervalSince1970 * 1000)] ?? 0) - 30.0 * 30 / 3600) < 1e-12)
        #expect(abs((split[Int64(t(60).timeIntervalSince1970 * 1000)] ?? 0) - 30.0 * 10 / 3600) < 1e-12)
    }

    @Test func gapsAreNotFilled() {
        var integrator = LocalEnergyIntegrator(maxGap: 60)
        _ = integrator.add(watts: 10, at: t(0))
        #expect(integrator.add(watts: 10, at: t(600)).isEmpty)
        #expect(!integrator.add(watts: 10, at: t(610)).isEmpty)
        // Clock going backwards is ignored.
        #expect(integrator.add(watts: 10, at: t(500)).isEmpty)
    }

    @Test func storeAccumulatesMinutes() throws {
        let store = try UsageStore()
        let minute = Int64(t(0).timeIntervalSince1970 * 1000)
        try store.addLocalEnergy([minute: 1.5])
        try store.addLocalEnergy([minute: 0.5, minute + 60_000: 2])
        #expect(try store.localEnergy(from: t(0), to: t(60)) == 2)
        #expect(try store.localEnergy(from: t(0), to: t(120)) == 4)
        #expect(try store.localEnergyBuckets(from: t(0), bucketSeconds: 60, count: 3) == [2, 2, 0])
        try store.deleteLocalEnergy()
        #expect(try store.localEnergy(from: t(0), to: t(120)) == 0)
    }

    @Test func snapshotIncludesLocalEnergyOnlyWhenEnabled() throws {
        let store = try UsageStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        try store.addLocalEnergy([Int64(t(0).timeIntervalSince1970 * 1000): 3])
        let off = try SnapshotBuilder.build(store: store, now: t(30), calendar: calendar)
        #expect(off.today.localEnergyWh == nil)
        let on = try SnapshotBuilder.build(store: store, now: t(30), calendar: calendar, includeLocalEnergy: true)
        #expect(on.today.localEnergyWh == 3)
        let object = try JSONSerialization.jsonObject(with: SnapshotFile.encoder().encode(off)) as? [String: Any]
        #expect((object?["today"] as? [String: Any])?["local_energy_wh"] == nil)
    }
}
