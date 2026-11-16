import Foundation
import Security

/// API keys live only in the user's login Keychain (macOS counterpart of the
/// Windows DPAPI credential store). One generic-password item per slot.
public enum KeychainStore {
    public static let service = "STTpro API Key"

    public enum KeychainError: LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            if case .status(let s) = self {
                return (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)"
            }
            return nil
        }
    }

    private static func query(_ slot: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot,
        ]
    }

    public static func save(_ apiKey: String, slot: String) throws {
        let data = Data(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query(slot) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(slot)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "STTpro API key (\(slot))"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func load(slot: String) -> String? {
        var q = query(slot)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    public static func hasKey(slot: String) -> Bool { load(slot: slot) != nil }

    public static func delete(slot: String) {
        SecItemDelete(query(slot) as CFDictionary)
    }

    /// "sk-…abcd" style hint for the UI; never shows the full key.
    public static func maskedHint(slot: String) -> String? {
        guard let key = load(slot: slot) else { return nil }
        return key.count > 8 ? "…" + key.suffix(4) : "saved"
    }
}
