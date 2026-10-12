import Foundation
import Testing
@testable import ElectricityCore

@Suite struct ClaudeCodeParserTests {
    private func assistantLine(
        model: String = "claude-sonnet-test",
        messageID: String? = "msg_1",
        requestID: String? = "req_1",
        timestamp: String? = "2026-10-12T01:00:00.000Z",
        sessionID: String? = "sess",
        usage: String = #"{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}"#
    ) -> Data {
        var fields = [#""type":"assistant""#]
        if let timestamp { fields.append(#""timestamp":"\#(timestamp)""#) }
        if let sessionID { fields.append(#""sessionId":"\#(sessionID)""#) }
        fields.append(#""cwd":"/tmp/example/project""#)
        if let requestID { fields.append(#""requestId":"\#(requestID)""#) }
        var message = [#""model":"\#(model)""#, #""usage":\#(usage)"#]
        if let messageID { message.insert(#""id":"\#(messageID)""#, at: 0) }
        fields.append(#""message":{\#(message.joined(separator: ","))}"#)
        return TestSupport.line("{" + fields.joined(separator: ",") + "}")
    }

    @Test func parsesNormalLine() throws {
        let usage = try #require(TestSupport.usage(of: ClaudeCodeParser.parse(line: assistantLine())))
        #expect(usage.dedupeKey == "msg_1:req_1")
        #expect(usage.source == .claudeCode)
        #expect(usage.sessionID == "sess")
        #expect(usage.projectPath == "/tmp/example/project")
        #expect(usage.model == "claude-sonnet-test")
        #expect(usage.tokens == TokenCounts(inputUncached: 10, cacheWrite: 30, cacheRead: 40, output: 20))
        #expect(usage.timestamp == Date(timeIntervalSince1970: 1_791_766_800))
    }

    @Test func duplicateLinesShareDedupeKey() throws {
        let first = try #require(TestSupport.usage(of: ClaudeCodeParser.parse(line: assistantLine(timestamp: "2026-10-12T01:00:00.000Z"))))
        let second = try #require(TestSupport.usage(of: ClaudeCodeParser.parse(line: assistantLine(timestamp: "2026-10-12T01:00:01.000Z"))))
        #expect(first.dedupeKey == second.dedupeKey)
    }

    @Test func missingIDsFallBackToLineHash() throws {
        let line = assistantLine(requestID: nil)
        let usage = try #require(TestSupport.usage(of: ClaudeCodeParser.parse(line: line)))
        #expect(usage.dedupeKey == "sha256:" + ParsingSupport.sha256Hex(line))
        let noMessageID = try #require(TestSupport.usage(of: ClaudeCodeParser.parse(line: assistantLine(messageID: nil))))
        #expect(noMessageID.dedupeKey.hasPrefix("sha256:"))
    }

    @Test func syntheticModelIsIgnored() {
        #expect(ClaudeCodeParser.parse(line: assistantLine(model: "<synthetic>")) == .ignored)
    }

    @Test func zeroUsageIsIgnored() {
        let zero = #"{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}"#
        #expect(ClaudeCodeParser.parse(line: assistantLine(usage: zero)) == .ignored)
    }

    @Test func missingCacheFieldsCountAsZero() throws {
        let usage = try #require(TestSupport.usage(of: ClaudeCodeParser.parse(line: assistantLine(usage: #"{"input_tokens":5,"output_tokens":6}"#))))
        #expect(usage.tokens == TokenCounts(inputUncached: 5, output: 6))
    }

    @Test func missingRequiredFieldsAreSkipped() {
        #expect(ClaudeCodeParser.parse(line: assistantLine(timestamp: nil)) == .skipped(.missingField))
        #expect(ClaudeCodeParser.parse(line: assistantLine(sessionID: nil)) == .skipped(.missingField))
        let noModel = TestSupport.line(#"{"type":"assistant","timestamp":"2026-10-12T01:00:00Z","sessionId":"s","message":{"usage":{"input_tokens":1}}}"#)
        #expect(ClaudeCodeParser.parse(line: noModel) == .skipped(.missingField))
    }

    @Test func wrongTypesAreSkipped() {
        #expect(ClaudeCodeParser.parse(line: assistantLine(usage: #"{"input_tokens":"ten"}"#)) == .skipped(.unexpectedStructure))
        #expect(ClaudeCodeParser.parse(line: assistantLine(usage: #"[1,2]"#)) == .skipped(.unexpectedStructure))
    }

    @Test func brokenJSONIsSkipped() {
        #expect(ClaudeCodeParser.parse(line: TestSupport.line(#"{"type":"assistant", BROKEN"#)) == .skipped(.invalidJSON))
        #expect(ClaudeCodeParser.parse(line: TestSupport.line("[]")) == .skipped(.invalidJSON))
    }

    @Test func otherLineTypesAreIgnored() {
        #expect(ClaudeCodeParser.parse(line: TestSupport.line(#"{"type":"user","message":{"content":"x"}}"#)) == .ignored)
        #expect(ClaudeCodeParser.parse(line: TestSupport.line(#"{"type":"assistant","message":{"model":"m"}}"#)) == .ignored)
    }
}
