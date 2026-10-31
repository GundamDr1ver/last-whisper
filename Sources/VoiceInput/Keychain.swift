import Foundation
import Security
import LocalAuthentication

private final class CredentialCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func get(_ account: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func set(_ account: String, _ value: String) { lock.lock(); defer { lock.unlock() }; values[account] = value }
}

enum Keychain {
    private static let cache = CredentialCache()
    static let service = "local.voiceinput.api"
    static func read(account: String, interactive: Bool = false) -> String {
        if ProcessInfo.processInfo.arguments.contains("--whisper-smoke") || ProcessInfo.processInfo.arguments.contains("--capture-smoke") { return "" }
        if let value = cache.get(account) { return value }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !interactive {
            let context = LAContext(); context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        let value = String(data: data, encoding: .utf8) ?? ""
        cache.set(account, value)
        return value
    }
    static func save(_ key: String, account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if key.isEmpty { let status = SecItemDelete(query as CFDictionary); if status == errSecSuccess || status == errSecItemNotFound { cache.set(account, ""); return true }; return false }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { cache.set(account, key); return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        if added { cache.set(account, key) }
        return added
    }
}

