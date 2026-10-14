import Foundation
import Testing
@testable import ElectricityCore

@Suite struct CodexParserTests {
    private let path = "/tmp/example/rollout-test.jsonl"

    private func tokenCount(last: (Int, Int, Int, Int), total: (Int, Int, Int, Int), timestamp: String = "2026-10-12T03:00:00.000Z") -> Data {
        func usage(_ u: (Int, Int, Int, Int)) -> String {
            #"{"input_tokens":\#(u.0),"cached_input_tokens":\#(u.1),"output_tokens":\#(u.2),"reasoning_output_tokens":\#(u.3),"total_tokens":\#(u.0 + u.2)}"#
        }
        return TestSupport.line(#"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":\#(usage(last)),"total_token_usage":\#(usage(total))}}}"#)
    }

    private func turnContext(model: String) -> Data {
        TestSupport.line(#"{"timestamp":"2026-10-12T03:00:00.000Z","type":"turn_context","payload":{"model":"\#(model)","cwd":"/tmp/example/p"}}"#)
    }

    @Test func sessionMetaAndTurnContextSetState() {
        var state = CodexParserState()
        let meta = TestSupport.line(#"{"timestamp":"2026-10-12T03:00:00.000Z","type":"session_meta","payload":{"id":"abc","cwd":"/tmp/example/p"}}"#)
        #expect(CodexParser.parse(line: meta, filePath: path, lineNumber: 1, state: &state) == .ignored)
        #expect(CodexParser.parse(line: turnContext(model: "gpt-x"), filePath: path, lineNumber: 2, state: &state) == .ignored)
        #expect(state.sessionID == "abc")
        #expect(state.cwd == "/tmp/example/p")
        #expect(state.model == "gpt-x")
    }

    @Test func turnContextSwitchesModel() throws {
        var state = CodexParserState()
        _ = CodexParser.parse(line: turnContext(model: "model-one"), filePath: path, lineNumber: 1, state: &state)
        let first = try #require(TestSupport.usage(of: CodexParser.parse(line: tokenCount(last: (10, 0, 1, 0), total: (10, 0, 1, 0)), filePath: path, lineNumber: 2, state: &state)))
        _ = CodexParser.parse(line: turnContext(model: "model-two"), filePath: path, lineNumber: 3, state: &state)
        let second = try #require(TestSupport.usage(of: CodexParser.parse(line: tokenCount(last: (5, 0, 1, 0), total: (15, 0, 2, 0)), filePath: path, lineNumber: 4, state: &state)))
        #expect(first.model == "model-one")
        #expect(second.model == "model-two")
    }

    @Test func firstEventUsesLastTokenUsage() throws {
        // A forked session starts with inherited totals; only the last turn is new.
        var state = CodexParserState()
        let usage = try #require(TestSupport.usage(of: CodexParser.parse(line: tokenCount(last: (100, 60, 10, 4), total: (9000, 8000, 500, 100)), filePath: path, lineNumber: 1, state: &state)))
        #expect(usage.tokens == TokenCounts(inputUncached: 40, cacheRead: 60, output: 10, reasoning: 4))
        #expect(usage.model == "unknown")
        #expect(usage.sessionID == "rollout-test")
    }

    @Test func laterEventsUseIncreaseOfTotal() throws {
        var state = CodexParserState()
        _ = CodexParser.parse(line: tokenCount(last: (100, 0, 10, 0), total: (100, 0, 10, 0)), filePath: path, lineNumber: 1, state: &state)
        // Two responses merged into one event: last covers only one of them.
        let usage = try #require(TestSupport.usage(of: CodexParser.parse(line: tokenCount(last: (50, 20, 5, 1), total: (300, 70, 40, 3)), filePath: path, lineNumber: 2, state: &state)))
        #expect(usage.tokens == TokenCounts(inputUncached: 130, cacheRead: 70, output: 30, reasoning: 3))
    }

    @Test func unchangedTotalIsDuplicate() {
        var state = CodexParserState()
        let line = tokenCount(last: (100, 0, 10, 0), total: (100, 0, 10, 0))
        #expect(TestSupport.usage(of: CodexParser.parse(line: line, filePath: path, lineNumber: 1, state: &state)) != nil)
        #expect(CodexParser.parse(line: line, filePath: path, lineNumber: 2, state: &state) == .ignored)
    }

    @Test func counterResetUsesLastTokenUsage() throws {
        var state = CodexParserState()
        _ = CodexParser.parse(line: tokenCount(last: (100, 0, 10, 0), total: (1000, 0, 100, 0)), filePath: path, lineNumber: 1, state: &state)
        let usage = try #require(TestSupport.usage(of: CodexParser.parse(line: tokenCount(last: (30, 10, 3, 0), total: (30, 10, 3, 0)), filePath: path, lineNumber: 2, state: &state)))
        #expect(usage.tokens == TokenCounts(inputUncached: 20, cacheRead: 10, output: 3))
    }

    @Test func cachedInputIsSubsetOfInput() {
        let usage = CodexTokenUsage(input: 1000, cachedInput: 900, cacheWriteInput: 50, output: 10, reasoningOutput: 5)
        #expect(usage.tokenCounts == TokenCounts(inputUncached: 50, cacheWrite: 50, cacheRead: 900, output: 10, reasoning: 5))
        let inconsistent = CodexTokenUsage(input: 10, cachedInput: 20, output: 0, reasoningOutput: 0)
        #expect(inconsistent.tokenCounts.inputUncached == 0)
    }

    @Test func dedupeKeyDependsOnPathLineAndTimestamp() throws {
        var a = CodexParserState(), b = CodexParserState(), c = CodexParserState()
        let line = tokenCount(last: (1, 0, 1, 0), total: (1, 0, 1, 0))
        let k1 = try #require(TestSupport.usage(of: CodexParser.parse(line: line, filePath: path, lineNumber: 7, state: &a))).dedupeKey
        let k2 = try #require(TestSupport.usage(of: CodexParser.parse(line: line, filePath: path, lineNumber: 7, state: &b))).dedupeKey
        let k3 = try #require(TestSupport.usage(of: CodexParser.parse(line: line, filePath: path, lineNumber: 8, state: &c))).dedupeKey
        #expect(k1 == k2)
        #expect(k1 != k3)
    }

    @Test func unknownAndNullEventsAreIgnored() {
        var state = CodexParserState()
        let unknown = TestSupport.line(#"{"timestamp":"2026-10-12T03:00:00Z","type":"brand_new_type","payload":{"x":1}}"#)
        let otherEvent = TestSupport.line(#"{"timestamp":"2026-10-12T03:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#)
        let nullInfo = TestSupport.line(#"{"timestamp":"2026-10-12T03:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#)
        #expect(CodexParser.parse(line: unknown, filePath: path, lineNumber: 1, state: &state) == .ignored)
        #expect(CodexParser.parse(line: otherEvent, filePath: path, lineNumber: 2, state: &state) == .ignored)
        #expect(CodexParser.parse(line: nullInfo, filePath: path, lineNumber: 3, state: &state) == .ignored)
    }

    @Test func malformedLinesAreSkipped() {
        var state = CodexParserState()
        let badUsage = TestSupport.line(#"{"timestamp":"2026-10-12T03:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":"x"},"total_token_usage":{}}}}"#)
        let noType = TestSupport.line(#"{"timestamp":"2026-10-12T03:00:00Z"}"#)
        let noTimestamp = TestSupport.line(#"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1},"total_token_usage":{"input_tokens":1}}}}"#)
        #expect(CodexParser.parse(line: badUsage, filePath: path, lineNumber: 1, state: &state) == .skipped(.unexpectedStructure))
        #expect(CodexParser.parse(line: noType, filePath: path, lineNumber: 2, state: &state) == .skipped(.missingField))
        #expect(CodexParser.parse(line: TestSupport.line("not json"), filePath: path, lineNumber: 3, state: &state) == .skipped(.invalidJSON))
        #expect(CodexParser.parse(line: noTimestamp, filePath: path, lineNumber: 4, state: &state) == .skipped(.missingField))
    }
}

@Suite struct CodexTaskStateTests {
    private func data(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }

    @Test func latestTaskEventWins() throws {
        let tail = data([
            #"{"timestamp":"2026-10-14T01:47:57.295Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}"#,
            #"{"timestamp":"2026-10-14T01:50:00.000Z","type":"response_item","payload":{"type":"message"}}"#,
            #"{"timestamp":"2026-10-14T02:07:36.417Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"\#(String(repeating: "x", count: 10_000))"}}"#,
            #"{"timestamp":"2026-10-14T02:07:37.000Z","type":"event_msg","payload":{"type":"token_count"}}"#,
        ])
        let state = try #require(CodexTaskState.latest(inTail: tail))
        #expect(state.running == false)
        #expect(abs((state.at?.timeIntervalSince1970 ?? 0) - 1_791_943_656.417) < 0.001)
    }

    @Test func startedAfterCompleteIsRunning() throws {
        let tail = data([
            #"{"timestamp":"2026-10-14T02:07:36.417Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
            #"{"timestamp":"2026-10-14T02:10:00.000Z","ordinal":5,"type":"event_msg","payload":{"type":"task_started"}}"#,
        ])
        #expect(try #require(CodexTaskState.latest(inTail: tail)).running)
    }

    @Test func abortedIsNotRunningAndPartialFirstLineIsSkipped() throws {
        let tail = data([
            #"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-10-14T02:07:36.417Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#,
        ])
        #expect(try #require(CodexTaskState.latest(inTail: tail)).running == false)
        #expect(CodexTaskState.latest(inTail: data([#"type":"event_msg","payload":{"type":"task_started"}}"#])) == nil)
        #expect(CodexTaskState.latest(inTail: Data()) == nil)
    }
}
