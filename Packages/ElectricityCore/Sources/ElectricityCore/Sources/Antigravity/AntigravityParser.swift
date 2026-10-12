import Foundation
import GRDB

/// Parses Google Antigravity conversation databases.
///
/// Each conversation is a SQLite file whose `gen_metadata` and `steps` tables hold protobuf blobs.
/// Only the usage message and model fields are decoded; conversation content is never read.
/// The same response can appear in generation rows, step rows and retry records, so records are merged by
/// response, provider message or message identity, keeping the largest value of each token count.
/// Field numbers follow the format documented by ccusage (MIT), which this parser was written against.
public enum AntigravityParser {
    static let unknownModel = "antigravity-unknown"

    /// Usage message (`ModelUsage`).
    struct Usage {
        var modelID: UInt64?
        var input: UInt64 = 0
        var totalOutput: UInt64 = 0
        var cacheWrite: UInt64 = 0
        var cacheRead: UInt64 = 0
        var reasoning: UInt64 = 0
        var visibleOutput: UInt64 = 0
        var messageID: String?
        var responseID: String?
        var providerMessageID: String?

        init(_ message: ProtoMessage) {
            modelID = message.varint(1).flatMap { $0 == 0 ? nil : $0 }
            input = message.varint(2) ?? 0
            totalOutput = message.varint(3) ?? 0
            cacheWrite = message.varint(4) ?? 0
            cacheRead = message.varint(5) ?? 0
            reasoning = message.varint(9) ?? 0
            visibleOutput = message.varint(10) ?? 0
            messageID = message.text(7)
            responseID = message.text(11)
            providerMessageID = message.text(12)
        }

        var hasTokens: Bool {
            input > 0 || totalOutput > 0 || cacheWrite > 0 || cacheRead > 0 || reasoning > 0 || visibleOutput > 0
        }

        var identities: [String] {
            [responseID.map { "response:\($0)" }, providerMessageID.map { "provider:\($0)" }, messageID.map { "message:\($0)" }]
                .compactMap { $0 }
        }
    }

    /// One usage record before merging.
    struct Record {
        var usage: Usage
        var model: String?
        /// Higher is more reliable: 3 row timestamp, 1 conversation start, 0 file modification time.
        var timestamp: Date
        var timestampRank: Int
    }

    public struct FileResult: Sendable {
        public var usages: [ParsedUsage]
        /// Rows whose protobuf could not be decoded.
        public var skippedRows: Int
    }

    public enum ParseError: Error {
        case notAConversationDatabase
    }

    /// Parses the databases of one conversation (the same file name may exist in several roots, such as backups)
    /// and returns merged usage records.
    public static func parse(paths: [String], sessionID: String) throws -> FileResult {
        var records: [Record] = []
        var skipped = 0
        var parsedAny = false
        for path in paths {
            guard let fileRecords = try? readRecords(path: path, skipped: &skipped) else { continue }
            parsedAny = true
            records += fileRecords
        }
        guard parsedAny else { throw ParseError.notAConversationDatabase }
        return FileResult(usages: merge(records, sessionID: sessionID), skippedRows: skipped)
    }

    static func readRecords(path: String, skipped: inout Int) throws -> [Record] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        let fileDate = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()

        return try queue.read { db -> [Record] in
            guard try db.tableExists("gen_metadata") else { throw ParseError.notAConversationDatabase }
            var conversationStart: Date?
            if try db.tableExists("trajectory_metadata_blob") {
                for blob in try Data.fetchAll(db, sql: "SELECT data FROM trajectory_metadata_blob ORDER BY rowid") {
                    if conversationStart == nil, let message = try? ProtoMessage(blob) {
                        conversationStart = (try? message.message(2)).flatMap(timestamp)
                    }
                }
            }
            func fallback() -> (Date, Int) {
                conversationStart.map { ($0, 1) } ?? (fileDate, 0)
            }

            var records: [Record] = []
            if try db.tableExists("steps") {
                for row in try Row.fetchAll(db, sql: "SELECT metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx") {
                    guard let blob = row[0] as Data?, let step = try? ProtoMessage(blob) else {
                        skipped += 1
                        continue
                    }
                    let info = try? step.message(24)
                    let model = info.flatMap { $0.text(12) ?? $0.text(8) }
                    let stamp = (try? step.message(8)).flatMap(timestamp)
                        ?? (try? step.message(1)).flatMap(timestamp)
                    let (date, rank) = stamp.map { ($0, 3) } ?? fallback()
                    var usages: [ProtoMessage] = []
                    if let usage = try? step.message(9) { usages.append(usage) }
                    usages += step.allBytes(28).compactMap { (try? ProtoMessage($0).message(2)) ?? nil }
                    for usage in usages {
                        records.append(Record(usage: Usage(usage), model: model, timestamp: date, timestampRank: rank))
                    }
                }
            }

            var currentModel: String?
            for blob in try Data.fetchAll(db, sql: "SELECT data FROM gen_metadata ORDER BY idx") {
                guard let root = try? ProtoMessage(blob), let chat = try? root.message(1) else {
                    skipped += 1
                    continue
                }
                if let model = chat.text(19) ?? chat.text(21) { currentModel = model }
                let stamp = (try? chat.message(9)).flatMap { info in (try? info.message(4)).flatMap(timestamp) }
                let (date, rank) = stamp.map { ($0, 3) } ?? fallback()
                var usages: [ProtoMessage] = []
                if let usage = try? chat.message(4) { usages.append(usage) }
                usages += chat.allBytes(17).compactMap { (try? ProtoMessage($0).message(2)) ?? nil }
                for usage in usages {
                    records.append(Record(usage: Usage(usage), model: currentModel, timestamp: date, timestampRank: rank))
                }
            }
            return records
        }
    }

    /// `google.protobuf.Timestamp`-like message: 1 seconds, 2 nanos.
    static func timestamp(_ message: ProtoMessage) -> Date? {
        guard let seconds = message.varint(1), seconds > 0, seconds < 1 << 40 else { return nil }
        let nanos = min(message.varint(2) ?? 0, 999_999_999)
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9)
    }

    /// Merges records that share any identity, then converts them to `ParsedUsage`.
    static func merge(_ records: [Record], sessionID: String) -> [ParsedUsage] {
        var groups: [[Record]] = []
        var groupForIdentity: [String: Int] = [:]
        var anonymous = 0
        var anonymousKeys: [Int: String] = [:]
        for record in records where record.usage.hasTokens {
            let identities = record.usage.identities
            let matches = Set(identities.compactMap { groupForIdentity[$0] })
            if let target = matches.min() {
                // Fold every other matching group into the first one.
                for other in matches where other != target {
                    groups[target] += groups[other]
                    groups[other] = []
                }
                groups[target].append(record)
                for identity in groups[target].flatMap(\.usage.identities) { groupForIdentity[identity] = target }
            } else {
                groups.append([record])
                let index = groups.count - 1
                for identity in identities { groupForIdentity[identity] = index }
                if identities.isEmpty {
                    anonymousKeys[index] = "\(sessionID)#\(anonymous)"
                    anonymous += 1
                }
            }
        }

        return groups.enumerated().compactMap { index, group -> ParsedUsage? in
            guard !group.isEmpty else { return nil }
            func maxOf(_ value: (Usage) -> UInt64) -> Int { Int(clamping: group.map { value($0.usage) }.max() ?? 0) }
            let reasoning = maxOf(\.reasoning)
            let visible = maxOf(\.visibleOutput)
            let output = max(maxOf(\.totalOutput), visible + reasoning)
            let best = group.max { ($0.timestampRank, -$0.timestamp.timeIntervalSince1970) < ($1.timestampRank, -$1.timestamp.timeIntervalSince1970) }!
            let model = group.lazy.compactMap { $0.model.flatMap(normalizeModel) }.first
                ?? group.lazy.compactMap { $0.usage.modelID.map { "antigravity-model-\($0)" } }.first
                ?? unknownModel
            let identity = group.flatMap(\.usage.identities).sorted().first ?? anonymousKeys[index] ?? "\(sessionID)#\(index)"
            return ParsedUsage(
                dedupeKey: "antigravity:" + ParsingSupport.sha256Hex("\(sessionID)\n\(identity)"),
                source: .antigravity,
                sessionID: sessionID,
                projectPath: nil,
                model: model,
                timestamp: best.timestamp,
                tokens: TokenCounts(
                    inputUncached: maxOf(\.input),
                    cacheWrite: maxOf(\.cacheWrite),
                    cacheRead: maxOf(\.cacheRead),
                    output: output,
                    reasoning: reasoning
                )
            )
        }
    }

    /// Turns display names such as "Gemini 3.8 Flash (High)" into "gemini-3.8-flash-high".
    static func normalizeModel(_ raw: String) -> String? {
        let lowered = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lowered.isEmpty else { return nil }
        let cleaned = lowered
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "_" })
            .joined(separator: "-")
        return cleaned.isEmpty ? nil : cleaned
    }
}
