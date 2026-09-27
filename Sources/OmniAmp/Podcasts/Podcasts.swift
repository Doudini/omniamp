import CryptoKit
import Foundation

/// A podcast (show) from the directory or a subscription.
struct PodcastShow: Codable, Equatable {
    var feedURL: String
    var title: String
    var author: String
    var artwork: String?
    var genre: String?
}

/// One episode from a show's RSS feed.
struct PodcastEpisode: Codable, Equatable {
    var title: String
    var url: String            // the audio file (enclosure)
    var published: Double?     // seconds since 1970
    var duration: Double?      // seconds
    var summary: String?       // show notes, plain text

    func track(show: PodcastShow) -> Track {
        .episode(url, title: title, show: show.title, artwork: show.artwork, duration: duration, published: published, summary: summary)
    }
}

// MARK: - Directory (Apple's podcast search: free, no API key)

final class PodcastDirectory {
    static let shared = PodcastDirectory()
    var transport: HTTPTransport = URLSessionTransport()

    private func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("OmniAmp/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, status) = try await transport.send(req)
        guard (200..<300).contains(status) else { throw ScrobbleError.http(status, "podcast directory") }
        return data
    }

    /// Shows matching `term` (title, author…) in a country's store.
    func search(_ term: String, country: String) async throws -> [PodcastShow] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [URLQueryItem(name: "media", value: "podcast"), URLQueryItem(name: "term", value: term),
                        URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "country", value: country)]
        return Self.decodeLookup(try await get(c.url!))
    }

    /// A country's top shows, in chart order.
    func top(country: String) async throws -> [PodcastShow] {
        let chart = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country.lowercased())/podcasts/top/100/podcasts.json")!
        let ids = Self.decodeChartIDs(try await get(chart))
        guard !ids.isEmpty else { return [] }
        // The chart has no feed addresses: look the shows up (one request).
        var c = URLComponents(string: "https://itunes.apple.com/lookup")!
        c.queryItems = [URLQueryItem(name: "id", value: ids.joined(separator: ",")), URLQueryItem(name: "country", value: country),
                        URLQueryItem(name: "entity", value: "podcast")]
        let byID = Dictionary(Self.decodeLookup(try await get(c.url!), keepingIDs: true).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    static func decodeChartIDs(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let feed = root["feed"] as? [String: Any], let results = feed["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { $0["id"] as? String }
    }

    static func decodeLookup(_ data: Data) -> [PodcastShow] { decodeLookup(data, keepingIDs: true).map(\.1) }

    static func decodeLookup(_ data: Data, keepingIDs: Bool) -> [(String, PodcastShow)] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let feed = r["feedUrl"] as? String, !feed.isEmpty,
                  let title = (r["collectionName"] as? String) ?? (r["trackName"] as? String) else { return nil }
            let id = (r["collectionId"] as? Int).map(String.init) ?? feed
            let art = (r["artworkUrl600"] as? String) ?? (r["artworkUrl100"] as? String)
            return (id, PodcastShow(feedURL: feed, title: title, author: r["artistName"] as? String ?? "",
                                    artwork: art, genre: r["primaryGenreName"] as? String))
        }
    }
}

// MARK: - RSS feed

/// Reads a podcast RSS feed. Forgiving: feeds in the wild are messy, so anything without an audio
/// enclosure is skipped and missing fields just stay empty.
final class PodcastFeedParser: NSObject, XMLParserDelegate {
    private(set) var title = ""
    private(set) var author = ""
    private(set) var artwork: String?
    private(set) var episodes: [PodcastEpisode] = []

    private var path: [String] = []
    private var text = ""
    private var item: [String: String]?
    private var itemURL: String?
    private var itemType: String?

    static func parse(_ data: Data) -> PodcastFeedParser {
        let p = PodcastFeedParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.shouldProcessNamespaces = false
        x.parse()
        return p
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let n = name.lowercased()
        path.append(n)
        text = ""
        switch n {
        case "item": item = [:]; itemURL = nil; itemType = nil
        case "enclosure" where item != nil:
            if itemURL == nil, let u = attributes["url"], !u.isEmpty { itemURL = u; itemType = attributes["type"] }
        case "itunes:image":
            if let h = attributes["href"], !h.isEmpty {
                if item == nil { artwork = artwork ?? h }
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let n = name.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if item != nil {
            switch n {
            case "title", "pubdate", "itunes:duration", "description", "itunes:summary", "content:encoded":
                if item?[n] == nil, !value.isEmpty { item?[n] = value }
            case "item":
                if let it = item, let url = itemURL, Self.isAudio(url: url, type: itemType) {
                    let notes = it["description"] ?? it["itunes:summary"] ?? it["content:encoded"]
                    episodes.append(PodcastEpisode(title: it["title"] ?? "Untitled episode", url: url,
                                                   published: it["pubdate"].flatMap(Self.date),
                                                   duration: it["itunes:duration"].flatMap(Self.duration),
                                                   summary: notes.map(Self.plainText)))
                }
                item = nil
            default: break
            }
        } else if path.count >= 2 && path[path.count - 2] == "channel" {
            switch n {
            case "title": if title.isEmpty { title = value }
            case "itunes:author": if author.isEmpty { author = value }
            default: break
            }
        } else if n == "url", path.suffix(3) == ["channel", "image", "url"], artwork == nil, !value.isEmpty {
            artwork = value
        }
        path.removeLast()
        text = ""
    }

    static func isAudio(url: String, type: String?) -> Bool {
        if let t = type?.lowercased(), !t.isEmpty { return t.hasPrefix("audio/") || t == "application/octet-stream" && hasAudioExtension(url) }
        return hasAudioExtension(url)
    }

    private static func hasAudioExtension(_ url: String) -> Bool {
        let ext = (URL(string: url)?.path ?? url).split(separator: ".").last.map { $0.lowercased() } ?? ""
        return ["mp3", "m4a", "aac", "mp4", "ogg", "opus", "wav"].contains(ext)
    }

    /// RSS dates ("Tue, 03 Mar 2026 10:00:00 +0000", and the usual variations).
    static func date(_ s: String) -> Double? {
        for f in dateFormats {
            if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        }
        return nil
    }

    private static let dateFormats: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z",
                                                       "EEE, dd MMM yyyy HH:mm Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ssZ"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }

    /// "1:02:03", "62:03" or "3723" → seconds.
    static func duration(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let secs = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return secs > 0 ? secs : nil
    }

    /// Show notes are HTML: keep the text, one paragraph per line, and cap the length.
    static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br\\s*/?>|</p>|</li>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (e, c) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&#8217;": "’", "&#8220;": "“", "&#8221;": "”"] {
            s = s.replacingOccurrences(of: e, with: c)
        }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > 2000 ? String(s.prefix(2000)) + "…" : s
    }
}

// MARK: - Library: subscriptions, cached feeds, played episodes

final class PodcastLibrary {
    static let shared = PodcastLibrary()
    var transport: HTTPTransport = URLSessionTransport()

    private struct FeedCache: Codable {
        var fetched: Double
        var episodes: [PodcastEpisode]
    }

    private let dir: URL
    private(set) var subscriptions: [PodcastShow] = []
    private var played: Set<String> = []
    /// Newest episode date the user has seen, per feed ("new" = released after that).
    private var seen: [String: Double] = [:]
    private var feeds: [String: FeedCache] = [:]

    init(directory: URL? = nil) {
        dir = directory ?? LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("Podcasts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("feeds"), withIntermediateDirectories: true)
        subscriptions = load("subscriptions.json") ?? []
        played = Set(load("played.json") ?? [String]())
        seen = load("seen.json") ?? [:]
    }

    private func load<T: Decodable>(_ name: String) -> T? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        try? JSONEncoder().encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    // Subscriptions

    func isSubscribed(_ show: PodcastShow) -> Bool { subscriptions.contains { $0.feedURL == show.feedURL } }

    func toggleSubscription(_ show: PodcastShow) {
        if let i = subscriptions.firstIndex(where: { $0.feedURL == show.feedURL }) {
            subscriptions.remove(at: i)
        } else {
            subscriptions.append(show)
            subscriptions.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            // Everything already out counts as seen; only later releases show up as new.
            if let newest = cachedEpisodes(show).first?.published { seen[show.feedURL] = newest; save(seen, "seen.json") }
        }
        save(subscriptions, "subscriptions.json")
    }

    // Episodes

    private func feedFile(_ feed: String) -> URL {
        dir.appendingPathComponent("feeds/" + Insecure.SHA1.hash(data: Data(feed.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }

    /// Episodes from the last download (newest first), without touching the network.
    func cachedEpisodes(_ show: PodcastShow) -> [PodcastEpisode] {
        if let c = feeds[show.feedURL] { return c.episodes }
        guard let data = try? Data(contentsOf: feedFile(show.feedURL)), let c = try? JSONDecoder().decode(FeedCache.self, from: data) else { return [] }
        feeds[show.feedURL] = c
        return c.episodes
    }

    /// Downloads the feed (unless it was fetched in the last `maxAge` seconds) and returns its episodes, newest first.
    func episodes(_ show: PodcastShow, maxAge: Double = 600) async throws -> [PodcastEpisode] {
        _ = cachedEpisodes(show)   // loads the disk cache
        if let c = feeds[show.feedURL], Date().timeIntervalSince1970 - c.fetched < maxAge { return c.episodes }
        guard let url = URL(string: show.feedURL) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("OmniAmp/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, status) = try await transport.send(req)
        guard (200..<300).contains(status) else { throw ScrobbleError.http(status, "podcast feed") }
        let parsed = PodcastFeedParser.parse(data)
        let eps = parsed.episodes.sorted { ($0.published ?? 0) > ($1.published ?? 0) }
        await MainActor.run {
            let c = FeedCache(fetched: Date().timeIntervalSince1970, episodes: eps)
            self.feeds[show.feedURL] = c
            try? JSONEncoder().encode(c).write(to: self.feedFile(show.feedURL), options: .atomic)
        }
        return eps
    }

    // Played / new

    func isPlayed(_ url: String) -> Bool { played.contains(url) }

    func markPlayed(_ url: String, _ on: Bool = true) {
        if on { played.insert(url) } else { played.remove(url) }
        if played.count > 5000 { played = Set(played.prefix(4000)) }
        save(Array(played), "played.json")
    }

    /// Episodes released since the user last opened this show.
    func newCount(_ show: PodcastShow) -> Int {
        guard isSubscribed(show) else { return 0 }
        let since = seen[show.feedURL] ?? .infinity
        return cachedEpisodes(show).filter { ($0.published ?? 0) > since && !isPlayed($0.url) }.count
    }

    func markSeen(_ show: PodcastShow) {
        guard let newest = cachedEpisodes(show).first?.published, seen[show.feedURL] != newest else { return }
        seen[show.feedURL] = newest
        save(seen, "seen.json")
    }
}
