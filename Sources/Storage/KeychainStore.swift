import Foundation
import Security

/// Generic-password storage for engine API keys, keyed by profile UUID.
///
/// M5 note: `preferSynchronizable` opts into iCloud Keychain
/// (`kSecAttrSynchronizable` + data-protection keychain). That path needs the
/// app to be signed with a provisioning profile carrying
/// `keychain-access-groups`; until then every call falls back to the legacy
/// file keychain, which needs no entitlements.
final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()

    private let service = "dev.bobby.DuoTranslator"
    /// Flipped on in M5 once provisioning profiles are in place.
    var preferSynchronizable = false
    private(set) var syncUnavailable = false

    func secret(for id: UUID) -> String? {
        // Look in both the synchronizable and local variants.
        for synchronizable in [true, false] {
            var query = baseQuery(account: id.uuidString, synchronizable: synchronizable)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data,
               let value = String(data: data, encoding: .utf8) {
                return value
            }
        }
        return nil
    }

    /// Cheap existence check for the settings UI (does an engine have a key
    /// configured?). Omits `kSecReturnData`, so it never decrypts the value or
    /// triggers an interactive keychain prompt.
    func hasSecret(for id: UUID) -> Bool {
        for synchronizable in [true, false] {
            var query = baseQuery(account: id.uuidString, synchronizable: synchronizable)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
                return true
            }
        }
        return false
    }

    func setSecret(_ value: String?, for id: UUID) {
        // Pasted keys often carry a trailing newline, which would corrupt the
        // auth header rather than fail cleanly.
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            deleteSecret(for: id)
            return
        }
        let data = Data(value.utf8)

        if preferSynchronizable {
            let status = upsert(account: id.uuidString, data: data, synchronizable: true)
            if status == errSecSuccess {
                // Remove any stale local copy so reads stay unambiguous.
                delete(account: id.uuidString, synchronizable: false)
                syncUnavailable = false
                return
            }
            if status == errSecMissingEntitlement {
                syncUnavailable = true
                Log.sync.warning("Synchronizable keychain unavailable (missing entitlement); storing locally")
            }
        }
        _ = upsert(account: id.uuidString, data: data, synchronizable: false)
    }

    func deleteSecret(for id: UUID) {
        delete(account: id.uuidString, synchronizable: true)
        delete(account: id.uuidString, synchronizable: false)
    }

    // MARK: - Internals

    private func baseQuery(account: String, synchronizable: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func upsert(account: String, data: Data, synchronizable: Bool) -> OSStatus {
        var add = baseQuery(account: account, synchronizable: synchronizable)
        add[kSecValueData as String] = data
        if synchronizable {
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query = baseQuery(account: account, synchronizable: synchronizable)
            let update: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
        return status
    }

    private func delete(account: String, synchronizable: Bool) {
        SecItemDelete(baseQuery(account: account, synchronizable: synchronizable) as CFDictionary)
    }
}
