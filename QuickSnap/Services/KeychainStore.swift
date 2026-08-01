//
//  KeychainStore.swift
//  QuickSnap
//

import Foundation
import Security

/// Minimal generic-password Keychain wrapper. Secrets (currently just the
/// Immich API key) live here rather than in UserDefaults — a defaults plist
/// is world-readable to anything running as the user and gets swept up by
/// backups and sync.
///
/// `nonisolated` like the other Services: the Keychain API is thread-safe,
/// and settings reads happen from whatever context needs them.
nonisolated enum KeychainStore {
    /// Account names — the Keychain equivalent of `AppSettings.Keys`.
    enum Account {
        static let immichAPIKey = "immich.apiKey"
        static let s3SecretKey = "s3.secretAccessKey"
        static let mcpAuthToken = "mcp.authToken"
    }

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain error: \(detail)"
            }
        }
    }

    private static let service = Bundle.main.bundleIdentifier ?? "com.dylanduff.QuickSnap"

    static func string(for account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    /// Writes `value`, or removes the item when it's nil/empty. Upserts:
    /// updates in place if an item already exists, otherwise adds one.
    static func setString(_ value: String?, for account: String) throws {
        guard let value, !value.isEmpty else {
            try remove(account)
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery(for: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
