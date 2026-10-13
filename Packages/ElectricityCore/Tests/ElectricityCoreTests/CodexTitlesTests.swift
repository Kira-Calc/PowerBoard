import Foundation
import Testing
@testable import ElectricityCore

struct CodexTitlesTests {
    @Test func lastNameWinsAndBadLinesAreSkipped() {
        let text = """
        {"id":"a","thread_name":"First name","updated_at":"2026-10-13T00:00:00Z"}
        not json
        {"id":"b","thread_name":"  "}
        {"id":"a","thread_name":"Renamed","updated_at":"2026-10-13T01:00:00Z"}
        """
        let titles = CodexTitles.read(Data(text.utf8))
        #expect(titles == ["a": "Renamed"])
    }

    @Test func indexSitsNextToSessions() {
        let urls = CodexTitles.indexURLs(sessionRoots: [URL(fileURLWithPath: "/tmp/home/.codex/sessions")])
        #expect(urls.map(\.path) == ["/tmp/home/.codex/session_index.jsonl"])
    }
}
