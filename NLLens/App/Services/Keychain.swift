import Foundation
import Security

/// Keychain storage for the Nebius API key.
///
/// The key is not in `UserDefaults` because App Group defaults are a plain
/// plist inside the container, readable by anything that can reach the
/// filesystem. It is not in the source either — see `Secrets.xcconfig` in the
/// README.
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

    /// Falls back to a build setting so a fresh install can work before the
    /// key has been typed into Settings.
    public static func resolvedAPIKey() -> String {
        if let stored = apiKey() { return stored }
        if let fromBuild = Bundle.main.object(forInfoDictionaryKey: "NEBIUS_API_KEY") as? String,
           !fromBuild.isEmpty,
           fromBuild != "$(NEBIUS_API_KEY)" {
            return fromBuild
        }
        return ""
    }
}
