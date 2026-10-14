import CryptoKit
import Foundation
import Testing
@testable import Band10Kit

// Expected values come from Python's `cryptography` library, following the flow
// recovered from Mi Fitness 3.46.1 (`com.xiaomi.fit.device.bind.LocalWearBinderV2`).

@Suite("Local binding crypto")
struct LocalBindingTests {
    private let appPrivateKey = Data(repeating: 0x11, count: 32)
    private let appPublicKey = Data(hex: "0217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed194a7debcb97712d2dda3ca85aa8765a56f45fc758599652f2897c65306e5794")
    private let devicePublicKey = Data(hex: "d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf350185e895372df6221ea3a137557e473fddb6755f05bd507c3c533fce9c91285")
    private let sharedSecret = Data(hex: "ccfc261f58193c98ca4ad4a53bbac6f0ee29bc4d48438090446908622ca79af6")
    private let appRandom = Data(hex: "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
    private let deviceRandom = Data(hex: "d0d1d2d3d4d5d6d7d8d9dadbdcdddedf")
    private let deviceSignature = Data(hex: "1f300e94f7f6cd025171d235da81d390052336f7b92a58204a93287c1b1a7be6")

    private func makeKeyPair() throws -> LocalBinding.KeyPair {
        try LocalBinding.KeyPair(privateKey: appPrivateKey)
    }

    @Test("exposes the public key as the raw 64-byte X||Y point the band expects")
    func exposesRawPublicKey() throws {
        #expect(try makeKeyPair().publicKey == appPublicKey)
    }

    @Test("generates a fresh key pair each time")
    func generatesDistinctKeyPairs() {
        #expect(LocalBinding.KeyPair().publicKey != LocalBinding.KeyPair().publicKey)
    }

    @Test("agrees on the same shared secret as the band")
    func computesSharedSecret() throws {
        #expect(try makeKeyPair().sharedSecret(withDevicePublicKey: devicePublicKey) == sharedSecret)
    }

    @Test("rejects a device public key that is not a point on the curve")
    func rejectsInvalidDevicePublicKey() throws {
        let keyPair = try makeKeyPair()

        #expect(throws: LocalBindingError.invalidDevicePublicKey) {
            try keyPair.sharedSecret(withDevicePublicKey: Data(repeating: 0xFF, count: 64))
        }
    }

    @Test("rejects a device public key of the wrong length")
    func rejectsShortDevicePublicKey() throws {
        let keyPair = try makeKeyPair()

        #expect(throws: LocalBindingError.invalidDevicePublicKey) {
            try keyPair.sharedSecret(withDevicePublicKey: Data(count: 63))
        }
    }

    @Test("accepts the signature a band holding the shared secret would send")
    func acceptsGenuineDeviceSignature() {
        #expect(LocalBinding.isValidDeviceSignature(
            deviceSignature, sharedSecret: sharedSecret, deviceRandom: deviceRandom, outOfBandCode: nil
        ))
    }

    @Test("includes the out-of-band code in the signature when one is used")
    func acceptsSignatureWithOutOfBandCode() {
        let withCode = Data(hex: "fdc81891336bd129e4368ef3bf3137431daf87d613db32492cd2e288c2e678dd")

        #expect(LocalBinding.isValidDeviceSignature(
            withCode, sharedSecret: sharedSecret, deviceRandom: deviceRandom, outOfBandCode: "123456"
        ))
        #expect(!LocalBinding.isValidDeviceSignature(
            withCode, sharedSecret: sharedSecret, deviceRandom: deviceRandom, outOfBandCode: nil
        ))
    }

    @Test("rejects a device signature with a flipped bit")
    func rejectsForgedDeviceSignature() {
        let forged = Data([deviceSignature[0] ^ 0x80]) + deviceSignature.dropFirst()

        #expect(!LocalBinding.isValidDeviceSignature(
            forged, sharedSecret: sharedSecret, deviceRandom: deviceRandom, outOfBandCode: nil
        ))
    }

    @Test("signs the app's random the same way")
    func signsAppRandom() {
        let signature = LocalBinding.appSignature(sharedSecret: sharedSecret, appRandom: appRandom, outOfBandCode: nil)

        #expect(signature == Data(hex: "ca9a6940d3cc3a9d3336151b3d58a4c28854eccaee2cbb140df2f5008fa9a841"))
    }

    @Test("derives the bind keys and the long-term auth key from the shared secret and both randoms")
    func derivesBindingKeys() throws {
        // Act
        let keys = try LocalBinding.deriveKeys(sharedSecret: sharedSecret, appRandom: appRandom, deviceRandom: deviceRandom)

        // Assert: slices of 1f87b329…34e8d429, the 64-byte HKDF output.
        #expect(keys.decryptionKey == Data(hex: "1f87b3292fbcf82bdb183321f3b299af"))
        #expect(keys.encryptionKey == Data(hex: "c5710581583e8e5288dc675fb6380e00"))
        #expect(keys.decryptionNonce == Data(hex: "7141276f"))
        #expect(keys.encryptionNonce == Data(hex: "c3294e87"))
        #expect(keys.authKey == Data(hex: "8de2fdfe86bf7cad4f262db393d7084f"))
    }

    @Test("rejects randoms that are not sixteen bytes")
    func rejectsShortRandom() {
        #expect(throws: LocalBindingError.invalidRandomLength(3)) {
            try LocalBinding.deriveKeys(sharedSecret: sharedSecret, appRandom: Data(count: 3), deviceRandom: deviceRandom)
        }
    }

    @Test("seals the bind result under the bind label with the protocol's fixed nonce")
    func sealsBindResult() throws {
        // Arrange: same key and message as the associated-data reference vector.
        let keys = LocalBinding.Keys(
            decryptionKey: Data(count: 16),
            encryptionKey: Data(hex: "7ca5c034b253c81caac5d66234371870"),
            decryptionNonce: Data(count: 4),
            encryptionNonce: Data(count: 4),
            authKey: Data(count: 16)
        )
        let message = Data((0..<5).map { UInt8($0) })

        // Act
        let sealed = try LocalBinding.sealBindResult(message, keys: keys)

        // Assert
        #expect(sealed == Data(hex: "d331510d221f22fd6f"))
    }
}
