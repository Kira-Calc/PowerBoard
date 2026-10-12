import Foundation

/// Lightweight data for the menu bar, notch panel and CLI (SPEC 7).
public struct Snapshot: Sendable, Hashable, Codable {
    public static let currentSchema = 1
    /// Number of 5-minute buckets in `lastHourSparklineWh`.
    public static let sparklineBuckets = 12

    public struct Tokens: Sendable, Hashable, Codable {
        public var input: Int
        public var output: Int
        public var cacheWrite: Int
        public var cacheRead: Int

        enum CodingKeys: String, CodingKey {
            case input, output
            case cacheWrite = "cache_write"
            case cacheRead = "cache_read"
        }

        public init(input: Int, output: Int, cacheWrite: Int, cacheRead: Int) {
            self.input = input
            self.output = output
            self.cacheWrite = cacheWrite
            self.cacheRead = cacheRead
        }

        public init(_ counts: TokenCounts) {
            self.init(input: counts.inputUncached, output: counts.output, cacheWrite: counts.cacheWrite, cacheRead: counts.cacheRead)
        }

        public var total: Int { input + output + cacheWrite + cacheRead }
    }

    public struct SourceShare: Sendable, Hashable, Codable {
        public var energyWhMid: Double

        enum CodingKeys: String, CodingKey {
            case energyWhMid = "energy_wh_mid"
        }

        public init(energyWhMid: Double) {
            self.energyWhMid = energyWhMid
        }
    }

    /// Grid state of the servers used most today (SPEC 10.5).
    public struct Grid: Sendable, Hashable, Codable {
        public var level: GridLevel?
        public var locationCertainty: LocationCertainty
        public var cleanShare: Double?
        public var updatedAt: Date?
        public var source: GridDataSource?
        public var provider: GridProvider

        enum CodingKeys: String, CodingKey {
            case level, source, provider
            case locationCertainty = "location_certainty"
            case cleanShare = "clean_share"
            case updatedAt = "updated_at"
        }

        public init(status: GridStatus) {
            level = status.level
            locationCertainty = status.certainty
            cleanShare = status.cleanShare
            updatedAt = status.updatedAt
            source = status.source
            provider = status.provider
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(level, forKey: .level)
            try container.encode(locationCertainty, forKey: .locationCertainty)
            try container.encode(cleanShare, forKey: .cleanShare)
            try container.encode(updatedAt, forKey: .updatedAt)
            try container.encode(source, forKey: .source)
            try container.encode(provider, forKey: .provider)
        }
    }

    public struct Today: Sendable, Hashable, Codable {
        /// Local calendar date, `YYYY-MM-DD`.
        public var date: String
        public var tokens: Tokens
        public var energyWh: Estimate
        public var co2G: Double
        public var cleanShare: Double?
        public var bySource: [String: SourceShare]
        /// Measured energy of this Mac today, in Wh. Present only when the user turned the feature on.
        public var localEnergyWh: Double?
        public var grid: Grid?

        enum CodingKeys: String, CodingKey {
            case date, tokens
            case energyWh = "energy_wh"
            case co2G = "co2_g"
            case cleanShare = "clean_share"
            case bySource = "by_source"
            case localEnergyWh = "local_energy_wh"
            case grid
        }

        public init(date: String, tokens: Tokens, energyWh: Estimate, co2G: Double, cleanShare: Double?, bySource: [String: SourceShare],
                    localEnergyWh: Double? = nil, grid: Grid? = nil) {
            self.date = date
            self.tokens = tokens
            self.energyWh = energyWh
            self.co2G = co2G
            self.cleanShare = cleanShare
            self.bySource = bySource
            self.localEnergyWh = localEnergyWh
            self.grid = grid
        }

        // `clean_share` is written as an explicit null, as in SPEC 7.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(date, forKey: .date)
            try container.encode(tokens, forKey: .tokens)
            try container.encode(energyWh, forKey: .energyWh)
            try container.encode(co2G, forKey: .co2G)
            try container.encode(cleanShare, forKey: .cleanShare)
            try container.encode(bySource, forKey: .bySource)
            try container.encodeIfPresent(localEnergyWh, forKey: .localEnergyWh)
            try container.encodeIfPresent(grid, forKey: .grid)
        }

        public func energyWhMid(for source: UsageSource) -> Double {
            bySource[source.rawValue]?.energyWhMid ?? 0
        }
    }

    public struct Session: Sendable, Hashable, Codable {
        public var source: String
        public var energyWhMid: Double
        public var co2G: Double
        public var tokensTotal: Int
        public var lastTs: Date

        enum CodingKeys: String, CodingKey {
            case source
            case energyWhMid = "energy_wh_mid"
            case co2G = "co2_g"
            case tokensTotal = "tokens_total"
            case lastTs = "last_ts"
        }

        public init(source: String, energyWhMid: Double, co2G: Double, tokensTotal: Int, lastTs: Date) {
            self.source = source
            self.energyWhMid = energyWhMid
            self.co2G = co2G
            self.tokensTotal = tokensTotal
            self.lastTs = lastTs
        }
    }

    public var schema: Int
    public var generatedAt: Date
    public var appRunning: Bool
    public var today: Today
    /// Sessions active in the last 24 hours, keyed by session ID.
    public var sessions: [String: Session]
    /// Energy (Wh, mid) per 5-minute bucket over the last hour, oldest first.
    public var lastHourSparklineWh: [Double]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case appRunning = "app_running"
        case today, sessions
        case lastHourSparklineWh = "last_hour_sparkline_wh"
    }

    public init(schema: Int = Snapshot.currentSchema, generatedAt: Date, appRunning: Bool, today: Today, sessions: [String: Session], lastHourSparklineWh: [Double]) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.appRunning = appRunning
        self.today = today
        self.sessions = sessions
        self.lastHourSparklineWh = lastHourSparklineWh
    }

    /// True when the snapshot is older than `maxAge` or the app reported that it stopped.
    public func isStale(now: Date = Date(), maxAge: TimeInterval = 300) -> Bool {
        !appRunning || now.timeIntervalSince(generatedAt) > maxAge
    }
}

/// Reads and writes the snapshot file. Writes go to a temporary file that atomically replaces the old one,
/// so readers never see a partial file (SPEC 7).
public enum SnapshotFile {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func write(_ snapshot: Snapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder().encode(snapshot)
        // `.atomic` writes to a temporary file in the same directory and renames it over the target.
        try data.write(to: url, options: [.atomic])
    }

    /// Returns nil when the file does not exist.
    public static func read(from url: URL) throws -> Snapshot? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        return try decoder().decode(Snapshot.self, from: data)
    }
}
