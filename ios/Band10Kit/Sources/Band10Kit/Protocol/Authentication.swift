// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Protocol behaviour derived from Gadgetbridge (XiaomiAuthService,
// wear_account.proto), AGPL-3.0.

import Foundation

/// Builders for the two commands of the encrypted handshake.
public enum AuthCommand {
    static let nonceSubtype = 26
    static let confirmSubtype = 27

    private enum Field {
        static let appVerify = 30
        static let appConfirm = 32
    }

    public static func nonce(_ phoneNonce: Data) -> Data {
        command(nonceSubtype, account: Protobuf.bytes(Field.appVerify, Protobuf.bytes(1, phoneNonce)))
    }

    public static func confirm(proof: Data, sealedCompanion: Data) -> Data {
        let confirm = Protobuf.bytes(1, proof) + Protobuf.bytes(2, sealedCompanion)
        return command(confirmSubtype, account: Protobuf.bytes(Field.appConfirm, confirm))
    }

    /// The phone description sealed into the confirm command (`CompanionDevice`).
    /// The device type is written explicitly even when zero.
    public static func companionDescription(_ companion: Authenticator.Companion) -> Data {
        let capability = companion.appCapability.map { Protobuf.varint(4, UInt64($0)) } ?? Data()
        return Protobuf.varint(1, UInt64(companion.deviceType.rawValue))
            + Protobuf.float(2, companion.systemVersion)
            + Protobuf.string(3, companion.phoneName)
            + capability
            + Protobuf.string(5, companion.region)
    }

    private static func command(_ subtype: Int, account: Data) -> Data {
        Protobuf.varint(CommandField.type, UInt64(BindingCommand.commandType))
            + Protobuf.varint(CommandField.subtype, UInt64(subtype))
            + Protobuf.bytes(CommandField.account, account)
    }
}

public enum AuthReplyError: Error, Equatable, Sendable {
    case malformed(ProtobufError)
    case unexpectedCommandType(Int)
}

/// A handshake reply from the band.
public enum AuthReply: Equatable, Sendable {
    case deviceVerify(nonce: Data, proof: Data)
    /// The band accepted the phone's proof; later commands are encrypted.
    case accepted
    case rejected(subtype: Int, status: Int)

    private enum Field {
        static let accountStatus = 8
        static let deviceVerify = 31
        static let commandStatus = 100
    }

    public static func parse(_ command: Data) throws(AuthReplyError) -> AuthReply {
        let fields = try decode(command)
        let type = Int(fields.varint(CommandField.type) ?? 0)
        guard type == BindingCommand.commandType else {
            throw .unexpectedCommandType(type)
        }
        let subtype = Int(fields.varint(CommandField.subtype) ?? 0)
        let account = try fields.bytes(CommandField.account).map(decode) ?? []

        if subtype == AuthCommand.nonceSubtype, let verifyBytes = account.bytes(Field.deviceVerify) {
            let verify = try decode(verifyBytes)
            if let nonce = verify.bytes(1), let proof = verify.bytes(2) {
                return .deviceVerify(nonce: nonce, proof: proof)
            }
        }
        if subtype == AuthCommand.confirmSubtype {
            return .accepted
        }
        let status = account.varint(Field.accountStatus) ?? fields.varint(Field.commandStatus) ?? 0
        return .rejected(subtype: subtype, status: Int(status))
    }

    private static func decode(_ message: Data) throws(AuthReplyError) -> [Protobuf.Field] {
        do {
            return try Protobuf.decode(message)
        } catch {
            throw .malformed(error)
        }
    }
}

/// Encrypts commands for the band and decrypts what it sends, once authenticated.
/// The transport uses AES counter mode with each key doubling as its initial
/// counter, and carries no integrity check: treat decrypted data as untrusted.
public struct SessionCipher: Equatable, Sendable {
    private let encryptionKey: Data
    private let decryptionKey: Data

    init(keys: SessionKeys) {
        encryptionKey = keys.encryptionKey
        decryptionKey = keys.decryptionKey
    }

    public func encrypt(_ plaintext: Data) throws(AESCipherError) -> Data {
        try AESCipher.counterMode(plaintext, key: encryptionKey, initialCounter: encryptionKey)
    }

    public func decrypt(_ ciphertext: Data) throws(AESCipherError) -> Data {
        try AESCipher.counterMode(ciphertext, key: decryptionKey, initialCounter: decryptionKey)
    }
}

public enum AuthenticatorFailure: Error, Equatable, Sendable {
    case invalidAuthKey
    /// The band's proof does not match: the stored key is not this band's key.
    case keyMismatch
    case malformedReply
    case rejectedByBand(subtype: Int, status: Int)
    case unexpectedReply
    case encodingFailed
}

/// Drives the encrypted handshake that opens every connection to a paired band.
/// It holds no transport: feed it each decoded reply and carry out its actions.
public struct Authenticator: Sendable {
    /// How the phone introduces itself (`CompanionDevice`; field names from the
    /// AstroBox protocol definitions, AGPL-3.0).
    public struct Companion: Equatable, Sendable {
        /// The band changes how it behaves towards its phone depending on this.
        /// Declaring `.android` from an iPhone left a band unable to reconnect to
        /// it until a factory reset, so the default is `.iOS`.
        public enum DeviceType: Int, Sendable {
            case android = 0
            case iOS = 1
            case vela = 2
            case other = 15
        }

        public let deviceType: DeviceType
        public let systemVersion: Float
        public let phoneName: String
        /// Two-letter upper-case region code.
        public let region: String
        /// Feature bits the app claims to support. Left out by default: the values
        /// Mi Fitness for iOS sends are not known, and none are implemented here.
        public let appCapability: UInt32?

        public init(
            deviceType: DeviceType = .iOS,
            systemVersion: Float,
            phoneName: String,
            region: String,
            appCapability: UInt32? = nil
        ) {
            self.deviceType = deviceType
            self.systemVersion = systemVersion
            self.phoneName = phoneName
            self.region = region
            self.appCapability = appCapability
        }
    }

    public enum Action: Equatable, Sendable {
        /// Send these command bytes, unencrypted, on the command channel.
        case send(Data)
        case authenticated(SessionCipher)
        case failed(AuthenticatorFailure)
    }

    private enum Step: Sendable {
        case awaitingDeviceVerify
        case awaitingAcceptance(SessionKeys)
        case finished
    }

    /// The confirm message is sealed with the session nonce prefix followed by
    /// two zero counters.
    private static let sealNonceSuffix = Data(count: 8)

    private let authKey: Data
    private let companion: Companion
    private let phoneNonce: Data
    private var step = Step.awaitingDeviceVerify

    public init(
        authKey: Data,
        companion: Companion,
        phoneNonce: Data = Data((0..<SessionKeys.nonceLength).map { _ in UInt8.random(in: .min ... .max) })
    ) throws(AuthenticatorFailure) {
        guard authKey.count == SessionKeys.authKeyLength, phoneNonce.count == SessionKeys.nonceLength else {
            throw .invalidAuthKey
        }
        self.authKey = authKey
        self.companion = companion
        self.phoneNonce = phoneNonce
    }

    public func start() -> [Action] {
        [.send(AuthCommand.nonce(phoneNonce))]
    }

    public mutating func handle(_ reply: AuthReply) -> [Action] {
        let outcome = advance(reply)
        step = outcome.next
        return outcome.actions
    }

    private func advance(_ reply: AuthReply) -> (next: Step, actions: [Action]) {
        switch (step, reply) {
        case (.finished, _):
            return (.finished, [])
        case (.awaitingDeviceVerify, .deviceVerify(let watchNonce, let proof)):
            return confirm(watchNonce: watchNonce, watchProof: proof)
        case (.awaitingAcceptance(let keys), .accepted):
            return (.finished, [.authenticated(SessionCipher(keys: keys))])
        case (_, .rejected(let subtype, let status)):
            return Self.fail(.rejectedByBand(subtype: subtype, status: status))
        default:
            return Self.fail(.unexpectedReply)
        }
    }

    private func confirm(watchNonce: Data, watchProof: Data) -> (next: Step, actions: [Action]) {
        guard let keys = try? SessionKeys.derive(authKey: authKey, phoneNonce: phoneNonce, watchNonce: watchNonce) else {
            return Self.fail(.malformedReply)
        }
        guard keys.isValidWatchProof(watchProof, phoneNonce: phoneNonce, watchNonce: watchNonce) else {
            return Self.fail(.keyMismatch)
        }
        guard let sealed = try? AESCipher.ccmSeal(
            AuthCommand.companionDescription(companion),
            key: keys.encryptionKey,
            nonce: keys.encryptionNonce + Self.sealNonceSuffix
        ) else {
            return Self.fail(.encodingFailed)
        }
        let proof = keys.phoneProof(phoneNonce: phoneNonce, watchNonce: watchNonce)
        return (.awaitingAcceptance(keys), [.send(AuthCommand.confirm(proof: proof, sealedCompanion: sealed))])
    }

    private static func fail(_ failure: AuthenticatorFailure) -> (next: Step, actions: [Action]) {
        (.finished, [.failed(failure)])
    }
}
