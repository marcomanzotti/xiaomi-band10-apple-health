import Foundation
import Testing
@testable import Band10Kit

// Plays the band's side of the local pairing with the same primitives, following
// the order of Mi Fitness 3.46.1 (`WearBinderV2` → `LocalWearBinderV2`).

@Suite("Local pairing sequence")
struct LocalBinderTests {
    private let identity = LocalBinder.Identity(
        userID: "1234", appDeviceID: "0123456789abcdef0123456789abcdef", systemVersion: 17.0, phoneModel: "iPhone"
    )
    private let appRandom = Data(hex: "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
    private let deviceRandom = Data(hex: "d0d1d2d3d4d5d6d7d8d9dadbdcdddedf")

    private func makeBinder() throws -> LocalBinder {
        LocalBinder(
            identity: identity,
            keyPair: try LocalBinding.KeyPair(privateKey: Data(repeating: 0x11, count: 32)),
            appRandom: appRandom
        )
    }

    private func makeDeviceKeyPair() throws -> LocalBinding.KeyPair {
        try LocalBinding.KeyPair(privateKey: Data(repeating: 0x22, count: 32))
    }

    private func bindInfo(_ mode: BindInfo.VerifyMode, outOfBandMode: Int = 3) -> BindingReply {
        .bindInfo(BindInfo(
            verifyMode: mode, outOfBandMode: outOfBandMode, macAddress: "AA:BB:CC:DD:EE:FF",
            unknownString2: "", unknownString4: "", unknownBytes6: Data(), unknownString7: ""
        ))
    }

    /// The reply a genuine band would give to the app's public key.
    private func deviceVerify(for binder: LocalBinder, tamperSignature: Bool = false) throws -> (reply: BindingReply, sharedSecret: Data) {
        let device = try makeDeviceKeyPair()
        let sharedSecret = try device.sharedSecret(withDevicePublicKey: binder.publicKey)
        let signature = LocalBinding.appSignature(sharedSecret: sharedSecret, appRandom: deviceRandom, outOfBandCode: nil)
        let sent = tamperSignature ? Data([signature[0] ^ 0x01]) + signature.dropFirst() : signature
        return (.deviceVerify(publicKey: device.publicKey, random: deviceRandom, signature: sent), sharedSecret)
    }

    @Test("starts by asking the band for its bind info")
    func startsWithBindInfoRequest() throws {
        #expect(try makeBinder().start() == [.send(BindingCommand.bindInfoRequest(userID: "1234"))])
    }

    @Test("sends its public key and asks for the on-band confirmation in button mode")
    func answersLocalBindInfo() throws {
        var binder = try makeBinder()

        let actions = binder.handle(bindInfo(.local))

        #expect(actions == [
            .send(BindingCommand.appVerify(appDeviceID: identity.appDeviceID, publicKey: binder.publicKey)),
            .askUserToConfirmOnBand,
        ])
    }

    @Test("does not ask for a button press in the other supported confirmation modes", arguments: [0, 2])
    func skipsConfirmationPrompt(outOfBandMode: Int) throws {
        var binder = try makeBinder()

        let actions = binder.handle(bindInfo(.local, outOfBandMode: outOfBandMode))

        #expect(actions.count == 1)
    }

    @Test("completes the whole exchange and yields the same auth key the band derives")
    func completesHappyPath() throws {
        // Arrange
        var binder = try makeBinder()
        _ = binder.handle(bindInfo(.local))
        let verify = try deviceVerify(for: binder)
        let expectedKeys = try LocalBinding.deriveKeys(
            sharedSecret: verify.sharedSecret, appRandom: appRandom, deviceRandom: deviceRandom
        )

        // Act
        let confirmActions = binder.handle(verify.reply)
        let resultActions = binder.handle(.confirmResult(true))
        let finalActions = binder.handle(.acknowledged)

        // Assert
        let appSignature = LocalBinding.appSignature(sharedSecret: verify.sharedSecret, appRandom: appRandom, outOfBandCode: nil)
        #expect(confirmActions == [.send(BindingCommand.appConfirm(appRandom: appRandom, signature: appSignature))])
        let plaintext = BindingCommand.bindResultPlaintext(userID: "1234", systemVersion: 17.0, phoneModel: "iPhone")
        let sealed = try LocalBinding.sealBindResult(plaintext, keys: expectedKeys)
        #expect(resultActions == [.send(BindingCommand.bindResult(sealed: sealed))])
        #expect(finalActions == [.completed(authKey: expectedKeys.authKey, macAddress: "AA:BB:CC:DD:EE:FF")])
    }

    @Test("accepts error code zero as the band's final acknowledgement")
    func acceptsZeroErrorCodeAsSuccess() throws {
        var binder = try makeBinder()
        _ = binder.handle(bindInfo(.local))
        _ = binder.handle(try deviceVerify(for: binder).reply)
        _ = binder.handle(.confirmResult(true))

        let actions = binder.handle(.error(code: 0))

        guard case .completed = actions.first else {
            Issue.record("expected completion, got \(actions)")
            return
        }
    }

    @Test("keeps waiting when the band reports that confirmation is still pending")
    func waitsWhileUnconfirmed() throws {
        var binder = try makeBinder()
        _ = binder.handle(bindInfo(.local))
        _ = binder.handle(try deviceVerify(for: binder).reply)

        #expect(binder.handle(.confirmResult(false)).isEmpty)
    }

    @Test("stops when the band is already bound")
    func failsWhenAlreadyBound() throws {
        var binder = try makeBinder()

        #expect(binder.handle(.error(code: 1)) == [.failed(.alreadyBound)])
    }

    @Test("stops when the band wants the server-assisted mode")
    func failsOnServerAssistedMode() throws {
        var binder = try makeBinder()

        #expect(binder.handle(bindInfo(.serverAssisted)) == [.failed(.serverAssistedPairingRequired)])
    }

    @Test("can be told to offer the local exchange to a band that asked for the server mode")
    func triesLocalModeWhenForced() throws {
        var binder = LocalBinder(
            identity: identity,
            keyPair: try LocalBinding.KeyPair(privateKey: Data(repeating: 0x11, count: 32)),
            appRandom: appRandom,
            triesLocalModeAnyway: true
        )

        let actions = binder.handle(bindInfo(.serverAssisted))

        #expect(actions.first == .send(BindingCommand.appVerify(appDeviceID: identity.appDeviceID, publicKey: binder.publicKey)))
    }

    @Test("stops on a confirmation mode it does not implement")
    func failsOnUnsupportedConfirmationMode() throws {
        var binder = try makeBinder()

        #expect(binder.handle(bindInfo(.local, outOfBandMode: 1)) == [.failed(.unsupportedConfirmationMode(1))])
    }

    @Test("stops when the band's signature does not verify")
    func failsOnForgedDeviceSignature() throws {
        var binder = try makeBinder()
        _ = binder.handle(bindInfo(.local))

        let actions = binder.handle(try deviceVerify(for: binder, tamperSignature: true).reply)

        #expect(actions == [.failed(.deviceSignatureInvalid)])
    }

    @Test("stops when the user cancels on the band")
    func failsWhenCancelledOnBand() throws {
        var binder = try makeBinder()
        _ = binder.handle(bindInfo(.local))
        _ = binder.handle(try deviceVerify(for: binder).reply)

        #expect(binder.handle(.error(code: 6)) == [.failed(.cancelledOnBand)])
    }

    @Test("stops on a reply that does not belong to the current step")
    func failsOnOutOfOrderReply() throws {
        var binder = try makeBinder()

        #expect(binder.handle(.confirmResult(true)) == [.failed(.unexpectedReply)])
    }

    @Test("ignores everything after it has finished")
    func ignoresRepliesAfterFailure() throws {
        var binder = try makeBinder()
        _ = binder.handle(.error(code: 1))

        #expect(binder.handle(bindInfo(.local)).isEmpty)
    }
}
