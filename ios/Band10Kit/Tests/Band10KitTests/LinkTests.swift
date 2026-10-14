import Foundation
import Testing
@testable import Band10Kit

// Session-config bytes and acknowledgement behaviour follow Gadgetbridge's
// XiaomiSppPacketV2 / XiaomiBleProtocolV2.

@Suite("Data payload codec")
struct DataPayloadTests {
    @Test("prefixes the body with channel and opcode")
    func encodes() {
        let payload = XiaomiDataPayload(channel: .command, opcode: .plaintext, body: Data(hex: "0801"))

        #expect(payload.encoded() == Data(hex: "01010801"))
    }

    @Test("decodes the channel from the low nibble and keeps the body")
    func decodes() throws {
        let payload = try XiaomiDataPayload.decode(Data(hex: "f502aabb"))

        #expect(payload == XiaomiDataPayload(channel: .activity, opcode: .encrypted, body: Data(hex: "aabb")))
    }

    @Test("rejects a payload too short to hold channel and opcode")
    func rejectsShortPayload() {
        #expect(throws: XiaomiDataPayloadError.tooShort(1)) {
            try XiaomiDataPayload.decode(Data(hex: "01"))
        }
    }

    @Test("rejects channels and opcodes the protocol does not define")
    func rejectsUnknownValues() {
        #expect(throws: XiaomiDataPayloadError.unknownChannel(9)) {
            try XiaomiDataPayload.decode(Data(hex: "0901"))
        }
        #expect(throws: XiaomiDataPayloadError.unknownOpcode(7)) {
            try XiaomiDataPayload.decode(Data(hex: "0107"))
        }
    }
}

@Suite("Link layer")
struct LinkTests {
    private let sessionRequestPayload = Data(hex: "01" + "010300010000" + "02020000fc" + "0302002000" + "0402001027")

    private func frame(_ kind: XiaomiFrame.Kind, _ sequence: UInt8, _ payloadHex: String = "") throws -> Data {
        try XiaomiFrame(kind: kind, sequence: sequence, payload: Data(hex: payloadHex)).encoded()
    }

    @Test("opens the session with the fixed configuration request")
    func buildsSessionRequest() throws {
        // Act
        let bytes = try XiaomiLink().sessionRequestFrame()

        // Assert
        let expected = XiaomiFrame(kind: .sessionConfig, sequence: 0, payload: sessionRequestPayload)
        #expect(try XiaomiFrame.decode(bytes) == .complete(expected, length: 30))
    }

    @Test("can ask the band to end a session left open on the same link")
    func buildsSessionStop() throws {
        let bytes = try XiaomiLink().sessionStopFrame()

        let expected = XiaomiFrame(kind: .sessionConfig, sequence: 0, payload: Data(hex: "03"))
        #expect(try XiaomiFrame.decode(bytes) == .complete(expected, length: 9))
    }

    @Test("numbers outgoing data frames from zero and wraps after 255")
    func numbersOutgoingFrames() throws {
        // Arrange
        var link = XiaomiLink()
        let payload = XiaomiDataPayload(channel: .command, opcode: .plaintext, body: Data(hex: "0801"))

        // Act
        let first = try link.dataFrame(payload)
        let second = try link.dataFrame(payload)
        for _ in 2..<256 { _ = try link.dataFrame(payload) }
        let wrapped = try link.dataFrame(payload)

        // Assert
        #expect(first == Data(hex: "a5a50300") + first.dropFirst(4))
        #expect(try XiaomiFrame.decode(first) == .complete(XiaomiFrame(kind: .data, sequence: 0, payload: Data(hex: "01010801")), length: 12))
        #expect(second[3] == 1)
        #expect(wrapped[3] == 0)
    }

    @Test("acknowledges a received data frame and surfaces its payload")
    func acknowledgesData() throws {
        // Arrange
        var link = XiaomiLink()

        // Act
        let output = link.receive(try frame(.data, 5, "0101aabb"))

        // Assert
        let payload = XiaomiDataPayload(channel: .command, opcode: .plaintext, body: Data(hex: "aabb"))
        #expect(output.events == [.payload(payload)])
        #expect(output.framesToSend == [Data(hex: "a5a5010500000000")])
    }

    @Test("reports the session-config reply without acknowledging it")
    func reportsSessionConfig() throws {
        var link = XiaomiLink()

        let output = link.receive(try frame(.sessionConfig, 0, "02" + "010300010000"))

        #expect(output.events == [.sessionConfig(opcode: 2)])
        #expect(output.framesToSend.isEmpty)
    }

    @Test("reports acks and nacks with their sequence numbers")
    func reportsAcknowledgements() throws {
        var link = XiaomiLink()

        let output = link.receive(try frame(.ack, 3) + frame(.nack, 4))

        #expect(output.events == [.acknowledged(sequence: 3), .rejected(sequence: 4)])
        #expect(output.framesToSend.isEmpty)
    }

    @Test("reassembles a frame delivered across several notifications")
    func reassemblesSplitFrames() throws {
        // Arrange
        var link = XiaomiLink()
        let bytes = try frame(.data, 9, "0101aabbccdd")

        // Act
        let firstHalf = link.receive(bytes.prefix(7))
        let secondHalf = link.receive(bytes.dropFirst(7))

        // Assert
        #expect(firstHalf.events.isEmpty)
        #expect(firstHalf.framesToSend.isEmpty)
        let payload = XiaomiDataPayload(channel: .command, opcode: .plaintext, body: Data(hex: "aabbccdd"))
        #expect(secondHalf.events == [.payload(payload)])
    }

    @Test("handles several frames in one notification, in order")
    func handlesBackToBackFrames() throws {
        var link = XiaomiLink()

        let output = link.receive(try frame(.data, 1, "0101aa") + frame(.data, 2, "0502bb"))

        #expect(output.events == [
            .payload(XiaomiDataPayload(channel: .command, opcode: .plaintext, body: Data(hex: "aa"))),
            .payload(XiaomiDataPayload(channel: .activity, opcode: .encrypted, body: Data(hex: "bb"))),
        ])
        #expect(output.framesToSend == [Data(hex: "a5a5010100000000"), Data(hex: "a5a5010200000000")])
    }

    @Test("skips garbage and still delivers the frame that follows")
    func resynchronizes() throws {
        var link = XiaomiLink()

        let output = link.receive(Data(hex: "0011") + (try frame(.ack, 7)))

        #expect(output.events == [.discarded(byteCount: 2, reason: .badPreamble), .acknowledged(sequence: 7)])
    }

    @Test("does not acknowledge a data frame whose payload cannot be read")
    func rejectsUnreadableData() throws {
        var link = XiaomiLink()

        let output = link.receive(try frame(.data, 6, "01"))

        #expect(output.events == [.malformedPayload(sequence: 6, reason: .tooShort(1))])
        #expect(output.framesToSend.isEmpty)
    }
}
