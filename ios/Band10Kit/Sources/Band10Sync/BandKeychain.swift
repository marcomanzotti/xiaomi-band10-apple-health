// Band10Sync — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.

import Foundation
import Security

public enum BandKeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    /// The text is not the 32 hexadecimal digits of a band key.
    case invalidKey
}

/// Stores the band's long-term auth key. It never leaves the Keychain except to
/// derive session keys, and is kept on this device only (no iCloud sync, no
/// backup to another phone). It stays readable while the phone is locked, so
/// that the sync can run in the background.
public struct BandKeychain: Sendable {
    private static let authKeyAccount = "authkey"
    private static let authKeyLength = 16

    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func saveAuthKey(_ key: Data) throws(BandKeychainError) {
        guard key.count == Self.authKeyLength else {
            throw .invalidKey
        }
        try removeAuthKey()
        let attributes: [String: Any] = [
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw .unexpectedStatus(status)
        }
    }

    /// Accepts the key as Xiaomi's servers give it: 32 hexadecimal digits.
    public func saveAuthKey(hex: String) throws(BandKeychainError) {
        let digits = Array(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        guard digits.count == 2 * Self.authKeyLength else {
            throw .invalidKey
        }
        let bytes = stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16) }
        guard !bytes.contains(nil) else {
            throw .invalidKey
        }
        try saveAuthKey(Data(bytes.compactMap { $0 }))
    }

    /// Returns nil when no key has been stored yet.
    public func loadAuthKey() throws(BandKeychainError) -> Data? {
        let query: [String: Any] = [
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery.merging(query) { _, new in new } as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw .unexpectedStatus(status)
        }
    }

    public func removeAuthKey() throws(BandKeychainError) {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.authKeyAccount,
        ]
    }
}
