import Foundation

/// The Listening page's figures: last.fm plays, and where the artists (played and owned) come from.
struct ListeningStats: Sendable {
    var plays = 0, artists = 0
    var firstPlay: Date?
    var lastPlay: Date?
    /// Plays whose artist has a known country, and artists still waiting for a lookup.
    var mappedPlays = 0
    var pendingArtists = 0
    var playsByCountry: [String: Double] = [:]
    var playedArtistsByCountry: [String: Int] = [:]
    var ownedByCountry: [String: Double] = [:]
    var ownedArtistsByCountry: [String: Int] = [:]
    var ownedTracks = 0, mappedOwnedTracks = 0
    var topArtists: [LibraryStats.Bar] = []
    var years: [(year: Int, releases: Int)] = []   // plays per year (named like the Stats chart's input)
    /// Plays by weekday (0 = Sunday) and hour, local time.
    var clock: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    var notOwned: [LibraryStats.Bar] = []
    /// Plays of artists who are in the library.
    var ownedPlays = 0
    var neverPlayed: [LibraryStats.Bar] = []
}

extension CollectionDB {
    /// Tables for plays and artist places (created with the database, or added to an older one).
    func ensureListeningTables() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS scrobbles(ts INTEGER NOT NULL, artist TEXT, album TEXT, title TEXT, artist_key TEXT NOT NULL,
            mbid TEXT, PRIMARY KEY(ts, artist_key, title));
        CREATE INDEX IF NOT EXISTS scrobbles_artist ON scrobbles(artist_key);
        CREATE TABLE IF NOT EXISTS artist_places(artist_key TEXT PRIMARY KEY, name TEXT, mbid TEXT, country TEXT, status INTEGER,
            checked REAL);
        CREATE TABLE IF NOT EXISTS area_country(area TEXT PRIMARY KEY, country TEXT);
        """)
    }

    func meta(_ key: String) -> Int? { try? db.scalar("SELECT value FROM meta WHERE key = ?", [key]).map(Int.init) }
    func setMeta(_ key: String, _ value: Int) throws { try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [key, value]) }

    // MARK: Plays

    /// Store plays (ones already there are skipped). Returns how many were new.
    @discardableResult
    func addPlays(_ plays: [LastFM.Play]) throws -> Int {
        guard !plays.isEmpty else { return 0 }
        return try db.transaction {
            var added = 0
            for p in plays {
                try db.run("INSERT OR IGNORE INTO scrobbles(ts, artist, album, title, artist_key, mbid) VALUES (?, ?, ?, ?, ?, ?)",
                           [p.ts, p.artist, p.album, p.title, Keys.artist(p.artist), p.artistMBID])
                added += db.changes
            }
            return added
        }
    }

    /// Oldest and newest play stored, and how many.
    func playRange() throws -> (oldest: Int?, newest: Int?, count: Int) {
        var r: (Int?, Int?, Int) = (nil, nil, 0)
        try db.query("SELECT min(ts), max(ts), count(*) FROM scrobbles") { s in r = (s.optInt(0), s.optInt(1), s.int(2)) }
        return r
    }

    func forgetPlays() throws {
        try db.exec("DELETE FROM scrobbles; DELETE FROM meta WHERE key LIKE 'lastfm%'")
    }

    // MARK: Artist places

    struct PendingArtist: Sendable {
        let key: String
        let name: String
        let mbid: String?
        var album: String? = nil
        /// The MBID is from the files' tags (reliable), not last.fm's.
        var trusted = false
    }

    /// Artists (played or owned) whose country is unknown, most played or owned first. Not-found ones are tried
    /// again after `retryAfter` seconds.
    func pendingArtists(limit: Int, retryAfter: TimeInterval = 90 * 86400) throws -> [PendingArtist] {
        var out: [PendingArtist] = []
        try db.query("""
            WITH cand AS (
                SELECT artist_key AS k, min(artist) AS name, max(mbid) AS lfm, NULL AS tag, count(*) AS w FROM scrobbles GROUP BY artist_key
                UNION ALL
                SELECT artist_key, min(album_artist), NULL, max(mb_artist), count(*) FROM files GROUP BY artist_key)
            SELECT k, min(name), coalesce(max(tag), max(lfm)), sum(w) AS weight,
                   (SELECT title FROM albums WHERE artist_key = k AND kind = 0 ORDER BY tracks DESC LIMIT 1),
                   (SELECT album FROM scrobbles WHERE artist_key = k AND album != '' GROUP BY album ORDER BY count(*) DESC LIMIT 1),
                   max(tag) IS NOT NULL
            FROM cand
            WHERE k NOT IN ('', 'unknown artist', 'various artists', 'various', 'va')
              AND k NOT IN (SELECT artist_key FROM artist_places WHERE status = 1 OR checked > ?)
            GROUP BY k ORDER BY weight DESC LIMIT ?
            """, [Date().timeIntervalSince1970 - retryAfter, limit]) { s in
            out.append(PendingArtist(key: s.text(0), name: s.text(1), mbid: s.optText(2), album: s.optText(4) ?? s.optText(5),
                                     trusted: s.int(6) == 1))
        }
        return out
    }

    func pendingArtistCount(retryAfter: TimeInterval = 90 * 86400) throws -> Int {
        Int(try db.scalar("""
            SELECT count(*) FROM (SELECT artist_key AS k FROM scrobbles UNION SELECT artist_key FROM files)
            WHERE k NOT IN ('', 'unknown artist', 'various artists', 'various', 'va')
              AND k NOT IN (SELECT artist_key FROM artist_places WHERE status = 1 OR checked > ?)
            """, [Date().timeIntervalSince1970 - retryAfter]) ?? 0)
    }

    /// A lookup's result: `country` nil with `found` false means MusicBrainz doesn't know the artist (asked again
    /// in 90 days). `retryInDays`: sooner, for a lookup that failed rather than found nothing.
    func savePlace(_ a: PendingArtist, mbid: String?, country: String?, found: Bool, retryInDays: Double = 90) throws {
        let checked = Date().timeIntervalSince1970 - (90 - retryInDays) * 86400
        try db.run("INSERT OR REPLACE INTO artist_places(artist_key, name, mbid, country, status, checked) VALUES (?, ?, ?, ?, ?, ?)",
                   [a.key, a.name, mbid ?? a.mbid, country, found && country != nil ? 1 : 2, checked])
    }

    /// The country an area belongs to, if already worked out: nil = not known yet; .some(nil) = it has none.
    func areaCountry(_ area: String) -> String?? {
        var r: String??
        try? db.query("SELECT country FROM area_country WHERE area = ?", [area]) { r = .some($0.optText(0)) }
        return r
    }

    func saveArea(_ area: String, country: String?) {
        try? db.run("INSERT OR REPLACE INTO area_country(area, country) VALUES (?, ?)", [area, country])
    }

    // MARK: Figures

    func listeningStats() throws -> ListeningStats {
        var s = ListeningStats()
        try db.query("SELECT count(*), count(DISTINCT artist_key), min(ts), max(ts) FROM scrobbles") { r in
            s.plays = r.int(0); s.artists = r.int(1)
            s.firstPlay = r.optInt(2).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            s.lastPlay = r.optInt(3).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
        try db.query("""
            SELECT p.country, count(*), count(DISTINCT s.artist_key) FROM scrobbles s JOIN artist_places p ON p.artist_key = s.artist_key
            WHERE p.country IS NOT NULL GROUP BY p.country
            """) { r in
            s.playsByCountry[r.text(0)] = Double(r.int(1)); s.playedArtistsByCountry[r.text(0)] = r.int(2); s.mappedPlays += r.int(1)
        }
        try db.query("""
            SELECT p.country, count(*), count(DISTINCT f.artist_key) FROM files f JOIN artist_places p ON p.artist_key = f.artist_key
            WHERE p.country IS NOT NULL GROUP BY p.country
            """) { r in
            s.ownedByCountry[r.text(0)] = Double(r.int(1)); s.ownedArtistsByCountry[r.text(0)] = r.int(2); s.mappedOwnedTracks += r.int(1)
        }
        s.ownedTracks = Int(try db.scalar("SELECT count(*) FROM files") ?? 0)
        s.ownedPlays = Int(try db.scalar("SELECT count(*) FROM scrobbles WHERE artist_key IN (SELECT key FROM artists)") ?? 0)
        s.pendingArtists = (try? pendingArtistCount()) ?? 0

        // Owned tracks per artist, to mark played artists that are (or aren't) in the library.
        var owned: [String: Int] = [:]
        try db.query("SELECT artist_key, sum(tracks) FROM albums GROUP BY artist_key") { owned[$0.text(0)] = $0.int(1) }
        try db.query("SELECT artist_key, min(artist), count(*) AS n FROM scrobbles GROUP BY artist_key ORDER BY n DESC LIMIT 400") { r in
            let key = r.text(0), n = r.int(2)
            let bar = LibraryStats.Bar(id: key, label: r.text(1), value: Double(n),
                                       detail: owned[key].map { "\($0.formatted()) owned" } ?? "not in library")
            if s.topArtists.count < 15 { s.topArtists.append(bar) }
            if owned[key] == nil, s.notOwned.count < 15, !["unknown artist", "various artists"].contains(key) { s.notOwned.append(bar) }
        }
        try db.query("""
            SELECT a.artist_key, min(a.artist), sum(a.tracks) AS t FROM albums a
            WHERE a.artist_key NOT IN (SELECT DISTINCT artist_key FROM scrobbles) AND a.artist_key NOT IN ('unknown artist', 'various artists')
            GROUP BY a.artist_key ORDER BY t DESC LIMIT 15
            """) { r in s.neverPlayed.append(.init(id: r.text(0), label: r.text(1), value: Double(r.int(2)), detail: "tracks")) }

        try db.query("SELECT CAST(strftime('%Y', ts, 'unixepoch', 'localtime') AS INTEGER), count(*) FROM scrobbles GROUP BY 1 ORDER BY 1") { r in
            s.years.append((r.int(0), r.int(1)))
        }
        try db.query("""
            SELECT CAST(strftime('%w', ts, 'unixepoch', 'localtime') AS INTEGER), CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER),
                   count(*) FROM scrobbles GROUP BY 1, 2
            """) { r in
            let d = r.int(0), h = r.int(1)
            if (0..<7).contains(d), (0..<24).contains(h) { s.clock[d][h] = r.int(2) }
        }
        return s
    }

    /// The artists behind one country on the map: by plays, or by tracks owned.
    func artists(country: String, owned: Bool) throws -> [LibraryStats.Bar] {
        var out: [LibraryStats.Bar] = []
        let sql = owned
            ? """
              SELECT f.artist_key, min(f.album_artist), count(*) AS n FROM files f JOIN artist_places p ON p.artist_key = f.artist_key
              WHERE p.country = ? GROUP BY f.artist_key ORDER BY n DESC LIMIT 20
              """
            : """
              SELECT s.artist_key, min(s.artist), count(*) AS n FROM scrobbles s JOIN artist_places p ON p.artist_key = s.artist_key
              WHERE p.country = ? GROUP BY s.artist_key ORDER BY n DESC LIMIT 20
              """
        try db.query(sql, [country]) { r in out.append(.init(id: r.text(0), label: r.text(1), value: Double(r.int(2)))) }
        return out
    }
}
