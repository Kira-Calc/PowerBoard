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

    public func recentMix(balancingAuthority: String, now: Date = Date()) async throws -> RecentFuelMix {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMddyyyy HH:mm:ss"
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "type[0]", value: "NG"),
            URLQueryItem(name: "respondent[0]", value: balancingAuthority),
            URLQueryItem(name: "start", value: formatter.string(from: now.addingTimeInterval(-4 * 86400))),
            URLQueryItem(name: "end", value: formatter.string(from: now)),
            URLQueryItem(name: "frequency", value: "hourly"),
            URLQueryItem(name: "timezone", value: "UTC"),
            URLQueryItem(name: "limit", value: "10000"),
            URLQueryItem(name: "offset", value: "0"),
        ]
        let (data, response) = try await transport.send(URLRequest(url: components.url!))
        guard response.statusCode == 200 else { throw GridAPIError.http(response.statusCode, nil) }
        return try Self.parse(data, balancingAuthority: balancingAuthority)
    }

    /// Sums the latest 24 hours that have data and returns the fossil-free share.
    static func parse(_ data: Data, balancingAuthority: String) throws -> RecentFuelMix {
        guard let blocks = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let rows = blocks.first?["data"] as? [[String: Any]]
        else { throw GridAPIError.missingData }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"

        var byHour: [Date: (clean: Double, total: Double)] = [:]
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
            }
        }
        guard let latest = byHour.keys.max() else { throw GridAPIError.missingData }
        let start = latest.addingTimeInterval(-23 * 3600)
        let window = byHour.filter { $0.key >= start }
        let total = window.values.reduce(0) { $0 + $1.total }
        guard total > 0, window.count >= 12 else { throw GridAPIError.missingData }
        return RecentFuelMix(
            balancingAuthority: balancingAuthority,
            cleanShare: window.values.reduce(0) { $0 + $1.clean } / total,
            start: start,
            end: latest.addingTimeInterval(3600)
        )
    }
}
