import Foundation

/// Minimal protobuf wire-format reader. Decodes one message level into fields; nested messages
/// are decoded on demand. Only numeric and length-delimited fields are kept.
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed
    }

    struct DecodeError: Error {}

    let fields: [(number: UInt32, value: Value)]

    init(_ data: Data) throws {
        var fields: [(UInt32, Value)] = []
        var index = data.startIndex
        while index < data.endIndex {
            let tag = try Self.readVarint(data, &index)
            let number = UInt32(truncatingIfNeeded: tag >> 3)
            guard number != 0 else { throw DecodeError() }
            switch tag & 7 {
            case 0:
                fields.append((number, .varint(try Self.readVarint(data, &index))))
            case 1:
                guard data.endIndex - index >= 8 else { throw DecodeError() }
                index += 8
                fields.append((number, .fixed))
            case 2:
                let length = try Self.readVarint(data, &index)
                guard length <= UInt64(data.endIndex - index) else { throw DecodeError() }
                let end = index + Int(length)
                fields.append((number, .bytes(data.subdata(in: index..<end))))
                index = end
            case 5:
                guard data.endIndex - index >= 4 else { throw DecodeError() }
                index += 4
                fields.append((number, .fixed))
            default:
                throw DecodeError()
            }
        }
        self.fields = fields
    }

    private static func readVarint(_ data: Data, _ index: inout Data.Index) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex {
            let byte = data[index]
            index += 1
            if shift >= 64 { throw DecodeError() }
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        throw DecodeError()
    }

    /// Last varint with this number (protobuf semantics for repeated scalar overrides).
    func varint(_ number: UInt32) -> UInt64? {
        for field in fields.reversed() where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }

    func bytes(_ number: UInt32) -> Data? {
        for field in fields where field.number == number {
            if case .bytes(let value) = field.value { return value }
        }
        return nil
    }

    func allBytes(_ number: UInt32) -> [Data] {
        fields.compactMap { field in
            guard field.number == number, case .bytes(let value) = field.value else { return nil }
            return value
        }
    }

    func text(_ number: UInt32) -> String? {
        guard let data = bytes(number), let string = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func message(_ number: UInt32) throws -> ProtoMessage? {
        try bytes(number).map(ProtoMessage.init)
    }
}
