import Foundation
import Testing
@testable import ElectricityCore

@Suite struct ActivityTests {
    @Test func codexTaskEventsSetRunningState() {
        var state = CodexParserState()
        let started = TestSupport.line(#"{"timestamp":"2026-10-12T03:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#)
        let complete = TestSupport.line(#"{"timestamp":"2026-10-12T03:05:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#)
        #expect(CodexParser.parse(line: started, filePath: "/p", lineNumber: 1, state: &state) == .ignored)
        #expect(state.taskRunning == true)
        _ = CodexParser.parse(line: complete, filePath: "/p", lineNumber: 2, state: &state)
        #expect(state.taskRunning == false)
        #expect(state.taskEventAt == Date(timeIntervalSince1970: 1_791_766_800 + 7200 + 300))
    }

    @Test func storeKeepsNewestActivity() throws {
        let store = try UsageStore()
        let t = Date(timeIntervalSince1970: 1_791_766_800)
        try store.saveActivity(SessionActivity(sessionID: "s", source: .codex, projectPath: "/a", logPath: "/l", running: true, eventAt: t))
        try store.saveActivity(SessionActivity(sessionID: "s", source: .codex, projectPath: "/a", logPath: "/l", running: false, eventAt: t.addingTimeInterval(-60)))
        #expect(try store.activities(since: t.addingTimeInterval(-10)).first?.running == true)
        try store.saveActivity(SessionActivity(sessionID: "s", source: .codex, projectPath: "/a", logPath: "/l", running: false, eventAt: t.addingTimeInterval(60)))
        #expect(try store.activities(since: t).first?.running == false)
        #expect(try store.activities(since: t.addingTimeInterval(120)).isEmpty)
    }

    @Test func ingestRecordsCodexActivity() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let codex = dir.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let file = codex.appendingPathComponent("rollout-x.jsonl")
        try Data("""
        {"timestamp":"2026-10-12T03:00:00.000Z","type":"session_meta","payload":{"id":"sess-x","cwd":"/tmp/example/p"}}
        {"timestamp":"2026-10-12T03:00:01.000Z","type":"event_msg","payload":{"type":"task_started"}}

        """.utf8).write(to: file)
        let store = try UsageStore()
        let service = IngestService(store: store, calculator: try TestSupport.calculator(), locations: LogLocations(claudeCode: [], codex: [codex]))
        _ = await service.scan()
        let activity = try #require(try store.activities(since: .distantPast).first)
        #expect(activity.sessionID == "sess-x")
        #expect(activity.running)
        #expect(activity.projectPath == "/tmp/example/p")
        #expect(activity.logPath.hasSuffix("rollout-x.jsonl"))
    }

    @Test func liveClaudeSessionParsing() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        try Data(#"{"pid": 42, "sessionId": "abc", "cwd": "/tmp/example/p", "status": "busy", "statusUpdatedAt": 1791766800000, "name": "Example title"}"#.utf8)
            .write(to: dir.appendingPathComponent("42.json"))
        try Data(#"{"pid": 43, "sessionId": "def", "status": "waiting"}"#.utf8).write(to: dir.appendingPathComponent("43.json"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("44.json"))
        try Data("secret".utf8).write(to: dir.appendingPathComponent("42.abc.key"))
        let sessions = LiveClaudeSession.read(directory: dir).sorted { $0.pid < $1.pid }
        #expect(sessions.count == 2)
        #expect(sessions[0] == LiveClaudeSession(pid: 42, sessionID: "abc", cwd: "/tmp/example/p", status: .busy, statusChangedAt: Date(timeIntervalSince1970: 1_791_766_800)))
        #expect(sessions[1].status == .other("waiting"))
    }

    @Test func latestTitleIsReadFromTheEndOfTheLog() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let project = dir.appendingPathComponent("projects/-tmp-example")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let log = project.appendingPathComponent("abc.jsonl")
        var text = #"{"type":"ai-title","sessionId":"abc","aiTitle":"First title"}"# + "\n"
        text += String(repeating: #"{"type":"user","message":{"content":"x"}}"# + "\n", count: 200)
        text += #"{"type":"ai-title","sessionId":"abc","aiTitle":"Second title"}"# + "\n"
        text += #"{"type":"assistant"}"# + "\n"
        try Data(text.utf8).write(to: log)
        // A small chunk size makes the search cross chunk boundaries.
        #expect(ClaudeCodeTitle.latest(inLogAt: log, chunkSize: 64) == "Second title")
        let found = ClaudeCodeTitle.logURL(sessionID: "abc", roots: [dir.appendingPathComponent("projects")])
        #expect(found?.resolvingSymlinksInPath().path == log.resolvingSymlinksInPath().path)
        try Data(#"{"type":"user"}"#.utf8).write(to: log)
        #expect(ClaudeCodeTitle.latest(inLogAt: log) == nil)

        // Without an AI title, the first line of the latest prompt is used.
        let prompts = #"{"type":"last-prompt","lastPrompt":"old prompt"}"# + "\n"
            + #"{"type":"last-prompt","lastPrompt":"\n  Fix the   build\nmore detail"}"# + "\n"
        try Data(prompts.utf8).write(to: log)
        #expect(ClaudeCodeTitle.latest(inLogAt: log) == "Fix the build")
        #expect(ClaudeCodeTitle.clean(String(repeating: "a", count: 100))?.count == ClaudeCodeTitle.maxLength)
    }

    @Test func sessionEnergyByID() throws {
        let store = try UsageStore()
        let usage = ParsedUsage(dedupeKey: "k", source: .claudeCode, sessionID: "s1", projectPath: nil, model: "sonnet",
                                timestamp: Date(), tokens: TokenCounts(output: 1_000_000))
        try store.insert([UsageEventRow(usage: usage, result: TestSupport.calculator().estimate(model: "sonnet", tokens: usage.tokens))], cursor: nil)
        #expect(try store.sessionEnergy(["s1", "s2"]) == ["s1": 2878])
        #expect(try store.sessionEnergy([]).isEmpty)
    }
}
