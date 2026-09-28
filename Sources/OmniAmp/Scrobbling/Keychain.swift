import Foundation
import Security

/// Tiny generic-password wrapper (service "OmniAmp"). Values are read from the Keychain once and then kept in
/// memory: every read can make macOS ask for permission, and scrobbling needs the login several times per track.
enum Keychain {
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()
    /// After a denied or failed read: don't ask again before this (no prompt storm), but not never either.
    private static var retryAfter: [String: Date] = [:]
    /// OMNIAMP_KEYCHAIN_SERVICE lets tests use their own entries, so they never touch a real login.
    private static var service: String { ProcessInfo.processInfo.environment["OMNIAMP_KEYCHAIN_SERVICE"] ?? "OmniAmp" }

    static func get(_ account: String) -> String? {
        let key = service + "|" + account
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        if let t = retryAfter[key], Date() < t { return nil }
        let (v, status) = read(account)
        // Remember a value, or a definite "not there". Any other outcome (the permission prompt was denied or
        // couldn't be shown) is tried again in 10 minutes: remembering it would log you out until relaunch,
        // asking on every read would prompt for every song.
        if status == errSecSuccess || status == errSecItemNotFound {
            cache[key] = .some(v)
            retryAfter.removeValue(forKey: key)
        } else {
            retryAfter[key] = Date().addingTimeInterval(600)
        }
        return v
    }

    private static func read(_ account: String) -> (String?, OSStatus) {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let d = out as? Data else { return (nil, status) }
        return (String(data: d, encoding: .utf8), status)
    }

    /// Returns false if the Keychain refused the write (the value then isn't cached as saved).
    @discardableResult
    static func set(_ account: String, _ value: String?) -> Bool {
        let key = service + "|" + account
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(base as CFDictionary)
        var ok = true
        if let v = value, let data = v.data(using: .utf8) {
            var add = base
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(add as CFDictionary, nil)
            ok = status == errSecSuccess
            if !ok { NSLog("OmniAmp: couldn't save %@ in the Keychain (%d)", account, status) }
        }
        lock.lock()
        if ok { cache[key] = .some(value) } else { cache.removeValue(forKey: key) }   // read it again next time
        retryAfter.removeValue(forKey: key)
        lock.unlock()
        return ok
    }
}
