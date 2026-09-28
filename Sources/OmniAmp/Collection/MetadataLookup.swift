import Foundation

/// A possible identity for a release, from one online source.
struct InfoCandidate: Equatable, Sendable {
    enum Source: String, Sendable { case musicBrainz = "MusicBrainz", iTunes = "iTunes", deezer = "Deezer", archive = "archive.org" }
    var source: Source
    var artist: String
    var album: String
    var year: Int?
    var genre: String?
    /// A cover to show in the list (small) and to save (large).
    var thumbURL: URL?
    var coverURL: URL?
    /// "Album · 1999-04-20", "SBD · Ithaca, NY"…
    var detail: String
    /// How well it matches what we have (0…1), for the order of the list.
    var score: Double
}

/// Looks a release up in public databases that need no account or key: MusicBrainz (with the Cover Art
/// Archive), the iTunes Store, Deezer, and for concert recordings archive.org's Live Music Archive.
///
/// MusicBrainz allows one request per second per client and asks for a User-Agent that says who's calling.
final class MetadataLookup: @unchecked Sendable {
    static let shared = MetadataLookup()
    static let userAgent = "OmniAmp/\(Updater.currentVersion) ( https://github.com/Doudini/omniamp )"

    private let http: HTTPTransport
    /// Wait before asking a busy MusicBrainz again (grows with each try).
    var retryPause: UInt64 = 3_000_000_000
    /// One gate for every MusicBrainz call in the app: its limit is per client, not per feature.
    private static let sharedGate = Gate(interval: 1.25)
    private let mbGate: Gate

    /// `pace`: seconds between MusicBrainz requests; nil = the app-wide gate (tests pass 0).
    init(http: HTTPTransport = URLSessionTransport(), pace: TimeInterval? = nil) {
        self.http = http
        mbGate = pace.map { Gate(interval: $0) } ?? Self.sharedGate
    }

    /// All sources at once; results best-first. A source that fails or times out just adds nothing.
    func candidates(artist: String, album: String, showDate: String? = nil) async -> [InfoCandidate] {
        async let mb = musicBrainz(artist: artist, album: album)
        async let it = iTunes(artist: artist, album: album)
        async let dz = deezer(artist: artist, album: album)
        async let ar = showDate != nil ? archive(artist: artist, date: showDate!) : []
        let all0 = await ar + mb + it + dz
        var all = all0
        for i in all.indices { all[i].score = max(all[i].score, Self.similarity(artist: artist, album: album, to: all[i])) }
        return all.sorted { $0.score > $1.score }
    }

    /// 1 when artist and title match after folding ("The", accents, punctuation), less the further off they are.
    static func similarity(artist: String, album: String, to c: InfoCandidate) -> Double {
        func sim(_ a: String, _ b: String) -> Double {
            let x = Keys.artist(a), y = Keys.artist(b)
            if x == y { return 1 }
            if x.isEmpty || y.isEmpty { return 0 }
            if x.contains(y) || y.contains(x) { return 0.7 }
            let wa = Set(x.split(separator: " ")), wb = Set(y.split(separator: " "))
            return Double(wa.intersection(wb).count) / Double(max(wa.union(wb).count, 1)) * 0.6
        }
        return sim(artist, c.artist) * 0.45 + sim(album, c.album) * 0.55
    }

    // MARK: Sources

    private func get(_ url: URL, musicBrainz: Bool = false) async -> Any? {
        // MusicBrainz sheds load with 503 "currently busy" now and then: that request, a few seconds later, works.
        for attempt in 0..<(musicBrainz ? 4 : 1) {
            if musicBrainz { await mbGate.wait() }
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if musicBrainz, ProcessInfo.processInfo.environment["OMNIAMP_DEBUG"] != nil { NSLog("OmniAmp: MB request %@", url.absoluteString) }
            guard let (data, status) = try? await http.send(req) else {
                if musicBrainz { NSLog("OmniAmp: MusicBrainz unreachable") }
                return nil
            }
            if status == 200 { return try? JSONSerialization.jsonObject(with: data) }
            if musicBrainz, status == 503, attempt < 3 {
                try? await Task.sleep(nanoseconds: retryPause * UInt64(1 + attempt))
                continue
            }
            if musicBrainz, status != 404, status != 400 { NSLog("OmniAmp: MusicBrainz answered %d", status) }
            return nil
        }
        return nil
    }

    private static func url(_ base: String, _ query: [String: String]) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }

    /// Lucene query text: quotes and backslashes escaped.
    private static func lucene(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func musicBrainz(artist: String, album: String) async -> [InfoCandidate] {
        let q = "releasegroup:\(Self.lucene(album)) AND artist:\(Self.lucene(artist))"
        guard let json = await get(Self.url("https://musicbrainz.org/ws/2/release-group/", ["query": q, "fmt": "json", "limit": "5"]),
                                   musicBrainz: true) as? [String: Any],
              let groups = json["release-groups"] as? [[String: Any]] else { return [] }
        var out: [InfoCandidate] = []
        for (i, g) in groups.prefix(4).enumerated() {
            guard let id = g["id"] as? String, let title = g["title"] as? String else { continue }
            let credit = (g["artist-credit"] as? [[String: Any]])?.compactMap { part in (part["name"] as? String).map { $0 + ((part["joinphrase"] as? String) ?? "") } }
                .joined() ?? artist
            let date = g["first-release-date"] as? String
            let type = [g["primary-type"] as? String].compactMap { $0 } + ((g["secondary-types"] as? [String]) ?? [])
            var c = InfoCandidate(source: .musicBrainz, artist: credit, album: title, year: Keys.year(date), genre: nil,
                                  thumbURL: URL(string: "https://coverartarchive.org/release-group/\(id)/front-250"),
                                  coverURL: URL(string: "https://coverartarchive.org/release-group/\(id)/front-1200"),
                                  detail: (type.isEmpty ? ["Release"] : type).joined(separator: " + ") + (date.map { " · \($0)" } ?? ""),
                                  score: Double((g["score"] as? Int) ?? 0) / 100 * 0.9)
            // Genres need the release group itself: only for the best match (one more request, a second later).
            if i == 0, let d = await get(URL(string: "https://musicbrainz.org/ws/2/release-group/\(id)?inc=genres&fmt=json")!,
                                         musicBrainz: true) as? [String: Any] {
                let genres = ((d["genres"] as? [[String: Any]]) ?? []).sorted { ($0["count"] as? Int ?? 0) > ($1["count"] as? Int ?? 0) }
                c.genre = (genres.first?["name"] as? String).map(Self.titleCase)
            }
            out.append(c)
        }
        return out
    }

    func iTunes(artist: String, album: String) async -> [InfoCandidate] {
        guard let json = await get(Self.url("https://itunes.apple.com/search", ["term": "\(artist) \(album)", "entity": "album", "limit": "5"]))
                as? [String: Any], let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let title = r["collectionName"] as? String, let a = r["artistName"] as? String else { return nil }
            let art = r["artworkUrl100"] as? String
            let date = (r["releaseDate"] as? String).map { String($0.prefix(10)) }
            return InfoCandidate(source: .iTunes, artist: a, album: title, year: Keys.year(date), genre: r["primaryGenreName"] as? String,
                                 thumbURL: art.flatMap { URL(string: $0.replacingOccurrences(of: "100x100", with: "200x200")) },
                                 coverURL: art.flatMap { URL(string: $0.replacingOccurrences(of: "100x100", with: "1200x1200")) },
                                 detail: "\((r["trackCount"] as? Int).map { "\($0) tracks" } ?? "Album")" + (date.map { " · \($0)" } ?? ""),
                                 score: 0)
        }
    }

    func deezer(artist: String, album: String) async -> [InfoCandidate] {
        let q = "artist:\(Self.lucene(artist)) album:\(Self.lucene(album))"
        guard let json = await get(Self.url("https://api.deezer.com/search/album", ["q": q, "limit": "4"])) as? [String: Any],
              let data = json["data"] as? [[String: Any]] else { return [] }
        var out: [InfoCandidate] = []
        for (i, r) in data.enumerated() {
            guard let title = r["title"] as? String, let a = (r["artist"] as? [String: Any])?["name"] as? String else { continue }
            var c = InfoCandidate(source: .deezer, artist: a, album: title, year: nil, genre: nil,
                                  thumbURL: (r["cover_medium"] as? String).flatMap(URL.init(string:)),
                                  coverURL: (r["cover_xl"] as? String).flatMap(URL.init(string:)),
                                  detail: "\((r["nb_tracks"] as? Int).map { "\($0) tracks" } ?? "Album")", score: 0)
            // Year and genres are on the album itself: fetched for the first result only.
            if i == 0, let id = r["id"] as? Int, let d = await get(URL(string: "https://api.deezer.com/album/\(id)")!) as? [String: Any] {
                let date = d["release_date"] as? String
                c.year = Keys.year(date)
                c.genre = (((d["genres"] as? [String: Any])?["data"] as? [[String: Any]])?.first?["name"] as? String)
                if let date { c.detail += " · \(date)" }
            }
            out.append(c)
        }
        return out
    }

    /// Recordings of a concert in the Live Music Archive (jam bands and other taper-friendly acts).
    func archive(artist: String, date: String) async -> [InfoCandidate] {
        let q = "collection:etree AND creator:\(Self.lucene(artist)) AND date:\(date)"
        var c = URLComponents(string: "https://archive.org/advancedsearch.php")!
        c.queryItems = [URLQueryItem(name: "q", value: q)] + ["identifier", "title", "venue", "coverage", "source", "date"].map {
            URLQueryItem(name: "fl[]", value: $0)
        } + [URLQueryItem(name: "rows", value: "5"), URLQueryItem(name: "output", value: "json")]
        guard let url = c.url, let json = await get(url) as? [String: Any],
              let docs = (json["response"] as? [String: Any])?["docs"] as? [[String: Any]] else { return [] }
        return docs.compactMap { d in
            let venue = [d["venue"] as? String, d["coverage"] as? String].compactMap { $0 }.joined(separator: ", ")
            let source = (d["source"] as? String) ?? ((d["source"] as? [String])?.first) ?? ""
            // SBD / AUD / matrix, from the source notes or the recording's name ("gd1977-05-08.sbd.cube…").
            let words = (source + " " + ((d["identifier"] as? String) ?? "")).lowercased()
                .split(whereSeparator: { !$0.isLetter }).map(String.init)
            let kind = ["sbd", "aud", "matrix", "mtx", "fm"].first { words.contains($0) }?.uppercased()
            return InfoCandidate(source: .archive, artist: artist, album: venue.isEmpty ? date : "\(date) \(venue)", year: Keys.year(date),
                                 genre: nil, thumbURL: nil, coverURL: nil,
                                 detail: [kind, d["identifier"] as? String].compactMap { $0 }.joined(separator: " · "), score: 0.95)
        }
    }

    // MARK: Artist countries

    /// An ISO country code, or nil for MusicBrainz's regions ("XE" Europe, "XW" worldwide…) that aren't countries.
    static func realCountry(_ code: String) -> String? {
        let c = code.uppercased()
        return c.count == 2 && !["XE", "XW", "XG", "XU"].contains(c) ? c : nil
    }

    /// Where an artist comes from, per MusicBrainz. `failed`: the service couldn't be reached (try again later).
    struct ArtistPlace: Sendable, Equatable {
        var mbid: String?
        var country: String?
        var area: String?
        var found = false
        var failed = false
    }

    /// By MBID when known (exact), else by name: only an exact name match (accents, "The", case aside) counts.
    /// `album`: one of the artist's albums, to tell apart artists with the same name ("The Sound").
    /// `trusted`: the MBID comes from the files' tags (Picard) and is used as it is. Last.fm's MBIDs are only a
    /// hint: some point to another artist of the same name, so the name search goes first.
    func artistPlace(name: String, mbid: String?, album: String? = nil, trusted: Bool = true) async -> ArtistPlace {
        func place(_ a: [String: Any]) -> ArtistPlace {
            let area = (a["area"] as? [String: Any])?["id"] as? String ?? (a["begin-area"] as? [String: Any])?["id"] as? String
            let country = (a["country"] as? String).flatMap { Self.realCountry($0) }
            return ArtistPlace(mbid: a["id"] as? String, country: country, area: area, found: true)
        }
        func byID(_ id: String) async -> ArtistPlace? {
            guard let a = await get(URL(string: "https://musicbrainz.org/ws/2/artist/\(id)?fmt=json")!, musicBrainz: true) as? [String: Any],
                  a["id"] != nil else { return nil }
            return place(a)
        }
        if trusted, let mbid, let p = await byID(mbid) { return p }
        guard let json = await get(Self.url("https://musicbrainz.org/ws/2/artist/", ["query": "artist:\(Self.lucene(name))", "fmt": "json",
                                                                                       "limit": "5"]), musicBrainz: true) as? [String: Any]
        else { return ArtistPlace(failed: true) }
        let key = Keys.artist(name)
        let hits = ((json["artists"] as? [[String: Any]]) ?? []).filter { a in
            ((a["score"] as? Int) ?? 0) >= 90 && (Keys.artist(a["name"] as? String ?? "") == key
                || ((a["aliases"] as? [[String: Any]]) ?? []).contains { Keys.artist($0["name"] as? String ?? "") == key })
        }
        if hits.count == 1 { return place(hits[0]) }
        // Several artists by that name: the one last.fm names, else the one with this album.
        if hits.count > 1, let mbid, let hit = hits.first(where: { ($0["id"] as? String) == mbid }) { return place(hit) }
        if hits.count > 1, let album, !album.isEmpty,
           let rg = await get(Self.url("https://musicbrainz.org/ws/2/release-group/", [
               "query": "releasegroup:\(Self.lucene(album)) AND artist:\(Self.lucene(name))", "fmt": "json", "limit": "5"]),
                              musicBrainz: true) as? [String: Any] {
            let ids = Set(((rg["release-groups"] as? [[String: Any]]) ?? []).flatMap { g in
                ((g["artist-credit"] as? [[String: Any]]) ?? []).compactMap { ($0["artist"] as? [String: Any])?["id"] as? String }
            })
            if let match = hits.first(where: { ids.contains($0["id"] as? String ?? "") }) { return place(match) }
        }
        if let first = hits.first { return place(first) }
        // Not found by name: last.fm's MBID is all there is.
        if !trusted, let mbid, let p = await byID(mbid) { return p }
        return ArtistPlace()
    }

    /// An area's country: its own ISO code, a subdivision's prefix ("US-NC" → "US"), or the next area up.
    /// Returns (country, parent area to try next); both nil when the area can't be placed. `failed` when unreachable.
    func areaStep(_ id: String) async -> (country: String?, parent: String?, failed: Bool) {
        guard let a = await get(URL(string: "https://musicbrainz.org/ws/2/area/\(id)?inc=area-rels&fmt=json")!, musicBrainz: true)
            as? [String: Any] else { return (nil, nil, true) }
        if let c = (a["iso-3166-1-codes"] as? [String])?.first.flatMap(Self.realCountry) { return (c, nil, false) }
        if let sub = (a["iso-3166-2-codes"] as? [String])?.first, let dash = sub.firstIndex(of: "-") {
            return (String(sub[..<dash]).uppercased(), nil, false)
        }
        let parent = ((a["relations"] as? [[String: Any]]) ?? []).first {
            ($0["type"] as? String) == "part of" && ($0["direction"] as? String) == "backward"
        }.flatMap { ($0["area"] as? [String: Any])?["id"] as? String }
        return (nil, parent, false)
    }

    /// "alternative rock" → "Alternative Rock".
    static func titleCase(_ s: String) -> String { s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }

    /// The cover image's bytes (JPEG or PNG), or nil.
    func image(_ url: URL) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, status) = try? await http.send(req), status == 200, data.count > 1000,
              data.starts(with: [0xFF, 0xD8]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        return data
    }
}

/// Spaces calls out: each `wait` returns at least `interval` seconds after the previous one.
actor Gate {
    private let interval: TimeInterval
    private var next = Date.distantPast
    init(interval: TimeInterval) { self.interval = interval }

    func wait() async {
        let now = Date()
        let at = max(now, next)
        next = at.addingTimeInterval(interval)
        let delay = at.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
}
