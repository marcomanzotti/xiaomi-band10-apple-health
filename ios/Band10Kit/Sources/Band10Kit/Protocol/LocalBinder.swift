// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Sequence recovered by static analysis of Mi Fitness 3.46.1
// (com.xiaomi.fit.device.bind.WearBinderV2 and LocalWearBinderV2).

import Foundation

public enum LocalBinderFailure: Error, Equatable, Sendable {
    /// The band is paired with another app; it must be factory reset first.
    case alreadyBound
    /// The band insists on the mode that needs Xiaomi's server.
    case serverAssistedPairingRequired
    case unsupportedVerifyMode(Int)
    case unsupportedConfirmationMode(Int)
    case deviceSignatureInvalid
    case deviceKeyInvalid
    case cancelledOnBand
    case bandReportedError(Int)
    case unexpectedReply
    case encodingFailed
}

/// Drives the band's local pairing step by step. It holds no transport: feed it
/// each decoded reply and carry out the actions it returns.
public struct LocalBinder: Sendable {
    /// How the phone introduces itself. None of it is checked by the band.
    public struct Identity: Equatable, Sendable {
        public let userID: String
        /// Any stable 32-character hex string identifying this phone.
        public let appDeviceID: String
        public let systemVersion: Float
        public let phoneModel: String

        public init(userID: String, appDeviceID: String, systemVersion: Float, phoneModel: String) {
            self.userID = userID
            self.appDeviceID = appDeviceID
            self.systemVersion = systemVersion
            self.phoneModel = phoneModel
        }
    }

    public enum Action: Equatable, Sendable {
        /// Send these command bytes, unencrypted, on the command channel.
        case send(Data)
        /// Tell the user to accept the pairing on the band's screen.
        case askUserToConfirmOnBand
        /// Pairing is done. Store `authKey` in the Keychain; never log it.
        case completed(authKey: Data, macAddress: String)
        case failed(LocalBinderFailure)
    }

    private enum Step: Sendable {
        case awaitingBindInfo
        case awaitingDeviceVerify(macAddress: String)
        case awaitingConfirmation(keys: LocalBinding.Keys, macAddress: String)
        case awaitingFinalAcknowledgement(authKey: Data, macAddress: String)
        case finished
    }

    private enum BandErrorCode {
        static let success = 0
        static let alreadyBound = 1
        static let cancelled = 6
        static let signatureRejected = 7
    }

    private static let buttonConfirmationMode = 3
    private static let supportedConfirmationModes: Set<Int> = [0, 2, buttonConfirmationMode]

    private let identity: Identity
    private let keyPair: LocalBinding.KeyPair
    private let appRandom: Data
    private let triesLocalModeAnyway: Bool
    private var step = Step.awaitingBindInfo

    public init(
        identity: Identity,
        keyPair: LocalBinding.KeyPair = LocalBinding.KeyPair(),
        appRandom: Data = Data((0..<LocalBinding.randomLength).map { _ in UInt8.random(in: .min ... .max) }),
        triesLocalModeAnyway: Bool = false
    ) {
        self.identity = identity
        self.keyPair = keyPair
        self.appRandom = appRandom
        self.triesLocalModeAnyway = triesLocalModeAnyway
    }

    /// The phone's public key for this attempt (not secret).
    public var publicKey: Data { keyPair.publicKey }

    public func start() -> [Action] {
        [.send(BindingCommand.bindInfoRequest(userID: identity.userID))]
    }

    public mutating func handle(_ reply: BindingReply) -> [Action] {
        let outcome = Self.advance(
            from: step, reply: reply, identity: identity, keyPair: keyPair,
            appRandom: appRandom, triesLocalModeAnyway: triesLocalModeAnyway
        )
        step = outcome.next
        return outcome.actions
    }

    private static func advance(
        from step: Step,
        reply: BindingReply,
        identity: Identity,
        keyPair: LocalBinding.KeyPair,
        appRandom: Data,
        triesLocalModeAnyway: Bool
    ) -> (next: Step, actions: [Action]) {
        switch (step, reply) {
        case (.finished, _):
            return (.finished, [])

        case (.awaitingBindInfo, .bindInfo(let info)):
            return begin(with: info, identity: identity, keyPair: keyPair, triesLocalModeAnyway: triesLocalModeAnyway)

        case (.awaitingDeviceVerify(let macAddress), .deviceVerify(let publicKey, let random, let signature)):
            return confirm(
                devicePublicKey: publicKey, deviceRandom: random, deviceSignature: signature,
                macAddress: macAddress, keyPair: keyPair, appRandom: appRandom
            )

        case (.awaitingConfirmation, .confirmResult(false)):
            return (step, [])

        case (.awaitingConfirmation(let keys, let macAddress), .confirmResult(true)):
            return sendBindResult(keys: keys, macAddress: macAddress, identity: identity)

        case (.awaitingFinalAcknowledgement(let authKey, let macAddress), .acknowledged),
             (.awaitingFinalAcknowledgement(let authKey, let macAddress), .error(BandErrorCode.success)):
            return (.finished, [.completed(authKey: authKey, macAddress: macAddress)])

        case (_, .error(let code)):
            return fail(failure(forBandError: code))

        default:
            return fail(.unexpectedReply)
        }
    }

    private static func begin(
        with info: BindInfo,
        identity: Identity,
        keyPair: LocalBinding.KeyPair,
        triesLocalModeAnyway: Bool
    ) -> (next: Step, actions: [Action]) {
        switch info.verifyMode {
        case .serverAssisted where !triesLocalModeAnyway:
            return fail(.serverAssistedPairingRequired)
        case .unknown(let mode):
            return fail(.unsupportedVerifyMode(mode))
        case .local, .serverAssisted:
            guard supportedConfirmationModes.contains(info.outOfBandMode) else {
                return fail(.unsupportedConfirmationMode(info.outOfBandMode))
            }
            let verify = BindingCommand.appVerify(appDeviceID: identity.appDeviceID, publicKey: keyPair.publicKey)
            let prompt: [Action] = info.outOfBandMode == buttonConfirmationMode ? [.askUserToConfirmOnBand] : []
            return (.awaitingDeviceVerify(macAddress: info.macAddress), [.send(verify)] + prompt)
        }
    }

    private static func confirm(
        devicePublicKey: Data,
        deviceRandom: Data,
        deviceSignature: Data,
        macAddress: String,
        keyPair: LocalBinding.KeyPair,
        appRandom: Data
    ) -> (next: Step, actions: [Action]) {
        guard let sharedSecret = try? keyPair.sharedSecret(withDevicePublicKey: devicePublicKey) else {
            return fail(.deviceKeyInvalid)
        }
        guard LocalBinding.isValidDeviceSignature(
            deviceSignature, sharedSecret: sharedSecret, deviceRandom: deviceRandom, outOfBandCode: nil
        ) else {
            return fail(.deviceSignatureInvalid)
        }
        guard let keys = try? LocalBinding.deriveKeys(
            sharedSecret: sharedSecret, appRandom: appRandom, deviceRandom: deviceRandom
        ) else {
            return fail(.deviceKeyInvalid)
        }
        let signature = LocalBinding.appSignature(sharedSecret: sharedSecret, appRandom: appRandom, outOfBandCode: nil)
        let command = BindingCommand.appConfirm(appRandom: appRandom, signature: signature)
        return (.awaitingConfirmation(keys: keys, macAddress: macAddress), [.send(command)])
    }

    private static func sendBindResult(
        keys: LocalBinding.Keys,
        macAddress: String,
        identity: Identity
    ) -> (next: Step, actions: [Action]) {
        let plaintext = BindingCommand.bindResultPlaintext(
            userID: identity.userID, systemVersion: identity.systemVersion, phoneModel: identity.phoneModel
        )
        guard let sealed = try? LocalBinding.sealBindResult(plaintext, keys: keys) else {
            return fail(.encodingFailed)
        }
        let next = Step.awaitingFinalAcknowledgement(authKey: keys.authKey, macAddress: macAddress)
        return (next, [.send(BindingCommand.bindResult(sealed: sealed))])
    }

    private static func failure(forBandError code: Int) -> LocalBinderFailure {
        switch code {
        case BandErrorCode.alreadyBound: .alreadyBound
        case BandErrorCode.cancelled: .cancelledOnBand
        case BandErrorCode.signatureRejected: .deviceSignatureInvalid
        default: .bandReportedError(code)
        }
    }

    private static func fail(_ failure: LocalBinderFailure) -> (next: Step, actions: [Action]) {
        (.finished, [.failed(failure)])
    }
}
