import Foundation
import Security

/// The OpenAI API key, kept in the Keychain.
///
/// Not UserDefaults: that file is plain XML in the user's Library, readable by
/// every process running as them and swept up by backups and sync. A key that
/// bills a real account belongs behind the Keychain's access controls, where it
/// is encrypted at rest and tied to this app's code signature.
///
/// The key is only ever read to build an `Authorization` header, and is never
/// logged — see `redacted` for the only form allowed near a log line.
enum APIKeyStore {
    private static let service = "com.murmur.app.openai"
    private static let account = "api-key"

    /// Store (or replace) the key. Passing an empty string deletes it.
    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Available after first unlock so a dictation right after login works,
            // but never migrated to another Mac by a backup.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static var hasKey: Bool { load() != nil }

    /// The only representation of a key that may go near a log or the UI.
    static func redacted(_ key: String) -> String {
        guard key.count > 8 else { return "sk-…" }
        return key.prefix(6) + "…" + key.suffix(4)
    }
}
