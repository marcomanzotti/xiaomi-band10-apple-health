// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Message layout derived from Gadgetbridge (XiaomiHealthService,
// wear_fitness.proto), AGPL-3.0.

import Foundation

/// Commands that list and download the band's recorded data. They are sent
/// encrypted, after authentication.
public enum HealthCommand {
    public static let commandType = 8

    enum Subtype {
        static let filesOfToday = 1
        static let filesOfPastDays = 2
        static let requestFile = 3
        static let acknowledgeFile = 5
    }

    enum Field {
        static let health = 10
        static let requestedFiles = 2
        static let acknowledgedFiles = 3
        static let todayRequest = 5
    }

    /// Asks which files hold today's data. The official app sends a zero here.
    public static let listToday = command(
        Subtype.filesOfToday,
        health: Protobuf.bytes(Field.todayRequest, Protobuf.varint(1, 0))
    )

    /// Asks which files of earlier days were never acknowledged.
    public static let listPastDays = command(Subtype.filesOfPastDays, health: nil)

    /// Asks the band to send a file on the activity channel.
    public static func request(_ file: ActivityFileID) -> Data {
        command(Subtype.requestFile, health: Protobuf.bytes(Field.requestedFiles, file.encoded()))
    }

    /// Tells the band a file was received, so that it stops listing it.
    public static func acknowledge(_ file: ActivityFileID) -> Data {
        command(Subtype.acknowledgeFile, health: Protobuf.bytes(Field.acknowledgedFiles, file.encoded()))
    }

    private static func command(_ subtype: Int, health: Data?) -> Data {
        Protobuf.varint(CommandField.type, UInt64(commandType))
            + Protobuf.varint(CommandField.subtype, UInt64(subtype))
            + (health.map { Protobuf.bytes(Field.health, $0) } ?? Data())
    }
}

public enum HealthReplyError: Error, Equatable, Sendable {
    case malformed(ProtobufError)
    case malformedFileList(ActivityParseError)
    case unexpectedCommandType(Int)
}

public enum HealthReply: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        case today
        case pastDays
    }

    /// The files the band holds for the requested period; may be empty.
    case files(Scope, [ActivityFileID])
    case other(subtype: Int)

    public static func parse(_ command: Data) throws(HealthReplyError) -> HealthReply {
        let fields = try decode(command)
        let type = Int(fields.varint(CommandField.type) ?? 0)
        guard type == HealthCommand.commandType else {
            throw .unexpectedCommandType(type)
        }
        let subtype = Int(fields.varint(CommandField.subtype) ?? 0)
        let scope: Scope
        switch subtype {
        case HealthCommand.Subtype.filesOfToday: scope = .today
        case HealthCommand.Subtype.filesOfPastDays: scope = .pastDays
        default: return .other(subtype: subtype)
        }
        let health = try fields.bytes(HealthCommand.Field.health).map(decode) ?? []
        do {
            return .files(scope, try ActivityFileID.list(decoding: health.bytes(HealthCommand.Field.requestedFiles) ?? Data()))
        } catch {
            throw .malformedFileList(error)
        }
    }

    private static func decode(_ message: Data) throws(HealthReplyError) -> [Protobuf.Field] {
        do {
            return try Protobuf.decode(message)
        } catch {
            throw .malformed(error)
        }
    }
}

/// The type and subtype every band command starts with, to route it.
public struct CommandHeader: Equatable, Sendable {
    public let type: Int
    public let subtype: Int

    public init(type: Int, subtype: Int) {
        self.type = type
        self.subtype = subtype
    }

    public static func parse(_ command: Data) throws(ProtobufError) -> CommandHeader {
        let fields = try Protobuf.decode(command)
        return CommandHeader(
            type: Int(fields.varint(CommandField.type) ?? 0),
            subtype: Int(fields.varint(CommandField.subtype) ?? 0)
        )
    }
}
