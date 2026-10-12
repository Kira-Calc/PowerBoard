import Foundation

/// Recent fuel mix from the EIA Hourly Electric Grid Monitor (EIA-930), which needs no account.
/// Uses the endpoint behind EIA's public grid monitor pages; it is undocumented and its data is often about
/// a day behind, so it is shown as "the latest published day", never as the current grid state.
public struct EIAFuelMixClient: Sendable {
    public static let endpoint = URL(string: "https://www.eia.gov/electricity/930-api/region_data_by_fuel_type/series_data")!
    /// Fuels counted as fossil-free. Battery storage (BAT) is left out so stored energy is not counted twice.
    static let cleanFuels: Set<String> = ["SUN", "SNB", "WND", "WAT", "NUC", "GEO"]
    static let excludedFuels: Set<String> = ["BAT"]

    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// The latest published day and the hourly generation by group behind it (about 33 days).
    public struct FuelData: Sendable {
        public var recent: RecentFuelMix
        public var history: FuelHistory
    }

    public func recentMix(balancingAuthority: String, now: Date = Date()) async throws -> RecentFuelMix {
        try await fuelData(balancingAuthority: balancingAuthority, now: now).recent
    }

    public func fuelData(balancingAuthority: String, now: Date = Date()) async throws -> FuelData {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMddyyyy HH:mm:ss"
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "type[0]", value: "NG"),
            URLQueryItem(name: "respondent[0]", value: balancingAuthority),
            // The latest day plus 30 earlier days to compare it with, and a margin for EIA's delay.
            URLQueryItem(name: "start", value: formatter.string(from: now.addingTimeInterval(-Double(RecentFuelMix.baselineDayCount + 3) * 86400))),
            URLQueryItem(name: "end", value: formatter.string(from: now)),
            URLQueryItem(name: "frequency", value: "hourly"),
            URLQueryItem(name: "timezone", value: "UTC"),
            URLQueryItem(name: "limit", value: "10000"),
            URLQueryItem(name: "offset", value: "0"),
        ]
        let (data, response) = try await transport.send(URLRequest(url: components.url!))
        guard response.statusCode == 200 else { throw GridAPIError.http(response.statusCode, nil) }
        return try Self.parseAll(data, balancingAuthority: balancingAuthority)
    }

    static func parse(_ data: Data, balancingAuthority: String) throws -> RecentFuelMix {
        try parseAll(data, balancingAuthority: balancingAuthority).recent
    }

    /// Fossil-free share of the latest 24 hours that have data, and its rank among the 30 days before it.
    static func parseAll(_ data: Data, balancingAuthority: String) throws -> FuelData {
        guard let blocks = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let rows = blocks.first?["data"] as? [[String: Any]]
        else { throw GridAPIError.missingData }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"

        var byHour: [Date: (clean: Double, total: Double)] = [:]
        var history: FuelHistory = [:]
        for row in rows {
            guard let fuel = row["FUEL_TYPE_ID"] as? String, !excludedFuels.contains(fuel),
                  let values = row["VALUES"] as? [String: Any],
                  let dates = values["DATES"] as? [String], let points = values["DATA"] as? [Any]
            else { continue }
            for (dateString, point) in zip(dates, points) {
                guard let date = formatter.date(from: dateString), let mwh = (point as? NSNumber)?.doubleValue, mwh > 0 else { continue }
                var hour = byHour[date] ?? (0, 0)
                hour.total += mwh
                if cleanFuels.contains(fuel) { hour.clean += mwh }
                byHour[date] = hour
                if let group = FuelGroup(eiaFuel: fuel) { history[date, default: [:]][group, default: 0] += mwh }
            }
        }
        guard let latest = byHour.keys.max() else { throw GridAPIError.missingData }
        // Day k covers the 24 hours ending 24k hours before the latest hour. A day needs at least 12 hours of data.
        func share(day k: Int) -> Double? {
            let end = latest.addingTimeInterval(-Double(24 * k) * 3600)
            let start = end.addingTimeInterval(-23 * 3600)
            let window = byHour.filter { $0.key >= start && $0.key <= end }
            let total = window.values.reduce(0) { $0 + $1.total }
            guard total > 0, window.count >= 12 else { return nil }
            return window.values.reduce(0) { $0 + $1.clean } / total
        }
        guard let latestShare = share(day: 0) else { throw GridAPIError.missingData }
        let baseline = (1...RecentFuelMix.baselineDayCount).compactMap { share(day: $0) }
        let recent = RecentFuelMix(
            balancingAuthority: balancingAuthority,
            cleanShare: latestShare,
            start: latest.addingTimeInterval(-23 * 3600),
            end: latest.addingTimeInterval(3600),
            percentile: RecentFuelMix.percentile(latest: latestShare, baseline: baseline),
            baselineDays: baseline.count
        )
        return FuelData(recent: recent, history: history)
    }
}
