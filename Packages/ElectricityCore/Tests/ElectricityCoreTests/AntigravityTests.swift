import Foundation
import GRDB
import Testing
@testable import ElectricityCore

/// Builds protobuf messages for hand-written test databases.
private struct ProtoBuilder {
    var data = Data()

    private mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    func int(_ number: UInt32, _ value: UInt64) -> ProtoBuilder {
        var copy = self
        copy.varint(UInt64(number) << 3)
        copy.varint(value)
        return copy
    }

    func bytes(_ number: UInt32, _ value: Data) -> ProtoBuilder {
        var copy = self
        copy.varint(UInt64(number) << 3 | 2)
        copy.varint(UInt64(value.count))
        copy.data.append(value)
        return copy
    }

    func text(_ number: UInt32, _ value: String) -> ProtoBuilder { bytes(number, Data(value.utf8)) }
    func message(_ number: UInt32, _ value: ProtoBuilder) -> ProtoBuilder { bytes(number, value.data) }
}

private func usage(input: UInt64, output: UInt64, cacheWrite: UInt64 = 0, cacheRead: UInt64 = 0, reasoning: UInt64 = 0, response: String? = nil, message: String? = nil) -> ProtoBuilder {
    var builder = ProtoBuilder().int(2, input).int(3, output).int(4, cacheWrite).int(5, cacheRead).int(9, reasoning)
    if let message { builder = builder.text(7, message) }
    if let response { builder = builder.text(11, response) }
    return builder
}

private func timestamp(_ seconds: UInt64) -> ProtoBuilder { ProtoBuilder().int(1, seconds) }

private func generation(model: String?, usage: ProtoBuilder?, retries: [ProtoBuilder] = [], at seconds: UInt64? = nil) -> Data {
    var chat = ProtoBuilder()
    if let usage { chat = chat.message(4, usage) }
    for retry in retries { chat = chat.message(17, ProtoBuilder().message(2, retry)) }
    if let seconds { chat = chat.message(9, ProtoBuilder().message(4, timestamp(seconds))) }
    if let model { chat = chat.text(19, model) }
    return ProtoBuilder().message(1, chat).data
}

private func step(model: String?, usage: ProtoBuilder, at seconds: UInt64) -> Data {
    var builder = ProtoBuilder().message(8, timestamp(seconds)).message(9, usage)
    if let model { builder = builder.message(24, ProtoBuilder().text(12, model)) }
    return builder.data
}

private func makeDatabase(at url: URL, generations: [Data], steps: [Data] = [], conversationStart: UInt64? = nil) throws {
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
        try db.execute(sql: "CREATE TABLE steps (idx INTEGER PRIMARY KEY, metadata BLOB)")
        try db.execute(sql: "CREATE TABLE trajectory_metadata_blob (data BLOB)")
        for (index, blob) in generations.enumerated() {
            try db.execute(sql: "INSERT INTO gen_metadata (idx, data) VALUES (?, ?)", arguments: [index, blob])
        }
        for (index, blob) in steps.enumerated() {
            try db.execute(sql: "INSERT INTO steps (idx, metadata) VALUES (?, ?)", arguments: [index, blob])
        }
        if let conversationStart {
            try db.execute(sql: "INSERT INTO trajectory_metadata_blob (data) VALUES (?)",
                           arguments: [ProtoBuilder().message(2, timestamp(conversationStart)).data])
        }
    }
}

@Suite struct AntigravityTests {
    private let t0: UInt64 = 1_791_766_800

    @Test func protobufReaderRejectsTruncatedData() {
        #expect(throws: ProtoMessage.DecodeError.self) { try ProtoMessage(Data([0x0A, 0x05, 0x01])) }
        #expect(throws: ProtoMessage.DecodeError.self) { try ProtoMessage(Data([0x80])) }
    }

    @Test func mergesGenerationStepAndRetryRecordsByIdentity() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("conv-1.db")
        try makeDatabase(
            at: url,
            generations: [
                generation(model: "Gemini 3.8 Flash (High)", usage: usage(input: 100, output: 40, cacheRead: 500, reasoning: 10, response: "r1"), at: t0 + 10),
                // Retry of a different response, plus a row that is not decodable.
                generation(model: nil, usage: nil, retries: [usage(input: 7, output: 3, message: "m2")], at: t0 + 20),
                Data([0xFF, 0xFF]),
            ],
            // The same response again, with a larger output count and an earlier timestamp.
            steps: [step(model: "Gemini 3.8 Flash (High)", usage: usage(input: 100, output: 55, cacheRead: 500, reasoning: 10, response: "r1"), at: t0 + 5)],
            conversationStart: t0
        )

        let result = try AntigravityParser.parse(paths: [url.path], sessionID: "conv-1")
        #expect(result.skippedRows == 1)
        #expect(result.usages.count == 2)
        let merged = try #require(result.usages.first { $0.tokens.inputUncached == 100 })
        #expect(merged.tokens == TokenCounts(inputUncached: 100, cacheRead: 500, output: 55, reasoning: 10))
        #expect(merged.model == "gemini-3.8-flash-high")
        #expect(merged.timestamp == Date(timeIntervalSince1970: Double(t0 + 5)))
        #expect(merged.source == .antigravity)
        #expect(merged.sessionID == "conv-1")
        let retry = try #require(result.usages.first { $0.tokens.inputUncached == 7 })
        // The retry inherits the most recent model seen in generation rows.
        #expect(retry.model == "gemini-3.8-flash-high")
    }

    @Test func outputIncludesReasoningWhenOnlyVisibleCountIsSet() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("c.db")
        let visibleOnly = ProtoBuilder().int(2, 10).int(9, 30).int(10, 20).text(11, "r")
        try makeDatabase(at: url, generations: [generation(model: "x", usage: visibleOnly, at: t0)])
        let usage = try #require(AntigravityParser.parse(paths: [url.path], sessionID: "c").usages.first)
        #expect(usage.tokens.output == 50)
        #expect(usage.tokens.reasoning == 30)
    }

    @Test func backupCopiesOfAConversationAreCountedOnce() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let first = dir.appendingPathComponent("a/conv.db")
        let second = dir.appendingPathComponent("b/conv.db")
        for url in [first, second] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try makeDatabase(at: url, generations: [generation(model: "Gemini 3.7 Pro", usage: usage(input: 1, output: 2, response: "same"), at: t0)])
        }
        let result = try AntigravityParser.parse(paths: [first.path, second.path], sessionID: "conv")
        #expect(result.usages.count == 1)
        #expect(result.usages[0].model == "gemini-3.7-pro")
    }

    @Test func recordsWithoutTimestampsUseConversationStart() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("c.db")
        try makeDatabase(at: url, generations: [generation(model: "m", usage: usage(input: 1, output: 1))], conversationStart: t0 + 99)
        let usage = try #require(AntigravityParser.parse(paths: [url.path], sessionID: "c").usages.first)
        #expect(usage.timestamp == Date(timeIntervalSince1970: Double(t0 + 99)))
    }

    @Test func otherDatabasesAreRejected() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("other.db")
        try DatabaseQueue(path: url.path).write { try $0.execute(sql: "CREATE TABLE t (x)") }
        #expect(throws: AntigravityParser.ParseError.self) {
            try AntigravityParser.parse(paths: [url.path], sessionID: "other")
        }
    }

    @Test func geminiTiers() throws {
        let table = try ModelTierTable.bundled()
        #expect(table.classify(model: "gemini-3.8-flash-high") == TierAssignment(tier: "small", confidence: .assumed))
        #expect(table.classify(model: "gemini-3.7-pro") == TierAssignment(tier: "medium", confidence: .assumed))
    }

    @Test func ingestReplacesChangedConversations() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let conversations = dir.appendingPathComponent("antigravity/conversations")
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        let url = conversations.appendingPathComponent("conv.db")
        try makeDatabase(at: url, generations: [generation(model: "Gemini 3.7 Pro", usage: usage(input: 10, output: 5, response: "r1"), at: t0)])

        let store = try UsageStore()
        let locations = LogLocations.standard(environment: ["ANTIGRAVITY_DATA_DIR": dir.appendingPathComponent("antigravity").path], home: dir)
        #expect(locations.antigravity.map(\.lastPathComponent) == ["conversations"])
        let service = IngestService(store: store, calculator: try TestSupport.calculator(), locations: locations)

        let first = await service.scan()
        #expect(first.bySource[.antigravity]?.eventsInserted == 1)
        #expect(try store.totals(source: .antigravity).tokens.output == 5)

        // Unchanged: nothing is read.
        let idle = await service.scan()
        #expect(idle.bySource[.antigravity]?.filesRead == 0)

        // The same response grows and a new one is added: rows are replaced, not duplicated.
        try await DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "INSERT INTO steps (idx, metadata) VALUES (?, ?)",
                           arguments: [1, step(model: nil, usage: usage(input: 10, output: 9, response: "r1"), at: t0)])
            try db.execute(sql: "INSERT INTO gen_metadata (idx, data) VALUES (?, ?)",
                           arguments: [5, generation(model: nil, usage: usage(input: 1, output: 1, response: "r2"), at: t0 + 60)])
        }
        _ = await service.scan()
        let totals = try store.totals(source: .antigravity)
        #expect(totals.eventCount == 2)
        #expect(totals.tokens.output == 10)
        #expect(try store.sourceStats()[.antigravity]?.filesTracked == 1)
    }
}
