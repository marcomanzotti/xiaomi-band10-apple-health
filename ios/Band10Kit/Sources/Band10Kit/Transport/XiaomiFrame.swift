// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Protocol behaviour derived from Gadgetbridge (XiaomiSppPacketV2), AGPL-3.0.

import Foundation

public enum XiaomiFrameError: Error, Equatable, Sendable {
    case badPreamble
    case unknownKind(UInt8)
    case checksumMismatch(expected: UInt16, actual: UInt16)
    case payloadTooLarge(Int)
}

/// One link-layer frame of the Xiaomi "V2" transport:
/// `a5 a5 | kind | sequence | length (LE16) | crc16 (LE16) | payload`.
public struct XiaomiFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case nack = 0
        case ack = 1
        case sessionConfig = 2
        case data = 3
    }

    public enum DecodeResult: Equatable, Sendable {
        /// More bytes are needed before a frame can be read.
        case incomplete
        /// A frame was read; `length` bytes of the buffer belong to it.
        case complete(XiaomiFrame, length: Int)
    }

    public static let preamble: [UInt8] = [0xA5, 0xA5]
    public static let headerLength = 8
    public static let maxPayloadLength = Int(UInt16.max)

    private static let kindMask: UInt8 = 0x0F
    private static let kindOffset = 2
    private static let sequenceOffset = 3
    private static let lengthOffset = 4
    private static let checksumOffset = 6

    public let kind: Kind
    public let sequence: UInt8
    public let payload: Data

    public init(kind: Kind, sequence: UInt8, payload: Data) {
        self.kind = kind
        self.sequence = sequence
        self.payload = payload
    }

    public func encoded() throws(XiaomiFrameError) -> Data {
        guard let length = UInt16(exactly: payload.count) else {
            throw .payloadTooLarge(payload.count)
        }
        let header = Self.preamble
            + [kind.rawValue, sequence]
            + Self.littleEndianBytes(length)
            + Self.littleEndianBytes(XiaomiChecksum.crc16(payload))
        return Data(header) + payload
    }

    /// Reads one frame from the start of `buffer`, which may hold a partial frame
    /// or several frames back to back.
    ///
    /// On `.complete`, drop `length` bytes and call again. On a thrown error the
    /// bytes at the start are not a usable frame: drop
    /// `resynchronizationOffset(in:)` bytes and call again. The high nibble of the
    /// kind byte carries flags and is ignored.
    public static func decode(_ buffer: Data) throws(XiaomiFrameError) -> DecodeResult {
        let bytes = [UInt8](buffer)
        guard zip(bytes, preamble).allSatisfy({ $0 == $1 }) else {
            throw .badPreamble
        }
        guard bytes.count >= headerLength else {
            return .incomplete
        }

        let rawKind = bytes[kindOffset] & kindMask
        guard let kind = Kind(rawValue: rawKind) else {
            throw .unknownKind(rawKind)
        }

        let payloadLength = Int(littleEndianValue(bytes, at: lengthOffset))
        let frameLength = headerLength + payloadLength
        guard bytes.count >= frameLength else {
            return .incomplete
        }

        let payload = Data(bytes[headerLength..<frameLength])
        let expected = littleEndianValue(bytes, at: checksumOffset)
        let actual = XiaomiChecksum.crc16(payload)
        guard expected == actual else {
            throw .checksumMismatch(expected: expected, actual: actual)
        }

        let frame = XiaomiFrame(kind: kind, sequence: bytes[sequenceOffset], payload: payload)
        return .complete(frame, length: frameLength)
    }

    /// How many leading bytes to discard after `decode` throws, so the next call
    /// starts at the following preamble candidate. Always advances on a non-empty
    /// buffer, so a rejected frame can never be retried forever.
    public static func resynchronizationOffset(in buffer: Data) -> Int {
        let bytes = [UInt8](buffer)
        return bytes.indices.dropFirst().first { bytes[$0] == preamble[0] } ?? bytes.count
    }

    private static func littleEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private static func littleEndianValue(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
}
