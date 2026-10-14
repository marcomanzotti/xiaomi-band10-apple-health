// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Layout derived from Gadgetbridge (XiaomiActivityFileFetcher), AGPL-3.0.

import Foundation

/// One file of recorded data as the band sent it:
/// `identifier (7) | padding (1) | content | CRC-32 (4, little endian)`.
public struct ActivityFile: Equatable, Sendable {
    static let headerLength = ActivityFileID.encodedLength + 1
    static let checksumLength = 4
    /// Identifier, padding, at least one content byte and the checksum.
    static let minimumLength = headerLength + 1 + checksumLength

    public let id: ActivityFileID
    /// The whole file, checksum included: what is kept on disk.
    public let raw: Data

    /// Validates the checksum and reads the identifier.
    public init(raw: Data) throws(ActivityParseError) {
        guard raw.count >= Self.minimumLength else {
            throw .truncated
        }
        let checksumStart = raw.count - Self.checksumLength
        var trailer = ByteReader(raw.suffix(Self.checksumLength))
        guard try trailer.uint32() == CRC32.checksum(raw.prefix(checksumStart)) else {
            throw .unexpectedContent("checksum mismatch")
        }
        id = try ActivityFileID(decoding: raw)
        self.raw = raw
    }

    /// What the parsers read: the file without identifier, padding and checksum.
    public var content: Data {
        Data(raw.dropFirst(Self.headerLength).dropLast(Self.checksumLength))
    }
}

/// Rebuilds a file from the numbered pieces the band sends on the activity
/// channel: `piece count (2) | piece number from 1 (2) | bytes`, little endian.
public struct ActivityFileAssembler: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// More pieces are expected.
        case incomplete(received: Int, total: Int)
        case complete(ActivityFile)
        case invalid(ActivityParseError)
    }

    private static let pieceHeaderLength = 4
    private static let firstPieceNumber = 1

    private var buffer = Data()

    public init() {}

    public mutating func append(_ piece: Data) -> Outcome {
        var reader = ByteReader(piece)
        guard let total = try? reader.uint16(), let number = try? reader.uint16() else {
            return .invalid(.truncated)
        }
        if Int(number) == Self.firstPieceNumber {
            buffer = Data()
        }
        buffer.append(piece.dropFirst(Self.pieceHeaderLength))
        guard number == total else {
            return .incomplete(received: Int(number), total: Int(total))
        }
        let assembled = buffer
        buffer = Data()
        do {
            return .complete(try ActivityFile(raw: assembled))
        } catch {
            return .invalid(error)
        }
    }

    /// Drops a half-received file, for example before asking for another one.
    public mutating func reset() {
        buffer = Data()
    }
}

/// The standard CRC-32 (reflected polynomial 0xEDB88320) that closes every activity file.
enum CRC32 {
    private static let reflectedPolynomial: UInt32 = 0xEDB8_8320
    private static let bitsPerByte = 8

    private static let table: [UInt32] = (0..<256).map { index in
        (0..<bitsPerByte).reduce(UInt32(index)) { value, _ in
            value & 1 == 1 ? (value >> 1) ^ reflectedPolynomial : value >> 1
        }
    }

    static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in
            table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
    }
}
