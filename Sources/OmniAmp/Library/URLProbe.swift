import Foundation

/// Works out what a pasted link is: a live station, a playlist of stations, a podcast feed, an Apple
/// Podcasts page, or a plain audio file on the web. It asks the server (reading only the first few KB,
/// so endless streams are fine) instead of guessing from the address.
enum URLProbe {
    enum Result: Equatable {
        /// Live radio (Icecast/SHOUTcast/HLS). `name` from the stream's icy-name when it has one.
        case station(url: String, name: String?)
        /// A .pls/.m3u from a radio website: the stations inside.
        case stations([Station])
        /// A podcast RSS feed.
        case podcast(PodcastShow)
        /// A finite audio file on the web.
        case file(url: String, title: String)
    }

    struct Station: Equatable {
        var url: String
        var name: String?
    }

    enum ProbeError: LocalizedError {
        case notAURL, webPage, unknown(String), empty
        var errorDescription: String? {
            switch self {
            case .notAURL: return "That doesn't look like a web address."
            case .webPage: return "That's a web page, not a stream, playlist or podcast feed. Look on the page for a “listen” or RSS link."
            case .unknown(let type): return "Couldn't tell what this link is (\(type.isEmpty ? "no content type" : type))."
            case .empty: return "The playlist at that address has no stations."
            }
        }
    }

    /// Cleans up what people paste: missing scheme, feed:/itpc:/pcast: schemes, surrounding spaces or <>.
    static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"")))
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        for scheme in ["feed://", "itpc://", "pcast://", "podcast://"] where s.lowercased().hasPrefix(scheme) {
            s = "https://" + s.dropFirst(scheme.count)
        }
        if s.lowercased().hasPrefix("feed:") { s = String(s.dropFirst(5)) }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = u.host, host.contains(".") || host == "localhost" else { return nil }
        return u
    }

    /// The show id in an Apple Podcasts link (…/podcast/name/id1200361736).
    static func applePodcastID(_ url: URL) -> String? {
        guard url.host?.hasSuffix("podcasts.apple.com") == true || url.host?.hasSuffix("itunes.apple.com") == true else { return nil }
        guard let r = url.path.range(of: "id[0-9]+", options: .regularExpression) else { return nil }
        return String(url.path[r].dropFirst(2))
    }

    /// Decide from what the server sent. `endless` = no Content-Length (typical for live streams).
    static func classify(url: URL, contentType: String, headers: [String: String], body: Data, endless: Bool) throws -> Result {
        let type = contentType.lowercased()
        let text = String(decoding: body.prefix(4096), as: UTF8.self)
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let icyName = headers.first { $0.key.lowercased() == "icy-name" }?.value.trimmingCharacters(in: .whitespaces)
        let hasICY = headers.keys.contains { $0.lowercased().hasPrefix("icy-") }
        let ext = url.pathExtension.lowercased()

        // HLS: a playlist of segments is one live station.
        if head.hasPrefix("#extm3u"), text.contains("#EXT-X-") { return .station(url: url.absoluteString, name: icyName) }
        // Station playlists (.pls / .m3u).
        if type.contains("scpls") || head.hasPrefix("[playlist]") || type.contains("mpegurl") || head.hasPrefix("#extm3u")
            || (ext == "pls" || ext == "m3u") && !type.hasPrefix("audio/mpeg") {
            let stations = parsePlaylist(text, base: url)
            if stations.isEmpty { throw ProbeError.empty }
            return .stations(stations)
        }
        // Podcast feed.
        if type.contains("xml") || type.contains("rss") || head.hasPrefix("<?xml") || head.hasPrefix("<rss") {
            let feed = PodcastFeedParser.parse(body)
            guard !feed.title.isEmpty || !feed.episodes.isEmpty else { throw ProbeError.unknown(contentType) }
            return .podcast(PodcastShow(feedURL: url.absoluteString, title: feed.title.isEmpty ? (url.host ?? "Podcast") : feed.title,
                                        author: feed.author, artwork: feed.artwork))
        }
        if type.hasPrefix("text/html") || head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { throw ProbeError.webPage }
        // Audio: live if the server says it's a station or never ends; otherwise a file.
        let audioTypes = ["audio/", "application/ogg", "video/mp2t", "application/octet-stream"]
        if audioTypes.contains(where: { type.hasPrefix($0) }) || type.isEmpty && ["mp3", "aac", "m4a", "ogg", "opus"].contains(ext) {
            if hasICY || endless { return .station(url: url.absoluteString, name: icyName) }
            let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            return .file(url: url.absoluteString, title: name.isEmpty ? (url.host ?? "Web audio") : name)
        }
        throw ProbeError.unknown(contentType)
    }

    /// Stations in a .pls or .m3u (text), with their titles.
    static func parsePlaylist(_ text: String, base: URL) -> [Station] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-probe-\(UUID().uuidString)")
            .appendingPathExtension(text.lowercased().contains("[playlist]") ? "pls" : "m3u")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? text.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return [] }
        return PlaylistFile.entries(tmp).compactMap { e in
            // Relative entries resolve against the playlist's web address.
            let url: URL? = e.url.isFileURL ? URL(string: e.url.lastPathComponent, relativeTo: base)?.absoluteURL : e.url
            guard let u = url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return nil }
            return Station(url: u.absoluteString, name: e.title.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// Fetch the start of `input` and classify it. Apple Podcasts links are looked up first.
    static func probe(_ input: String) async throws -> Result {
        guard let url = normalize(input) else { throw ProbeError.notAURL }
        if let id = applePodcastID(url) {
            var c = URLComponents(string: "https://itunes.apple.com/lookup")!
            c.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "entity", value: "podcast")]
            let (data, _) = try await URLSession.shared.data(from: c.url!)
            if let show = PodcastDirectory.decodeLookup(data).first { return .podcast(show) }
            throw ProbeError.unknown("Apple Podcasts page without a public feed")
        }
        var req = URLRequest(url: url)
        req.setValue("OmniAmp/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        req.timeoutInterval = 15
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        var body = Data()
        for try await b in bytes {
            body.append(b)
            if body.count >= 64 * 1024 { break }   // enough to recognise anything; streams never end
        }
        bytes.task.cancel()
        let http = response as? HTTPURLResponse
        if let code = http?.statusCode, !(200..<300).contains(code) { throw ScrobbleError.http(code, "That address") }
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { headers["\(k)"] = "\(v)" }
        // Keep the address the user gave: redirect targets of streams and feeds often expire.
        return try classify(url: url, contentType: response.mimeType ?? headers["Content-Type"] ?? "", headers: headers,
                            body: body, endless: response.expectedContentLength < 0)
    }
}
