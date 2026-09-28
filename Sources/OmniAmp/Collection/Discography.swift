import Foundation

/// What an artist released, from MusicBrainz, next to what you own: the official albums, EPs and live
/// records, and the bootlegs collectors have catalogued there. Looked up when the artist page opens (never in
/// the background) and kept for a month.
struct ArtistDiscography: Codable, Sendable, Equatable {
    struct Release: Codable, Sendable, Equatable {
        let id: String            // MusicBrainz release group
        let title: String
        let date: String?         // first release, "1991-09-24" / "1991"
        let type: String          // "Album", "EP"
        let secondary: [String]   // "Live", "Compilation", …

        var year: Int? { Keys.year(date) }
        var isLive: Bool { secondary.contains("Live") }
        var isCompilation: Bool { secondary.contains("Compilation") }
        /// Studio albums and EPs: nothing but the primary type.
        var isStudio: Bool { secondary.isEmpty }
        /// The concert's date: a full release date of a live record, or a date in the title ("1991-10-31: Paramount").
        var showDate: String? {
            if let d = ReleaseClassifier.dateAndVenue(title)?.0 { return d }
            return isLive && date?.count == 10 ? date : nil
        }
        var url: URL { URL(string: "https://musicbrainz.org/release-group/\(id)")! }
    }

    var mbid: String
    var official: [Release] = []
    var bootlegs: [Release] = []
    /// More bootleg groups than were fetched (the list stops at a few hundred).
    var bootlegTotal = 0
    /// Recordings on the Live Music Archive (archive.org's etree collection), nil when unknown.
    var liveArchive: Int?
    /// Those recordings, oldest first (up to `MetadataLookup.liveArchiveLimit`); nil in copies kept before they were.
    var liveRecordings: [LiveRecording]?

    var artistURL: URL { URL(string: "https://musicbrainz.org/artist/\(mbid)")! }

    /// An album title without edition notes: "Nevermind (Remastered)", "Nevermind [Deluxe]" → "nevermind".
    static func titleKey(_ s: String) -> String {
        var t = s
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
            while let o = t.range(of: open), let c = t.range(of: close, range: o.upperBound..<t.endIndex) { t.removeSubrange(o.lowerBound..<c.upperBound) }
        }
        let k = Keys.fold(t)
        return k.isEmpty ? Keys.fold(s) : k
    }

    /// The owned release that is this one: the same title, or for a concert the same date.
    static func owned(_ r: Release, in albums: [LibraryAlbum]) -> LibraryAlbum? {
        let key = titleKey(r.title)
        if let a = albums.first(where: { titleKey($0.title) == key }) { return a }
        if let d = r.showDate, let a = albums.first(where: { $0.showDate == d }) { return a }
        // A shorter name for it: "Unplugged in New York" for "MTV Unplugged in New York" (whole words, 3 or more).
        let padded = " \(key) "
        return albums.first { a in
            let k = titleKey(a.title)
            return k.split(separator: " ").count >= 3 && padded.contains(" \(k) ")
        }
    }

    /// "1991-10-31: Paramount Theatre" → "Paramount Theatre" (the date is shown beside it).
    static func withoutDate(_ title: String, _ date: String?) -> String {
        guard let date, title.hasPrefix(date) else { return title }
        let rest = title.dropFirst(date.count).drop { " :-–—,".contains($0) }
        return rest.isEmpty ? title : String(rest)
    }

    /// The official releases worth listing: albums, EPs and live records; compilations only when owned
    /// (hits packages and box reissues crowd out the rest).
    func listed(owned albums: [LibraryAlbum]) -> [(release: Release, owned: LibraryAlbum?)] {
        official.compactMap { r in
            let o = Self.owned(r, in: albums)
            return r.isCompilation && o == nil ? nil : (r, o)
        }.sorted { ($0.release.date ?? "9999") < ($1.release.date ?? "9999") }
    }
}

extension MetadataLookup {
    /// Pages of 100; a prolific artist's bootleg list stops after `maxPages`.
    static let discographyPages = 5

    /// nil when MusicBrainz can't be reached (try again next time).
    func discography(mbid: String, artist: String) async -> ArtistDiscography? {
        guard let official = await releaseGroups(mbid, status: "website-default", pages: 3),
              let all = await releaseGroups(mbid, status: "all", pages: Self.discographyPages) else { return nil }
        var d = ArtistDiscography(mbid: mbid)
        d.official = official.groups
        let ids = Set(official.groups.map(\.id))
        d.bootlegs = all.groups.filter { !ids.contains($0.id) }.sorted { ($0.showDate ?? $0.date ?? "9999") < ($1.showDate ?? $1.date ?? "9999") }
        d.bootlegTotal = max(d.bootlegs.count, all.total - official.total)
        if let live = await liveArchive(artist) {
            d.liveArchive = live.total
            d.liveRecordings = live.recordings
        }
        return d
    }

    private func releaseGroups(_ mbid: String, status: String, pages: Int) async -> (groups: [ArtistDiscography.Release], total: Int)? {
        var out: [ArtistDiscography.Release] = [], total = 0
        for page in 0..<pages {
            guard let json = await get(Self.url("https://musicbrainz.org/ws/2/release-group", [
                "artist": mbid, "type": "album|ep", "release-group-status": status, "limit": "100", "offset": String(page * 100), "fmt": "json"]),
                                       musicBrainz: true) as? [String: Any] else { return page == 0 ? nil : (out, total) }
            total = json["release-group-count"] as? Int ?? 0
            let groups = (json["release-groups"] as? [[String: Any]]) ?? []
            out += groups.compactMap { g in
                guard let id = g["id"] as? String, let title = g["title"] as? String else { return nil }
                let date = (g["first-release-date"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return .init(id: id, title: title, date: date, type: g["primary-type"] as? String ?? "Album",
                             secondary: g["secondary-types"] as? [String] ?? [])
            }
            if groups.count < 100 || out.count >= total { break }
        }
        return (out, total)
    }
}

extension CollectionDB {
    private func ensureDiscographyTable() throws {
        try db.exec("CREATE TABLE IF NOT EXISTS artist_discography(artist_key TEXT PRIMARY KEY, json TEXT, checked REAL);")
    }

    /// The kept discography, and whether it's due to be looked up again.
    func discography(_ key: String, maxAge: TimeInterval = 30 * 86400) throws -> (ArtistDiscography?, stale: Bool) {
        try ensureDiscographyTable()
        var out: (ArtistDiscography?, stale: Bool) = (nil, true)
        try db.query("SELECT json, checked FROM artist_discography WHERE artist_key = ?", [key]) { r in
            let d = try? JSONDecoder().decode(ArtistDiscography.self, from: Data(r.text(0).utf8))
            // Kept before recordings were: look up again.
            out = (d, Date().timeIntervalSince1970 - r.double(1) > maxAge || d?.liveRecordings == nil)
        }
        return out
    }

    func saveDiscography(_ key: String, _ d: ArtistDiscography) throws {
        try ensureDiscographyTable()
        let json = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        try db.run("INSERT OR REPLACE INTO artist_discography(artist_key, json, checked) VALUES (?,?,?)", [key, json, Date().timeIntervalSince1970])
    }
}
