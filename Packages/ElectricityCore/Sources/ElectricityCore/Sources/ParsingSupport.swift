import CryptoKit
import Foundation

/// Shared helpers for log parsers. Parsers read only the fields listed in SPEC section 4
/// and never retain or print anything else from a line.
enum ParsingSupport {
    /// Parses a line into a JSON object. Returns nil for invalid JSON or non-object values.
    static func jsonObject(_ line: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: line, options: []) else { return nil }
        return object as? [String: Any]
    }

    /// Reads an integer token count. Missing keys count as zero; present but non-numeric values return nil.
    static func tokenCount(_ dict: [String: Any], _ key: String) -> Int? {
        guard let value = dict[key] else { return 0 }
        if value is NSNull { return 0 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let int = number.intValue
        return int >= 0 ? int : nil
    }

    static func parseTimestamp(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(string, strategy: Date.ISO8601FormatStyle())
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }
}
