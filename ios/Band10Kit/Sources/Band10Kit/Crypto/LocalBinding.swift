// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Behaviour recovered by static analysis of Mi Fitness 3.46.1
// (com.xiaomi.fit.device.bind.LocalWearBinderV2); not derived from Gadgetbridge,
// which does not implement pairing.

import CryptoKit
import Foundation

public enum LocalBindingError: Error, Equatable, Sendable {
    case invalidPrivateKey
    case invalidDevicePublicKey
    case invalidRandomLength(Int)
    case sealingFailed(AESCipherError)
}

/// Cryptography of the band's "local" pairing mode, in which the phone and the
/// band agree on the long-term auth key between themselves over ECDH, with no
/// server involved.
///
/// Flow: exchange P-256 public keys, check the band's HMAC over its random,
/// answer with an HMAC over ours, then derive the keys with HKDF-SHA256.
public enum LocalBinding {
    public static let randomLength = 16

    private static let rawPublicKeyLength = 64
    private static let derivationLabel = Data("miwear-bind".utf8)
    private static let derivedLength = 64
    private static let keyLength = 16
    private static let noncePrefixLength = 4
    private static let bindResultLabel = Data("bind-data".utf8)
    /// Constant nonce the protocol uses for the single bind-result message.
    private static let bindResultNonce = Data((0x10...0x1B).map { UInt8($0) })

    /// The phone's ephemeral P-256 key pair for one pairing attempt.
    public struct KeyPair: Sendable {
        private let privateKey: P256.KeyAgreement.PrivateKey

        public init() {
            privateKey = P256.KeyAgreement.PrivateKey()
        }

        /// Rebuilds a key pair from a raw 32-byte scalar.
        public init(privateKey rawPrivateKey: Data) throws(LocalBindingError) {
            guard let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey) else {
                throw .invalidPrivateKey
            }
            privateKey = key
        }

        /// The public point as raw `X || Y` (64 bytes), the form sent to the band.
        public var publicKey: Data {
            privateKey.publicKey.rawRepresentation
        }

        /// ECDH with the band's raw `X || Y` public key.
        public func sharedSecret(withDevicePublicKey devicePublicKey: Data) throws(LocalBindingError) -> Data {
            guard devicePublicKey.count == LocalBinding.rawPublicKeyLength,
                  let publicKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: devicePublicKey),
                  let secret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            else {
                throw .invalidDevicePublicKey
            }
            return secret.withUnsafeBytes { Data($0) }
        }
    }

    /// Everything derived at the end of a successful local pairing.
    public struct Keys: Sendable {
        public let decryptionKey: Data
        public let encryptionKey: Data
        public let decryptionNonce: Data
        public let encryptionNonce: Data
        /// The long-term secret every later connection authenticates with.
        /// Store it in the Keychain; never log it.
        public let authKey: Data
    }

    /// Checks, in constant time, the band's proof that it holds the shared secret.
    public static func isValidDeviceSignature(
        _ received: Data,
        sharedSecret: Data,
        deviceRandom: Data,
        outOfBandCode: String?
    ) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            received,
            authenticating: signedMessage(random: deviceRandom, outOfBandCode: outOfBandCode),
            using: SymmetricKey(data: sharedSecret)
        )
    }

    /// The phone's matching proof over its own random.
    public static func appSignature(sharedSecret: Data, appRandom: Data, outOfBandCode: String?) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: signedMessage(random: appRandom, outOfBandCode: outOfBandCode),
            using: SymmetricKey(data: sharedSecret)
        ))
    }

    public static func deriveKeys(
        sharedSecret: Data,
        appRandom: Data,
        deviceRandom: Data
    ) throws(LocalBindingError) -> Keys {
        guard appRandom.count == randomLength else {
            throw .invalidRandomLength(appRandom.count)
        }
        guard deviceRandom.count == randomLength else {
            throw .invalidRandomLength(deviceRandom.count)
        }

        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: appRandom + deviceRandom,
            info: derivationLabel,
            outputByteCount: derivedLength
        ).withUnsafeBytes { Data($0) }

        let nonceStart = 2 * keyLength
        let authKeyStart = nonceStart + 2 * noncePrefixLength
        return Keys(
            decryptionKey: derived.subdata(in: 0..<keyLength),
            encryptionKey: derived.subdata(in: keyLength..<nonceStart),
            decryptionNonce: derived.subdata(in: nonceStart..<nonceStart + noncePrefixLength),
            encryptionNonce: derived.subdata(in: nonceStart + noncePrefixLength..<authKeyStart),
            authKey: derived.subdata(in: authKeyStart..<authKeyStart + keyLength)
        )
    }

    /// Encrypts the final bind-result message (phone identity) for the band.
    public static func sealBindResult(_ plaintext: Data, keys: Keys) throws(LocalBindingError) -> Data {
        do {
            return try AESCipher.ccmSeal(
                plaintext,
                key: keys.encryptionKey,
                nonce: bindResultNonce,
                associatedData: bindResultLabel
            )
        } catch {
            throw .sealingFailed(error)
        }
    }

    private static func signedMessage(random: Data, outOfBandCode: String?) -> Data {
        random + Data((outOfBandCode ?? "").utf8)
    }
}
