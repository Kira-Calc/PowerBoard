import Foundation
import GRDB
import IOKit

/// Reads the whole-system power draw of this Mac from the battery controller's power telemetry.
/// Available on Mac laptops with Apple silicon; returns nil on Macs without that data (for example desktops).
public enum SystemPowerReader {
    /// Current system load in watts, or nil when the Mac does not report it.
    public static func currentWatts() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard
            let property = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0),
            let telemetry = property.takeRetainedValue() as? [String: Any],
            let milliwatts = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue,
            milliwatts >= 0, milliwatts < 1_000_000
        else { return nil }
        return milliwatts / 1000
    }
}

/// Turns periodic power readings into energy per minute.
/// A gap longer than `maxGap` (sleep, app not running) is not filled in.
public struct LocalEnergyIntegrator: Sendable {
    public let maxGap: TimeInterval
    private var last: (date: Date, watts: Double)?

    public init(maxGap: TimeInterval = 60) {
        self.maxGap = maxGap
    }

    /// Adds a reading and returns the energy since the previous reading, split by UTC minute, in Wh.
    public mutating func add(watts: Double, at date: Date) -> [Int64: Double] {
        defer { last = (date, watts) }
        guard let last, date > last.date, date.timeIntervalSince(last.date) <= maxGap else { return [:] }
        // Trapezoid between the two readings, assigned to minutes in proportion to time.
        let averageWatts = (last.watts + watts) / 2
        var result: [Int64: Double] = [:]
        var cursor = last.date
        while cursor < date {
            let minuteStart = (cursor.timeIntervalSince1970 / 60).rounded(.down) * 60
            let segmentEnd = min(date, Date(timeIntervalSince1970: minuteStart + 60))
            let seconds = segmentEnd.timeIntervalSince(cursor)
            result[Int64(minuteStart * 1000), default: 0] += averageWatts * seconds / 3600
            cursor = segmentEnd
        }
        return result
    }
}

extension UsageStore {
    /// Adds energy (Wh) to per-minute totals. Keys are UTC minute starts in Unix milliseconds.
    public func addLocalEnergy(_ minutes: [Int64: Double]) throws {
        guard !minutes.isEmpty else { return }
        try write { db in
            for (minute, wh) in minutes {
                try db.execute(sql: """
                    INSERT INTO local_energy (minute_utc, wh) VALUES (?, ?)
                    ON CONFLICT(minute_utc) DO UPDATE SET wh = wh + excluded.wh
                    """, arguments: [minute, wh])
            }
        }
    }

    /// Local energy (Wh) with `start <= minute < end`.
    public func localEnergy(from start: Date, to end: Date) throws -> Double {
        try read { db in
            try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(wh), 0) FROM local_energy WHERE minute_utc >= ? AND minute_utc < ?",
                                arguments: [Self.milliseconds(start), Self.milliseconds(end)]) ?? 0
        }
    }

    /// Local energy (Wh) per bucket of `bucketSeconds`, for `count` buckets starting at `start`.
    public func localEnergyBuckets(from start: Date, bucketSeconds: Int, count: Int) throws -> [Double] {
        let startMs = Self.milliseconds(start)
        let bucketMs = Int64(bucketSeconds) * 1000
        return try read { db in
            var buckets = Array(repeating: 0.0, count: count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT (minute_utc - ?) / ?, SUM(wh) FROM local_energy
                WHERE minute_utc >= ? AND minute_utc < ? GROUP BY 1
                """, arguments: [startMs, bucketMs, startMs, startMs + bucketMs * Int64(count)])
            for row in rows {
                let index: Int = row[0]
                if buckets.indices.contains(index) { buckets[index] = row[1] }
            }
            return buckets
        }
    }

    public func deleteLocalEnergy() throws {
        try write { db in try db.execute(sql: "DELETE FROM local_energy") }
    }
}
