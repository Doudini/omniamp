import Foundation

/// Figures about the collection for the Stats page, all computed in one go (on a background connection).
struct LibraryStats: Sendable {
    struct Bar: Sendable, Equatable {
        let id: String       // what a click opens (a genre, an artist key, a year…)
        let label: String
        let value: Double
        var detail = ""      // a second, quieter figure ("312 releases")
    }

    struct Song: Sendable, Equatable {
        let title: String
        let artist: String
        let artistKey: String
        let titleKey: String
        let versions: Int
        let unofficial: Int
    }

    var tracks = 0, releases = 0, artists = 0, shows = 0
    var seconds = 0.0, bytes: Int64 = 0, losslessTracks = 0, unplayable = 0
    var kinds: [Bar] = []
    var genres: [Bar] = []
    var otherGenres = 0
    /// Releases per year of release (only years that have some).
    var years: [(year: Int, releases: Int)] = []
    var formats: [Bar] = []
    /// Tracks in the collection by the month their files date from ("2004-05"), running total.
    var growth: [(month: String, total: Int)] = []
    /// Shows owned per month of the concert ("1977-05" → 23).
    var showMonths: [String: Int] = [:]
    var songs: [Song] = []
    var topArtists: [Bar] = []
}

extension CollectionDB {
    func stats(_ filter: LibraryFilter) throws -> LibraryStats {
        var s = LibraryStats()
        let f = filter.sql
        try db.query("""
            SELECT count(*), coalesce(sum(a.tracks), 0), coalesce(sum(a.duration), 0), count(DISTINCT a.artist_key),
                   coalesce(sum(a.kind = \(ReleaseKind.show.rawValue)), 0), coalesce(sum(a.unplayable), 0)
            FROM albums a WHERE \(f)
            """) { r in
            s.releases = r.int(0); s.tracks = r.int(1); s.seconds = r.double(2); s.artists = r.int(3); s.shows = r.int(4)
            s.unplayable = r.int(5)
        }
        try db.query("SELECT coalesce(sum(f.size), 0), coalesce(sum(f.lossless), 0) FROM files f JOIN albums a ON a.key = f.album_key WHERE \(f)") { r in
            s.bytes = r.int64(0); s.losslessTracks = r.int(1)
        }

        var byKind: [Int: (Int, Int)] = [:]
        try db.query("SELECT a.kind, count(*), sum(a.tracks) FROM albums a WHERE \(f) GROUP BY a.kind") { r in byKind[r.int(0)] = (r.int(1), r.int(2)) }
        s.kinds = ReleaseKind.allCases.compactMap { k in
            byKind[k.rawValue].map { LibraryStats.Bar(id: String(k.rawValue), label: k.title, value: Double($0.0), detail: "\($0.1.formatted()) tracks") }
        }

        var genres: [LibraryStats.Bar] = []
        try db.query("""
            SELECT min(g.genre), count(DISTINCT f.id) AS n, count(DISTINCT a.key) FROM genres g JOIN files f ON f.id = g.file_id
            JOIN albums a ON a.key = f.album_key WHERE \(f) GROUP BY g.genre ORDER BY n DESC
            """) { r in genres.append(.init(id: r.text(0), label: r.text(0), value: Double(r.int(1)), detail: "\(r.int(2).formatted()) releases")) }
        s.genres = Array(genres.prefix(14))
        s.otherGenres = genres.dropFirst(14).count

        try db.query("SELECT a.year, count(*) FROM albums a WHERE \(f) AND a.year IS NOT NULL GROUP BY a.year ORDER BY a.year") { r in
            s.years.append((r.int(0), r.int(1)))
        }

        // Formats: codec, and for lossless the resolution; MP3 by bitrate.
        var formats: [String: Int] = [:]
        try db.query("""
            SELECT lower(replace(f.path, rtrim(f.path, replace(f.path, '.', '')), '')), f.bit_depth, f.sample_rate, f.bitrate, count(*)
            FROM files f JOIN albums a ON a.key = f.album_key WHERE \(f) GROUP BY 1, 2, 3, 4 / 32
            """) { r in
            formats[Self.formatGroup(ext: r.text(0), bits: r.optInt(1), rate: r.optInt(2), kbps: r.optInt(3)), default: 0] += r.int(4)
        }
        s.formats = formats.sorted { $0.value > $1.value }.map { .init(id: $0.key, label: $0.key, value: Double($0.value)) }

        var running = 0
        try db.query("""
            SELECT strftime('%Y-%m', f.mtime, 'unixepoch', 'localtime') AS m, count(*) FROM files f JOIN albums a ON a.key = f.album_key
            WHERE \(f) AND f.mtime > 0 GROUP BY m ORDER BY m
            """) { r in
            running += r.int(1)
            s.growth.append((r.text(0), running))
        }

        try db.query("""
            SELECT substr(a.show_date, 1, 7), count(*) FROM albums a
            WHERE \(f) AND a.kind = \(ReleaseKind.show.rawValue) AND a.show_date IS NOT NULL GROUP BY 1
            """) { r in s.showMonths[r.text(0)] = r.int(1) }

        // Songs with the most recordings: the same title (versions folded) by the same artist on several releases.
        try db.query("""
            SELECT min(f.title), min(a.artist), count(DISTINCT f.album_key) AS n,
                   count(DISTINCT CASE WHEN a.kind > \(ReleaseKind.live.rawValue) THEN f.album_key END), f.artist_key, f.title_key
            FROM files f JOIN albums a ON a.key = f.album_key WHERE \(f) AND length(f.title_key) >= 3
            GROUP BY f.artist_key, f.title_key HAVING n >= 3 ORDER BY n DESC LIMIT 60
            """) { r in
            let title = r.text(0)
            guard !Self.isPlaceholderTitle(title) else { return }
            s.songs.append(.init(title: title, artist: r.text(1), artistKey: r.text(4), titleKey: r.text(5), versions: r.int(2),
                                 unofficial: r.int(3)))
        }
        s.songs = Array(s.songs.prefix(12))

        try db.query("""
            SELECT a.artist_key, min(a.artist), sum(a.duration) AS d, sum(a.tracks), count(*) FROM albums a WHERE \(f)
            GROUP BY a.artist_key ORDER BY d DESC LIMIT 12
            """) { r in
            s.topArtists.append(.init(id: r.text(0), label: r.text(1), value: r.double(2) / 3600,
                                      detail: "\(r.int(4).formatted()) releases"))
        }
        return s
    }

    /// "FLAC 24-bit", "FLAC 16-bit", "MP3 256–320", "AAC", "WMA"…
    static func formatGroup(ext: String, bits: Int?, rate: Int?, kbps: Int?) -> String {
        switch ext {
        case "flac", "wav", "wave", "aif", "aiff", "aifc":
            let codec = ext == "flac" ? "FLAC" : (ext.hasPrefix("wav") ? "WAV" : "AIFF")
            return bits.map { $0 > 16 ? "\(codec) \($0)-bit" : "\(codec) 16-bit" } ?? codec
        case "mp3":
            guard let k = kbps else { return "MP3" }
            return k >= 256 ? "MP3 256–320" : k >= 160 ? "MP3 160–255" : "MP3 under 160"
        case "m4a", "mp4", "m4b": return bits != nil ? "ALAC" : "AAC"
        case "ogg", "oga": return "Ogg Vorbis"
        default: return ext.uppercased()
        }
    }

    /// Titles that are file names rather than songs ("Track 01", "Untitled", "Intro").
    static func isPlaceholderTitle(_ t: String) -> Bool {
        let k = Keys.fold(t)
        if k.allSatisfy({ $0.isNumber || $0 == " " }) { return true }
        let first = k.split(separator: " ").first.map(String.init) ?? ""
        return ["track", "piste", "untitled", "unknown", "intro", "outro", "audiotrack", "titel", "tuning", "crowd", "applause",
                "banter", "introduction", "noodling", "jam"].contains(first)
            || first.hasPrefix("track") || first.hasPrefix("d1t") || first.hasPrefix("d2t")
    }
}
