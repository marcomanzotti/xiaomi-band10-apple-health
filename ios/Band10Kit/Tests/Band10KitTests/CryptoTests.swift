import Foundation
import Testing
@testable import Band10Kit

// Expected values come from an independent Python port of Gadgetbridge's
// `XiaomiAuthService`, cross-checked against library HKDF, AES-CTR and AES-CCM.

@Suite("Session key derivation")
struct SessionKeysTests {
    private let authKey = Data(hex: "000102030405060708090a0b0c0d0e0f")
    private let phoneNonce = Data(hex: "00112233445566778899aabbccddeeff")
    private let watchNonce = Data(hex: "ffeeddccbbaa99887766554433221100")
    private let watchProof = Data(hex: "2fd5de8be55c663a3cd56464c401cdeff512b6f072c48a7fa8fc524c4b9b2a23")

    private func deriveKeys() throws -> SessionKeys {
        try SessionKeys.derive(authKey: authKey, phoneNonce: phoneNonce, watchNonce: watchNonce)
    }

    @Test("derives the four session secrets from the auth key and both nonces")
    func derivesSessionSecrets() throws {
        // Act
        let keys = try deriveKeys()

        // Assert
        #expect(keys.decryptionKey == Data(hex: "40892431c57653d6756152a367c2144f"))
        #expect(keys.encryptionKey == Data(hex: "7ca5c034b253c81caac5d66234371870"))
        #expect(keys.decryptionNonce == Data(hex: "e29dfde0"))
        #expect(keys.encryptionNonce == Data(hex: "38d4b6f2"))
    }

    @Test("accepts the proof a band holding the same auth key would send")
    func acceptsGenuineWatchProof() throws {
        let keys = try deriveKeys()

        #expect(keys.isValidWatchProof(watchProof, phoneNonce: phoneNonce, watchNonce: watchNonce))
    }

    @Test("rejects a watch proof with a single flipped bit")
    func rejectsForgedWatchProof() throws {
        let keys = try deriveKeys()
        let forged = watchProof.dropLast() + Data([watchProof[watchProof.count - 1] ^ 0x01])

        #expect(!keys.isValidWatchProof(forged, phoneNonce: phoneNonce, watchNonce: watchNonce))
    }

    @Test("rejects a watch proof computed with the nonces in the wrong order")
    func rejectsProofWithSwappedNonces() throws {
        let keys = try deriveKeys()

        #expect(!keys.isValidWatchProof(watchProof, phoneNonce: watchNonce, watchNonce: phoneNonce))
    }

    @Test("computes the proof the phone sends back")
    func computesPhoneProof() throws {
        let proof = try deriveKeys().phoneProof(phoneNonce: phoneNonce, watchNonce: watchNonce)

        #expect(proof == Data(hex: "39d2a1e2e53a187cecf1f3243ec27eb660dae8450c89f653e2fa18ebfe02b700"))
    }

    @Test("rejects an auth key that is not sixteen bytes")
    func rejectsShortAuthKey() {
        #expect(throws: SessionKeysError.invalidAuthKeyLength(2)) {
            try SessionKeys.derive(authKey: Data(hex: "0001"), phoneNonce: phoneNonce, watchNonce: watchNonce)
        }
    }

    @Test("rejects a phone nonce that is not sixteen bytes")
    func rejectsShortPhoneNonce() {
        #expect(throws: SessionKeysError.invalidNonceLength(1)) {
            try SessionKeys.derive(authKey: authKey, phoneNonce: Data(hex: "00"), watchNonce: watchNonce)
        }
    }

    @Test("rejects a watch nonce that is not sixteen bytes")
    func rejectsLongWatchNonce() {
        #expect(throws: SessionKeysError.invalidNonceLength(17)) {
            try SessionKeys.derive(authKey: authKey, phoneNonce: phoneNonce, watchNonce: Data(count: 17))
        }
    }
}

@Suite("AES counter mode")
struct AESCounterModeTests {
    private let key = Data(hex: "7ca5c034b253c81caac5d66234371870")
    private let plaintext = Data(hex: "62616e643130207265666572656e6365207061796c6f616420000102")
    private let ciphertext = Data(hex: "dc1fce72199c4bdf248331f0f3520465a090ed15231e71cb7e6f2547")
    private let threeBlockMessage = Data((0..<40).map { UInt8($0) })

    @Test("encrypts with the key as initial counter, as the band's transport does")
    func encrypts() throws {
        #expect(try AESCipher.counterMode(plaintext, key: key, initialCounter: key) == ciphertext)
    }

    @Test("is its own inverse")
    func decrypts() throws {
        #expect(try AESCipher.counterMode(ciphertext, key: key, initialCounter: key) == plaintext)
    }

    @Test("carries from the lowest counter byte into the next one")
    func carriesOneByte() throws {
        let counter = Data(count: 15) + Data([0xFF])
        let expected = Data(hex: "b1ab0c950a55d58badff993285fbeffedf9ec37c496540545803253125b7efa3b850513fba25e184")

        #expect(try AESCipher.counterMode(threeBlockMessage, key: key, initialCounter: counter) == expected)
    }

    @Test("wraps an all-ones counter around to zero")
    func wrapsAround() throws {
        let counter = Data(repeating: 0xFF, count: 16)
        let expected = Data(hex: "06fca9b3d11fc80324f7195549dedd3f9c82d23b19414cc2a5cc7c68684dc8c07b352602b00a7b0f")

        #expect(try AESCipher.counterMode(threeBlockMessage, key: key, initialCounter: counter) == expected)
    }

    @Test("accepts a slice that does not start at index zero")
    func acceptsSlices() throws {
        let padded = Data(hex: "ffff") + plaintext

        #expect(try AESCipher.counterMode(padded.dropFirst(2), key: key, initialCounter: key) == ciphertext)
    }

    @Test("returns nothing for an empty message")
    func emptyMessage() throws {
        #expect(try AESCipher.counterMode(Data(), key: key, initialCounter: key).isEmpty)
    }

    @Test("rejects a key that is not sixteen bytes")
    func rejectsShortKey() {
        #expect(throws: AESCipherError.invalidKeyLength(8)) {
            try AESCipher.counterMode(plaintext, key: Data(count: 8), initialCounter: key)
        }
    }

    @Test("rejects a counter that is not one block long")
    func rejectsShortCounter() {
        #expect(throws: AESCipherError.invalidCounterLength(4)) {
            try AESCipher.counterMode(plaintext, key: key, initialCounter: Data(count: 4))
        }
    }
}

@Suite("AES-CCM with a 12-byte nonce and 4-byte tag")
struct AESCCMTests {
    private let key = Data(hex: "7ca5c034b253c81caac5d66234371870")
    private let nonce = Data(hex: "38d4b6f20000000000000000")
    private let plaintext = Data(hex: "62616e643130207265666572656e6365207061796c6f616420000102")
    private let sealed = Data(hex: "b29ff5f96610926bef013df45b8451483662842a6015bf22520da3ab57600199")

    @Test("seal appends a four byte tag")
    func seals() throws {
        #expect(try AESCipher.ccmSeal(plaintext, key: key, nonce: nonce) == sealed)
    }

    @Test("open returns the plaintext")
    func opens() throws {
        #expect(try AESCipher.ccmOpen(sealed, key: key, nonce: nonce) == plaintext)
    }

    @Test(
        "matches the reference at block-boundary message sizes",
        arguments: [
            (0, "3d0bc375"),
            (1, "d00cd5038e"),
            (16, "d0ff999e5325b41e826e528d32e73c221a965dad"),
            (32, "d0ff999e5325b41e826e528d32e73c220603f740186fc8516a14b8b2c310aa8f5358d2c6"),
        ]
    )
    func matchesReference(size: Int, expectedHex: String) throws {
        // Arrange
        let message = Data((0..<size).map { UInt8($0) })
        let expected = Data(hex: expectedHex)

        // Act
        let sealedMessage = try AESCipher.ccmSeal(message, key: key, nonce: nonce)
        let opened = try AESCipher.ccmOpen(expected, key: key, nonce: nonce)

        // Assert
        #expect(sealedMessage == expected)
        #expect(opened == message)
    }

    @Test("open rejects a flipped bit anywhere in the message or tag", arguments: [0, 13, 27, 28, 31])
    func rejectsTampering(at index: Int) {
        let tampered = sealed.prefix(index) + Data([sealed[index] ^ 0x01]) + sealed.dropFirst(index + 1)

        #expect(throws: AESCipherError.authenticationFailed) {
            try AESCipher.ccmOpen(tampered, key: key, nonce: nonce)
        }
    }

    @Test("open rejects the right message under the wrong nonce")
    func rejectsWrongNonce() {
        #expect(throws: AESCipherError.authenticationFailed) {
            try AESCipher.ccmOpen(sealed, key: key, nonce: Data(count: 12))
        }
    }

    @Test("open rejects the right message under the wrong key")
    func rejectsWrongKey() {
        #expect(throws: AESCipherError.authenticationFailed) {
            try AESCipher.ccmOpen(sealed, key: Data(count: 16), nonce: nonce)
        }
    }

    @Test("open accepts a slice that does not start at index zero")
    func opensSlices() throws {
        let padded = Data(hex: "ffff") + sealed

        #expect(try AESCipher.ccmOpen(padded.dropFirst(2), key: key, nonce: nonce) == plaintext)
    }

    @Test("open rejects input shorter than the tag")
    func rejectsTruncatedInput() {
        #expect(throws: AESCipherError.messageTooShort(3)) {
            try AESCipher.ccmOpen(Data(hex: "010203"), key: key, nonce: nonce)
        }
    }

    @Test("refuses nonce lengths other than the band's twelve bytes")
    func rejectsOtherNonceLengths() {
        #expect(throws: AESCipherError.invalidNonceLength(13)) {
            try AESCipher.ccmSeal(plaintext, key: key, nonce: Data(count: 13))
        }
    }

    @Test("refuses a message the three-byte length field cannot describe")
    func rejectsOversizedMessage() {
        let tooLong = AESCipher.ccmMaxMessageLength + 1

        #expect(throws: AESCipherError.messageTooLong(tooLong)) {
            try AESCipher.ccmSeal(Data(count: tooLong), key: key, nonce: nonce)
        }
    }

    @Test("rejects a key that is not sixteen bytes")
    func rejectsShortKey() {
        #expect(throws: AESCipherError.invalidKeyLength(8)) {
            try AESCipher.ccmSeal(plaintext, key: Data(count: 8), nonce: nonce)
        }
    }
}

@Suite("AES-CCM with associated data")
struct AESCCMAssociatedDataTests {
    private let key = Data(hex: "7ca5c034b253c81caac5d66234371870")
    private let nonce = Data(hex: "101112131415161718191a1b")
    private let bindLabel = Data("bind-data".utf8)

    @Test(
        "matches the reference when the bind label is authenticated alongside the message",
        arguments: [
            (0, "d0a89496"),
            (5, "d331510d221f22fd6f"),
            (16, "d331510d22c23aad31266c5193a8996d24133fc8"),
            (33, "d331510d22c23aad31266c5193a8996d443dd67cf9c79ac9f2148e2373741f394c89d13150"),
        ]
    )
    func matchesReference(size: Int, expectedHex: String) throws {
        // Arrange
        let message = Data((0..<size).map { UInt8($0) })
        let expected = Data(hex: expectedHex)

        // Act
        let sealed = try AESCipher.ccmSeal(message, key: key, nonce: nonce, associatedData: bindLabel)
        let opened = try AESCipher.ccmOpen(expected, key: key, nonce: nonce, associatedData: bindLabel)

        // Assert
        #expect(sealed == expected)
        #expect(opened == message)
    }

    @Test("matches the reference when the associated data spans more than one block")
    func matchesReferenceForLongAssociatedData() throws {
        let message = Data((0..<20).map { UInt8($0) })
        let associatedData = Data((0..<30).map { UInt8($0) })
        let expected = Data(hex: "d331510d22c23aad31266c5193a8996d443dd67cb626f6b1")

        #expect(try AESCipher.ccmSeal(message, key: key, nonce: nonce, associatedData: associatedData) == expected)
    }

    @Test("open rejects a message sealed under different associated data")
    func rejectsWrongAssociatedData() {
        let sealed = Data(hex: "d331510d221f22fd6f")

        #expect(throws: AESCipherError.authenticationFailed) {
            try AESCipher.ccmOpen(sealed, key: key, nonce: nonce, associatedData: Data("bind-dat0".utf8))
        }
    }

    @Test("open rejects a message sealed with associated data when none is supplied")
    func rejectsMissingAssociatedData() {
        let sealed = Data(hex: "d331510d221f22fd6f")

        #expect(throws: AESCipherError.authenticationFailed) {
            try AESCipher.ccmOpen(sealed, key: key, nonce: nonce)
        }
    }

    @Test("refuses associated data too long for the two-byte length encoding")
    func rejectsOversizedAssociatedData() {
        let tooLong = AESCipher.ccmMaxAssociatedDataLength + 1

        #expect(throws: AESCipherError.associatedDataTooLong(tooLong)) {
            try AESCipher.ccmSeal(Data(), key: key, nonce: nonce, associatedData: Data(count: tooLong))
        }
    }
}
