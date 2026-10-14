import Foundation
import Security

enum BandKeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Stores the band's long-term auth key. It never leaves the Keychain except to
/// derive session keys, and is kept on this device only (no iCloud sync, no backup
/// to another phone).
enum BandKeychain {
    private static let service = "com.band10health.band"
    private static let authKeyAccount = "authkey"

    static func saveAuthKey(_ key: Data) throws(BandKeychainError) {
        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw .unexpectedStatus(deleteStatus)
        }
        let attributes: [String: Any] = [
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw .unexpectedStatus(addStatus)
        }
    }

    /// Returns nil when no band has been paired yet.
    static func loadAuthKey() throws(BandKeychainError) -> Data? {
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

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: authKeyAccount,
        ]
    }
}
