import Foundation

/// One file in the library, as the scanner hands it to the database.
struct LibraryFile: Sendable {
    var key: String            // path, or path#start for a CUE track
    var path: String
    var root: String
    var size: Int64
    var mtime: Double
    var cueStart: Double?
    var cueEnd: Double?
    var cueNumber: Int?
    var info: TagInfo
    var result: ReleaseClassifier.Result
    var title: String
    /// False for formats OmniAmp can't play (WMA, SHN, protected M4P…): listed, marked, never sent to the player.
    var playable = true
}

/// What the browser shows.
struct LibraryArtist: Equatable {
    let key: String
    let name: String
    let letter: String
    let albums: Int
    let tracks: Int
}

struct LibraryAlbum: Equatable {
    let key: String
    let artistKey: String
    let artist: String
    let title: String
    let year: Int?
    let kind: ReleaseKind
    let folder: String
    let tracks: Int
    let duration: Double
    let firstPath: String
    let lossless: Bool
    let added: Double
    let showDate: String?
    let venue: String?
    /// Tracks in formats OmniAmp can't play, and which format that is ("WMA").
    var unplayable = 0
    var unplayableFormat: String?
}

struct LibraryTrack: Equatable {
    let id: Int64
    let key: String
    let path: String
    let size: Int64
    let mtime: Double
    let cueStart: Double?
    let cueEnd: Double?
    let cueNumber: Int?
    let title: String
    let artist: String
    let album: String
    let albumKey: String
    let disc: Int?
    let number: Int?
    let duration: Double?
    let format: String
    var playable = true

    /// A playlist entry: known tags filled in so it shows at once (the playlist reads the rest).
    var track: Track {
        var t = Track(path: path, size: size, mtime: mtime)
        t.title = title
        t.artist = artist
        t.album = album
        t.duration = duration
        t.cueStart = cueStart
        t.cueEnd = cueEnd
        t.cueNumber = cueNumber
        return t
    }
}

/// A group in the middle list with how many albums it holds (years, genres, months…).
struct LibraryBucket: Equatable {
    let id: String
    let title: String
    let count: Int
}

/// Which releases the browser shows.
struct LibraryFilter: Equatable {
    enum Scope: Int { case all, official, unofficial }
    var scope: Scope = .all
    var losslessOnly = false

    /// A WHERE clause over the albums table (alias `a`).
    var sql: String {
        var parts: [String] = []
        switch scope {
        case .all: break
        case .official: parts.append("a.kind <= \(ReleaseKind.live.rawValue)")
        case .unofficial: parts.append("a.kind > \(ReleaseKind.live.rawValue)")
        }
        if losslessOnly { parts.append("a.lossless = 1") }
        return parts.isEmpty ? "1" : parts.joined(separator: " AND ")
    }
}

/// The music library: an SQLite database next to the playlist cache (never on the music share).
///
/// `files` holds every track with its tags and what the classifier made of it; `albums` and `artists` are
/// rolled up from it for the albums and artists a write touched, so browsing never aggregates 100,000 rows.
/// `fts` is a full-text index over titles, artists, albums and venues.
final class CollectionDB {
    static let schemaVersion = 1
    /// Bump when the classifier or the tags read change: every file is read and sorted again on the next scan.
    static let contentVersion = 4
    let db: SQLiteDB
    private(set) var hasFTS = true
    /// Opened after a contentVersion bump: every folder has to be listed and read again.
    private(set) var needsFullScan = false

    static var defaultURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("collection.sqlite") }

    init(url: URL = CollectionDB.defaultURL, readOnly: Bool = false) throws {
        db = try SQLiteDB(path: url.path, readOnly: readOnly)
        if readOnly {
            hasFTS = (try? db.scalar("SELECT count(*) FROM sqlite_master WHERE name = 'fts'")) == 1
            return
        }
        try db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = OFF;")
        try migrate()
        try db.exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value INTEGER)")
        // Columns added after the first release of the library.
        func addColumn(_ table: String, _ column: String, _ type: String) throws {
            var has = false
            try db.query("PRAGMA table_info(\(table))") { if $0.text(1) == column { has = true } }
            if !has { try db.exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type)") }
        }
        try addColumn("files", "playable", "INTEGER NOT NULL DEFAULT 1")
        try addColumn("albums", "unplayable", "INTEGER NOT NULL DEFAULT 0")
        try addColumn("albums", "unplayable_format", "TEXT")
        try ensureListeningTables()
        // Song keys follow Keys.title: recomputed from the stored titles when its rules change (no files read).
        if (try db.scalar("SELECT value FROM meta WHERE key = 'songKeys'") ?? 1) < songKeyVersion {
            try db.transaction {
                var rows: [(Int64, String)] = []
                try db.query("SELECT id, title FROM files") { rows.append(($0.int64(0), $0.text(1))) }
                for (id, title) in rows { try db.run("UPDATE files SET title_key = ? WHERE id = ?", [Keys.title(title), id]) }
                try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('songKeys', ?)", [songKeyVersion])
            }
        }
        // FLAC behind an ID3 tag couldn't be read before (no tags, no length): read just those again, once.
        if (try db.scalar("SELECT value FROM meta WHERE key = 'flacBehindID3'") ?? 0) < 1 {
            try db.run("UPDATE files SET mtime = -1 WHERE duration IS NULL AND lower(path) LIKE '%.flac'")
            if (try db.scalar("SELECT changes()") ?? 0) > 0 { needsFullScan = true }
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('flacBehindID3', 1)")
        }
        let content = try db.scalar("SELECT value FROM meta WHERE key = 'content'") ?? 0
        if content < Self.contentVersion {
            // Unknown mtime: the scanner treats every file as changed.
            try db.run("UPDATE files SET mtime = -1")
            needsFullScan = true
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('content', ?)", [Self.contentVersion])
        }
    }

    private func migrate() throws {
        let version = try db.scalar("PRAGMA user_version") ?? 0
        guard version < Self.schemaVersion else {
            hasFTS = (try? db.scalar("SELECT count(*) FROM sqlite_master WHERE name = 'fts'")) == 1
            return
        }
        try db.transaction {
            try db.exec("""
            CREATE TABLE IF NOT EXISTS files(
                id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, path TEXT NOT NULL, root TEXT NOT NULL, folder TEXT NOT NULL,
                size INTEGER, mtime REAL, added REAL, cue_start REAL, cue_end REAL, cue_number INTEGER,
                title TEXT, artist TEXT, album_artist TEXT, album TEXT, date TEXT, year INTEGER, genre TEXT,
                track_no INTEGER, disc_no INTEGER, duration REAL, bitrate INTEGER, sample_rate INTEGER, bit_depth INTEGER,
                mb_artist TEXT, mb_group TEXT, release_type TEXT, release_status TEXT,
                kind INTEGER, show_date TEXT, venue TEXT, artist_key TEXT, album_key TEXT, title_key TEXT, lossless INTEGER);
            CREATE INDEX IF NOT EXISTS files_album ON files(album_key);
            CREATE INDEX IF NOT EXISTS files_artist ON files(artist_key);
            CREATE INDEX IF NOT EXISTS files_title ON files(title_key);
            CREATE TABLE IF NOT EXISTS albums(
                key TEXT PRIMARY KEY, artist_key TEXT, artist TEXT, title TEXT, year INTEGER, kind INTEGER, folder TEXT,
                tracks INTEGER, duration REAL, first_path TEXT, lossless INTEGER, added REAL, show_date TEXT, venue TEXT);
            CREATE INDEX IF NOT EXISTS albums_artist ON albums(artist_key, year);
            CREATE INDEX IF NOT EXISTS albums_year ON albums(year);
            CREATE INDEX IF NOT EXISTS albums_added ON albums(added);
            CREATE INDEX IF NOT EXISTS albums_show ON albums(show_date);
            CREATE TABLE IF NOT EXISTS artists(
                key TEXT PRIMARY KEY, name TEXT, sort_name TEXT, letter TEXT, mbid TEXT, country TEXT, begin_year INTEGER);
            CREATE INDEX IF NOT EXISTS artists_sort ON artists(sort_name COLLATE NOCASE);
            CREATE TABLE IF NOT EXISTS genres(file_id INTEGER NOT NULL, genre TEXT NOT NULL COLLATE NOCASE);
            CREATE INDEX IF NOT EXISTS genres_genre ON genres(genre);
            CREATE INDEX IF NOT EXISTS genres_file ON genres(file_id);
            """)
            do {
                try db.exec("""
                CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(title, artist, album, venue, content='files', content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2');
                CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
                    INSERT INTO fts(rowid, title, artist, album, venue) VALUES (new.id, new.title, new.artist, new.album, new.venue);
                END;
                CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
                    INSERT INTO fts(fts, rowid, title, artist, album, venue) VALUES ('delete', old.id, old.title, old.artist, old.album, old.venue);
                END;
                CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE ON files BEGIN
                    INSERT INTO fts(fts, rowid, title, artist, album, venue) VALUES ('delete', old.id, old.title, old.artist, old.album, old.venue);
                    INSERT INTO fts(rowid, title, artist, album, venue) VALUES (new.id, new.title, new.artist, new.album, new.venue);
                END;
                """)
            } catch {
                // An SQLite without FTS5: search falls back to LIKE.
                hasFTS = false
                NSLog("OmniAmp: library search without FTS5 (%@)", "\(error)")
            }
            try db.exec("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    // MARK: Writing (the writer connection only)

    /// Size and mtime of every file under `scope` (a folder), to tell new and changed files from known ones.
    func known(under scope: String) throws -> [String: (size: Int64, mtime: Double)] {
        var out: [String: (Int64, Double)] = [:]
        // Keys under a folder sort between "folder/" and "folder0" ("0" follows "/").
        try db.query("SELECT key, size, mtime FROM files WHERE key >= ? AND key < ?", [scope + "/", scope + "0"]) { s in
            out[s.text(0)] = (s.int64(1), s.double(2))
        }
        return out
    }

    /// Insert or update files, then roll up the albums and artists they touched. One transaction.
    func upsert(_ files: [LibraryFile], now: Double = Date().timeIntervalSince1970) throws {
        guard !files.isEmpty else { return }
        try db.transaction {
            var albums = Set<String>(), artists = Set<String>()
            for f in files {
                // The old album/artist too: a retagged file leaves them.
                try db.query("SELECT album_key, artist_key FROM files WHERE key = ?", [f.key]) { s in
                    albums.insert(s.text(0)); artists.insert(s.text(1))
                }
                let r = f.result, i = f.info
                let artistKey = Keys.artist(r.artist)
                let albumKey = artistKey + "\u{1}" + Keys.fold(r.album) + "\u{1}" + r.albumFolder
                albums.insert(albumKey); artists.insert(artistKey)
                let lossless = Self.isLossless(f.path, bitDepth: i.bitDepth)
                try db.run("""
                    INSERT INTO files(key, path, root, folder, size, mtime, added, cue_start, cue_end, cue_number, title, artist,
                        album_artist, album, date, year, genre, track_no, disc_no, duration, bitrate, sample_rate, bit_depth, mb_artist,
                        mb_group, release_type, release_status, kind, show_date, venue, artist_key, album_key, title_key, lossless, playable)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(key) DO UPDATE SET path=excluded.path, root=excluded.root, folder=excluded.folder, size=excluded.size,
                        mtime=excluded.mtime, cue_start=excluded.cue_start, cue_end=excluded.cue_end, cue_number=excluded.cue_number,
                        title=excluded.title, artist=excluded.artist, album_artist=excluded.album_artist, album=excluded.album,
                        date=excluded.date, year=excluded.year, genre=excluded.genre, track_no=excluded.track_no, disc_no=excluded.disc_no,
                        duration=excluded.duration, bitrate=excluded.bitrate, sample_rate=excluded.sample_rate, bit_depth=excluded.bit_depth,
                        mb_artist=excluded.mb_artist, mb_group=excluded.mb_group, release_type=excluded.release_type,
                        release_status=excluded.release_status, kind=excluded.kind, show_date=excluded.show_date, venue=excluded.venue,
                        artist_key=excluded.artist_key, album_key=excluded.album_key, title_key=excluded.title_key, lossless=excluded.lossless,
                        playable=excluded.playable
                    """, [f.key, f.path, f.root, r.albumFolder, f.size, f.mtime, now, f.cueStart, f.cueEnd, f.cueNumber,
                          f.title, i.artist ?? r.artist, r.artist, r.album, i.originalDate ?? i.date, r.year, i.genre,
                          f.cueNumber ?? i.trackNumber, i.discNumber, i.duration, i.bitrate, i.sampleRate, i.bitDepth, i.mbArtistID,
                          i.mbReleaseGroupID, i.releaseType, i.releaseStatus, r.kind.rawValue, r.showDate, r.venue, artistKey, albumKey,
                          Keys.title(f.title), lossless && f.playable, f.playable])
                let id = try db.scalar("SELECT id FROM files WHERE key = ?", [f.key]) ?? 0
                try db.run("DELETE FROM genres WHERE file_id = ?", [id])
                for g in Self.genres(i.genre) { try db.run("INSERT INTO genres(file_id, genre) VALUES (?, ?)", [id, g]) }
            }
            try rollUp(albums: albums, artists: artists)
        }
    }

    /// Remove files by key (deleted on disk).
    func remove(keys: [String]) throws {
        guard !keys.isEmpty else { return }
        try db.transaction {
            var albums = Set<String>(), artists = Set<String>()
            for k in keys {
                var id: Int64?
                try db.query("SELECT id, album_key, artist_key FROM files WHERE key = ?", [k]) { s in
                    id = s.int64(0); albums.insert(s.text(1)); artists.insert(s.text(2))
                }
                guard let id else { continue }
                try db.run("DELETE FROM genres WHERE file_id = ?", [id])
                try db.run("DELETE FROM files WHERE id = ?", [id])
            }
            try rollUp(albums: albums, artists: artists)
        }
    }

    /// Forget everything under a root (the user removed it from the library).
    func removeRoot(_ root: String) throws {
        var keys: [String] = []
        try db.query("SELECT key FROM files WHERE root = ?", [root]) { keys.append($0.text(0)) }
        try remove(keys: keys)
    }

    private func rollUp(albums: Set<String>, artists: Set<String>) throws {
        for a in albums {
            try db.run("DELETE FROM albums WHERE key = ?", [a])
            // One row per album: most fields agree across its tracks; the first track (disc, number, path) gives the art.
            try db.run("""
                INSERT INTO albums(key, artist_key, artist, title, year, kind, folder, tracks, duration, first_path, lossless, added,
                                   show_date, venue, unplayable, unplayable_format)
                SELECT album_key, min(artist_key), min(album_artist), min(album), min(year), min(kind), min(folder), count(*),
                       coalesce(sum(duration), 0),
                       (SELECT path FROM files f2 WHERE f2.album_key = ?1 ORDER BY disc_no, track_no, path LIMIT 1),
                       min(lossless), max(added), min(show_date), min(venue), sum(playable = 0),
                       (SELECT upper(replace(path, rtrim(path, replace(path, '.', '')), '')) FROM files f3
                        WHERE f3.album_key = ?1 AND f3.playable = 0 LIMIT 1)
                FROM files WHERE album_key = ?1 GROUP BY album_key
                """, [a])
        }
        for k in artists {
            var name: String?
            try db.query("SELECT artist FROM albums WHERE artist_key = ? GROUP BY artist ORDER BY sum(tracks) DESC LIMIT 1", [k]) {
                name = $0.text(0)
            }
            if let name {
                try db.run("""
                    INSERT INTO artists(key, name, sort_name, letter) VALUES (?, ?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET name = excluded.name, sort_name = excluded.sort_name, letter = excluded.letter
                    """, [k, name, Keys.sortName(name), Keys.letter(name)])
            } else {
                try db.run("DELETE FROM artists WHERE key = ?", [k])
            }
        }
    }

    static func isLossless(_ path: String, bitDepth: Int?) -> Bool {
        switch (path as NSString).pathExtension.lowercased() {
        case "flac", "wav", "wave", "aif", "aiff", "aifc": return true
        case "m4a", "mp4", "caf": return bitDepth != nil   // ALAC reports a bit depth, AAC doesn't
        default: return false
        }
    }

    /// "Rock; Indie/Alternative, Shoegaze" → each on its own, trimmed.
    static func genres(_ s: String?) -> [String] {
        guard let s else { return [] }
        var seen = Set<String>()
        return s.split(whereSeparator: { $0 == ";" || $0 == "/" || $0 == "," || $0 == "\0" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: Reading

    struct Summary: Equatable {
        var tracks = 0, albums = 0, artists = 0
        var duration = 0.0
    }

    func summary() throws -> Summary {
        var s = Summary()
        try db.query("SELECT count(*), coalesce(sum(tracks), 0), coalesce(sum(duration), 0), count(DISTINCT artist_key) FROM albums") { r in
            s.albums = r.int(0); s.tracks = r.int(1); s.duration = r.double(2); s.artists = r.int(3)
        }
        return s
    }

    private static let albumColumns = """
        a.key, a.artist_key, a.artist, a.title, a.year, a.kind, a.folder, a.tracks, a.duration, a.first_path, a.lossless, a.added,
        a.show_date, a.venue, a.unplayable, a.unplayable_format
        """

    /// Albums matching a condition on `a` (the albums table), in an order.
    func albumsWhere(_ condition: String, _ args: [SQLValue?], order: String) throws -> [LibraryAlbum] {
        try albums("SELECT \(Self.albumColumns) FROM albums a WHERE \(condition) ORDER BY \(order)", args)
    }

    private func albums(_ sql: String, _ args: [SQLValue?]) throws -> [LibraryAlbum] {
        var out: [LibraryAlbum] = []
        try db.query(sql, args) { s in
            out.append(LibraryAlbum(key: s.text(0), artistKey: s.text(1), artist: s.text(2), title: s.text(3), year: s.optInt(4),
                                    kind: ReleaseKind(rawValue: s.int(5)) ?? .album, folder: s.text(6), tracks: s.int(7),
                                    duration: s.double(8), firstPath: s.text(9), lossless: s.int(10) == 1, added: s.double(11),
                                    showDate: s.optText(12), venue: s.optText(13), unplayable: s.int(14), unplayableFormat: s.optText(15)))
        }
        return out
    }

    /// Every artist with releases passing the filter, in A–Z order ("The" ignored).
    func artists(_ filter: LibraryFilter, onlyKind: ReleaseKind? = nil) throws -> [LibraryArtist] {
        var out: [LibraryArtist] = []
        let kind = onlyKind.map { " AND a.kind = \($0.rawValue)" } ?? ""
        try db.query("""
            SELECT r.key, r.name, r.letter, count(*), sum(a.tracks) FROM albums a JOIN artists r ON r.key = a.artist_key
            WHERE \(filter.sql)\(kind) GROUP BY r.key ORDER BY r.sort_name COLLATE NOCASE
            """) { s in
            out.append(LibraryArtist(key: s.text(0), name: s.text(1), letter: s.text(2), albums: s.int(3), tracks: s.int(4)))
        }
        return out
    }

    /// An artist's releases, oldest first (shows by date).
    func albums(artist: String, _ filter: LibraryFilter) throws -> [LibraryAlbum] {
        try albums("SELECT \(Self.albumColumns) FROM albums a WHERE a.artist_key = ? AND \(filter.sql) ORDER BY a.kind, coalesce(a.show_date, a.year), a.title",
                   [artist])
    }

    func albums(year: Int?, _ filter: LibraryFilter) throws -> [LibraryAlbum] {
        try albums("SELECT \(Self.albumColumns) FROM albums a WHERE a.year IS ? AND \(filter.sql) ORDER BY a.kind, a.artist COLLATE NOCASE, a.title",
                   [year])
    }

    func albums(genre: String, _ filter: LibraryFilter) throws -> [LibraryAlbum] {
        try albums("""
            SELECT \(Self.albumColumns) FROM albums a WHERE a.key IN
                (SELECT f.album_key FROM genres g JOIN files f ON f.id = g.file_id WHERE g.genre = ?)
            AND \(filter.sql) ORDER BY a.kind, a.artist COLLATE NOCASE, a.year
            """, [genre])
    }

    /// Albums added in a month ("2026-09"), newest first.
    func albums(addedIn month: String, _ filter: LibraryFilter) throws -> [LibraryAlbum] {
        try albums("""
            SELECT \(Self.albumColumns) FROM albums a WHERE strftime('%Y-%m', a.added, 'unixepoch', 'localtime') = ? AND \(filter.sql)
            ORDER BY a.added DESC
            """, [month])
    }

    /// Albums with a track matching the search.
    func albums(matching query: String, _ filter: LibraryFilter) throws -> [LibraryAlbum] {
        let (sql, args) = matchSQL(query)
        return try albums("""
            SELECT \(Self.albumColumns) FROM albums a WHERE a.key IN (SELECT album_key FROM files WHERE id IN (\(sql)))
            AND \(filter.sql) ORDER BY a.artist COLLATE NOCASE, a.kind, a.year LIMIT 2000
            """, args)
    }

    /// Artists matching the search by name, or with matching tracks.
    func artists(matching query: String, _ filter: LibraryFilter) throws -> [LibraryArtist] {
        let (sql, args) = matchSQL(query)
        var out: [LibraryArtist] = []
        try db.query("""
            SELECT r.key, r.name, r.letter, count(*), sum(a.tracks) FROM albums a JOIN artists r ON r.key = a.artist_key
            WHERE \(filter.sql) AND a.key IN (SELECT album_key FROM files WHERE id IN (\(sql)))
            GROUP BY r.key ORDER BY r.sort_name COLLATE NOCASE LIMIT 1000
            """, args) { s in
            out.append(LibraryArtist(key: s.text(0), name: s.text(1), letter: s.text(2), albums: s.int(3), tracks: s.int(4)))
        }
        return out
    }

    /// File ids matching the words typed: every word must match (as a prefix) somewhere.
    private func matchSQL(_ query: String) -> (String, [SQLValue?]) {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        if hasFTS {
            // Each word quoted (no FTS syntax from the user), matched as a prefix.
            let q = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " ")
            return ("SELECT rowid FROM fts WHERE fts MATCH ?", [q.isEmpty ? "\"\"" : q])
        }
        // Plain "?" placeholders (4 per word), so the clause can go after other parameters.
        var sql = "SELECT id FROM files WHERE 1", args: [SQLValue?] = []
        for w in words {
            sql += " AND (title LIKE ? OR artist LIKE ? OR album LIKE ? OR venue LIKE ?)"
            args += Array(repeating: "%" + w + "%", count: 4)
        }
        return (sql, args)
    }

    /// Years with how many albums each (nil year: "Unknown"), newest first.
    func years(_ filter: LibraryFilter) throws -> [LibraryBucket] {
        var out: [LibraryBucket] = []
        try db.query("SELECT a.year, count(*) FROM albums a WHERE \(filter.sql) GROUP BY a.year ORDER BY a.year IS NULL, a.year DESC") { s in
            let y = s.optInt(0)
            out.append(LibraryBucket(id: y.map(String.init) ?? "", title: y.map(String.init) ?? "Unknown", count: s.int(1)))
        }
        return out
    }

    /// Genres with their album counts, biggest first.
    func genres(_ filter: LibraryFilter) throws -> [LibraryBucket] {
        var out: [LibraryBucket] = []
        try db.query("""
            SELECT g.genre, count(DISTINCT a.key) AS n FROM genres g JOIN files f ON f.id = g.file_id JOIN albums a ON a.key = f.album_key
            WHERE \(filter.sql) GROUP BY g.genre ORDER BY n DESC, g.genre COLLATE NOCASE
            """) { s in
            out.append(LibraryBucket(id: s.text(0), title: s.text(0), count: s.int(1)))
        }
        return out
    }

    /// Months albums were added in, newest first.
    func addedMonths(_ filter: LibraryFilter) throws -> [LibraryBucket] {
        var out: [LibraryBucket] = []
        try db.query("""
            SELECT strftime('%Y-%m', a.added, 'unixepoch', 'localtime') AS m, count(*) FROM albums a WHERE \(filter.sql)
            GROUP BY m ORDER BY m DESC
            """) { s in
            let id = s.text(0)
            out.append(LibraryBucket(id: id, title: Self.monthTitle(id), count: s.int(1)))
        }
        return out
    }

    private static func monthTitle(_ ym: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        guard let d = f.date(from: ym) else { return ym }
        f.dateFormat = "MMMM yyyy"
        return f.string(from: d)
    }

    /// The columns a LibraryTrack is read from (files table, alias f).
    private static let trackColumns = """
        f.id, f.key, f.path, f.size, f.mtime, f.cue_start, f.cue_end, f.cue_number, f.title, f.artist, f.album, f.album_key, f.disc_no,
        f.track_no, f.duration, f.bit_depth, f.sample_rate, f.bitrate, f.playable
        """

    private static func track(_ s: Statement) -> LibraryTrack {
        let path = s.text(2)
        return LibraryTrack(id: s.int64(0), key: s.text(1), path: path, size: s.int64(3), mtime: s.double(4), cueStart: s.optDouble(5),
                            cueEnd: s.optDouble(6), cueNumber: s.optInt(7), title: s.text(8), artist: s.text(9), album: s.text(10),
                            albumKey: s.text(11), disc: s.optInt(12), number: s.optInt(13), duration: s.optDouble(14),
                            format: format(path, bitDepth: s.optInt(15), rate: s.optInt(16), kbps: s.optInt(17)), playable: s.int(18) == 1)
    }

    /// An album's tracks in order. With a search, only the matching ones.
    func tracks(album: String, matching query: String? = nil) throws -> [LibraryTrack] {
        var out: [LibraryTrack] = []
        var sql = "SELECT \(Self.trackColumns) FROM files f WHERE f.album_key = ?"
        var args: [SQLValue?] = [album]
        if let q = query, !q.trimmingCharacters(in: .whitespaces).isEmpty {
            let (m, margs) = matchSQL(q)
            sql += " AND f.id IN (\(m))"
            args += margs
        }
        sql += " ORDER BY f.disc_no, f.track_no, f.cue_start, f.path"
        try db.query(sql, args) { out.append(Self.track($0)) }
        return out
    }

    /// Every recording of one song by one artist (versions folded by title key), oldest first.
    func versions(artist: String, titleKey: String) throws -> [SongVersion] {
        var out: [SongVersion] = []
        try db.query("""
            SELECT \(Self.trackColumns), a.kind, a.title, a.year, a.show_date, a.venue, f.date, a.first_path, a.folder
            FROM files f JOIN albums a ON a.key = f.album_key WHERE f.artist_key = ? AND f.title_key = ?
            """, [artist, titleKey]) { s in
            out.append(SongVersion(track: Self.track(s), kind: ReleaseKind(rawValue: s.int(19)) ?? .album, release: s.text(20),
                                   year: s.optInt(21), showDate: s.optText(22), venue: s.optText(23), date: s.optText(24),
                                   artPath: s.text(25), folder: s.text(26)))
        }
        return out.sorted { ($0.when ?? .infinity, $0.release) < ($1.when ?? .infinity, $1.release) }
    }

    /// An artist's plays of one song, from the last.fm history: per album name, per year, and the first one.
    func songPlays(artist: String, titleKey: String) throws -> SongPlays {
        var p = SongPlays()
        var years: [Int: Int] = [:]
        try db.query("SELECT ts, album, title FROM scrobbles WHERE artist_key = ?", [artist]) { s in
            guard Keys.title(s.text(2)) == titleKey else { return }
            let ts = s.int(0)
            p.total += 1
            p.byAlbum[Keys.fold(s.text(1)), default: 0] += 1
            let d = Date(timeIntervalSince1970: TimeInterval(ts))
            years[Calendar.current.component(.year, from: d), default: 0] += 1
            if p.first.map({ d < $0 }) ?? true { p.first = d }
            if p.last.map({ d > $0 }) ?? true { p.last = d }
        }
        p.byYear = years.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return p
    }

    /// Where a playlist track sits in the library (its artist, song and release), if it's there.
    func place(ofTrack key: String) throws -> (artist: String, artistName: String, song: String, album: String)? {
        var out: (String, String, String, String)?
        try db.query("SELECT artist_key, album_artist, title_key, album_key FROM files WHERE key = ?", [key]) {
            out = ($0.text(0), $0.text(1), $0.text(2), $0.text(3))
        }
        return out
    }

    /// The genre most of an album's tracks have (nil when none has one).
    func genre(album: String) throws -> String? {
        var g: String?
        try db.query("SELECT genre FROM files WHERE album_key = ? AND genre IS NOT NULL GROUP BY genre ORDER BY count(*) DESC LIMIT 1",
                     [album]) { g = $0.text(0) }
        return g
    }

    /// "FLAC 24/96", "MP3 320".
    static func format(_ path: String, bitDepth: Int?, rate: Int?, kbps: Int?) -> String {
        var ext = (path as NSString).pathExtension.uppercased()
        if ext == "M4A" || ext == "MP4" { ext = bitDepth != nil ? "ALAC" : "AAC" }
        if isLossless(path, bitDepth: bitDepth), let b = bitDepth, let r = rate {
            let k = Double(r) / 1000
            return "\(ext) \(b)/\(k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k))"
        }
        return kbps.map { "\(ext) \($0)" } ?? ext
    }
}

/// One recording of a song: the track, and what release it's on.
struct SongVersion: Equatable {
    let track: LibraryTrack
    let kind: ReleaseKind
    let release: String
    let year: Int?
    let showDate: String?
    let venue: String?
    /// The DATE tag ("1991", "1991-11-25").
    let date: String?
    let artPath: String
    let folder: String

    /// A point in time for the timeline: the concert date, the full DATE tag, or the middle of the year.
    var when: Double? {
        for d in [showDate, date] {
            guard let d, d.count >= 10 else { continue }
            let parts = d.prefix(10).split(separator: "-").compactMap { Int($0) }
            if parts.count == 3, let y = parts.first {
                return Double(y) + (Double(parts[1] - 1) * 30.5 + Double(parts[2] - 1)) / 366
            }
        }
        return year.map { Double($0) + 0.5 }
    }

    /// "1991-11-25 Paradiso, Amsterdam", "Bleach (1989)".
    var label: String {
        if kind == .show, let d = showDate { return [d, venue].compactMap { $0 }.joined(separator: " ") }
        return release + (year.map { " (\($0))" } ?? "")
    }
}

/// Last.fm plays of one song.
struct SongPlays: Equatable {
    var total = 0
    /// Folded album name → plays (scrobbles carry the album they were played from).
    var byAlbum: [String: Int] = [:]
    var byYear: [(year: Int, releases: Int)] = []
    var first: Date?
    var last: Date?

    static func == (a: SongPlays, b: SongPlays) -> Bool {
        a.total == b.total && a.byAlbum == b.byAlbum && a.first == b.first && a.last == b.last
    }
}
