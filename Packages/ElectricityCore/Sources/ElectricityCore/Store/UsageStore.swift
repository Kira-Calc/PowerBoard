import Foundation
import GRDB

/// One row of `usage_event` (SPEC 6.1).
public struct UsageEventRow: Sendable, Hashable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "usage_event"

    public var id: Int64?
    public var dedupeKey: String
    public var source: String
    public var sessionId: String
    public var projectPath: String?
    public var model: String
    public var tier: String
    public var tierConfidence: String
    /// Unix milliseconds, UTC.
    public var tsUtc: Int64
    public var inputUncached: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    public var output: Int
    public var reasoning: Int
    public var factorVersion: String
    public var gridGPerKwh: Double
    public var gridBasis: String
    public var gridRegion: String?
    public var cleanShare: Double?
    public var cleanLevel: String?
    public var gridSource: String?
    public var energyWhLow: Double
    public var energyWhMid: Double
    public var energyWhHigh: Double
    public var co2GMid: Double
    /// Client that wrote the record ("CLI", "Desktop", …). Nil for records read before clients were recorded.
    public var client: String?

    enum CodingKeys: String, CodingKey {
        case id
        case dedupeKey = "dedupe_key"
        case source
        case sessionId = "session_id"
        case projectPath = "project_path"
        case model, tier
        case tierConfidence = "tier_confidence"
        case tsUtc = "ts_utc"
        case inputUncached = "input_uncached"
        case cacheWrite = "cache_write"
        case cacheRead = "cache_read"
        case output, reasoning
        case factorVersion = "factor_version"
        case gridGPerKwh = "grid_g_per_kwh"
        case gridBasis = "grid_basis"
        case gridRegion = "grid_region"
        case cleanShare = "clean_share"
        case cleanLevel = "clean_level"
        case gridSource = "grid_source"
        case energyWhLow = "energy_wh_low"
        case energyWhMid = "energy_wh_mid"
        case energyWhHigh = "energy_wh_high"
        case co2GMid = "co2_g_mid"
        case client
    }

    public init(usage: ParsedUsage, result: EnergyResult) {
        id = nil
        dedupeKey = usage.dedupeKey
        source = usage.source.rawValue
        sessionId = usage.sessionID
        projectPath = usage.projectPath
        model = usage.model
        tier = result.tier.tier
        tierConfidence = result.tier.confidence.rawValue
        tsUtc = Int64((usage.timestamp.timeIntervalSince1970 * 1000).rounded())
        inputUncached = usage.tokens.inputUncached
        cacheWrite = usage.tokens.cacheWrite
        cacheRead = usage.tokens.cacheRead
        output = usage.tokens.output
        reasoning = usage.tokens.reasoning
        cleanShare = nil
        cleanLevel = nil
        gridSource = nil
        factorVersion = ""
        gridGPerKwh = 0
        gridBasis = ""
        gridRegion = nil
        energyWhLow = 0
        energyWhMid = 0
        energyWhHigh = 0
        co2GMid = 0
        client = usage.client
        apply(result)
    }

    public var tokens: TokenCounts {
        TokenCounts(inputUncached: inputUncached, cacheWrite: cacheWrite, cacheRead: cacheRead, output: output, reasoning: reasoning)
    }

    public var timestamp: Date { Date(timeIntervalSince1970: Double(tsUtc) / 1000) }

    public var energyWh: Estimate { Estimate(low: energyWhLow, mid: energyWhMid, high: energyWhHigh) }

    public var grid: GridIntensity {
        GridIntensity(gramsPerKWh: gridGPerKwh, basis: GridBasis(rawValue: gridBasis) ?? .cloudAverage, region: gridRegion)
    }

    mutating func apply(_ result: EnergyResult) {
        tier = result.tier.tier
        tierConfidence = result.tier.confidence.rawValue
        factorVersion = result.factorVersion
        gridGPerKwh = result.grid.gramsPerKWh
        gridBasis = result.grid.basis.rawValue
        gridRegion = result.grid.region
        energyWhLow = result.energyWh.low
        energyWhMid = result.energyWh.mid
        energyWhHigh = result.energyWh.high
        co2GMid = result.co2Grams.mid
    }
}

struct FileCursorRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "file_cursor"

    var path: String
    var inode: Int64
    var offset: Int64
    var mtime: Double
    var skippedLines: Int
    var lineCount: Int
    var parserState: String?
    var source: String?

    enum CodingKeys: String, CodingKey {
        case path, inode, offset, mtime, source
        case skippedLines = "skipped_lines"
        case lineCount = "line_count"
        case parserState = "parser_state"
    }

    init(_ cursor: FileCursor) {
        path = cursor.path
        inode = Int64(bitPattern: cursor.inode)
        offset = cursor.offset
        mtime = cursor.mtime
        skippedLines = cursor.skippedLines
        lineCount = cursor.lineCount
        parserState = cursor.parserState
        source = cursor.source?.rawValue
    }

    var cursor: FileCursor {
        FileCursor(path: path, inode: UInt64(bitPattern: inode), offset: offset, mtime: mtime, skippedLines: skippedLines, lineCount: lineCount, parserState: parserState, source: source.flatMap(UsageSource.init))
    }
}

/// Aggregated usage over a set of records.
public struct UsageTotals: Sendable, Hashable {
    public var eventCount: Int
    public var tokens: TokenCounts
    public var energyWh: Estimate
    public var co2GramsMid: Double

    public static let zero = UsageTotals(eventCount: 0, tokens: .zero, energyWh: .zero, co2GramsMid: 0)
}

/// SQLite storage for usage events and file cursors. Thread-safe; callers run it off the main thread.
public final class UsageStore: Sendable {
    private let writer: any DatabaseWriter

    /// Opens or creates the database at `url` and runs migrations.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try DatabasePool(path: url.path)
        try Self.migrator.migrate(writer)
    }

    /// In-memory database, for tests.
    public init() throws {
        writer = try DatabaseQueue()
        try Self.migrator.migrate(writer)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "usage_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("dedupe_key", .text).notNull().unique(onConflict: .ignore)
                t.column("source", .text).notNull()
                t.column("session_id", .text).notNull()
                t.column("project_path", .text)
                t.column("model", .text).notNull()
                t.column("tier", .text).notNull()
                t.column("tier_confidence", .text).notNull()
                t.column("ts_utc", .integer).notNull()
                t.column("input_uncached", .integer).notNull()
                t.column("cache_write", .integer).notNull()
                t.column("cache_read", .integer).notNull()
                t.column("output", .integer).notNull()
                t.column("reasoning", .integer).notNull()
                t.column("factor_version", .text).notNull()
                t.column("grid_g_per_kwh", .double).notNull()
                t.column("grid_basis", .text).notNull()
                t.column("grid_region", .text)
                t.column("clean_share", .double)
                t.column("clean_level", .text)
                t.column("grid_source", .text)
                t.column("energy_wh_low", .double).notNull()
                t.column("energy_wh_mid", .double).notNull()
                t.column("energy_wh_high", .double).notNull()
                t.column("co2_g_mid", .double).notNull()
            }
            try db.create(index: "usage_event_ts", on: "usage_event", columns: ["ts_utc"])
            try db.create(index: "usage_event_source_ts", on: "usage_event", columns: ["source", "ts_utc"])
            try db.create(index: "usage_event_session", on: "usage_event", columns: ["session_id"])

            try db.create(table: "file_cursor") { t in
                t.primaryKey("path", .text)
                t.column("inode", .integer).notNull()
                t.column("offset", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("skipped_lines", .integer).notNull()
                t.column("line_count", .integer).notNull()
                t.column("parser_state", .text)
            }
        }
        migrator.registerMigration("v2-cursor-source") { db in
            try db.alter(table: "file_cursor") { t in
                t.add(column: "source", .text)
            }
        }
        migrator.registerMigration("v3-local-energy") { db in
            // Measured energy of this Mac per UTC minute (optional feature, off by default).
            try db.create(table: "local_energy") { t in
                t.primaryKey("minute_utc", .integer)
                t.column("wh", .double).notNull()
            }
        }
        migrator.registerMigration("v4-session-activity") { db in
            // Latest task state per session, for the active conversations list. Codex only for now.
            try db.create(table: "session_activity") { t in
                t.primaryKey("session_id", .text)
                t.column("source", .text).notNull()
                t.column("project_path", .text)
                t.column("log_path", .text).notNull()
                t.column("running", .boolean).notNull()
                t.column("event_utc", .integer).notNull()
            }
        }
        migrator.registerMigration("v5-client") { db in
            try db.alter(table: "usage_event") { t in t.add(column: "client", .text) }
        }
        return migrator
    }

    // MARK: Writing

    /// Inserts events, ignoring duplicates by dedupe key, and saves the cursor in the same transaction.
    /// Returns the number of new rows.
    @discardableResult
    public func insert(_ events: [UsageEventRow], cursor: FileCursor?) throws -> Int {
        try writer.write { db in
            var inserted = 0
            for event in events {
                try event.insert(db, onConflict: .ignore)
                inserted += db.changesCount
            }
            if let cursor {
                try FileCursorRow(cursor).save(db)
            }
            return inserted
        }
    }

    /// Replaces all records of one session with `events` and saves the cursors, in one transaction.
    /// Used for sources that are re-read as a whole (Antigravity databases). Returns the number of rows written.
    @discardableResult
    public func replaceSession(source: UsageSource, sessionID: String, with events: [UsageEventRow], cursors: [FileCursor]) throws -> Int {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM usage_event WHERE source = ? AND session_id = ?", arguments: [source.rawValue, sessionID])
            var written = 0
            for event in events {
                try event.insert(db, onConflict: .ignore)
                written += db.changesCount
            }
            for cursor in cursors {
                try FileCursorRow(cursor).save(db)
            }
            return written
        }
    }

    /// Recomputes energy and carbon for every record with the given calculator.
    /// Records based on the fixed cloud average use the calculator's current grid intensity. Records based on
    /// regional or live grid data keep the value stored with them, because live data cannot be fetched again.
    @discardableResult
    public func recalculateAll(with calculator: EnergyCalculator, batchSize: Int = 5000) throws -> Int {
        var lastID: Int64 = 0
        var updated = 0
        while true {
            let count = try writer.write { db -> Int in
                let rows = try UsageEventRow
                    .filter(Column("id") > lastID)
                    .order(Column("id"))
                    .limit(batchSize)
                    .fetchAll(db)
                for var row in rows {
                    let grid = row.grid.basis == .cloudAverage ? calculator.grid : row.grid
                    row.apply(calculator.estimate(model: row.model, tokens: row.tokens, grid: grid))
                    try row.update(db)
                }
                if let last = rows.last?.id { lastID = last }
                return rows.count
            }
            updated += count
            if count < batchSize { return updated }
        }
    }

    /// Deletes all records and cursors.
    public func deleteAll() throws {
        try writer.write { db in
            try UsageEventRow.deleteAll(db)
            try FileCursorRow.deleteAll(db)
        }
    }

    // MARK: Reading

    public func cursor(forPath path: String) throws -> FileCursor? {
        try writer.read { db in try FileCursorRow.fetchOne(db, key: path)?.cursor }
    }

    public func allCursors() throws -> [FileCursor] {
        try writer.read { db in try FileCursorRow.fetchAll(db).map(\.cursor) }
    }

    /// Totals for records with `start <= ts < end`, optionally for one source. Nil bounds are open.
    public func totals(source: UsageSource? = nil, from start: Date? = nil, to end: Date? = nil) throws -> UsageTotals {
        try writer.read { db in
            var conditions: [String] = []
            var arguments: StatementArguments = []
            if let source {
                conditions.append("source = ?")
                arguments += [source.rawValue]
            }
            if let start {
                conditions.append("ts_utc >= ?")
                arguments += [Self.milliseconds(start)]
            }
            if let end {
                conditions.append("ts_utc < ?")
                arguments += [Self.milliseconds(end)]
            }
            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
                SELECT COUNT(*), COALESCE(SUM(input_uncached), 0), COALESCE(SUM(cache_write), 0),
                       COALESCE(SUM(cache_read), 0), COALESCE(SUM(output), 0), COALESCE(SUM(reasoning), 0),
                       COALESCE(SUM(energy_wh_low), 0), COALESCE(SUM(energy_wh_mid), 0),
                       COALESCE(SUM(energy_wh_high), 0), COALESCE(SUM(co2_g_mid), 0)
                FROM usage_event \(whereClause)
                """
            guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return .zero }
            return UsageTotals(
                eventCount: row[0],
                tokens: TokenCounts(inputUncached: row[1], cacheWrite: row[2], cacheRead: row[3], output: row[4], reasoning: row[5]),
                energyWh: Estimate(low: row[6], mid: row[7], high: row[8]),
                co2GramsMid: row[9]
            )
        }
    }

    public func events(source: UsageSource? = nil) throws -> [UsageEventRow] {
        try writer.read { db in
            var request = UsageEventRow.order(Column("ts_utc"))
            if let source { request = request.filter(Column("source") == source.rawValue) }
            return try request.fetchAll(db)
        }
    }

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
