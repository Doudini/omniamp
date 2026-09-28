import CryptoKit
import Foundation

/// Last.fm scrobbling (API 2.0, desktop auth flow).
///
/// The app's API key/secret come from the build (Info.plist `LastFMAPIKey`/`LastFMSecret`, injected by
/// scripts/make-app.sh from the untracked secrets.env) or the OMNIAMP_LASTFM_KEY/SECRET environment.
/// Users can use their own key instead (Settings); its secret and the user's session key live in the Keychain.
final class LastFM: ScrobbleService {
    static let shared = LastFM()

    let id = "lastfm"
    let maxBatch = 50
    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    var transport: HTTPTransport = URLSessionTransport()
    private let fixedKey: String?, fixedSecret: String?    // tests
    private let builtInKey: String?, builtInSecret: String?

    init(apiKey: String? = nil, secret: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary
        fixedKey = apiKey
        fixedSecret = secret
        builtInKey = env["OMNIAMP_LASTFM_KEY"] ?? (info?["LastFMAPIKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        builtInSecret = env["OMNIAMP_LASTFM_SECRET"] ?? (info?["LastFMSecret"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: API key: the user's own, or the one built into the app

    /// The user's own API key (Settings), used instead of the built-in one when both key and secret are set.
    var customKey: String? { UserDefaults.standard.string(forKey: "lastfmCustomKey").flatMap { $0.isEmpty ? nil : $0 } }
    /// Read through Keychain's own (locked) cache: this is used from background tasks too.
    private var customSecret: String? { customKey == nil ? nil : Keychain.get("lastfm.customSecret") }
    var usesCustomKey: Bool { fixedKey == nil && customKey != nil && customSecret != nil }
    var hasBuiltInKey: Bool { builtInKey != nil && builtInSecret != nil }

    var apiKey: String? { fixedKey ?? (usesCustomKey ? customKey : builtInKey) }
    var secret: String? { fixedSecret ?? (usesCustomKey ? customSecret : builtInSecret) }

    /// Use your own key (nil or empty = back to the built-in one). A session belongs to the key it was made with,
    /// so this disconnects.
    func setCustomKey(_ key: String?, secret: String?) {
        let k = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let s = secret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let on = !k.isEmpty && !s.isEmpty
        UserDefaults.standard.set(on ? k : nil, forKey: "lastfmCustomKey")
        Keychain.set("lastfm.customSecret", on ? s : nil)
        // A session belongs to its key: reconnect with the new one. Plays wait in the queue meanwhile.
        let was = isConnected || needsReconnect
        disconnect()
        if was { ReconnectMark.set(id, true) }
    }

    /// There's an API key to use (otherwise Last.fm can't be offered).
    var isAvailable: Bool { apiKey != nil && secret != nil }
    var sessionKey: String? { Keychain.get("lastfm.session") }
    var username: String? { UserDefaults.standard.string(forKey: "lastfmUser") }
    var isConnected: Bool { isAvailable && sessionKey != nil }
    var needsReconnect: Bool { !isConnected && ReconnectMark.get(id) }

    // MARK: Signing

    /// api_sig: md5 of the parameters sorted by name, concatenated as name+value, followed by the secret.
    static func signature(_ params: [String: String], secret: String) -> String {
        let s = params.keys.sorted().map { $0 + params[$0]! }.joined() + secret
        return Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func call(_ method: String, _ params: [String: String], signed: Bool = true, post: Bool = true) async throws -> [String: Any] {
        guard let key = apiKey, let secret else { throw ScrobbleError.auth("Last.fm isn't set up in this build") }
        var p = params
        p["method"] = method
        p["api_key"] = key
        if signed { p["api_sig"] = Self.signature(p, secret: secret) }
        p["format"] = "json"   // not part of the signature
        let body = p.keys.sorted().map { "\($0)=\(Self.escape(p[$0]!))" }.joined(separator: "&")
        var req: URLRequest
        if post {
            req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body.utf8)
        } else {
            req = URLRequest(url: URL(string: endpoint.absoluteString + "?" + body)!)
        }
        req.setValue("OmniAmp/1.0", forHTTPHeaderField: "User-Agent")
        let (data, status) = try await transport.send(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let code = json["error"] as? Int {
            let msg = json["message"] as? String ?? "error \(code)"
            // 9 = invalid session (user revoked access): forget it.
            if code == 9 { Keychain.set("lastfm.session", nil); ReconnectMark.set(id, true) }
            // 6 / 7: invalid parameters or resource: that scrobble will never be accepted (auth and outages will).
            if code == 6 || code == 7 { throw ScrobbleError.rejected(msg) }
            throw ScrobbleError.http(status, msg)
        }
        guard (200..<300).contains(status) else { throw ScrobbleError.http(status, String(decoding: data.prefix(200), as: UTF8.self)) }
        return json
    }

    static func escape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Auth (desktop flow: token → user approves in the browser → session)

    /// Step 1: a request token and the page where the user approves OmniAmp.
    func beginAuth() async throws -> (token: String, url: URL) {
        let json = try await call("auth.getToken", [:], post: false)
        guard let token = json["token"] as? String, let key = apiKey,
              let url = URL(string: "https://www.last.fm/api/auth/?api_key=\(key)&token=\(token)") else {
            throw ScrobbleError.auth("Last.fm didn't return a token")
        }
        return (token, url)
    }

    /// Step 2: exchange the approved token for a permanent session (fails until the user approved).
    func finishAuth(token: String) async throws {
        let json = try await call("auth.getSession", ["token": token], post: false)
        guard let session = json["session"] as? [String: Any], let key = session["key"] as? String else {
            throw ScrobbleError.auth("Not approved yet")
        }
        Keychain.set("lastfm.session", key)
        ReconnectMark.set(id, false)
        UserDefaults.standard.set(session["name"] as? String, forKey: "lastfmUser")
    }

    func disconnect() {
        Keychain.set("lastfm.session", nil)
        ReconnectMark.set(id, false)
        UserDefaults.standard.removeObject(forKey: "lastfmUser")
    }

    // MARK: Scrobbling

    func nowPlaying(_ s: Scrobble) async throws {
        guard let sk = sessionKey else { throw ScrobbleError.notConnected }
        var p = ["artist": s.artist, "track": s.title, "sk": sk]
        if let a = s.album { p["album"] = a }
        if let d = s.duration { p["duration"] = String(d) }
        _ = try await call("track.updateNowPlaying", p)
    }

    func submit(_ batch: [Scrobble]) async throws -> Int {
        guard let sk = sessionKey else { throw ScrobbleError.notConnected }
        var p = ["sk": sk]
        for (i, s) in batch.prefix(maxBatch).enumerated() {
            p["artist[\(i)]"] = s.artist
            p["track[\(i)]"] = s.title
            p["timestamp[\(i)]"] = String(s.timestamp)
            if let a = s.album { p["album[\(i)]"] = a }
            if let d = s.duration { p["duration[\(i)]"] = String(d) }
        }
        _ = try await call("track.scrobble", p)
        return min(batch.count, maxBatch)
    }
}
