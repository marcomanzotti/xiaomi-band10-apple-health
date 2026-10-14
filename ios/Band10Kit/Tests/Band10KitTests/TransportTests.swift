import Foundation
import Testing
@testable import Band10Kit

// Expected values come from an independent Python port of Gadgetbridge's
// `XiaomiSppPacketV2`.

@Suite("CRC-16 checksum")
struct ChecksumTests {
    @Test("matches the standard CRC-16/ARC check value")
    func matchesStandardCheckValue() {
        // Arrange
        let input = Data("123456789".utf8)

        // Act
        let checksum = XiaomiChecksum.crc16(input)

        // Assert
        #expect(checksum == 0xBB3D)
    }

    @Test("is zero for an empty payload")
    func isZeroForEmptyPayload() {
        #expect(XiaomiChecksum.crc16(Data()) == 0)
    }
}

@Suite("Frame encoding")
struct FrameEncodingTests {
    @Test("encodes a data frame with its length and checksum")
    func encodesDataFrame() throws {
        let frame = XiaomiFrame(kind: .data, sequence: 1, payload: Data(hex: "01010801101a"))

        #expect(try frame.encoded() == Data(hex: "a5a503010600e3ba01010801101a"))
    }

    @Test("encodes an ack with an empty payload")
    func encodesAck() throws {
        let frame = XiaomiFrame(kind: .ack, sequence: 0xF2, payload: Data())

        #expect(try frame.encoded() == Data(hex: "a5a501f200000000"))
    }

    @Test("accepts the largest payload the length field can describe")
    func acceptsLargestPayload() throws {
        let frame = XiaomiFrame(kind: .data, sequence: 0, payload: Data(count: XiaomiFrame.maxPayloadLength))

        let encoded = try frame.encoded()

        #expect(encoded.count == XiaomiFrame.headerLength + XiaomiFrame.maxPayloadLength)
        #expect(encoded[4] == 0xFF)
        #expect(encoded[5] == 0xFF)
    }

    @Test("refuses a payload the length field cannot describe")
    func rejectsOversizedPayload() {
        let tooLarge = XiaomiFrame.maxPayloadLength + 1
        let frame = XiaomiFrame(kind: .data, sequence: 0, payload: Data(count: tooLarge))

        #expect(throws: XiaomiFrameError.payloadTooLarge(tooLarge)) {
            try frame.encoded()
        }
    }

    @Test(
        "round-trips every frame kind",
        arguments: [XiaomiFrame.Kind.nack, .ack, .sessionConfig, .data]
    )
    func roundTrips(kind: XiaomiFrame.Kind) throws {
        let frame = XiaomiFrame(kind: kind, sequence: 0x7F, payload: Data(hex: "0102030405"))

        let decoded = try XiaomiFrame.decode(try frame.encoded())

        #expect(decoded == .complete(frame, length: 13))
    }
}

@Suite("Frame decoding")
struct FrameDecodingTests {
    private let dataFrameBytes = Data(hex: "a5a503010600e3ba01010801101a")
    private let dataFrame = XiaomiFrame(kind: .data, sequence: 1, payload: Data(hex: "01010801101a"))

    @Test("decodes a complete frame and reports its length")
    func decodesCompleteFrame() throws {
        #expect(try XiaomiFrame.decode(dataFrameBytes) == .complete(dataFrame, length: 14))
    }

    @Test("decodes the nack captured from a Band 10")
    func decodesCapturedNack() throws {
        // Captured from a Mi Band 10 (Gadgetbridge XiaomiSppPacketV2Test).
        let captured = Data(hex: "a5a500f600000000")

        let result = try XiaomiFrame.decode(captured)

        #expect(result == .complete(XiaomiFrame(kind: .nack, sequence: 0xF6, payload: Data()), length: 8))
    }

    @Test("decodes two frames back to back using the reported length")
    func decodesConsecutiveFrames() throws {
        // Arrange
        let ackBytes = Data(hex: "a5a501f200000000")
        let buffer = dataFrameBytes + ackBytes

        // Act
        let first = try XiaomiFrame.decode(buffer)
        let second = try XiaomiFrame.decode(buffer.dropFirst(14))

        // Assert
        #expect(first == .complete(dataFrame, length: 14))
        #expect(second == .complete(XiaomiFrame(kind: .ack, sequence: 0xF2, payload: Data()), length: 8))
    }

    @Test("treats the high nibble of the kind byte as flags and ignores it")
    func ignoresFlagBits() throws {
        let flagged = Data(hex: "a5a513010600e3ba01010801101a")

        #expect(try XiaomiFrame.decode(flagged) == .complete(dataFrame, length: 14))
    }

    @Test(
        "reports incomplete until a whole frame has arrived",
        arguments: ["", "a5", "a5a501", "a5a503010600e3ba0101"]
    )
    func incomplete(hex: String) throws {
        #expect(try XiaomiFrame.decode(Data(hex: hex)) == .incomplete)
    }

    @Test("throws when the preamble is wrong", arguments: ["00", "a500", "a5a403010000000000"])
    func rejectsBadPreamble(hex: String) {
        #expect(throws: XiaomiFrameError.badPreamble) {
            try XiaomiFrame.decode(Data(hex: hex))
        }
    }

    @Test("throws when the checksum does not match")
    func rejectsChecksumMismatch() {
        let actual = XiaomiChecksum.crc16(Data(hex: "0102"))

        #expect(throws: XiaomiFrameError.checksumMismatch(expected: 0xFFFF, actual: actual)) {
            try XiaomiFrame.decode(Data(hex: "a5a503010200ffff0102"))
        }
    }

    @Test("throws when the packet type is unknown")
    func rejectsUnknownKind() {
        #expect(throws: XiaomiFrameError.unknownKind(9)) {
            try XiaomiFrame.decode(Data(hex: "a5a5090100000000"))
        }
    }
}

@Suite("Frame resynchronization")
struct FrameResynchronizationTests {
    @Test("skips to the next preamble byte after a rejected frame")
    func skipsToNextPreambleByte() {
        let buffer = Data(hex: "0011a5a501f200000000")

        #expect(XiaomiFrame.resynchronizationOffset(in: buffer) == 2)
    }

    @Test("never returns zero, so a rejected frame cannot be retried forever")
    func alwaysAdvances() {
        let buffer = Data(hex: "a5a5090100000000")

        #expect(XiaomiFrame.resynchronizationOffset(in: buffer) == 1)
    }

    @Test("discards the whole buffer when no preamble byte follows")
    func discardsEverythingWithoutPreamble() {
        let buffer = Data(hex: "a5000102")

        #expect(XiaomiFrame.resynchronizationOffset(in: buffer) == 4)
    }

    @Test("is zero for an empty buffer")
    func emptyBuffer() {
        #expect(XiaomiFrame.resynchronizationOffset(in: Data()) == 0)
    }

    @Test("recovers the frame that follows garbage")
    func recoversFollowingFrame() throws {
        // Arrange
        let ackBytes = Data(hex: "a5a501f200000000")
        let buffer = Data(hex: "0011") + ackBytes

        // Act
        let offset = XiaomiFrame.resynchronizationOffset(in: buffer)
        let result = try XiaomiFrame.decode(buffer.dropFirst(offset))

        // Assert
        #expect(result == .complete(XiaomiFrame(kind: .ack, sequence: 0xF2, payload: Data()), length: 8))
    }
}
