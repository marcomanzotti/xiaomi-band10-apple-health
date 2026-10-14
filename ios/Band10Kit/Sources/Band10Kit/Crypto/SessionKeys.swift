// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Protocol behaviour derived from Gadgetbridge (XiaomiAuthService), AGPL-3.0.

import CryptoKit
import Foundation

public enum SessionKeysError: Error, Equatable, Sendable {
    case invalidAuthKeyLength(Int)
    case invalidNonceLength(Int)
}

/// Per-connection secrets negotiated during the encrypted handshake.
///
/// Both sides run HKDF-SHA256 with the two handshake nonces as salt, the
/// per-pairing auth key as input and the label `miwear-auth`, then split the
/// 64 output bytes into two AES keys and two nonce prefixes.
public struct SessionKeys: Sendable {
    public static let authKeyLength = 16
    public static let nonceLength = 16

    private static let derivationLabel = Data("miwear-auth".utf8)
    private static let derivedLength = 64
    private static let keyLength = 16
    private static let noncePrefixLength = 4

    /// Decrypts what the band sends.
    public let decryptionKey: Data
    /// Encrypts what the phone sends.
    public let encryptionKey: Data
    public let decryptionNonce: Data
    public let encryptionNonce: Data

    public static func derive(
        authKey: Data,
        phoneNonce: Data,
        watchNonce: Data
    ) throws(SessionKeysError) -> SessionKeys {
        guard authKey.count == authKeyLength else {
            throw .invalidAuthKeyLength(authKey.count)
        }
        guard phoneNonce.count == nonceLength else {
            throw .invalidNonceLength(phoneNonce.count)
        }
        guard watchNonce.count == nonceLength else {
            throw .invalidNonceLength(watchNonce.count)
        }

        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: authKey),
            salt: phoneNonce + watchNonce,
            info: derivationLabel,
            outputByteCount: derivedLength
        ).withUnsafeBytes { Data($0) }

        let nonceStart = 2 * keyLength
        return SessionKeys(
            decryptionKey: derived.subdata(in: 0..<keyLength),
            encryptionKey: derived.subdata(in: keyLength..<nonceStart),
            decryptionNonce: derived.subdata(in: nonceStart..<nonceStart + noncePrefixLength),
            encryptionNonce: derived.subdata(in: nonceStart + noncePrefixLength..<nonceStart + 2 * noncePrefixLength)
        )
    }

    /// Checks, in constant time, the HMAC the band sends with its nonce.
    /// A mismatch means the band does not hold the same auth key.
    public func isValidWatchProof(_ received: Data, phoneNonce: Data, watchNonce: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            received,
            authenticating: watchNonce + phoneNonce,
            using: SymmetricKey(data: decryptionKey)
        )
    }

    /// The HMAC the phone returns to prove it derived the same keys.
    public func phoneProof(phoneNonce: Data, watchNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: phoneNonce + watchNonce,
            using: SymmetricKey(data: encryptionKey)
        ))
    }
}
