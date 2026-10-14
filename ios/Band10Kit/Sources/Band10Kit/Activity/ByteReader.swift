// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.

import Foundation

public enum ActivityParseError: Error, Equatable, Sendable {
    /// The file ended in the middle of a value.
    case truncated
    case unsupportedVersion(Int)
    /// The file does not hold what its identifier announces.
    case unexpectedContent(String)
}

/// Reads fixed-width integers from an activity file. The content comes from the
/// band, so running out of bytes throws instead of trapping.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { remaining <= 0 }

    mutating func byte() throws(ActivityParseError) -> UInt8 {
        try take(1)[0]
    }

    mutating func uint16() throws(ActivityParseError) -> UInt16 {
        UInt16(truncatingIfNeeded: try littleEndian(width: 2))
    }

    mutating func uint32() throws(ActivityParseError) -> UInt32 {
        UInt32(truncatingIfNeeded: try littleEndian(width: 4))
    }

    mutating func uint64() throws(ActivityParseError) -> UInt64 {
        try littleEndian(width: 8)
    }

    mutating func bigEndianUInt16() throws(ActivityParseError) -> UInt16 {
        let pair = try take(2)
        return UInt16(pair[0]) << 8 | UInt16(pair[1])
    }

    mutating func take(_ count: Int) throws(ActivityParseError) -> [UInt8] {
        guard count >= 0, count <= remaining else {
            throw .truncated
        }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func skip(_ count: Int) throws(ActivityParseError) {
        _ = try take(count)
    }

    /// Moves back, to re-read bytes while searching for a marker.
    mutating func rewind(_ count: Int) {
        offset = max(0, offset - count)
    }

    private mutating func littleEndian(width: Int) throws(ActivityParseError) -> UInt64 {
        try take(width).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) }
    }
}

/// Tells which optional fields a file carries: one bit per field, most
/// significant bit first within each header byte.
struct ValidityBitmap {
    private static let bitsPerByte = 8

    let header: [UInt8]

    func isValid(_ index: Int) -> Bool {
        let byteIndex = index / Self.bitsPerByte
        guard header.indices.contains(byteIndex) else { return false }
        return header[byteIndex] & (1 << UInt8(Self.bitsPerByte - 1 - index % Self.bitsPerByte)) != 0
    }
}
