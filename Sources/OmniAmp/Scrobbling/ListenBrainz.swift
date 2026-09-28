import Foundation

/// ListenBrainz scrobbling (open, MetaBrainz). The user pastes their token from listenbrainz.org/settings.
final class ListenBrainz: ScrobbleService {
    static let shared = ListenBrainz()

    let id = "listenbrainz"
    let maxBatch = 100
    var transport: HTTPTransport = URLSessionTransport()
    private let api = "https://api.listenbrainz.org/1/"

    var token: String? { Keychain.get("listenbrainz.token") }
    var username: String? { UserDefaults.standard.string(forKey: Pref.listenbrainzUser) }
    var isConnected: Bool { token != nil }
    var needsReconnect: Bool { !isConnected && ReconnectMark.get(id) }

    private func request(_ path: String, token: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: api + path)!)
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("OmniAmp/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, status) = try await transport.send(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            if status == 401 { Keychain.set("listenbrainz.token", nil); ReconnectMark.set(id, true) }
            let msg = json["error"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self)
            if status == 400 { throw ScrobbleError.rejected(msg) }   // a bad listen, not auth or an outage
            throw ScrobbleError.http(status, msg)
        }
        return json
    }

    /// Check a pasted token; on success it is stored and the user name remembered.
    func connect(token raw: String) async throws {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = try await request("validate-token", token: token)
        guard json["valid"] as? Bool == true, let user = json["user_name"] as? String else {
            throw ScrobbleError.auth(json["message"] as? String ?? "That token isn't valid")
        }
        Keychain.set("listenbrainz.token", token)
        ReconnectMark.set(id, false)
        UserDefaults.standard.set(user, forKey: Pref.listenbrainzUser)
    }

    func disconnect() {
        Keychain.set("listenbrainz.token", nil)
        ReconnectMark.set(id, false)
        UserDefaults.standard.removeObject(forKey: Pref.listenbrainzUser)
    }

    static func payload(_ s: Scrobble, withTime: Bool) -> [String: Any] {
        var meta: [String: Any] = ["artist_name": s.artist, "track_name": s.title]
        if let a = s.album { meta["release_name"] = a }
        var info: [String: Any] = ["media_player": "OmniAmp", "submission_client": "OmniAmp"]
        if let d = s.duration { info["duration"] = d }
        meta["additional_info"] = info
        var p: [String: Any] = ["track_metadata": meta]
        if withTime { p["listened_at"] = s.timestamp }
        return p
    }

    func nowPlaying(_ s: Scrobble) async throws {
        guard let t = token else { throw ScrobbleError.notConnected }
        _ = try await request("submit-listens", token: t, body: ["listen_type": "playing_now", "payload": [Self.payload(s, withTime: false)]])
    }

    func submit(_ batch: [Scrobble]) async throws -> Int {
        guard let t = token else { throw ScrobbleError.notConnected }
        let items = Array(batch.prefix(maxBatch))
        let type = items.count == 1 ? "single" : "import"
        _ = try await request("submit-listens", token: t, body: ["listen_type": type, "payload": items.map { Self.payload($0, withTime: true) }])
        return items.count
    }
}
