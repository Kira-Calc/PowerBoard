import Foundation
import Testing
@testable import ElectricityCore

@Suite struct IncrementalReaderTests {
    private func strings(_ chunk: LineChunk?) -> [String] {
        chunk?.lines.map { String(decoding: $0, as: UTF8.self) } ?? []
    }

    @Test func readsOnlyCompleteLines() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let file = dir.appendingPathComponent("log.jsonl")
        try Data("one\ntwo\npart".utf8).write(to: file)

        let chunk = try IncrementalReader.readChunk(path: file.path, offset: 0, firstLineNumber: 1)
        #expect(strings(chunk) == ["one", "two"])
        #expect(chunk?.endOffset == 8)
        #expect(try IncrementalReader.readChunk(path: file.path, offset: 8, firstLineNumber: 3) == nil)

        try TestSupport.append("ial\nthree\n", to: file)
        let next = try IncrementalReader.readChunk(path: file.path, offset: 8, firstLineNumber: 3)
        #expect(strings(next) == ["partial", "three"])
        #expect(next?.firstLineNumber == 3)
    }

    @Test func handlesCRLFAndLongLinesAcrossChunks() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { TestSupport.cleanup(dir) }
        let file = dir.appendingPathComponent("log.jsonl")
        let long = String(repeating: "x", count: 100)
        try Data("a\r\n\(long)\nb\n".utf8).write(to: file)

        var offset: Int64 = 0
        var lines: [String] = []
        while let chunk = try IncrementalReader.readChunk(path: file.path, offset: offset, firstLineNumber: 1, maxBytes: 16) {
            lines += strings(chunk)
            offset = chunk.endOffset
        }
        #expect(lines == ["a", long, "b"])
    }

    @Test func planDetectsAppendTruncationAndReplacement() throws {
        let saved = FileCursor(path: "/p", inode: 7, offset: 100, mtime: 50, lineCount: 4)
        #expect(IncrementalReader.plan(path: "/p", saved: nil, status: FileStatus(inode: 7, size: 10, mtime: 1)) == .restart(FileCursor(path: "/p", inode: 7)))
        #expect(IncrementalReader.plan(path: "/p", saved: saved, status: FileStatus(inode: 7, size: 100, mtime: 50)) == .upToDate)
        #expect(IncrementalReader.plan(path: "/p", saved: saved, status: FileStatus(inode: 7, size: 150, mtime: 60)) == .resume(saved))
        // Truncated.
        #expect(IncrementalReader.plan(path: "/p", saved: saved, status: FileStatus(inode: 7, size: 20, mtime: 60)) == .restart(FileCursor(path: "/p", inode: 7)))
        // Replaced by a new file.
        #expect(IncrementalReader.plan(path: "/p", saved: saved, status: FileStatus(inode: 8, size: 200, mtime: 60)) == .restart(FileCursor(path: "/p", inode: 8)))
    }
}
