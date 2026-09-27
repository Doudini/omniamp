import Foundation
import Security

/// Tiny generic-password wrapper (service "OmniAmp").
enum Keychain {
    /// OMNIAMP_KEYCHAIN_SERVICE lets tests use their own entries, so they never touch a real login.
    private static var service: String { ProcessInfo.processInfo.environment["OMNIAMP_KEYCHAIN_SERVICE"] ?? "OmniAmp" }

    static func get(_ account: String) -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String?) {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(base as CFDictionary)
        guard let v = value, let data = v.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
