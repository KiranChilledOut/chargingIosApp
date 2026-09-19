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

    private static let service = "com.nllens.keys"

    /// Which key. Both live in the keychain rather than in a file, and both
    /// survive the weekly re-signing a free developer account requires.
    public enum Account: String {
        case nebius = "nebius-api-key"
        case tavily = "tavily-api-key"
    }

    /// Returns whether the key was actually stored.
    ///
    /// The result used to be discarded. A keychain write can fail, and when it
    /// did the interface still said "Saved" while the old value stayed in
    /// place — invisible, because the field is empty again on the next launch.
    /// A silent failure here looks exactly like a rejected key later.
    @discardableResult
    public static func set(_ key: String, for account: Account = .nebius) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(account)
            return true
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // Available in the background so an App Intent can run while locked
        // is *not* wanted here; require a first unlock instead.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func key(for account: Account = .nebius) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
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

    public static func delete(_ account: Account = .nebius) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// The key, or an empty string when none has been set.
    ///
    /// Deliberately keychain-only: a build-setting fallback would mean the key
    /// lives in a file in the repo, and the keychain survives the weekly
    /// re-signing a free developer account requires.
    public static func resolvedAPIKey() -> String {
        key(for: .nebius) ?? ""
    }

    public static func resolvedSearchKey() -> String {
        key(for: .tavily) ?? ""
    }
}
