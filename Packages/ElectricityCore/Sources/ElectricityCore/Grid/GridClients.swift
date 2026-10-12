import Foundation

/// Sends HTTP requests. Replaced in tests so no network is used.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GridAPIError.badResponse }
        return (data, http)
    }
}

public enum GridAPIError: Error, Equatable, Sendable {
    case badResponse
    case unauthorized
    case http(Int, String?)
    case missingData
}

public struct WattTimeCredentials: Sendable, Hashable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// WattTime API v3 (SPEC 10.3). Uses the free CO2 percentile ("signal index") and region lookup.
public actor WattTimeClient {
    public static let baseURL = URL(string: "https://api.watttime.org")!

    private let transport: HTTPTransport
    private let credentials: WattTimeCredentials
    private var token: (value: String, expires: Date)?
    /// A login in progress, shared by concurrent requests so only one login is sent.
    private var pendingLogin: Task<String, Error>?

    public init(credentials: WattTimeCredentials, transport: HTTPTransport = URLSessionTransport()) {
        self.credentials = credentials
        self.transport = transport
    }

    /// Creates a free account. WattTime requires a username, password, email and organization.
    public static func register(username: String, password: String, email: String, organization: String,
                                transport: HTTPTransport = URLSessionTransport()) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username, "password": password, "email": email, "org": organization,
        ])
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw GridAPIError.http(response.statusCode, Self.message(in: data))
        }
    }

    /// Logs in and returns a token, valid for 30 minutes. Cached for 25 minutes; concurrent callers share one login.
    public func login() async throws -> String {
        if let token, token.expires > Date() { return token.value }
        if let pendingLogin { return try await pendingLogin.value }
        let task = Task { try await self.performLogin() }
        pendingLogin = task
        defer { pendingLogin = nil }
        return try await task.value
    }

    private func performLogin() async throws -> String {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("login"))
        let basic = Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        if response.statusCode == 401 || response.statusCode == 403 { throw GridAPIError.unauthorized }
        guard response.statusCode == 200,
              let value = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? String
        else { throw GridAPIError.http(response.statusCode, Self.message(in: data)) }
        token = (value, Date().addingTimeInterval(25 * 60))
        return value
    }

    /// The WattTime region that contains a location.
    public func region(latitude: Double, longitude: Double) async throws -> String {
        let object = try await get("v3/region-from-loc", query: [
            "latitude": String(latitude), "longitude": String(longitude), "signal_type": "co2_moer",
        ])
        guard let region = object["region"] as? String, !region.isEmpty else { throw GridAPIError.missingData }
        return region
    }

    /// Current CO2 percentile of a region against its next 24 hours of forecast: 0 cleanest, 100 dirtiest.
    /// Free for every account in all covered regions (WattTime API spec, `GET /v3/signal-index`).
    public func signalIndex(region: String) async throws -> (percentile: Double, at: Date?) {
        let object = try await get("v3/signal-index", query: ["region": region, "signal_type": "co2_moer"])
        guard let first = (object["data"] as? [[String: Any]])?.first,
              let value = (first["value"] as? NSNumber)?.doubleValue
        else { throw GridAPIError.missingData }
        return (value, ParsingSupport.parseTimestamp(first["point_time"]))
    }

    private func get(_ path: String, query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await login())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        if response.statusCode == 401 {
            token = nil
            throw GridAPIError.unauthorized
        }
        guard response.statusCode == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GridAPIError.http(response.statusCode, Self.message(in: data))
        }
        return object
    }

    static func message(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["message"] ?? object["error"] ?? object["detail"]).map { "\($0)" }
    }
}

/// Electricity Maps API v3 (optional, SPEC 10.3): absolute carbon intensity and fossil-free share.
public struct ElectricityMapsClient: Sendable {
    public static let baseURL = URL(string: "https://api.electricitymaps.com/v3")!

    private let apiKey: String
    private let transport: HTTPTransport

    public init(apiKey: String, transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    public func latest(zone: String) async throws -> (gramsPerKWh: Double?, cleanShare: Double?, at: Date?) {
        let intensity = try await get("carbon-intensity/latest", zone: zone)
        let breakdown = try? await get("power-breakdown/latest", zone: zone)
        let fossilFree = (breakdown?["fossilFreePercentage"] as? NSNumber)?.doubleValue
        return (
            (intensity["carbonIntensity"] as? NSNumber)?.doubleValue,
            fossilFree.map { $0 / 100 },
            ParsingSupport.parseTimestamp(intensity["datetime"])
        )
    }

    private func get(_ path: String, zone: String) async throws -> [String: Any] {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "zone", value: zone)]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "auth-token")
        let (data, response) = try await transport.send(request)
        if response.statusCode == 401 || response.statusCode == 403 { throw GridAPIError.unauthorized }
        guard response.statusCode == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GridAPIError.http(response.statusCode, WattTimeClient.message(in: data))
        }
        return object
    }
}

/// WattTime's sign-up rules, checked before sending so problems show while typing.
/// Password rule as returned by `POST /register`: at least 8 characters, with a letter, a number and a special character.
public enum WattTimeAccountRules {
    public enum PasswordRule: String, CaseIterable, Sendable {
        case length, letter, number, special
    }

    public static func passes(_ rule: PasswordRule, _ password: String) -> Bool {
        switch rule {
        case .length: password.count >= 8
        case .letter: password.contains { $0.isLetter }
        case .number: password.contains { $0.isNumber }
        case .special: password.contains { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
        }
    }

    public static func isValidPassword(_ password: String) -> Bool {
        PasswordRule.allCases.allSatisfy { passes($0, password) }
    }

    /// A light check (something@something.tld); WattTime does the real validation.
    public static func isPlausibleEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !email.contains(" ") else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
    }

    /// Organization is required by WattTime but means nothing for personal use, so it is filled in.
    public static let defaultOrganization = "Personal (PowerBoard)"
}
