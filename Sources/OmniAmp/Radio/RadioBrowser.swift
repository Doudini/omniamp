import Foundation

/// A station from radio-browser.info (or a saved favorite).
struct RadioStation: Codable, Equatable {
    var uuid: String
    var name: String
    var url: String
    var tags: String
    var country: String
    var countryCode: String
    var codec: String
    var bitrate: Int

    /// Station logo (radio-browser "favicon"), if any.
    var favicon: String?

    /// MP3/AAC go through our engine; HLS and Ogg/Opus through the system player. Anything http(s) works.
    var isPlayable: Bool { url.hasPrefix("http://") || url.hasPrefix("https://") }

    var formatLabel: String {
        let c = codec.uppercased() == "UNKNOWN" || codec.isEmpty ? (url.lowercased().contains(".m3u8") ? "HLS" : "?") : codec
        return bitrate > 0 ? "\(c) \(bitrate)" : c
    }
    /// "deep house, techno · Germany" for the INFO drawer.
    var summary: String? {
        let place = countryCode.isEmpty ? country : (Locale.current.localizedString(forRegionCode: countryCode) ?? country)
        let parts = [genreLabel, place].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A station added by URL (not from the directory).
    static func custom(url: String, name: String) -> RadioStation {
        RadioStation(uuid: "custom:" + url, name: name, url: url, tags: "", country: "", countryCode: "", codec: "URL", bitrate: 0, favicon: nil)
    }

    var genreLabel: String { tags.split(separator: ",").prefix(3).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ") }
}

/// Client for the free, community-run radio-browser.info directory (no API key).
@MainActor
final class RadioBrowser {
    static let shared = RadioBrowser()

    var transport: HTTPTransport = URLSessionTransport()
    /// Mirrors, tried in order; the first that answers is remembered.
    private var servers = ["https://de1.api.radio-browser.info", "https://nl1.api.radio-browser.info",
                           "https://at1.api.radio-browser.info", "https://fi1.api.radio-browser.info"]

    private func get(_ path: String, _ query: [String: String]) async throws -> Data {
        var lastError: Error = ScrobbleError.http(0, "No radio directory server answered")
        for (i, server) in servers.enumerated() {
            var c = URLComponents(string: server + path)!
            c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            var req = URLRequest(url: c.url!)
            req.setValue("OmniAmp/1.0", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 10
            do {
                let (data, status) = try await transport.send(req)
                guard (200..<300).contains(status) else { throw ScrobbleError.http(status, "radio directory") }
                if i > 0 { servers.insert(servers.remove(at: i), at: 0) }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    nonisolated static func decode(_ data: Data) -> [RadioStation] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let uuid = d["stationuuid"] as? String, let name = d["name"] as? String else { return nil }
            let url = (d["url_resolved"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? d["url"] as? String ?? ""
            if let ok = d["lastcheckok"] as? Int, ok == 0 { return nil }
            let s = RadioStation(uuid: uuid, name: name.trimmingCharacters(in: .whitespacesAndNewlines), url: url,
                                 tags: d["tags"] as? String ?? "", country: d["country"] as? String ?? "",
                                 countryCode: d["countrycode"] as? String ?? "", codec: d["codec"] as? String ?? "",
                                 bitrate: d["bitrate"] as? Int ?? 0,
                                 favicon: (d["favicon"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            return s.isPlayable ? s : nil
        }
    }

    /// Most popular stations, or a search by name / genre tag / country code.
    func stations(name: String = "", tag: String = "", country: String = "") async throws -> [RadioStation] {
        var q = ["hidebroken": "true", "limit": "300", "order": "clickcount", "reverse": "true"]
        if !name.isEmpty { q["name"] = name }
        if !tag.isEmpty { q["tag"] = tag; q["tagExact"] = "false" }
        if !country.isEmpty { q["countrycode"] = country }
        return Self.decode(try await get("/json/stations/search", q))
    }

    /// Tell the directory a station was played (their requested etiquette; helps popularity ranking).
    func countClick(_ uuid: String) {
        Task { _ = try? await get("/json/url/\(uuid)", [:]) }
    }
}

/// Favorite stations, kept locally.
enum RadioFavorites {
    private static let key = "radioFavorites"

    static var all: [RadioStation] {
        get { (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([RadioStation].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static func contains(_ s: RadioStation) -> Bool { all.contains { $0.uuid == s.uuid } }

    static func toggle(_ s: RadioStation) {
        var a = all
        if let i = a.firstIndex(where: { $0.uuid == s.uuid }) { a.remove(at: i) } else { a.append(s) }
        all = a
    }
}
