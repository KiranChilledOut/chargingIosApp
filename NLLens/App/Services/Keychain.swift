import Foundation
import Security

/// Keychain storage for the Nebius API key.
///
/// The key is not in `UserDefaults` because App Group defaults are a plain
/// plist inside the container, readable by anything that can reach the
/// filesystem, and not in a build setting because that would put it in a file
/// in the repo. It is typed into Settings once and survives the weekly
/// re-signing a free developer account requires.
public enum Keychain {

    private static let service = "com.nllens.nebius"
    private static let account = "api-key"

    public static func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteAPIKey()
            return
        }
        guard let data = trimmed.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // Available in the background so an App Intent can run while locked
        // is *not* wanted here; require a first unlock instead.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public static func apiKey() -> String? {
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
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    public static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// The key, or an empty string when none has been set.
    ///
    /// Deliberately keychain-only: a build-setting fallback would mean the key
    /// lives in a file in the repo, and the keychain survives the weekly
    /// re-signing a free developer account requires.
    public static func resolvedAPIKey() -> String {
        apiKey() ?? ""
    }
}
