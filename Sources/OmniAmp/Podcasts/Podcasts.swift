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
    var image: String?         // the episode's own artwork, if the feed has one
    var season: Int?
    var number: Int?           // episode number
    /// Links from the show notes as [text, url] pairs (the plain-text notes keep only the text).
    var links: [[String]]?
    /// The feed's own id for the episode: stays the same when the audio address changes (tracking prefixes, CDNs).
    var guid: String?

    /// The episode's own image, else the show's.
    func artwork(show: PodcastShow) -> String? { image ?? show.artwork }

    func track(show: PodcastShow) -> Track {
        .episode(url, title: title, show: show.title, artwork: artwork(show: show), duration: duration, published: published, summary: summary)
    }
}

enum PodcastFeedError: Error, LocalizedError {
    case unreadable(String)
    var errorDescription: String? { if case .unreadable(let why) = self { return "Couldn't read this feed: " + why } else { return nil } }
}

// MARK: - Directory (Apple's podcast search: free, no API key)

final class PodcastDirectory {
    static let shared = PodcastDirectory()
    var transport: HTTPTransport = URLSessionTransport()

    private func get(_ url: URL, timeout: TimeInterval = 15) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("OmniAmp/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = timeout
        let (data, status) = try await transport.send(req)
        guard (200..<300).contains(status) else { throw ScrobbleError.http(status, "podcast directory") }
        return data
    }

    // Search goes to Apple (fast, the country's store) and fyyd (a free directory strong on German-language and
    // independent shows, but it can take 10+ s). The window shows Apple's results at once and adds fyyd's
    // when they come; results are kept for a while so going back to a search is instant.

    private var searchCache: [String: (at: Date, shows: [PodcastShow])] = [:]
    private static let searchMaxAge: TimeInterval = 30 * 60

    @MainActor
    private func cachedSearch(_ key: String, _ fetch: () async throws -> [PodcastShow]) async throws -> [PodcastShow] {
        if let c = searchCache[key], Date().timeIntervalSince(c.at) < Self.searchMaxAge { return c.shows }
        let shows = try await fetch()
        if searchCache.count > 40 { searchCache.removeAll() }
        searchCache[key] = (Date(), shows)
        return shows
    }

    /// fyyd also matches episode texts, which brings in unrelated shows: keep those whose title or author
    /// has every word searched for.
    static func relevant(_ shows: [PodcastShow], to term: String) -> [PodcastShow] {
        let words = term.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return shows }
        return shows.filter { s in
            let hay = (s.title + " " + s.author).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    /// `extra` shows not already in `first` (same feed, or same title and author).
    static func merge(_ first: [PodcastShow], _ extra: [PodcastShow]) -> [PodcastShow] {
        func feedKey(_ s: String) -> String {
            var k = s.lowercased()
            for p in ["https://", "http://", "www."] where k.hasPrefix(p) { k.removeFirst(p.count) }
            while k.hasSuffix("/") { k.removeLast() }
            return k
        }
        func nameKey(_ s: PodcastShow) -> String { (s.title + "|" + s.author).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "|" } }
        var feeds = Set(first.map { feedKey($0.feedURL) }), names = Set(first.map(nameKey))
        var out = first
        for s in extra where !feeds.contains(feedKey(s.feedURL)) && !names.contains(nameKey(s)) {
            out.append(s)
            feeds.insert(feedKey(s.feedURL))
            names.insert(nameKey(s))
        }
        return out
    }

    /// fyyd.de search (no key needed), only the shows that really match; gives up after 10 s.
    @MainActor
    func searchFyyd(_ term: String) async throws -> [PodcastShow] {
        try await cachedSearch("fyyd|" + term.lowercased()) {
            var c = URLComponents(string: "https://api.fyyd.de/0.2/search/podcast")!
            c.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "count", value: "50")]
            // A request timeout only counts silence; a server that trickles could take much longer. Cap the whole thing.
            let url = c.url!
            let data = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await self.get(url, timeout: 10) }
                group.addTask { try await Task.sleep(for: .seconds(10)); throw URLError(.timedOut) }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            return Self.relevant(Self.decodeFyyd(data), to: term)
        }
    }

    static func decodeFyyd(_ data: Data) -> [PodcastShow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { r in
            guard let feed = (r["xmlURL"] as? String)?.trimmingCharacters(in: .whitespaces), !feed.isEmpty,
                  let title = (r["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let art = [r["layoutImageURL"], r["imgURL"], r["smallImageURL"]].compactMap { $0 as? String }.first { !$0.isEmpty }
            return PodcastShow(feedURL: feed, title: title, author: (r["author"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                               artwork: art, genre: nil)
        }
    }

    /// Apple's search in a country's store.
    @MainActor
    func searchApple(_ term: String, country: String) async throws -> [PodcastShow] {
        try await cachedSearch("apple|\(country)|" + term.lowercased()) { try await fetchApple(term, country: country) }
    }

    private func fetchApple(_ term: String, country: String) async throws -> [PodcastShow] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [URLQueryItem(name: "media", value: "podcast"), URLQueryItem(name: "term", value: term),
                        URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "country", value: country)]
        return Self.decodeLookup(try await get(c.url!))
    }

    // Top charts are kept on disk per country: the chart service takes ~2 s, and it changes slowly.
    private struct Chart: Codable { var fetched: Double; var shows: [PodcastShow] }
    private var charts: [String: Chart] = [:]
    private static let chartMaxAge: TimeInterval = 6 * 3600

    private func chartFile(_ country: String) -> URL {
        let d = LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("Podcasts/charts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent(country.lowercased() + ".json")
    }

    /// The last chart we have for a country, however old (shown at once while a fresh one loads).
    @MainActor
    func cachedTop(country: String) -> (shows: [PodcastShow], fresh: Bool)? {
        if charts[country] == nil, let d = try? Data(contentsOf: chartFile(country)), let c = try? JSONDecoder().decode(Chart.self, from: d) {
            charts[country] = c
        }
        guard let c = charts[country], !c.shows.isEmpty else { return nil }
        return (c.shows, Date().timeIntervalSince1970 - c.fetched < Self.chartMaxAge)
    }

    /// A country's top shows, in chart order (from the cache when it's recent enough).
    @MainActor
    func top(country: String) async throws -> [PodcastShow] {
        if let c = cachedTop(country: country), c.fresh { return c.shows }
        let shows = try await fetchTop(country: country)
        let chart = Chart(fetched: Date().timeIntervalSince1970, shows: shows)
        charts[country] = chart
        try? JSONEncoder().encode(chart).write(to: chartFile(country), options: .atomic)
        return shows
    }

    private func fetchTop(country: String) async throws -> [PodcastShow] {
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

/// Feeds and OPML files in the wild are often not quite XML: HTML entities (&nbsp;, &hellip;) and bare
/// ampersands make XMLParser stop at the first one. Rewrite those into valid XML before parsing.
enum XMLRepair {
    private static let named: [String: String] = [
        "nbsp": "#160", "hellip": "#8230", "mdash": "#8212", "ndash": "#8211", "lsquo": "#8216", "rsquo": "#8217",
        "ldquo": "#8220", "rdquo": "#8221", "laquo": "#171", "raquo": "#187", "copy": "#169", "reg": "#174",
        "trade": "#8482", "euro": "#8364", "pound": "#163", "bull": "#8226", "middot": "#183", "deg": "#176",
        "auml": "#228", "ouml": "#246", "uuml": "#252", "Auml": "#196", "Ouml": "#214", "Uuml": "#220", "szlig": "#223",
        "eacute": "#233", "egrave": "#232", "agrave": "#224", "ccedil": "#231", "iacute": "#237", "oacute": "#243",
    ]
    private static let predefined: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    /// The code point of an HTML entity name we know ("hellip" → "8230").
    static func namedCode(_ name: String) -> String? { named[name].map { String($0.dropFirst()) } }

    /// Works on the bytes: no String or UTF-16 copies of a feed that can be several MB, and no copy at all when
    /// nothing needs fixing. CDATA is taken literally by the parser, so those blocks are left as they are.
    static func repair(_ data: Data) -> Data {
        let b = [UInt8](data)
        let amp = UInt8(ascii: "&"), lt = UInt8(ascii: "<"), semi = UInt8(ascii: ";"), hash = UInt8(ascii: "#")
        let cdOpen = Array("<![CDATA[".utf8), cdClose = Array("]]>".utf8)
        func starts(_ seq: [UInt8], at i: Int) -> Bool {
            i + seq.count <= b.count && b[i..<(i + seq.count)].elementsEqual(seq)
        }
        func isNameByte(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
        var out: [UInt8]?     // made on the first fix
        var copied = 0        // b[..<copied] is already in `out` (or unchanged)
        func replace(_ range: Range<Int>, with bytes: [UInt8]) {
            if out == nil { out = []; out!.reserveCapacity(b.count + 1024) }
            out!.append(contentsOf: b[copied..<range.lowerBound])
            out!.append(contentsOf: bytes)
            copied = range.upperBound
        }
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == lt, starts(cdOpen, at: i) {
                var j = i + cdOpen.count
                while j < b.count, !starts(cdClose, at: j) { j += 1 }
                i = min(b.count, j + cdClose.count)
                continue
            }
            guard c == amp else { i += 1; continue }
            var j = i + 1
            if j < b.count, b[j] == hash { j += 1 }
            while j < b.count, j - i <= 32, isNameByte(b[j]) { j += 1 }
            if j < b.count, b[j] == semi, j > i + 1 {
                let name = String(decoding: b[(i + 1)..<j], as: UTF8.self)
                if predefined.contains(name) || (name.hasPrefix("#") && name.count > 1) {
                    // fine as it is
                } else if let n = named[name] {
                    replace(i..<(j + 1), with: Array("&\(n);".utf8))
                } else {
                    replace(i..<(i + 1), with: Array("&amp;".utf8))   // unknown entity: keep it as text
                }
                i = j + 1
            } else {
                replace(i..<(i + 1), with: Array("&amp;".utf8))       // a bare &
                i += 1
            }
        }
        guard var fixed = out else { return data }
        fixed.append(contentsOf: b[copied...])
        return Data(fixed)
    }
}

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

    /// The parser stopped at an error (what came before it is kept).
    private(set) var failed = false

    static func parse(_ data: Data) -> PodcastFeedParser {
        let p = PodcastFeedParser()
        let x = XMLParser(data: XMLRepair.repair(data))
        x.delegate = p
        x.shouldProcessNamespaces = false
        p.failed = !autoreleasepool { x.parse() }
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
                if item == nil { artwork = artwork ?? h } else if item?["image"] == nil { item?["image"] = h }
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
            case "title", "pubdate", "itunes:duration", "description", "itunes:summary", "content:encoded", "itunes:season", "itunes:episode", "guid":
                if item?[n] == nil, !value.isEmpty { item?[n] = value }
            case "item":
                // Each episode's notes go through several text passes: free their temporaries per episode,
                // not at the end of a feed of 800 (that pile-up doubled the app's memory while parsing).
                if let it = item, let url = itemURL, Self.isAudio(url: url, type: itemType) { autoreleasepool {
                    let notes = it["description"] ?? it["itunes:summary"] ?? it["content:encoded"]
                    // The long form usually has the links (descriptions are often plain text).
                    let links = (it["content:encoded"] ?? notes).map(Self.links) ?? []
                    episodes.append(PodcastEpisode(title: it["title"] ?? "Untitled episode", url: url,
                                                   published: it["pubdate"].flatMap(Self.date),
                                                   duration: it["itunes:duration"].flatMap(Self.duration),
                                                   summary: notes.map(Self.plainText),
                                                   image: it["image"],
                                                   season: it["itunes:season"].flatMap { Int($0) },
                                                   number: it["itunes:episode"].flatMap { Int($0) },
                                                   links: links.isEmpty ? nil : links, guid: it["guid"]))
                } }
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
        return Sane.duration(secs)
    }

    /// The notes' links as [text, url] (web and mail links only, at most 30): the notes pane puts them back
    /// on the text that plainText keeps.
    static func links(_ html: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: "<a\\s[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
                                                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        var out: [[String]] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) where out.count < 30 {
            let href = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            guard let scheme = URL(string: href)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { continue }
            let text = plainText(ns.substring(with: m.range(at: 2)))
            if !text.isEmpty { out.append([text, href]) }
        }
        return out
    }

    private static let entityPattern = try! NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z]{2,10});")
    private static let namedText: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]

    /// One pass over the text: every entity once (so "&amp;lt;" stays "&lt;"), numeric ones too (&#8230;, &#x27;).
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = "", last = 0
        for m in entityPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))
            var decoded: String?
            if body.hasPrefix("#") {
                let hex = body.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = body.dropFirst(hex ? 2 : 1)
                if let v = UInt32(digits, radix: hex ? 16 : 10), let u = Unicode.Scalar(v) { decoded = String(Character(u)) }
            } else if let t = namedText[body] {
                decoded = t
            } else if let code = XMLRepair.namedCode(body), let v = UInt32(code), let u = Unicode.Scalar(v) {
                decoded = String(Character(u))
            }
            out += decoded ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Show notes are HTML: keep the text, one paragraph per line, and cap the length.
    static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br\\s*/?>|</p>|</li>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > 2000 ? String(s.prefix(2000)) + "…" : s
    }
}

// MARK: - Library: subscriptions, cached feeds, played episodes

@MainActor
final class PodcastLibrary {
    static let shared = PodcastLibrary()
    /// An episode was marked played, or its resume position was saved or cleared.
    static let progressChanged = Notification.Name("OmniAmp.podcastProgressChanged")
    var transport: HTTPTransport = URLSessionTransport()

    private struct FeedCache: Codable {
        var fetched: Double
        var episodes: [PodcastEpisode]
    }

    private let dir: URL
    private(set) var subscriptions: [PodcastShow] = []
    /// Played episodes and when they were marked (the oldest go first when the list gets long).
    private var played: [String: Double] = [:]
    private static let maxPlayed = 20_000
    /// Newest episode date the user has seen, per feed ("new" = released after that).
    private var seen: [String: Double] = [:]
    private var feeds: [String: FeedCache] = [:]
    /// When each episode was last listened to (orders "Continue listening").
    private var listened: [String: Double] = [:]
    /// Shows whose feeds were read this session, by feed URL (to find an episode's show again).
    private var knownShows: [String: PodcastShow] = [:]

    init(directory: URL? = nil) {
        dir = directory ?? LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("Podcasts", isDirectory: true)
        Self.writes.sync {}   // saves are written in the background: let any still on their way land first
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("feeds"), withIntermediateDirectories: true)
        subscriptions = load("subscriptions.json") ?? []
        // Older builds saved a plain list (no dates): those count as oldest.
        played = load("played.json") ?? Dictionary((load("played.json") ?? [String]()).map { ($0, 0) }, uniquingKeysWith: { a, _ in a })
        seen = load("seen.json") ?? [:]
        listened = load("listened.json") ?? [:]
        started = load("started.json") ?? [:]
        // Only subscriptions have "new" episodes: drop what browsing other shows left behind.
        let subscribed = Set(subscriptions.map(\.feedURL))
        if seen.keys.contains(where: { !subscribed.contains($0) }) {
            seen = seen.filter { subscribed.contains($0.key) }
            save(seen, "seen.json")
        }
        // Saved feeds of shows you only browsed are dropped after 30 days (subscriptions' are kept).
        let keep = Set(subscriptions.map { feedFile($0.feedURL).lastPathComponent }), folder = dir.appendingPathComponent("feeds")
        DispatchQueue.global(qos: .background).async {
            let cutoff = Date().addingTimeInterval(-30 * 86_400)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where !keep.contains(f.lastPathComponent) {
                if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                    try? FileManager.default.removeItem(at: f)
                }
            }
        }
    }

    /// What Continue listening needs to show an episode after a relaunch, also when its show isn't subscribed
    /// (those feeds don't stay in memory or on disk).
    private struct Started: Codable { var episode: PodcastEpisode; var show: PodcastShow }
    private var started: [String: Started] = [:]

    /// `track`: the playlist entry, used when no feed read so far has the episode.
    func noteListened(_ url: String, track: Track? = nil) {
        listened[url] = Date().timeIntervalSince1970
        if listened.count > 500 { for k in listened.sorted(by: { $0.value < $1.value }).prefix(100).map(\.key) { listened.removeValue(forKey: k) } }
        save(listened, "listened.json")
        // Noted on every pause and track change: the feeds on disk are only searched the first time.
        if let found = lookupInFeeds(url, disk: started[url] == nil) {
            started[url] = Started(episode: found.episode, show: found.show)
        } else if started[url] == nil, let t = track, t.isEpisode {
            let showName = t.podcast.flatMap { $0.isEmpty ? nil : $0 } ?? "Web audio"
            started[url] = Started(episode: PodcastEpisode(title: t.title ?? "Episode", url: url, published: t.published,
                                                          duration: t.duration, summary: t.summary, image: t.logo),
                                   show: PodcastShow(feedURL: "", title: showName, author: "", artwork: t.logo))
        }
        started = started.filter { listened[$0.key] != nil }
        save(started, "started.json")
    }

    func lastListened(_ url: String) -> Double? { listened[url] }

    /// An episode and its show: from the feeds read so far, the subscriptions' saved feeds, or what was noted
    /// when it was listened to.
    func lookup(_ url: String) -> (episode: PodcastEpisode, show: PodcastShow)? {
        // Memory first (feeds read this session, then what was noted when listening); the saved feeds on
        // disk (several MB each) only if neither knows it.
        if let found = lookupInFeeds(url, disk: false) { return found }
        if let s = started[url] { return (s.episode, s.show) }
        return lookupInFeeds(url, disk: true)
    }

    private func lookupInFeeds(_ url: String, disk: Bool = true) -> (episode: PodcastEpisode, show: PodcastShow)? {
        for (feed, c) in feeds {
            if let e = c.episodes.first(where: { $0.url == url }), let s = knownShows[feed] ?? subscriptions.first(where: { $0.feedURL == feed }) {
                return (e, s)
            }
        }
        guard disk else { return nil }
        for s in subscriptions where feeds[s.feedURL] == nil {
            if let e = cachedEpisodes(s).first(where: { $0.url == url }) { return (e, s) }
        }
        return nil
    }

    private func load<T: Decodable>(_ name: String) -> T? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    /// Encoded and written on the serial `writes` queue, in order: the played list alone can hold 20,000
    /// entries, and it's saved at every mark and pause.
    private func save<T: Encodable>(_ value: T, _ name: String) {
        let url = dir.appendingPathComponent(name)
        Self.writes.async { try? JSONEncoder().encode(value).write(to: url, options: .atomic) }
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

    /// Subscribe to several shows at once (OPML import). Returns how many were new.
    @discardableResult
    func subscribe(_ list: [PodcastShow]) -> Int {
        var added = 0
        for s in list where !isSubscribed(s) && !s.feedURL.isEmpty {
            subscriptions.append(s)
            added += 1
        }
        subscriptions.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        save(subscriptions, "subscriptions.json")
        return added
    }

    /// A subscribed feed was read: fill in what the subscription lacks (an imported show only has its name),
    /// and start its "new" count from what's out now.
    private func completeSubscription(_ feed: String, title: String, author: String, artwork: String?, newest: Double?) {
        guard let i = subscriptions.firstIndex(where: { $0.feedURL == feed }) else { return }
        var s = subscriptions[i]
        if s.title.isEmpty || s.title == feed, !title.isEmpty { s.title = title }
        if s.author.isEmpty { s.author = author }
        if s.artwork == nil { s.artwork = artwork }
        if s != subscriptions[i] {
            subscriptions[i] = s
            save(subscriptions, "subscriptions.json")
        }
        if seen[feed] == nil, let newest { seen[feed] = newest; save(seen, "seen.json") }
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
    /// Main-actor isolated: the library's state is only ever touched on main (refreshes run several of these at once).
    func episodes(_ show: PodcastShow, maxAge: Double = 600) async throws -> [PodcastEpisode] {
        knownShows[show.feedURL] = show
        _ = cachedEpisodes(show)   // loads the disk cache
        if let c = feeds[show.feedURL], Date().timeIntervalSince1970 - c.fetched < maxAge { return c.episodes }
        // Opening the window refreshes subscriptions while the show you click loads too: one download per feed.
        if let running = fetching[show.feedURL] { return try await running.value }
        let task = Task { try await self.fetch(show, fresh: maxAge <= 0) }
        fetching[show.feedURL] = task
        defer { fetching[show.feedURL] = nil }
        return try await task.value
    }

    private var fetching: [String: Task<[PodcastEpisode], Error>] = [:]
    /// Feed caches are written here, one after the other (tests wait on it with `writes.sync {}`).
    static let writes = DispatchQueue(label: "omniamp.podcast.writes", qos: .utility)

    private func fetch(_ show: PodcastShow, fresh: Bool) async throws -> [PodcastEpisode] {
        guard let url = URL(string: show.feedURL) else { return [] }
        var req = URLRequest(url: url)
        if fresh { req.cachePolicy = .reloadIgnoringLocalCacheData }   // Refresh Episodes: really ask the server
        req.setValue("OmniAmp/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, status) = try await transport.send(req)
        guard (200..<300).contains(status) else { throw ScrobbleError.http(status, "podcast feed") }
        let (eps, channel, failed) = await Task.detached(priority: .utility) { () -> ([PodcastEpisode], (title: String, author: String, artwork: String?), Bool) in
            let p = PodcastFeedParser.parse(data)
            return (p.episodes.sorted { ($0.published ?? 0) > ($1.published ?? 0) }, (p.title, p.author, p.artwork), p.failed)
        }.value
        // A login page, an error page or a damaged feed must not replace the episodes we have: keep the saved
        // copy (it's still shown, offline too) and say what went wrong.
        let saved = feeds[show.feedURL]?.episodes ?? []
        if eps.isEmpty, failed || !saved.isEmpty {
            throw PodcastFeedError.unreadable(failed ? "the feed isn't valid XML (a login or error page?)" : "the feed has no episodes now")
        }
        if failed, saved.count > eps.count {
            throw PodcastFeedError.unreadable("the feed is damaged part-way through")
        }
        migrateMovedEpisodes(from: saved, to: eps)
        let c = FeedCache(fetched: Date().timeIntervalSince1970, episodes: eps)
        feeds[show.feedURL] = c
        let file = feedFile(show.feedURL)
        Self.writes.async { try? JSONEncoder().encode(c).write(to: file, options: .atomic) }   // off the main thread, in order
        keepInMemory(show.feedURL)
        MemoryTrim.soon()   // parsing and saving a big feed leaves freed memory behind
        completeSubscription(show.feedURL, title: channel.title, author: channel.author, artwork: channel.artwork, newest: eps.first?.published)
        return eps
    }

    // Played / new

    func isPlayed(_ url: String) -> Bool { played[url] != nil }

    /// Keep the list bounded by dropping the oldest marks, never the ones just made.
    private func prunePlayed() {
        guard played.count > Self.maxPlayed else { return }
        for (k, _) in played.sorted(by: { $0.value < $1.value }).prefix(played.count - Self.maxPlayed + 1000) { played.removeValue(forKey: k) }
    }

    func markPlayed(_ url: String, _ on: Bool = true) {
        if on { played[url] = Date().timeIntervalSince1970 } else { played.removeValue(forKey: url) }
        prunePlayed()
        save(played, "played.json")
        NotificationCenter.default.post(name: Self.progressChanged, object: nil)
    }

    /// An episode from the feeds read so far or the subscriptions' saved feeds (nil if none has it).
    func knownEpisode(_ url: String) -> PodcastEpisode? { lookup(url)?.episode }

    /// Newest episode date the user had seen of a subscribed show (nil: not subscribed, nothing is "new").
    func seenMark(_ show: PodcastShow) -> Double? {
        isSubscribed(show) ? (seen[show.feedURL] ?? .infinity) : nil
    }

    /// Episodes released since the user last opened this show.
    func newCount(_ show: PodcastShow) -> Int {
        guard isSubscribed(show) else { return 0 }
        let since = seen[show.feedURL] ?? .infinity
        return cachedEpisodes(show).filter { ($0.published ?? 0) > since && !isPlayed($0.url) }.count
    }

    /// Feeds of shows you don't subscribe to stay in memory only while recent (they're on disk anyway):
    /// browsing the charts would otherwise keep every show's episodes and notes for the whole session.
    private var recentFeeds: [String] = []
    private func keepInMemory(_ feed: String) {
        recentFeeds.removeAll { $0 == feed }
        recentFeeds.append(feed)
        let subscribed = Set(subscriptions.map(\.feedURL))
        let others = recentFeeds.filter { !subscribed.contains($0) }
        for f in others.dropLast(3) {
            feeds.removeValue(forKey: f)
            recentFeeds.removeAll { $0 == f }
        }
    }

    /// Posted with `userInfo["moved"]: [old URL: new URL]` when episodes' audio addresses changed.
    static let episodesMoved = Notification.Name("OmniAmp.podcastEpisodesMoved")

    /// Feeds sometimes change an episode's audio address (a tracking prefix added, a new CDN) while its guid
    /// stays: carry played, listened and downloaded state (and, via the notification, resume positions and
    /// playlist entries) over to the new address.
    private func migrateMovedEpisodes(from old: [PodcastEpisode], to new: [PodcastEpisode]) {
        // Only guids that name one episode on both sides (some feeds give every item the same one), and only
        // addresses that really left the feed.
        func unique(_ list: [PodcastEpisode]) -> [String: String] {
            var map: [String: String] = [:], dup = Set<String>()
            for e in list { if let g = e.guid, !g.isEmpty { if map.updateValue(e.url, forKey: g) != nil { dup.insert(g) } } }
            dup.forEach { map.removeValue(forKey: $0) }
            return map
        }
        let before = unique(old), after = unique(new)
        let stillThere = Set(new.map(\.url))
        var moved: [String: String] = [:]
        for (g, now) in after { if let was = before[g], was != now, !stillThere.contains(was) { moved[was] = now } }
        guard !moved.isEmpty else { return }
        for (was, now) in moved {
            if let d = played.removeValue(forKey: was) { played[now] = d }
            if let d = listened.removeValue(forKey: was) { listened[now] = d }
            if var s = started.removeValue(forKey: was) { s.episode.url = now; started[now] = s }
        }
        save(played, "played.json")
        save(listened, "listened.json")
        save(started, "started.json")
        PodcastDownloads.shared.rekey(moved)
        NSLog("OmniAmp: %d episode address(es) changed in a feed; their state moved along", moved.count)
        NotificationCenter.default.post(name: Self.episodesMoved, object: nil, userInfo: ["moved": moved])
    }

    /// Mark (or unmark) many at once: one save and one refresh, not one per episode.
    func markPlayed(_ urls: [String], _ on: Bool = true) {
        let now = Date().timeIntervalSince1970
        for u in urls { if on { played[u] = now } else { played.removeValue(forKey: u) } }
        prunePlayed()
        save(played, "played.json")
        NotificationCenter.default.post(name: Self.progressChanged, object: nil)
    }

    func markSeen(_ show: PodcastShow) {
        guard isSubscribed(show), let newest = cachedEpisodes(show).first?.published, seen[show.feedURL] != newest else { return }
        seen[show.feedURL] = newest
        save(seen, "seen.json")
    }
}
