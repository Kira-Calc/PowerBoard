import Foundation

/// Read progress for one log file (SPEC 4.3, table `file_cursor`).
public struct FileCursor: Sendable, Hashable {
    public var path: String
    public var inode: UInt64
    /// Byte offset just past the last complete line read.
    public var offset: Int64
    /// Modification time (seconds since 1970) when the file was last read.
    public var mtime: Double
    public var skippedLines: Int
    /// Number of complete lines read so far. Codex dedupe keys use line numbers.
    public var lineCount: Int
    /// Parser state carried between reads, encoded as JSON. Used by the Codex parser.
    public var parserState: String?
    /// The tool that wrote the file.
    public var source: UsageSource?

    public init(path: String, inode: UInt64, offset: Int64 = 0, mtime: Double = 0, skippedLines: Int = 0, lineCount: Int = 0, parserState: String? = nil, source: UsageSource? = nil) {
        self.path = path
        self.inode = inode
        self.offset = offset
        self.mtime = mtime
        self.skippedLines = skippedLines
        self.lineCount = lineCount
        self.parserState = parserState
        self.source = source
    }
}

public struct FileStatus: Sendable, Hashable {
    public var inode: UInt64
    public var size: Int64
    public var mtime: Double

    public static func of(path: String) throws -> FileStatus {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileStatus(inode: inode, size: size, mtime: mtime)
    }
}

/// A batch of complete lines read from a file.
public struct LineChunk: Sendable {
    /// Lines without their trailing newline.
    public var lines: [Data]
    /// Line number (1-based) of the first line in `lines`.
    public var firstLineNumber: Int
    /// Offset just past the last newline in this chunk.
    public var endOffset: Int64
}

/// Reads only complete lines from a growing file, starting at a saved offset.
public enum IncrementalReader {
    public enum Plan: Sendable, Equatable {
        /// Nothing new to read.
        case upToDate
        /// Continue from the saved cursor.
        case resume(FileCursor)
        /// The file is new, was truncated or replaced: read from the start with a fresh cursor.
        case restart(FileCursor)
    }

    /// Decides where to start reading. A file smaller than the saved offset, or with a different inode,
    /// is read again from the start; deduplication prevents double counting.
    public static func plan(path: String, saved: FileCursor?, status: FileStatus) -> Plan {
        guard let saved, saved.inode == status.inode, status.size >= saved.offset else {
            return .restart(FileCursor(path: path, inode: status.inode))
        }
        if status.size == saved.offset && status.mtime == saved.mtime {
            return .upToDate
        }
        return .resume(saved)
    }

    /// Reads up to roughly `maxBytes` of complete lines starting at `offset`.
    /// Returns nil when no complete line is available. An incomplete last line is left for the next read.
    public static func readChunk(path: String, offset: Int64, firstLineNumber: Int, maxBytes: Int = 8 << 20) throws -> LineChunk? {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        var buffer = Data()
        var lastNewline: Int?
        // Keep reading until the buffer holds at least one newline, so a line longer than maxBytes is still read whole.
        while true {
            guard let data = try handle.read(upToCount: maxBytes), !data.isEmpty else { break }
            let searchStart = buffer.count
            buffer.append(data)
            if let index = buffer[searchStart...].lastIndex(of: UInt8(ascii: "\n")) {
                lastNewline = index
                break
            }
        }
        guard let lastNewline else { return nil }

        var lines: [Data] = []
        var lineStart = buffer.startIndex
        for index in buffer.startIndex...lastNewline where buffer[index] == UInt8(ascii: "\n") {
            var end = index
            if end > lineStart && buffer[end - 1] == UInt8(ascii: "\r") { end -= 1 }
            lines.append(buffer.subdata(in: lineStart..<end))
            lineStart = index + 1
        }
        return LineChunk(lines: lines, firstLineNumber: firstLineNumber, endOffset: offset + Int64(lastNewline + 1))
    }
}
