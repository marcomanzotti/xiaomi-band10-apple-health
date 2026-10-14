// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Protocol behaviour derived from Gadgetbridge (XiaomiSppPacketV2,
// XiaomiBleProtocolV2), AGPL-3.0.

import Foundation

public enum XiaomiDataPayloadError: Error, Equatable, Sendable {
    case tooShort(Int)
    case unknownChannel(UInt8)
    case unknownOpcode(UInt8)
}

/// The content of a `data` frame: `channel | opcode | body`.
public struct XiaomiDataPayload: Equatable, Sendable {
    public enum Channel: UInt8, Sendable {
        /// Protobuf commands; encrypted once the session is authenticated.
        case command = 1
        /// Bulk uploads to the band; never encrypted.
        case data = 2
        /// Activity files coming from the band; always encrypted.
        case activity = 5
    }

    public enum Opcode: UInt8, Sendable {
        case plaintext = 1
        case encrypted = 2
    }

    private static let headerLength = 2
    private static let channelMask: UInt8 = 0x0F

    public let channel: Channel
    public let opcode: Opcode
    public let body: Data

    public init(channel: Channel, opcode: Opcode, body: Data) {
        self.channel = channel
        self.opcode = opcode
        self.body = body
    }

    public func encoded() -> Data {
        Data([channel.rawValue, opcode.rawValue]) + body
    }

    public static func decode(_ payload: Data) throws(XiaomiDataPayloadError) -> XiaomiDataPayload {
        let bytes = [UInt8](payload)
        guard bytes.count >= headerLength else {
            throw .tooShort(bytes.count)
        }
        let rawChannel = bytes[0] & channelMask
        guard let channel = Channel(rawValue: rawChannel) else {
            throw .unknownChannel(rawChannel)
        }
        guard let opcode = Opcode(rawValue: bytes[1]) else {
            throw .unknownOpcode(bytes[1])
        }
        return XiaomiDataPayload(channel: channel, opcode: opcode, body: Data(bytes[headerLength...]))
    }
}

/// Link-layer state for one connection: reassembles incoming notifications into
/// frames, says which acknowledgements to send, and numbers outgoing frames.
/// It knows nothing about Bluetooth; the caller moves the bytes.
public struct XiaomiLink: Sendable {
    public enum Event: Equatable, Sendable {
        /// The band answered the session request (`opcode` 2) or closed the session (4).
        case sessionConfig(opcode: UInt8)
        case payload(XiaomiDataPayload)
        case acknowledged(sequence: UInt8)
        case rejected(sequence: UInt8)
        /// Bytes that were not a usable frame were dropped to resynchronize.
        case discarded(byteCount: Int, reason: XiaomiFrameError)
        /// A well-formed data frame carried a payload that could not be read.
        case malformedPayload(sequence: UInt8, reason: XiaomiDataPayloadError)
    }

    public struct Output: Equatable, Sendable {
        public let events: [Event]
        /// Encoded frames (acknowledgements) to write back, in order.
        public let framesToSend: [Data]
    }

    /// Session parameters every known client sends: protocol version 1.0.0,
    /// max packet 0xFC00, transmit window 32, send timeout 10 000 ms.
    private static let sessionRequestPayload = Data([
        0x01,
        0x01, 0x03, 0x00, 0x01, 0x00, 0x00,
        0x02, 0x02, 0x00, 0x00, 0xFC,
        0x03, 0x02, 0x00, 0x20, 0x00,
        0x04, 0x02, 0x00, 0x10, 0x27,
    ])
    private static let sessionRequestSequence: UInt8 = 0
    /// Opcode 3 asks the band to end the current session; it answers with opcode 4.
    private static let sessionStopPayload = Data([0x03])

    private var receiveBuffer = Data()
    private var nextSequence: UInt8 = 0

    public init() {}

    /// The first frame to write after subscribing to notifications.
    public func sessionRequestFrame() throws(XiaomiFrameError) -> Data {
        try XiaomiFrame(
            kind: .sessionConfig,
            sequence: Self.sessionRequestSequence,
            payload: Self.sessionRequestPayload
        ).encoded()
    }

    /// Ends whatever session the band still holds, for example one left open by a
    /// previous connection on the same Bluetooth link. Safe to send when none is open.
    public func sessionStopFrame() throws(XiaomiFrameError) -> Data {
        try XiaomiFrame(
            kind: .sessionConfig,
            sequence: Self.sessionRequestSequence,
            payload: Self.sessionStopPayload
        ).encoded()
    }

    /// Encodes a data frame and consumes one sequence number.
    public mutating func dataFrame(_ payload: XiaomiDataPayload) throws(XiaomiFrameError) -> Data {
        let frame = try XiaomiFrame(kind: .data, sequence: nextSequence, payload: payload.encoded()).encoded()
        nextSequence &+= 1
        return frame
    }

    /// Feeds the bytes of one notification and returns everything they completed.
    public mutating func receive(_ bytes: Data) -> Output {
        receiveBuffer.append(bytes)
        var events: [Event] = []
        var framesToSend: [Data] = []

        while !receiveBuffer.isEmpty {
            do {
                guard case .complete(let frame, let length) = try XiaomiFrame.decode(receiveBuffer) else {
                    break
                }
                receiveBuffer = Data(receiveBuffer.dropFirst(length))
                let handled = Self.handle(frame)
                events.append(handled.event)
                framesToSend.append(contentsOf: handled.acknowledgement.map { [$0] } ?? [])
            } catch {
                let skipped = XiaomiFrame.resynchronizationOffset(in: receiveBuffer)
                receiveBuffer = Data(receiveBuffer.dropFirst(skipped))
                events.append(.discarded(byteCount: skipped, reason: error))
            }
        }
        return Output(events: events, framesToSend: framesToSend)
    }

    private static func handle(_ frame: XiaomiFrame) -> (event: Event, acknowledgement: Data?) {
        switch frame.kind {
        case .ack:
            return (.acknowledged(sequence: frame.sequence), nil)
        case .nack:
            return (.rejected(sequence: frame.sequence), nil)
        case .sessionConfig:
            return (.sessionConfig(opcode: frame.payload.first ?? 0), nil)
        case .data:
            do {
                let payload = try XiaomiDataPayload.decode(frame.payload)
                let acknowledgement = try? XiaomiFrame(kind: .ack, sequence: frame.sequence, payload: Data()).encoded()
                return (.payload(payload), acknowledgement)
            } catch {
                return (.malformedPayload(sequence: frame.sequence, reason: error), nil)
            }
        }
    }
}
