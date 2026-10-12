import Foundation

/// Edits one top-level key of a JSON object in place, keeping the rest of the text exactly as it was
/// (key order, spacing, comments are not supported by JSON and are not expected).
struct JSONTextEditor {
    enum EditError: Error, Equatable {
        case notAnObject
        case malformed
    }

    private(set) var text: String

    init(text: String) throws {
        self.text = text
        // Validate up front so a malformed file is never rewritten.
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
        else { throw EditError.notAnObject }
    }

    /// Range of the value of a top-level key, if present.
    func valueRange(of key: String) throws -> Range<String.Index>? {
        try scanTopLevel().first { $0.key == key }?.value
    }

    /// The raw JSON text of a top-level value, if present.
    func rawValue(of key: String) throws -> String? {
        try valueRange(of: key).map { String(text[$0]) }
    }

    /// Replaces the value of `key`, or adds the key at the end of the object. `value` is raw JSON.
    /// With `reindent`, lines after the first are indented to match the key; pass false for text that
    /// was taken from this file and already carries its indentation.
    mutating func set(_ key: String, rawValue value: String, reindent: Bool = true) throws {
        let entries = try scanTopLevel()
        if let existing = entries.first(where: { $0.key == key }) {
            let indented = reindent ? Self.reindent(value, by: indentOfLine(at: existing.keyStart)) : value
            text.replaceSubrange(existing.value, with: indented)
            return
        }
        guard let close = text.lastIndex(of: "}") else { throw EditError.malformed }
        let indent = detectIndent()
        let entry = "\(indent)\(Self.quote(key)): \(Self.reindent(value, by: indent))"
        if let last = entries.last {
            text.insert(contentsOf: ",\n" + entry, at: last.value.upperBound)
        } else {
            text.replaceSubrange(text.index(after: text.firstIndex(of: "{")!)..<close, with: "\n\(entry)\n")
        }
    }

    /// Removes a top-level key and its separator.
    mutating func remove(_ key: String) throws {
        let entries = try scanTopLevel()
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return }
        let entry = entries[index]
        if index > 0 {
            // Remove from the end of the previous value through the end of this one.
            text.removeSubrange(entries[index - 1].value.upperBound..<entry.value.upperBound)
        } else if entries.count > 1 {
            // First entry: remove through the start of the next key.
            text.removeSubrange(entry.keyStart..<entries[1].keyStart)
        } else {
            let open = text.index(after: text.firstIndex(of: "{")!)
            let close = text.lastIndex(of: "}")!
            text.replaceSubrange(open..<close, with: "")
        }
    }

    // MARK: Scanning

    private struct Entry {
        var key: String
        var keyStart: String.Index
        var value: Range<String.Index>
    }

    private func scanTopLevel() throws -> [Entry] {
        var index = text.startIndex
        skipWhitespace(&index)
        guard index < text.endIndex, text[index] == "{" else { throw EditError.notAnObject }
        index = text.index(after: index)
        var entries: [Entry] = []
        while true {
            skipWhitespace(&index)
            guard index < text.endIndex else { throw EditError.malformed }
            if text[index] == "}" { return entries }
            if text[index] == "," {
                index = text.index(after: index)
                continue
            }
            let keyStart = index
            let keyRange = try scanString(&index)
            let key = try decodeString(String(text[keyRange]))
            skipWhitespace(&index)
            guard index < text.endIndex, text[index] == ":" else { throw EditError.malformed }
            index = text.index(after: index)
            skipWhitespace(&index)
            let valueStart = index
            try skipValue(&index)
            entries.append(Entry(key: key, keyStart: keyStart, value: valueStart..<index))
        }
    }

    private func skipWhitespace(_ index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
    }

    /// Scans a string literal starting at `index`; returns its range including quotes.
    private func scanString(_ index: inout String.Index) throws -> Range<String.Index> {
        guard index < text.endIndex, text[index] == "\"" else { throw EditError.malformed }
        let start = index
        index = text.index(after: index)
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if character == "\\" {
                guard index < text.endIndex else { throw EditError.malformed }
                index = text.index(after: index)
            } else if character == "\"" {
                return start..<index
            }
        }
        throw EditError.malformed
    }

    private func skipValue(_ index: inout String.Index) throws {
        guard index < text.endIndex else { throw EditError.malformed }
        switch text[index] {
        case "\"":
            _ = try scanString(&index)
        case "{", "[":
            var depth = 0
            while index < text.endIndex {
                let character = text[index]
                if character == "\"" {
                    _ = try scanString(&index)
                    continue
                }
                if character == "{" || character == "[" { depth += 1 }
                if character == "}" || character == "]" { depth -= 1 }
                index = text.index(after: index)
                if depth == 0 { return }
            }
            throw EditError.malformed
        default:
            while index < text.endIndex, !",}] \n\r\t".contains(text[index]) { index = text.index(after: index) }
        }
    }

    private func decodeString(_ literal: String) throws -> String {
        guard let data = literal.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
        else { throw EditError.malformed }
        return value
    }

    /// Leading whitespace of the line that contains `index`.
    private func indentOfLine(at index: String.Index) -> String {
        let lineStart = text[..<index].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let prefix = text[lineStart..<index]
        return prefix.allSatisfy({ $0 == " " || $0 == "\t" }) ? String(prefix) : ""
    }

    /// Indentation of the first top-level key, or two spaces.
    private func detectIndent() -> String {
        guard let entry = try? scanTopLevel().first else { return "  " }
        let lineStart = text[..<entry.keyStart].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let prefix = text[lineStart..<entry.keyStart]
        return prefix.allSatisfy({ $0 == " " || $0 == "\t" }) && !prefix.isEmpty ? String(prefix) : "  "
    }

    static func quote(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(string)\""
    }

    /// Indents every line after the first, so a multi-line value lines up under its key.
    static func reindent(_ value: String, by indent: String) -> String {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { $0.offset == 0 ? String($0.element) : indent + $0.element }
            .joined(separator: "\n")
    }
}
