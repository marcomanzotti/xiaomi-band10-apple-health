// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Message layout recovered by static analysis of Mi Fitness 3.46.1
// (protobuf serializers of the Command, Account and bind messages).

import CryptoKit
import Foundation

/// Field numbers of the outer `Command` message shared by every band command.
enum CommandField {
    static let type = 1
    static let subtype = 2
    static let account = 3
}

/// Field numbers inside the `Account` message used while pairing.
enum AccountField {
    static let errorCode = 3
    static let bindInfoRequest = 11
    static let bindInfo = 12
    static let appVerify = 17
    static let deviceVerify = 18
    static let appConfirm = 19
    static let confirmResult = 20
    static let bindResult = 29
}

/// Builders for the unencrypted commands the phone sends while pairing.
public enum BindingCommand {
    /// Every pairing command is an "account" command.
    public static let commandType = 1

    public enum Subtype: Int, Sendable {
        case bindInfo = 17
        case appVerify = 18
        case appConfirm = 19
        case bindResult = 25
    }

    /// Asks the band which pairing mode it wants. An already-bound band answers
    /// with error code 1 instead.
    public static func bindInfoRequest(userID: String) -> Data {
        let userDigest = Data(Insecure.MD5.hash(data: Data(userID.utf8)))
        let request = Protobuf.bool(1, false) + Protobuf.bytes(2, userDigest)
        return command(.bindInfo, account: Protobuf.bytes(AccountField.bindInfoRequest, request))
    }

    public static func appVerify(appDeviceID: String, publicKey: Data) -> Data {
        let verify = Protobuf.string(1, appDeviceID) + Protobuf.bytes(2, publicKey)
        return command(.appVerify, account: Protobuf.bytes(AccountField.appVerify, verify))
    }

    public static func appConfirm(appRandom: Data, signature: Data) -> Data {
        let confirm = Protobuf.bytes(1, appRandom) + Protobuf.bytes(2, signature)
        return command(.appConfirm, account: Protobuf.bytes(AccountField.appConfirm, confirm))
    }

    /// `sealed` is `bindResultPlaintext` encrypted with `LocalBinding.sealBindResult`.
    public static func bindResult(sealed: Data) -> Data {
        command(.bindResult, account: Protobuf.bytes(AccountField.bindResult, Protobuf.bytes(1, sealed)))
    }

    /// Describes the phone to the band; the content is informational.
    public static func bindResultPlaintext(userID: String, systemVersion: Float, phoneModel: String) -> Data {
        let companion = Protobuf.varint(1, UInt64(Authenticator.Companion.DeviceType.iOS.rawValue))
            + Protobuf.float(2, systemVersion)
            + Protobuf.string(3, phoneModel)
        return Protobuf.string(1, userID) + Protobuf.bytes(2, companion)
    }

    private static func command(_ subtype: Subtype, account: Data) -> Data {
        Protobuf.varint(CommandField.type, UInt64(commandType))
            + Protobuf.varint(CommandField.subtype, UInt64(subtype.rawValue))
            + Protobuf.bytes(CommandField.account, account)
    }
}

/// What the band reports before pairing starts.
public struct BindInfo: Equatable, Sendable {
    public enum VerifyMode: Equatable, Sendable {
        /// Needs a secret held by Xiaomi's server; cannot be completed offline.
        case serverAssisted
        /// Phone and band agree on the key between themselves (ECDH).
        case local
        case unknown(Int)

        init(rawValue: Int) {
            switch rawValue {
            case 1: self = .serverAssisted
            case 2: self = .local
            default: self = .unknown(rawValue)
            }
        }
    }

    public let verifyMode: VerifyMode
    /// How the user confirms on the band; 3 means pressing its on-screen button.
    public let outOfBandMode: Int
    public let macAddress: String
    // The meaning of the remaining fields is not established yet; they are kept
    // verbatim because Mi Fitness passes them along after pairing.
    public let unknownString2: String
    public let unknownString4: String
    public let unknownBytes6: Data
    public let unknownString7: String
}

public enum BindingReplyError: Error, Equatable, Sendable {
    case malformed(ProtobufError)
    case unexpectedCommandType(Int)
    case missingField(String)
}

/// A pairing reply from the band, decoded from an unencrypted command.
public enum BindingReply: Equatable, Sendable {
    case bindInfo(BindInfo)
    case deviceVerify(publicKey: Data, random: Data, signature: Data)
    case confirmResult(Bool)
    /// Known codes: 1 already bound, 6 cancelled on the band, 7 signature rejected.
    case error(code: Int)
    /// The band answered without any pairing payload.
    case acknowledged

    public var bindInfo: BindInfo? {
        if case .bindInfo(let info) = self { info } else { nil }
    }

    public static func parse(_ command: Data) throws(BindingReplyError) -> BindingReply {
        let fields = try decode(command)
        let type = Int(fields.varint(CommandField.type) ?? 0)
        guard type == BindingCommand.commandType else {
            throw .unexpectedCommandType(type)
        }
        guard let accountBytes = fields.bytes(CommandField.account) else {
            return .acknowledged
        }
        return try parseAccount(try decode(accountBytes))
    }

    private static func parseAccount(_ account: [Protobuf.Field]) throws(BindingReplyError) -> BindingReply {
        if let code = account.varint(AccountField.errorCode) {
            return .error(code: Int(code))
        }
        if let info = account.bytes(AccountField.bindInfo) {
            return .bindInfo(parseBindInfo(try decode(info)))
        }
        if let verify = account.bytes(AccountField.deviceVerify) {
            return try parseDeviceVerify(try decode(verify))
        }
        if let result = account.bytes(AccountField.confirmResult) {
            return .confirmResult(try decode(result).varint(1) == 1)
        }
        return .acknowledged
    }

    private static func parseBindInfo(_ info: [Protobuf.Field]) -> BindInfo {
        BindInfo(
            verifyMode: BindInfo.VerifyMode(rawValue: Int(info.varint(1) ?? 0)),
            outOfBandMode: Int(info.varint(5) ?? 0),
            macAddress: info.string(3) ?? "",
            unknownString2: info.string(2) ?? "",
            unknownString4: info.string(4) ?? "",
            unknownBytes6: info.bytes(6) ?? Data(),
            unknownString7: info.string(7) ?? ""
        )
    }

    private static func parseDeviceVerify(_ verify: [Protobuf.Field]) throws(BindingReplyError) -> BindingReply {
        guard let publicKey = verify.bytes(1), let random = verify.bytes(2), let signature = verify.bytes(3) else {
            throw .missingField("deviceVerify")
        }
        return .deviceVerify(publicKey: publicKey, random: random, signature: signature)
    }

    private static func decode(_ message: Data) throws(BindingReplyError) -> [Protobuf.Field] {
        do {
            return try Protobuf.decode(message)
        } catch {
            throw .malformed(error)
        }
    }
}
