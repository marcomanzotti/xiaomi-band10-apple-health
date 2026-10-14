// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Message layout derived from Gadgetbridge (XiaomiSystemService,
// wear_system.proto), AGPL-3.0.

import Foundation

/// Requests about the band itself. They are sent encrypted, after authentication.
public enum SystemCommand {
    public static let commandType = 2

    enum Subtype {
        static let battery = 1
        static let deviceInfo = 2
    }

    public static let batteryRequest = request(Subtype.battery)
    public static let deviceInfoRequest = request(Subtype.deviceInfo)

    private enum ClockField {
        static let system = 4
        static let clock = 4
        static let date = 1
        static let time = 2
        static let timeZone = 3
        static let isTwelveHour = 4
    }

    private static let clockSubtype = 3
    private static let secondsPerQuarterHour = 15 * 60
    private static let nanosecondsPerMillisecond = 1_000_000

    /// Sets the band's clock. The band has no other source of time, so this is
    /// also what moves it across daylight-saving changes.
    public static func setClock(to date: Date, in timeZone: TimeZone, usesTwelveHourFormat: Bool = false) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let daylightOffset = Int(timeZone.daylightSavingTimeOffset(for: date))
        let standardOffset = timeZone.secondsFromGMT(for: date) - daylightOffset

        let day = field(1, parts.year) + field(2, parts.month) + field(3, parts.day)
        let time = field(1, parts.hour) + field(2, parts.minute) + field(3, parts.second)
            + field(4, (parts.nanosecond ?? 0) / nanosecondsPerMillisecond)
        let zone = signed(1, standardOffset / secondsPerQuarterHour)
            + signed(2, daylightOffset / secondsPerQuarterHour)
            + Protobuf.string(3, timeZone.identifier)
        let clock = Protobuf.bytes(ClockField.date, day)
            + Protobuf.bytes(ClockField.time, time)
            + Protobuf.bytes(ClockField.timeZone, zone)
            + Protobuf.bool(ClockField.isTwelveHour, usesTwelveHourFormat)
        return request(clockSubtype) + Protobuf.bytes(ClockField.system, Protobuf.bytes(ClockField.clock, clock))
    }

    private static func field(_ number: Int, _ value: Int?) -> Data {
        Protobuf.varint(number, UInt64(max(0, value ?? 0)))
    }

    /// Protobuf `sint32`: zig-zag encoding keeps small negative numbers short.
    private static func signed(_ number: Int, _ value: Int) -> Data {
        let narrowed = Int32(truncatingIfNeeded: value)
        return Protobuf.varint(number, UInt64(UInt32(bitPattern: (narrowed << 1) ^ (narrowed >> 31))))
    }

    private static func request(_ subtype: Int) -> Data {
        Protobuf.varint(CommandField.type, UInt64(commandType)) + Protobuf.varint(CommandField.subtype, UInt64(subtype))
    }
}

public enum SystemReplyError: Error, Equatable, Sendable {
    case malformed(ProtobufError)
    case unexpectedCommandType(Int)
}

public enum SystemReply: Equatable, Sendable {
    case deviceInfo(serialNumber: String, firmware: String, model: String)
    /// Battery charge in percent.
    case battery(level: Int)
    case other(subtype: Int)

    private enum Field {
        static let system = 4
        static let power = 2
        static let deviceInfo = 3
        static let battery = 1
        static let level = 1
        static let serialNumber = 1
        static let firmware = 2
        static let model = 4
    }

    public static func parse(_ command: Data) throws(SystemReplyError) -> SystemReply {
        let fields = try decode(command)
        let type = Int(fields.varint(CommandField.type) ?? 0)
        guard type == SystemCommand.commandType else {
            throw .unexpectedCommandType(type)
        }
        let subtype = Int(fields.varint(CommandField.subtype) ?? 0)
        let system = try fields.bytes(Field.system).map(decode) ?? []

        if let infoBytes = system.bytes(Field.deviceInfo) {
            let info = try decode(infoBytes)
            return .deviceInfo(
                serialNumber: info.string(Field.serialNumber) ?? "",
                firmware: info.string(Field.firmware) ?? "",
                model: info.string(Field.model) ?? ""
            )
        }
        if let powerBytes = system.bytes(Field.power),
           let batteryBytes = try decode(powerBytes).bytes(Field.battery),
           let level = try decode(batteryBytes).varint(Field.level) {
            return .battery(level: Int(level))
        }
        return .other(subtype: subtype)
    }

    private static func decode(_ message: Data) throws(SystemReplyError) -> [Protobuf.Field] {
        do {
            return try Protobuf.decode(message)
        } catch {
            throw .malformed(error)
        }
    }
}
