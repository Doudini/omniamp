import Foundation

// Audiobooks and radio plays (Hörspiele) for the Podcasts window's Books mode. A book or a series is a
// `PodcastShow` and its parts are `PodcastEpisode`s, so resume, speed, downloads, played marks and Continue
// listening work as they do for podcasts. What tells a book apart is its feed address: not an RSS URL but
// `ard:<programSet>`, `ard-search:<words>`, `archive:<item>` or `librivox:<item>`.
//
// Sources (no key needed for any):
// - ARD Audiothek (ARD Sounds): the public broadcasters' radio plays and readings, through the GraphQL API its
//   own site uses. Its editorial categories (Hörspiel, Hörbuch, Für Kinder) are the browse lists, and search is
//   limited to the series in them (the API's search covers every news and talk show too). Items stay online for
//   a year or two; some may only be streamed (`allowDownload`).
// - archive.org: any audio item. One item is one book; its MP3 files are the parts.
// - LibriVox: public-domain audiobooks read by volunteers. Every LibriVox book is also an archive.org item (the
//   `librivoxaudio` collection), and archive.org answers in a second where LibriVox's own API takes 10–15 s,
//   so LibriVox books are found and read through archive.org.

enum BookSource: String {
    case ard
    /// Single radio plays that match a search, from all of ARD's Hörspiel / Hörbuch series.
    case ardSearch = "ard-search"
    case archive
    case librivox
}

extension PodcastShow {
    /// Where a book or radio-play series comes from; nil for a podcast (an RSS feed).
    var bookSource: BookSource? {
        guard let colon = feedURL.firstIndex(of: ":") else { return nil }
        return BookSource(rawValue: String(feedURL[..<colon]))
    }
    var isBook: Bool { bookSource != nil }
    /// The source's own id: the programSet, the archive.org identifier, or the words searched for.
    var bookID: String {
        guard let colon = feedURL.firstIndex(of: ":") else { return "" }
        return String(feedURL[feedURL.index(after: colon)...])
    }
    /// One archive.org item: its parts never change, so it's read again once a week, not every 10 minutes.
    var isFixedBook: Bool { bookSource == .archive || bookSource == .librivox }
    /// Shown next to the author in the list.
    var sourceLabel: String? {
        switch bookSource {
        case .ard, .ardSearch: "ARD"
        case .librivox: "LibriVox"
        case .archive: "archive.org"
        case nil: nil
        }
    }
}

@MainActor
final class BookDirectory {
    static let shared = BookDirectory()
    var transport: HTTPTransport
    private let cacheDir: URL

    /// `cacheDir` (tests): where the browse lists are kept. Otherwise next to the podcast caches.
    init(transport: HTTPTransport = URLSessionTransport(), cacheDir: URL? = nil) {
        self.transport = transport
        self.cacheDir = cacheDir ?? LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("Podcasts/books", isDirectory: true)
    }

    /// The browse lists (BROWSE in Books mode).
    enum Shelf: String, CaseIterable {
        case ardRadioPlays, ardAudiobooks, ardKids, librivoxGerman, librivoxAll, archiveRadioPlays, oldTimeRadio

        var title: String {
            switch self {
            case .ardRadioPlays: "ARD Hörspiele"
            case .ardAudiobooks: "ARD Hörbücher"
            case .ardKids: "ARD für Kinder"
            case .librivoxGerman: "LibriVox Deutsch"
            case .librivoxAll: "LibriVox (all languages)"
            case .archiveRadioPlays: "archive.org Hörspiele"
            case .oldTimeRadio: "Old-time radio"
            }
        }
        /// ARD's editorial category for the list.
        var ardCategory: String? {
            switch self {
            case .ardRadioPlays: "42914712"
            case .ardAudiobooks: "42914713"
            case .ardKids: "42914714"
            default: nil
            }
        }
        /// The archive.org search for the list.
        var archiveQuery: String? {
            switch self {
            case .librivoxGerman: "collection:librivoxaudio AND language:(ger OR deu OR German)"
            case .librivoxAll: "collection:librivoxaudio"
            case .archiveRadioPlays: "(subject:hörspiel OR subject:hoerspiel OR collection:germanradio OR collection:radioaufnahmen) AND mediatype:audio"
            case .oldTimeRadio: "collection:oldtimeradio"
            default: nil
            }
        }
    }

    // MARK: Requests

    /// archive.org asks bots to slow down with a 429: wait a moment and try once more.
    private func send(_ req: URLRequest, what: String) async throws -> Data {
        var req = req
        req.setValue(MetadataLookup.userAgent, forHTTPHeaderField: "User-Agent")
        var (data, status) = try await transport.send(req)
        if status == 429 {
            try await Task.sleep(for: .seconds(2))
            (data, status) = try await transport.send(req)
        }
        guard (200..<300).contains(status) else { throw ScrobbleError.http(status, what) }
        return data
    }

    private static let ardURL = URL(string: "https://api.ardaudiothek.de/graphql")!

    /// One GraphQL request; the answer's whole body (the decoders read `data`).
    private func ard(_ query: String, _ variables: [String: String]) async throws -> Data {
        var req = URLRequest(url: Self.ardURL, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let data = try await send(req, what: "ARD Audiothek")
        // GraphQL answers 200 with "errors" (and no data) when it refuses a query.
        if Self.dataNode(data) == nil, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let message = (root["errors"] as? [[String: Any]])?.first?["message"] as? String {
            throw PodcastFeedError.unreadable("ARD Audiothek refused the request (\(message))")
        }
        return data
    }

    private func archiveSearch(_ q: String, rows: Int) async throws -> Data {
        var c = URLComponents(string: "https://archive.org/advancedsearch.php")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
            + ["identifier", "title", "creator", "collection", "language", "licenseurl"].map { URLQueryItem(name: "fl[]", value: $0) }
            + [URLQueryItem(name: "sort[]", value: "downloads desc"), URLQueryItem(name: "rows", value: String(rows)),
               URLQueryItem(name: "output", value: "json")]
        // A literal + in the query would reach Solr as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return try await send(URLRequest(url: c.url!, timeoutInterval: 20), what: "archive.org")
    }

    // MARK: Browse

    private struct List: Codable { var fetched: Double; var shows: [PodcastShow] }
    private var lists: [Shelf: List] = [:]
    nonisolated private static let listMaxAge: TimeInterval = 12 * 3600

    private func listFile(_ shelf: Shelf) -> URL { cacheDir.appendingPathComponent(shelf.rawValue + ".json") }

    /// The last copy of a browse list, however old (shown at once while a fresh one loads).
    func cachedBrowse(_ shelf: Shelf) -> (shows: [PodcastShow], fresh: Bool)? {
        if lists[shelf] == nil, let d = try? Data(contentsOf: listFile(shelf)), let l = try? JSONDecoder().decode(List.self, from: d) {
            lists[shelf] = l
        }
        guard let l = lists[shelf], !l.shows.isEmpty else { return nil }
        return (l.shows, Date().timeIntervalSince1970 - l.fetched < Self.listMaxAge)
    }

    func browse(_ shelf: Shelf) async throws -> [PodcastShow] {
        if let c = cachedBrowse(shelf), c.fresh { return c.shows }
        let shows: [PodcastShow]
        if let cat = shelf.ardCategory {
            shows = Self.decodeARDCategory(try await ard(Self.categoryQuery, ["id": cat]))
        } else {
            shows = Self.decodeArchiveSearch(try await archiveSearch(shelf.archiveQuery ?? "", rows: 150))
        }
        let l = List(fetched: Date().timeIntervalSince1970, shows: shows)
        lists[shelf] = l
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(l).write(to: listFile(shelf), options: .atomic)
        return shows
    }

    // MARK: Search

    private var searchCache: [String: (at: Date, shows: [PodcastShow])] = [:]

    /// `fetch` says whether its answer may be kept (not when it was made from incomplete lists).
    private func cachedSearch(_ key: String, _ fetch: () async throws -> (shows: [PodcastShow], keep: Bool)) async throws -> [PodcastShow] {
        if let c = searchCache[key], Date().timeIntervalSince(c.at) < 30 * 60 { return c.shows }
        let (shows, keep) = try await fetch()
        if searchCache.count > 40 { searchCache.removeAll() }
        if keep { searchCache[key] = (Date(), shows) }
        return shows
    }

    /// ARD's Hörspiel, Hörbuch and children's series (the ids search results are kept to). A list that can't be
    /// loaded falls back to its last copy, however old; `complete` is false when one has neither.
    private func ardSeriesIDs() async throws -> (ids: Set<String>, complete: Bool) {
        var ids = Set<String>(), complete = true, failure: Error?
        for shelf in Shelf.allCases where shelf.ardCategory != nil {
            do {
                ids.formUnion(try await browse(shelf).map(\.bookID))
            } catch {
                if let old = cachedBrowse(shelf) { ids.formUnion(old.shows.map(\.bookID)) } else { complete = false; failure = error }
            }
        }
        // Without any list every result would be dropped: say why instead of "nothing found".
        if ids.isEmpty, let failure { throw failure }
        return (ids, complete)
    }

    /// Matching series, plus (first) one entry holding the single radio plays that match.
    func searchARD(_ term: String) async throws -> [PodcastShow] {
        try await cachedSearch("ard|" + term.lowercased()) {
            let (allowed, complete) = try await ardSeriesIDs()
            let data = try await ard(Self.searchQuery, ["q": term])
            var shows = Self.decodeARDSearchSets(data, allowed: allowed, term: term)
            let items = Self.decodeARDSearchItems(data, allowed: allowed, term: term)
            if !items.isEmpty {
                shows.insert(PodcastShow(feedURL: "ard-search:" + term, title: "“\(term)” in ARD radio plays",
                                         author: "", artwork: nil, genre: "\(items.count) found in ARD Audiothek"), at: 0)
            }
            return (shows, complete)
        }
    }

    /// Any audio item whose title, creator or subject has every word.
    func searchArchive(_ term: String) async throws -> [PodcastShow] {
        try await cachedSearch("archive|" + term.lowercased()) {
            (Self.decodeArchiveSearch(try await archiveSearch(Self.archiveQuery(for: term), rows: 100)), true)
        }
    }

    nonisolated static func archiveQuery(for term: String) -> String {
        let words = term.split(whereSeparator: \.isWhitespace).map { lucene(String($0)) }.filter { !$0.isEmpty }
        let all = "(" + words.joined(separator: " AND ") + ")"
        // Live concerts have their own place (the library's Live Music Archive).
        return "(title:\(all) OR creator:\(all) OR subject:\(all)) AND mediatype:audio AND NOT collection:etree"
    }

    /// Solr's special characters escaped (a typed "???" or "c++" is text, not syntax).
    nonisolated static func lucene(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "+-&|!(){}[]^\"~*?:\\/".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // MARK: Parts

    func episodes(for show: PodcastShow) async throws -> [PodcastEpisode] {
        switch show.bookSource {
        case .ard:
            return Self.decodeARDSet(try await ard(Self.setQuery, ["id": show.bookID]))
        case .ardSearch:
            let allowed = try await ardSeriesIDs().ids
            return Self.decodeARDSearchItems(try await ard(Self.searchQuery, ["q": show.bookID]), allowed: allowed, term: show.bookID)
        case .archive, .librivox:
            let id = show.bookID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? show.bookID
            let data = try await send(URLRequest(url: URL(string: "https://archive.org/metadata/\(id)")!, timeoutInterval: 20), what: "archive.org")
            guard let eps = Self.decodeArchiveItem(data, id: show.bookID) else {
                throw PodcastFeedError.unreadable("archive.org no longer has this item (removed, or not public)")
            }
            return eps
        case nil:
            return []
        }
    }

    // MARK: ARD decoding

    private static let setFields = "id title synopsis numberOfElements image { url } publicationService { title }"
    // Search answers with ItemInterface, which has no episodeNumber: part numbers come from the titles.
    private static let itemFields = "id title synopsis duration publishDate endDate image { url } "
        + "programSet { id title } audios { url downloadUrl allowDownload mimeType }"
    private static let categoryQuery = "query($id: ID!) { editorialCategory(id: $id) { sections { type nodes { __typename "
        + "... on ProgramSet { \(setFields) } } } } }"
    private static let searchQuery = "query($q: String) { search(query: $q, limit: 200) { programSets { nodes { \(setFields) } } "
        + "items { nodes { \(itemFields) } } } }"
    /// The newest 1000 (ARD's Hörspiel-Speicher alone has ~2000, many of them no longer playable).
    private static let setQuery = "query($id: ID!) { programSet(id: $id) { items(first: 1000) { nodes { \(itemFields) } } } }"

    nonisolated private static func dataNode(_ data: Data) -> [String: Any]? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [String: Any]
    }

    /// ARD image addresses have a {width} to fill in.
    nonisolated static func ardImage(_ node: [String: Any]?, width: Int = 400) -> String? {
        ((node?["image"] as? [String: Any])?["url"] as? String)?.replacingOccurrences(of: "{width}", with: String(width))
    }

    nonisolated static func ardSet(_ n: [String: Any]) -> PodcastShow? {
        guard let id = n["id"] as? String, let title = (n["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        let station = (n["publicationService"] as? [String: Any])?["title"] as? String
        return PodcastShow(feedURL: "ard:" + id, title: title, author: station ?? "ARD", artwork: ardImage(n), genre: "ARD Audiothek")
    }

    /// A category's series: the featured ones first, then the rest; empty ones left out.
    nonisolated static func decodeARDCategory(_ data: Data) -> [PodcastShow] {
        let sections = (dataNode(data)?["editorialCategory"] as? [String: Any])?["sections"] as? [[String: Any]] ?? []
        var seen = Set<String>(), out: [PodcastShow] = []
        for s in sections {
            for n in s["nodes"] as? [[String: Any]] ?? [] where n["__typename"] as? String == "ProgramSet" {
                guard (n["numberOfElements"] as? Int ?? 0) > 0, let show = ardSet(n), seen.insert(show.feedURL).inserted else { continue }
                out.append(show)
            }
        }
        return out
    }

    nonisolated static func decodeARDSearchSets(_ data: Data, allowed: Set<String>, term: String) -> [PodcastShow] {
        let nodes = ((dataNode(data)?["search"] as? [String: Any])?["programSets"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.filter { mentions($0, term) }.compactMap(ardSet).filter { allowed.contains($0.bookID) }
    }

    nonisolated static func decodeARDSearchItems(_ data: Data, allowed: Set<String>, term: String) -> [PodcastEpisode] {
        let nodes = ((dataNode(data)?["search"] as? [String: Any])?["items"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.filter { n in ((n["programSet"] as? [String: Any])?["id"] as? String).map(allowed.contains) ?? false }
            .filter { mentions($0, term) }
            .compactMap { ardItem($0, inSearch: true) }
    }

    /// ARD's search matches any one of the words (and loosely): keep what has every word in its title, its
    /// series' title or its description.
    nonisolated static func mentions(_ n: [String: Any], _ term: String) -> Bool {
        let words = term.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let hay = [n["title"], (n["programSet"] as? [String: Any])?["title"], n["synopsis"]].compactMap { $0 as? String }
            .joined(separator: " ").lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    /// A series' plays: newest first like a podcast, unless every one has a part number (a serial, a reading
    /// in chapters): then in story order.
    nonisolated static func decodeARDSet(_ data: Data) -> [PodcastEpisode] {
        let items = ((dataNode(data)?["programSet"] as? [String: Any])?["items"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let eps = items.compactMap { ardItem($0, inSearch: false) }.sorted { ($0.published ?? 0) > ($1.published ?? 0) }
        return storyOrder(eps) ?? eps.map { var e = $0; e.number = nil; return e }
    }

    nonisolated private static func isoDate(_ s: String) -> Double? { ISO8601DateFormatter().date(from: s)?.timeIntervalSince1970 }

    /// One play; nil when it has no audio any more (taken offline, but still listed).
    nonisolated static func ardItem(_ n: [String: Any], inSearch: Bool) -> PodcastEpisode? {
        guard let id = n["id"] as? String, let title = (n["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, let audios = n["audios"] as? [[String: Any]], !audios.isEmpty else { return nil }
        func isMP3(_ a: [String: Any]) -> Bool {
            ((a["mimeType"] as? String)?.contains("mp3") ?? false) || ((a["url"] as? String)?.lowercased().hasSuffix(".mp3") ?? false)
        }
        let mp3 = audios.filter(isMP3)
        guard let pick = mp3.first(where: { $0["allowDownload"] as? Bool == true }) ?? mp3.first ?? audios.first,
              let url = pick["url"] as? String, url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
        var summary = (n["synopsis"] as? String).map(PodcastFeedParser.plainText)
        // In a search the plays come from many series: say which.
        if inSearch, let series = (n["programSet"] as? [String: Any])?["title"] as? String {
            summary = [series, summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        var e = PodcastEpisode(title: title, url: url, published: (n["publishDate"] as? String).flatMap(isoDate),
                               duration: (n["duration"] as? Double) ?? (n["duration"] as? Int).map(Double.init),
                               summary: summary, image: ardImage(n), guid: "ard:" + id)
        e.downloadable = pick["allowDownload"] as? Bool ?? false
        e.expires = (n["endDate"] as? String).flatMap(isoDate)
        return e
    }

    // MARK: Part order

    /// The part number in a title: "Teil 3", "Folge 12", "Kapitel 2", "(3/8)", "03 - …".
    nonisolated static func partNumber(_ title: String) -> Int? {
        let patterns = [#"(?i)\b(?:teil|folge|kapitel|episode|part|chapter)\s*(\d{1,4})\b"#, #"\((\d{1,3})\s*/\s*\d{1,3}\)"#,
                        #"^\s*(\d{1,4})\s*[.:)\-–]\s"#]
        let ns = title as NSString
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)) else { continue }
            return Int(ns.substring(with: m.range(at: 1)))
        }
        return nil
    }

    /// Ascending by part number when every part has a different one (two at least); nil otherwise.
    nonisolated static func storyOrder(_ eps: [PodcastEpisode]) -> [PodcastEpisode]? {
        guard eps.count >= 2 else { return nil }
        let keys = eps.map { $0.number ?? partNumber($0.title) }
        let known = keys.compactMap { $0 }
        guard known.count == eps.count, Set(known).count == known.count else { return nil }
        return zip(eps, known).sorted { $0.1 < $1.1 }.map { var e = $0.0; e.number = $0.1; return e }
    }

    // MARK: archive.org decoding

    nonisolated static func decodeArchiveSearch(_ data: Data) -> [PodcastShow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let docs = (root["response"] as? [String: Any])?["docs"] as? [[String: Any]] else { return [] }
        return docs.compactMap { d in
            guard let id = d["identifier"] as? String, !id.isEmpty else { return nil }
            let title = strings(d["title"]).first ?? id
            let isLibriVox = strings(d["collection"]).contains("librivoxaudio")
            let info = [isLibriVox ? "LibriVox" : "archive.org", licence(strings(d["licenseurl"]).first),
                        language(strings(d["language"]).first)].compactMap { $0 }
            return PodcastShow(feedURL: (isLibriVox ? "librivox:" : "archive:") + id, title: title,
                               author: strings(d["creator"]).prefix(2).joined(separator: ", "),
                               artwork: "https://archive.org/services/img/" + id, genre: info.joined(separator: " · "))
        }
    }

    /// archive.org gives a single value as a string and several as a list.
    nonisolated static func strings(_ v: Any?) -> [String] {
        if let s = v as? String { return s.isEmpty ? [] : [s] }
        return (v as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
    }

    /// What an item's licence lets you do, in a few words.
    nonisolated static func licence(_ url: String?) -> String {
        guard let u = url?.lowercased(), !u.isEmpty else { return "no licence stated" }
        if u.contains("publicdomain") || u.contains("/zero/") { return "public domain" }
        if let r = u.range(of: "creativecommons.org/licenses/") {
            let code = u[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            return code.isEmpty ? "Creative Commons" : "CC " + code.uppercased()
        }
        return "licence: " + (URL(string: u)?.host ?? u)
    }

    nonisolated static func language(_ code: String?) -> String? {
        guard let c = code?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return nil }
        switch c.lowercased() {
        case "ger", "deu", "de", "german", "deutsch": return "German"
        case "eng", "en", "english": return "English"
        case "fre", "fra", "fr", "french": return "French"
        case "spa", "es", "spanish": return "Spanish"
        case "ita", "it", "italian": return "Italian"
        case "dut", "nld", "nl", "dutch": return "Dutch"
        default: return c.count <= 20 ? c.prefix(1).uppercased() + c.dropFirst() : nil
        }
    }

    /// An item's parts in order. nil when archive.org has no such item any more (it answers `{}`).
    nonisolated static func decodeArchiveItem(_ data: Data, id: String) -> [PodcastEpisode]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let files = root["files"] as? [[String: Any]] else { return nil }
        let meta = root["metadata"] as? [String: Any]
        let notes = strings(meta?["description"]).first.map(PodcastFeedParser.plainText)
        // The MP3s archive.org makes of everything, else the uploaded files macOS can play.
        let mp3s = ["VBR MP3", "MP3", "128Kbps MP3", "64Kbps MP3"]
        func playable(_ f: [String: Any]) -> Bool {
            ["mp3", "m4a", "m4b", "aac", "flac", "wav"].contains(((f["name"] as? String ?? "") as NSString).pathExtension.lowercased())
        }
        var chosen: [[String: Any]] = []
        for f in mp3s {
            chosen = files.filter { $0["format"] as? String == f }
            if !chosen.isEmpty { break }
        }
        if chosen.isEmpty {
            chosen = files.filter { $0["source"] as? String == "original" && playable($0) }
        }
        // An item can mix formats (a FLAC part got MP3 copies, an uploaded MP3 part kept only its "MP3"): every
        // uploaded file none of the chosen ones was made from is added too, as its best MP3 (itself or a copy).
        // Not one without any MP3, such as LibriVox's whole book as one .m4b next to its parts.
        // A copy can be made from another copy, so each file is traced back to the upload it came from.
        let byName = Dictionary(files.compactMap { f in (f["name"] as? String).map { ($0, f) } }, uniquingKeysWith: { a, _ in a })
        func upload(_ f: [String: Any]) -> String? {
            var f = f
            for _ in 0..<5 {
                guard f["source"] as? String == "derivative" else { return f["name"] as? String }
                guard let o = f["original"] as? String, let next = byName[o] else { return f["original"] as? String }
                f = next
            }
            return nil
        }
        // Uploaders often put up each part twice ("01.flac" and "01.mp3"): the same name is the same part.
        func stem(_ name: String) -> String { (name as NSString).deletingPathExtension.lowercased() }
        let covered = Set(chosen.compactMap(upload)), coveredStems = Set(covered.map(stem))
        for o in files where o["source"] as? String == "original" {
            guard let name = o["name"] as? String, !covered.contains(name), !coveredStems.contains(stem(name)) else { continue }
            let versions = [o] + files.filter { $0["source"] as? String == "derivative" && upload($0) == name }
            if let best = mp3s.lazy.compactMap({ f in versions.first { $0["format"] as? String == f } }).first { chosen.append(best) }
        }
        let named = chosen.compactMap { f in (f["name"] as? String).map { ($0, f) } }
        // By track number when every file has a different one, else by name ("2" before "10").
        let tracks = named.map { trackNumber($0.1["track"]) }
        let ordered: [(String, [String: Any])]
        if !tracks.contains(nil), Set(tracks.compactMap { $0 }).count == tracks.count {
            ordered = zip(named, tracks).sorted { $0.1! < $1.1! }.map(\.0)
        } else {
            ordered = named.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        }
        return ordered.enumerated().compactMap { i, pair in
            let (name, f) = pair
            let path = name.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            let base = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            let title = (f["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? base
            var e = PodcastEpisode(title: title, url: "https://archive.org/download/\(id)/\(path)", published: nil,
                                   duration: length(f["length"]), summary: notes, number: i + 1, guid: id + "/" + name)
            e.downloadable = true
            return e
        }
    }

    /// "3", "03" or "3/12"; nil for anything else (some uploads have junk there).
    nonisolated static func trackNumber(_ v: Any?) -> Int? {
        guard let s = v as? String, let first = s.split(separator: "/").first else { return nil }
        return Int(first.trimmingCharacters(in: .whitespaces))
    }

    /// Seconds ("2465.8") or a clock ("41:05", "1:02:03").
    nonisolated static func length(_ v: Any?) -> Double? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if !s.contains(":") { return Double(s) }
        let parts = s.split(separator: ":").map { Double($0) }
        guard !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}
