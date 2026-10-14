// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.

import Foundation

public enum ProtobufError: Error, Equatable, Sendable {
    case truncated
    case malformedVarint
    case invalidFieldNumber
    case unsupportedWireType(UInt8)
}

/// A minimal protobuf wire-format codec: just enough to build and read the
/// band's command messages without pulling in a code generator. Messages are
/// built by concatenating encoded fields and read as a flat list of fields.
public enum Protobuf {
    public enum Value: Equatable, Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    public struct Field: Equatable, Sendable {
        public let number: Int
        public let value: Value

        public init(number: Int, value: Value) {
            self.number = number
            self.value = value
        }
    }

    private enum WireType: UInt8 {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    private static let wireTypeBits = 3
    private static let wireTypeMask: UInt64 = 0x07
    private static let continuationBit: UInt8 = 0x80
    private static let payloadMask: UInt8 = 0x7F
    private static let payloadBits = 7
    private static let maxVarintLength = 10

    // MARK: - Encoding

    public static func varint(_ number: Int, _ value: UInt64) -> Data {
        tag(number, .varint) + rawVarint(value)
    }

    public static func bool(_ number: Int, _ value: Bool) -> Data {
        varint(number, value ? 1 : 0)
    }

    /// Also used for embedded messages: pass the encoded sub-message.
    public static func bytes(_ number: Int, _ value: Data) -> Data {
        tag(number, .lengthDelimited) + rawVarint(UInt64(value.count)) + value
    }

    public static func string(_ number: Int, _ value: String) -> Data {
        bytes(number, Data(value.utf8))
    }

    public static func float(_ number: Int, _ value: Float) -> Data {
        tag(number, .fixed32) + littleEndianBytes(UInt64(value.bitPattern), width: 4)
    }

    private static func tag(_ number: Int, _ type: WireType) -> Data {
        rawVarint(UInt64(number) << UInt64(wireTypeBits) | UInt64(type.rawValue))
    }

    private static func rawVarint(_ value: UInt64) -> Data {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            let low = UInt8(truncatingIfNeeded: remaining) & payloadMask
            remaining >>= UInt64(payloadBits)
            bytes.append(remaining == 0 ? low : low | continuationBit)
        } while remaining != 0
        return Data(bytes)
    }

    private static func littleEndianBytes(_ value: UInt64, width: Int) -> Data {
        Data((0..<width).map { UInt8(truncatingIfNeeded: value >> UInt64(8 * $0)) })
    }

    // MARK: - Decoding

    /// Reads every top-level field of a message, in wire order. The content comes
    /// from the band, so malformed input throws instead of trapping.
    public static func decode(_ message: Data) throws(ProtobufError) -> [Field] {
        var cursor = Cursor(bytes: [UInt8](message))
        var fields: [Field] = []
        while !cursor.isAtEnd {
            fields.append(try cursor.readField())
        }
        return fields
    }

    private struct Cursor {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func readField() throws(ProtobufError) -> Field {
            let key = try readVarint()
            let number = Int(truncatingIfNeeded: key >> UInt64(Protobuf.wireTypeBits))
            guard number > 0 else {
                throw .invalidFieldNumber
            }
            let rawType = UInt8(key & Protobuf.wireTypeMask)
            guard let type = WireType(rawValue: rawType) else {
                throw .unsupportedWireType(rawType)
            }
            return Field(number: number, value: try readValue(of: type))
        }

        private mutating func readValue(of type: WireType) throws(ProtobufError) -> Value {
            switch type {
            case .varint:
                return .varint(try readVarint())
            case .fixed64:
                return .fixed64(try readLittleEndian(width: 8))
            case .fixed32:
                return .fixed32(UInt32(truncatingIfNeeded: try readLittleEndian(width: 4)))
            case .lengthDelimited:
                let length = try readVarint()
                guard length <= UInt64(bytes.count - offset) else {
                    throw .truncated
                }
                return .bytes(Data(try take(Int(length))))
            }
        }

        private mutating func readVarint() throws(ProtobufError) -> UInt64 {
            var result: UInt64 = 0
            for index in 0..<Protobuf.maxVarintLength {
                let byte = try take(1)[offset - 1]
                result |= UInt64(byte & Protobuf.payloadMask) << UInt64(Protobuf.payloadBits * index)
                if byte & Protobuf.continuationBit == 0 {
                    return result
                }
            }
            throw .malformedVarint
        }

        private mutating func readLittleEndian(width: Int) throws(ProtobufError) -> UInt64 {
            try take(width).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) }
        }

        private mutating func take(_ count: Int) throws(ProtobufError) -> ArraySlice<UInt8> {
            guard count <= bytes.count - offset else {
                throw .truncated
            }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }
    }
}

// MARK: - Field lookup

public extension Array where Element == Protobuf.Field {
    /// Last occurrence wins, as the protobuf specification requires for scalars.
    func varint(_ number: Int) -> UInt64? {
        last(matching: number) { if case .varint(let value) = $0 { value } else { nil } }
    }

    func bytes(_ number: Int) -> Data? {
        last(matching: number) { if case .bytes(let value) = $0 { value } else { nil } }
    }

    func string(_ number: Int) -> String? {
        bytes(number).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func last<T>(matching number: Int, _ extract: (Protobuf.Value) -> T?) -> T? {
        last { $0.number == number }.flatMap { extract($0.value) }
    }
}
