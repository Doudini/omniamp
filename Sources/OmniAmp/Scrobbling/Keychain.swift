import Foundation
import Security

/// Tiny generic-password wrapper (service "OmniAmp"). Values are read from the Keychain once and then kept in
/// memory: every read can make macOS ask for permission, and scrobbling needs the login several times per track.
enum Keychain {
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()
    /// OMNIAMP_KEYCHAIN_SERVICE lets tests use their own entries, so they never touch a real login.
    private static var service: String { ProcessInfo.processInfo.environment["OMNIAMP_KEYCHAIN_SERVICE"] ?? "OmniAmp" }

    static func get(_ account: String) -> String? {
        let key = service + "|" + account
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let v = read(account)
        cache[key] = .some(v)   // "not there" is remembered too
        return v
    }

    private static func read(_ account: String) -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String?) {
        lock.lock()
        cache[service + "|" + account] = .some(value)
        lock.unlock()
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(base as CFDictionary)
        guard let v = value, let data = v.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
