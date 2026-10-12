import Foundation

/// Progress of a scan, reported after each file.
public struct IngestProgress: Sendable, Hashable {
    public var filesDone: Int
    public var filesTotal: Int
}

/// Per-source results of a scan.
public struct SourceScanSummary: Sendable, Hashable {
    public var filesFound: Int = 0
    public var filesRead: Int = 0
    public var linesRead: Int = 0
    public var eventsInserted: Int = 0
    /// Skipped lines found during this scan.
    public var linesSkipped: Int = 0
    /// Files that could not be opened or read.
    public var fileErrors: Int = 0

    public init() {}
}

public struct ScanSummary: Sendable, Hashable {
    public var bySource: [UsageSource: SourceScanSummary] = [:]

    public init() {}

    public var eventsInserted: Int { bySource.values.reduce(0) { $0 + $1.eventsInserted } }
}

/// Reads new log lines, parses them, computes energy, and stores the results (SPEC 4.3).
/// All parsing and database work runs on this actor, off the main thread.
public actor IngestService {
    private let store: UsageStore
    private var calculator: EnergyCalculator
    private var locations: LogLocations
    private let chunkBytes: Int
    private var grid: [GridProvider: GridStatus] = [:]
    /// Only records this recent get the current grid level; older ones happened under other conditions.
    static let gridRecencyWindow: TimeInterval = 20 * 60

    public init(store: UsageStore, calculator: EnergyCalculator, locations: LogLocations, chunkBytes: Int = 8 << 20) {
        self.store = store
        self.calculator = calculator
        self.locations = locations
        self.chunkBytes = chunkBytes
    }

    /// Used for new records only. Use `UsageStore.recalculateAll` to update history.
    public func setCalculator(_ calculator: EnergyCalculator) {
        self.calculator = calculator
    }

    public func setLocations(_ locations: LogLocations) {
        self.locations = locations
    }

    public func setGrid(_ statuses: [GridProvider: GridStatus]) {
        grid = statuses
    }

    /// An event row with energy and, for recent records, the grid state at the time (SPEC 10.3).
    func row(for usage: ParsedUsage, now: Date = Date()) -> UsageEventRow {
        var row = UsageEventRow(usage: usage, result: calculator.estimate(model: usage.model, tokens: usage.tokens))
        if now.timeIntervalSince(usage.timestamp) < Self.gridRecencyWindow,
           let status = grid[GridProvider(source: usage.source)], let source = status.source {
            row.cleanLevel = status.level?.rawValue
            row.cleanShare = status.cleanShare
            row.gridSource = source.rawValue
        }
        return row
    }

    /// Scans every log file and reads what is new since the last scan. The first scan backfills all history.
    public func scan(progress: (@Sendable (IngestProgress) -> Void)? = nil) -> ScanSummary {
        var summary = ScanSummary()
        let files = UsageSource.allCases.map { source in (source, locations.logFiles(for: source)) }
        let total = files.reduce(0) { $0 + $1.1.count }
        var done = 0
        for (source, paths) in files {
            var sourceSummary = SourceScanSummary()
            sourceSummary.filesFound = paths.count
            if source == .antigravity {
                // Databases of the same conversation (for example a backup copy) are read together.
                let groups = Dictionary(grouping: paths) { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                for (sessionID, groupPaths) in groups.sorted(by: { $0.key < $1.key }) {
                    do {
                        try ingestAntigravity(sessionID: sessionID, paths: groupPaths.sorted(), summary: &sourceSummary)
                    } catch {
                        sourceSummary.fileErrors += 1
                    }
                    done += groupPaths.count
                    progress?(IngestProgress(filesDone: done, filesTotal: total))
                }
                summary.bySource[source] = sourceSummary
                continue
            }
            for path in paths {
                do {
                    try ingestFile(path: path, source: source, summary: &sourceSummary)
                } catch {
                    sourceSummary.fileErrors += 1
                }
                done += 1
                progress?(IngestProgress(filesDone: done, filesTotal: total))
            }
            summary.bySource[source] = sourceSummary
        }
        return summary
    }

    /// Antigravity databases change in place, so a changed conversation is read again as a whole and its
    /// records are replaced. The cursor stores the combined size and latest modification time of the database
    /// and its write-ahead log.
    private func ingestAntigravity(sessionID: String, paths: [String], summary: inout SourceScanSummary) throws {
        var cursors: [FileCursor] = []
        var changed = false
        for path in paths {
            let status = try FileStatus.of(path: path)
            let wal = try? FileStatus.of(path: path + "-wal")
            let size = status.size + (wal?.size ?? 0)
            let mtime = max(status.mtime, wal?.mtime ?? 0)
            let saved = try store.cursor(forPath: path)
            if saved?.inode != status.inode || saved?.offset != size || saved?.mtime != mtime {
                changed = true
            }
            cursors.append(FileCursor(path: path, inode: status.inode, offset: size, mtime: mtime, skippedLines: saved?.skippedLines ?? 0, source: .antigravity))
        }
        guard changed else { return }
        summary.filesRead += paths.count

        let result = try AntigravityParser.parse(paths: paths, sessionID: sessionID)
        let rows = result.usages.map { row(for: $0) }
        for index in cursors.indices { cursors[index].skippedLines = 0 }
        if !cursors.isEmpty { cursors[0].skippedLines = result.skippedRows }
        summary.linesSkipped += result.skippedRows
        let before = try store.totals(source: .antigravity).eventCount
        try store.replaceSession(source: .antigravity, sessionID: sessionID, with: rows, cursors: cursors)
        let after = try store.totals(source: .antigravity).eventCount
        summary.eventsInserted += max(0, after - before)
    }

    private func ingestFile(path: String, source: UsageSource, summary: inout SourceScanSummary) throws {
        let status = try FileStatus.of(path: path)
        var cursor: FileCursor
        let saved = try store.cursor(forPath: path)
        switch IncrementalReader.plan(path: path, saved: saved, status: status) {
        case .upToDate:
            // Cursors saved before the source column existed get it filled in here.
            if var saved, saved.source != source {
                saved.source = source
                try store.insert([], cursor: saved)
            }
            return
        case .resume(let saved):
            cursor = saved
        case .restart(let fresh):
            cursor = fresh
        }
        cursor.source = source
        summary.filesRead += 1

        var codexState = cursor.parserState
            .flatMap { try? JSONDecoder().decode(CodexParserState.self, from: Data($0.utf8)) } ?? CodexParserState()

        while let chunk = try IncrementalReader.readChunk(
            path: path,
            offset: cursor.offset,
            firstLineNumber: cursor.lineCount + 1,
            maxBytes: chunkBytes
        ) {
            var rows: [UsageEventRow] = []
            for (index, line) in chunk.lines.enumerated() {
                if line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }) { continue }
                let outcome: ParseOutcome
                switch source {
                case .claudeCode:
                    outcome = ClaudeCodeParser.parse(line: line)
                case .codex:
                    outcome = CodexParser.parse(line: line, filePath: path, lineNumber: chunk.firstLineNumber + index, state: &codexState)
                case .antigravity:
                    // Antigravity databases are read by `ingestAntigravity`, never line by line.
                    outcome = .ignored
                }
                switch outcome {
                case .usage(let usage):
                    rows.append(row(for: usage))
                case .ignored:
                    break
                case .skipped:
                    cursor.skippedLines += 1
                    summary.linesSkipped += 1
                }
            }
            summary.linesRead += chunk.lines.count
            cursor.offset = chunk.endOffset
            cursor.lineCount += chunk.lines.count
            if source == .codex {
                cursor.parserState = (try? JSONEncoder().encode(codexState)).map { String(decoding: $0, as: UTF8.self) }
            }
            summary.eventsInserted += try store.insert(rows, cursor: cursor)
        }

        // Latest task state of a Codex session, for the active conversations list.
        if source == .codex, let running = codexState.taskRunning, let eventAt = codexState.taskEventAt {
            try store.saveActivity(SessionActivity(
                sessionID: codexState.sessionID ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                source: .codex,
                projectPath: codexState.cwd,
                logPath: path,
                running: running,
                eventAt: eventAt
            ))
        }

        // Record mtime only once the file is read to its last complete line.
        cursor.mtime = status.mtime
        try store.insert([], cursor: cursor)
    }
}
