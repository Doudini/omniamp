import Foundation

/// The Listening page's figures: last.fm plays, and where the artists (played and owned) come from.
struct ListeningStats: Sendable {
    var plays = 0, artists = 0
    /// Last year's plays up to today's date (to compare this year so far with).
    var lastYearToDate = 0
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
        // Each play's local calendar (year, "MM-DD", weekday 0 = Sunday, hour), worked out once: the charts group
        // 200,000 plays by these, and converting every timestamp each time was most of the Listening page's cost.
        var has = false
        try db.query("PRAGMA table_info(scrobbles)") { if $0.text(1) == "year" { has = true } }
        if !has {
            try db.exec("""
            ALTER TABLE scrobbles ADD COLUMN year INTEGER;
            ALTER TABLE scrobbles ADD COLUMN md TEXT;
            ALTER TABLE scrobbles ADD COLUMN wday INTEGER;
            ALTER TABLE scrobbles ADD COLUMN hour INTEGER;
            """)
        }
        try db.exec("""
        CREATE INDEX IF NOT EXISTS scrobbles_year ON scrobbles(year, artist_key);
        CREATE INDEX IF NOT EXISTS scrobbles_md ON scrobbles(md);
        """)
    }

    // MARK: Artist info cache

    func ensureArtistInfoTable() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS artist_info(artist_key TEXT PRIMARY KEY, description TEXT, extract TEXT, image_url TEXT, page_url TEXT,
            found INTEGER, checked REAL);
        """)
    }

    enum CachedInfo: Sendable {
        case unknown                 // never looked up, or due again
        case none                    // looked up, nothing found (not asked again for a while)
        case found(MetadataLookup.ArtistInfo)
    }

    func artistInfo(_ key: String, retryAfter: TimeInterval = 30 * 86400) throws -> CachedInfo {
        try ensureArtistInfoTable()
        var out = CachedInfo.unknown
        try db.query("SELECT description, extract, image_url, page_url, found, checked FROM artist_info WHERE artist_key = ?", [key]) { r in
            if r.int(4) == 1 {
                out = .found(MetadataLookup.ArtistInfo(description: r.optText(0), extract: r.optText(1), imageURL: r.optText(2).flatMap(URL.init(string:)),
                                                       pageURL: r.optText(3).flatMap(URL.init(string:))))
            } else if Date().timeIntervalSince1970 - r.double(5) < retryAfter {
                out = .none
            }
        }
        return out
    }

    func saveArtistInfo(_ key: String, _ info: MetadataLookup.ArtistInfo?) throws {
        try ensureArtistInfoTable()
        try db.run("INSERT OR REPLACE INTO artist_info(artist_key, description, extract, image_url, page_url, found, checked) VALUES (?,?,?,?,?,?,?)",
                   [key, info?.description, info?.extract, info?.imageURL?.absoluteString, info?.pageURL?.absoluteString, info == nil ? 0 : 1,
                    Date().timeIntervalSince1970])
    }

    /// The artist's MusicBrainz ID, if known (a lookup, or the files' tags).
    func artistMBID(_ key: String) throws -> String? {
        var m: String?
        try db.query("SELECT mbid FROM artist_places WHERE artist_key = ? AND mbid IS NOT NULL", [key]) { m = $0.text(0) }
        if m == nil { try db.query("SELECT max(mb_artist) FROM files WHERE artist_key = ?", [key]) { m = $0.optText(0) } }
        return m
    }

    /// Fill in the calendar of plays stored before it existed (one pass, the first time). Off the main thread.
    func fillPlayCalendar() throws {
        guard (try db.scalar("SELECT count(*) FROM scrobbles WHERE year IS NULL") ?? 0) > 0 else { return }
        try db.exec("""
        UPDATE scrobbles SET year = CAST(strftime('%Y', ts, 'unixepoch', 'localtime') AS INTEGER),
            md = strftime('%m-%d', ts, 'unixepoch', 'localtime'),
            wday = CAST(strftime('%w', ts, 'unixepoch', 'localtime') AS INTEGER),
            hour = CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER)
        WHERE year IS NULL
        """)
    }

    /// Changes whenever plays, places or the library change: the Listening page's figures are kept until it does.
    func listeningVersion() throws -> String {
        var v = ""
        try db.query("""
            SELECT (SELECT count(*) || ':' || coalesce(max(ts), 0) FROM scrobbles) || '/' ||
                   (SELECT count(*) || ':' || coalesce(max(checked), 0) FROM artist_places) || '/' ||
                   (SELECT count(*) || ':' || coalesce(max(added), 0) FROM albums)
            """) { v = $0.text(0) }
        return v
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
            let cal = Calendar.current
            for p in plays {
                let c = cal.dateComponents([.year, .month, .day, .weekday, .hour], from: Date(timeIntervalSince1970: TimeInterval(p.ts)))
                try db.run("""
                    INSERT OR IGNORE INTO scrobbles(ts, artist, album, title, artist_key, mbid, year, md, wday, hour) VALUES (?,?,?,?,?,?,?,?,?,?)
                    """, [p.ts, p.artist, p.album, p.title, Keys.artist(p.artist), p.artistMBID, c.year,
                          String(format: "%02d-%02d", c.month ?? 1, c.day ?? 1), (c.weekday ?? 1) - 1, c.hour])
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
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let md = String(format: "%02d-%02d", today.month ?? 1, today.day ?? 1)
        s.lastYearToDate = Int(try db.scalar("SELECT count(*) FROM scrobbles WHERE year = ? AND md <= ?", [(today.year ?? 2000) - 1, md]) ?? 0)
        try db.query("""
            SELECT p.country, count(*), count(DISTINCT s.artist_key) FROM scrobbles s JOIN artist_places p ON p.artist_key = s.artist_key
            WHERE p.country IS NOT NULL AND p.country NOT IN ('XE', 'XW', 'XG', 'XU') GROUP BY p.country
            """) { r in
            s.playsByCountry[r.text(0)] = Double(r.int(1)); s.playedArtistsByCountry[r.text(0)] = r.int(2); s.mappedPlays += r.int(1)
        }
        try db.query("""
            SELECT p.country, count(*), count(DISTINCT f.artist_key) FROM files f JOIN artist_places p ON p.artist_key = f.artist_key
            WHERE p.country IS NOT NULL AND p.country NOT IN ('XE', 'XW', 'XG', 'XU') GROUP BY p.country
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
            let bar = LibraryStats.Bar(id: key, label: r.text(1), value: Double(n), count: owned[key])
            if s.topArtists.count < 15 { s.topArtists.append(bar) }
            if bar.count == nil, s.notOwned.count < 15, !["unknown artist", "various artists"].contains(key) { s.notOwned.append(bar) }
        }
        try db.query("""
            SELECT a.artist_key, min(a.artist), sum(a.tracks) AS t FROM albums a
            WHERE a.artist_key NOT IN (SELECT DISTINCT artist_key FROM scrobbles) AND a.artist_key NOT IN ('unknown artist', 'various artists')
            GROUP BY a.artist_key ORDER BY t DESC LIMIT 15
            """) { r in s.neverPlayed.append(.init(id: r.text(0), label: r.text(1), value: Double(r.int(2)))) }

        try db.query("SELECT year, count(*) FROM scrobbles GROUP BY year ORDER BY year") { r in
            s.years.append((r.int(0), r.int(1)))
        }
        try db.query("""
            SELECT wday, hour, count(*) FROM scrobbles GROUP BY wday, hour
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
              WHERE p.country = ? GROUP BY f.artist_key ORDER BY n DESC LIMIT 12
              """
            : """
              SELECT s.artist_key, min(s.artist), count(*) AS n FROM scrobbles s JOIN artist_places p ON p.artist_key = s.artist_key
              WHERE p.country = ? GROUP BY s.artist_key ORDER BY n DESC LIMIT 12
              """
        try db.query(sql, [country]) { r in out.append(.init(id: r.text(0), label: r.text(1), value: Double(r.int(2)))) }
        return out
    }
}

/// Your top artists over the years, for the river chart: the most played overall, the rest as "other".
struct ListeningRiver: Sendable {
    struct Series: Sendable {
        let key: String
        let name: String
        let plays: [Int]   // per year, in `years` order
    }
    var years: [Int] = []
    var series: [Series] = []
    var other: [Int] = []
}

/// What happened on this date in other years: shows you own recorded then, and what you played.
struct OnThisDay: Sendable {
    struct Day: Sendable {
        let year: Int
        let plays: Int
        let artist: String
        let artistKey: String
        let title: String
    }
    var month = 1, day = 1
    var shows: [LibraryAlbum] = []
    var days: [Day] = []
}

extension CollectionDB {
    /// Most played artists between two times (nil: no limit), with whether they're in the library.
    func topArtists(from: Int?, to: Int?, limit: Int = 15) throws -> [LibraryStats.Bar] {
        var owned: [String: Int] = [:]
        try db.query("SELECT artist_key, sum(tracks) FROM albums GROUP BY artist_key") { owned[$0.text(0)] = $0.int(1) }
        var out: [LibraryStats.Bar] = []
        try db.query("""
            SELECT artist_key, min(artist), count(*) AS n FROM scrobbles WHERE ts >= ? AND ts < ?
            GROUP BY artist_key ORDER BY n DESC LIMIT ?
            """, [from ?? 0, to ?? Int.max, limit]) { r in
            out.append(.init(id: r.text(0), label: r.text(1), value: Double(r.int(2)), count: owned[r.text(0)]))
        }
        return out
    }

    /// The years with plays, newest first (for the year menu).
    func playYears() throws -> [Int] {
        var out: [Int] = []
        try db.query("SELECT DISTINCT year FROM scrobbles WHERE year IS NOT NULL ORDER BY year DESC") {
            out.append($0.int(0))
        }
        return out
    }

    /// Plays per year of the `top` most played artists overall, and of everyone else.
    func river(top: Int = 8) throws -> ListeningRiver {
        var r = ListeningRiver()
        r.years = try playYears().reversed()
        guard !r.years.isEmpty else { return r }
        let index = Dictionary(uniqueKeysWithValues: r.years.enumerated().map { ($1, $0) })
        var keys: [(String, String)] = []
        try db.query("SELECT artist_key, min(artist), count(*) AS n FROM scrobbles GROUP BY artist_key ORDER BY n DESC LIMIT ?", [top]) {
            keys.append(($0.text(0), $0.text(1)))
        }
        var perArtist: [String: [Int]] = [:]
        var totals = Array(repeating: 0, count: r.years.count)
        try db.query("""
            SELECT artist_key, year, count(*) FROM scrobbles GROUP BY artist_key, year
            """) { row in
            guard let i = index[row.int(1)] else { return }
            totals[i] += row.int(2)
            if keys.contains(where: { $0.0 == row.text(0) }) {
                perArtist[row.text(0), default: Array(repeating: 0, count: r.years.count)][i] += row.int(2)
            }
        }
        r.series = keys.map { .init(key: $0.0, name: $0.1, plays: perArtist[$0.0] ?? Array(repeating: 0, count: r.years.count)) }
        r.other = totals.indices.map { i in totals[i] - r.series.reduce(0) { $0 + $1.plays[i] } }
        return r
    }

    /// This month and day in other years (local time).
    func onThisDay(_ date: Date = Date()) throws -> OnThisDay {
        let c = Calendar.current.dateComponents([.month, .day, .year], from: date)
        var o = OnThisDay(month: c.month ?? 1, day: c.day ?? 1)
        let md = String(format: "%02d-%02d", o.month, o.day)
        o.shows = try albumsWhere("a.kind = \(ReleaseKind.show.rawValue) AND substr(a.show_date, 6, 5) = ?", [md], order: "a.show_date")
        var best: [Int: (plays: Int, artists: [String: (String, Int)], titles: [String: Int])] = [:]
        try db.query("""
            SELECT year, artist_key, artist, title FROM scrobbles WHERE md = ?
            """, [md]) { r in
            let y = r.int(0)
            guard y != c.year else { return }   // today isn't history yet
            var e = best[y] ?? (0, [:], [:])
            e.plays += 1
            e.artists[r.text(1)] = (r.text(2), (e.artists[r.text(1)]?.1 ?? 0) + 1)
            e.titles[r.text(1) + "\u{1}" + r.text(3), default: 0] += 1
            best[y] = e
        }
        o.days = best.sorted { $0.key > $1.key }.map { y, e in
            let top = e.artists.max { $0.value.1 < $1.value.1 }!
            let song = e.titles.filter { $0.key.hasPrefix(top.key + "\u{1}") }.max { $0.value < $1.value }?.key.components(separatedBy: "\u{1}").last ?? ""
            return .init(year: y, plays: e.plays, artist: top.value.0, artistKey: top.key, title: song)
        }
        return o
    }
}
