import CryptoKit
import Foundation
import Testing
@testable import Band10Kit

// Message layout follows Gadgetbridge's wear_account.proto and XiaomiAuthService;
// key material reuses the session-key reference vectors.

@Suite("Authentication messages")
struct AuthMessagesTests {
    private let nonce = Data(hex: "00112233445566778899aabbccddeeff")

    @Test("sends the phone nonce in an account command of subtype 26")
    func buildsNonceCommand() {
        let expected = Data(hex: "0801" + "101a" + "1a15" + "f20112" + "0a10") + nonce

        #expect(AuthCommand.nonce(nonce) == expected)
    }

    @Test("sends the proof and the sealed phone description in subtype 27")
    func buildsConfirmCommand() {
        let proof = Data(repeating: 0x01, count: 32)
        let sealed = Data(hex: "aabbcc")
        // AppConfirm = 0a20 <32> 1203 aabbcc (39 bytes) in account field 32.
        let expected = Data(hex: "0801" + "101b" + "1a2a" + "820227" + "0a20") + proof + Data(hex: "1203aabbcc")

        #expect(AuthCommand.confirm(proof: proof, sealedCompanion: sealed) == expected)
    }

    @Test("introduces the phone as an iPhone, never as an Android device")
    func buildsCompanionDescription() {
        // device_type IOS = 1; declaring ANDROID (0) made a band unreachable from its iPhone.
        let companion = Authenticator.Companion(systemVersion: 17.0, phoneName: "iPhone", region: "IT")
        let expected = Data(hex: "0801" + "1500008841" + "1a06") + Data("iPhone".utf8) + Data(hex: "2a024954")

        #expect(companion.deviceType == .iOS)
        #expect(AuthCommand.companionDescription(companion) == expected)
    }

    @Test("writes the device type explicitly even when it is zero, and the capability when given")
    func buildsCompanionDescriptionWithAllFields() {
        let companion = Authenticator.Companion(
            deviceType: .android, systemVersion: 17.0, phoneName: "p", region: "IT", appCapability: 224
        )
        let expected = Data(hex: "0800" + "1500008841" + "1a0170" + "20e001" + "2a024954")

        #expect(AuthCommand.companionDescription(companion) == expected)
    }

    @Test("reads the band's nonce and proof")
    func parsesDeviceVerify() throws {
        let watchNonce = Data(repeating: 0x07, count: 16)
        let proof = Data(repeating: 0x08, count: 32)
        let body = Data(hex: "0a10") + watchNonce + Data(hex: "1220") + proof
        let reply = Data(hex: "0801" + "101a" + "1a37" + "fa0134") + body

        #expect(try AuthReply.parse(reply) == .deviceVerify(nonce: watchNonce, proof: proof))
    }

    @Test("reads a subtype 27 reply as the band accepting the session")
    func parsesAccepted() throws {
        #expect(try AuthReply.parse(Data(hex: "0801" + "101b" + "1a05" + "8a020208" + "01")) == .accepted)
    }

    @Test("reports anything else with its subtype and status")
    func parsesRejection() throws {
        #expect(try AuthReply.parse(Data(hex: "0801" + "101a" + "1a02" + "4003")) == .rejected(subtype: 26, status: 3))
    }

    @Test("rejects a command that is not an account command")
    func rejectsOtherTypes() {
        #expect(throws: AuthReplyError.unexpectedCommandType(2)) {
            try AuthReply.parse(Data(hex: "0802" + "1001"))
        }
    }
}

@Suite("Authentication sequence")
struct AuthenticatorTests {
    private let authKey = Data(hex: "000102030405060708090a0b0c0d0e0f")
    private let phoneNonce = Data(hex: "00112233445566778899aabbccddeeff")
    private let watchNonce = Data(hex: "ffeeddccbbaa99887766554433221100")
    private let watchProof = Data(hex: "2fd5de8be55c663a3cd56464c401cdeff512b6f072c48a7fa8fc524c4b9b2a23")
    private let companion = Authenticator.Companion(systemVersion: 17.0, phoneName: "iPhone", region: "IT")

    private func makeAuthenticator(key: Data? = nil) throws -> Authenticator {
        try Authenticator(authKey: key ?? authKey, companion: companion, phoneNonce: phoneNonce)
    }

    @Test("starts by sending the phone nonce")
    func startsWithNonce() throws {
        #expect(try makeAuthenticator().start() == [.send(AuthCommand.nonce(phoneNonce))])
    }

    @Test("answers a genuine band with its own proof and a sealed phone description")
    func answersDeviceVerify() throws {
        // Arrange
        var authenticator = try makeAuthenticator()

        // Act
        let actions = authenticator.handle(.deviceVerify(nonce: watchNonce, proof: watchProof))

        // Assert: reference phone proof, and the sealed part opens to the description.
        let keys = try SessionKeys.derive(authKey: authKey, phoneNonce: phoneNonce, watchNonce: watchNonce)
        let sealNonce = keys.encryptionNonce + Data(count: 8)
        let sealed = try AESCipher.ccmSeal(AuthCommand.companionDescription(companion), key: keys.encryptionKey, nonce: sealNonce)
        let phoneProof = Data(hex: "39d2a1e2e53a187cecf1f3243ec27eb660dae8450c89f653e2fa18ebfe02b700")
        #expect(actions == [.send(AuthCommand.confirm(proof: phoneProof, sealedCompanion: sealed))])
    }

    @Test("hands over a working cipher once the band accepts")
    func authenticates() throws {
        // Arrange
        var authenticator = try makeAuthenticator()
        _ = authenticator.handle(.deviceVerify(nonce: watchNonce, proof: watchProof))

        // Act
        let actions = authenticator.handle(.accepted)

        // Assert: the cipher is the transport's counter mode with each key as its own counter.
        guard case .authenticated(let cipher) = actions.first else {
            Issue.record("expected authentication, got \(actions)")
            return
        }
        let plaintext = Data(hex: "62616e643130207265666572656e6365207061796c6f616420000102")
        #expect(try cipher.encrypt(plaintext) == Data(hex: "dc1fce72199c4bdf248331f0f3520465a090ed15231e71cb7e6f2547"))
        let keys = try SessionKeys.derive(authKey: authKey, phoneNonce: phoneNonce, watchNonce: watchNonce)
        let fromBand = try AESCipher.counterMode(plaintext, key: keys.decryptionKey, initialCounter: keys.decryptionKey)
        #expect(try cipher.decrypt(fromBand) == plaintext)
    }

    @Test("stops when the band's proof shows it holds a different key")
    func failsOnWrongKey() throws {
        var authenticator = try makeAuthenticator(key: Data(repeating: 0x99, count: 16))

        let actions = authenticator.handle(.deviceVerify(nonce: watchNonce, proof: watchProof))

        #expect(actions == [.failed(.keyMismatch)])
    }

    @Test("stops when the band rejects the handshake")
    func failsOnRejection() throws {
        var authenticator = try makeAuthenticator()

        #expect(authenticator.handle(.rejected(subtype: 26, status: 3)) == [.failed(.rejectedByBand(subtype: 26, status: 3))])
    }

    @Test("stops on an acceptance that arrives before the proof exchange")
    func failsOnOutOfOrderAcceptance() throws {
        var authenticator = try makeAuthenticator()

        #expect(authenticator.handle(.accepted) == [.failed(.unexpectedReply)])
    }

    @Test("refuses an auth key that is not sixteen bytes")
    func rejectsShortKey() {
        #expect(throws: AuthenticatorFailure.invalidAuthKey) {
            try Authenticator(authKey: Data(count: 4), companion: companion)
        }
    }

    @Test("ignores replies after it has finished")
    func ignoresRepliesAfterFinishing() throws {
        var authenticator = try makeAuthenticator()
        _ = authenticator.handle(.accepted)

        #expect(authenticator.handle(.accepted).isEmpty)
    }
}

@Suite("System messages")
struct SystemMessagesTests {
    @Test("asks for device info and battery with bare system commands")
    func buildsRequests() {
        #expect(SystemCommand.deviceInfoRequest == Data(hex: "0802" + "1002"))
        #expect(SystemCommand.batteryRequest == Data(hex: "0802" + "1001"))
    }

    @Test("reads serial, firmware and model from a device info reply")
    func parsesDeviceInfo() throws {
        // DeviceInfo{1:"SN", 2:"1.2", 4:"m"} in System field 3, Command field 4.
        let info = "0a02534e" + "1203312e32" + "22016d"
        let reply = Data(hex: "0802" + "1002" + "220e" + "1a0c" + info)

        #expect(try SystemReply.parse(reply) == .deviceInfo(serialNumber: "SN", firmware: "1.2", model: "m"))
    }

    @Test("reads the battery level")
    func parsesBattery() throws {
        // Battery{1: 76} in Power field 1, System field 2, Command field 4.
        let reply = Data(hex: "0802" + "1001" + "2206" + "1204" + "0a02" + "084c")

        #expect(try SystemReply.parse(reply) == .battery(level: 76))
    }

    @Test("reports other system replies by subtype")
    func parsesOther() throws {
        #expect(try SystemReply.parse(Data(hex: "0802" + "1011")) == .other(subtype: 17))
    }

    @Test("rejects a command that is not a system command")
    func rejectsOtherTypes() {
        #expect(throws: SystemReplyError.unexpectedCommandType(1)) {
            try SystemReply.parse(Data(hex: "0801" + "1001"))
        }
    }
}
