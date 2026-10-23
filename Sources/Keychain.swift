import Foundation
import Security

/// Storage for the API key the user pastes into the app.
/// The Keychain rather than UserDefaults — a preferences plist is readable by anything
/// running as this user.
enum Keychain {
    private static let service = "com.oeaio.aishell"
    /// Where keys were kept before the app was renamed from TermDefine.
    private static let legacyService = "com.oeaio.termdefine"
    private static let account = "ANTHROPIC_API_KEY"

    private static var baseQuery: [String: Any] { query(service: service) }

    private static func query(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// A key pasted under the old name is moved across the first time it is read.
    static func read() -> String? {
        if let value = read(service: service) { return value }
        guard let legacy = read(service: legacyService) else { return nil }
        if write(legacy) { SecItemDelete(query(service: legacyService) as CFDictionary) }
        return legacy
    }

    private static func read(service: String) -> String? {
        var query = query(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.trimmed.isEmpty
        else { return nil }
        return value.trimmed
    }

    /// Whether a key is stored, without reading it. Reading an item that a differently signed
    /// build wrote makes macOS ask for permission — and blocks until it is answered — whereas
    /// asking for attributes alone never does. So launch and the menu use this, and the key
    /// itself is read only when a request first needs it.
    static var exists: Bool {
        [service, legacyService].contains { service in
            var query = query(service: service)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
        }
    }

    @discardableResult
    static func write(_ value: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)

        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = "AI Shell — Anthropic API key"
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
