import Foundation

/// Everything the artist page shows: their releases, and your listening of them.
struct ArtistDashboard {
    var key = ""
    var name = ""
    var country: String?
    var releases: [LibraryAlbum] = []
    var ownedTracks = 0
    var ownedSeconds = 0.0
    var plays = 0
    var firstPlay: (date: Date, title: String)?
    var lastPlay: Date?
    /// Plays per month ("2008-03"), oldest first.
    var months: [(month: String, plays: Int)] = []
    var topSongs: [Song] = []
    var mostRecorded: [Song] = []
    var playedAlbums: [LibraryStats.Bar] = []
    /// Kind of each played album that's in the library (folded title → kind), for its color.
    var playedAlbumKinds: [String: ReleaseKind] = [:]
    var showsPerYear: [(year: Int, releases: Int)] = []

    struct Song: Equatable {
        let title: String
        let titleKey: String
        let plays: Int
        /// Recordings in the library.
        let versions: Int
    }
}

extension CollectionDB {
    func artistDashboard(_ key: String) throws -> ArtistDashboard {
        var d = ArtistDashboard(key: key)
        try db.query("SELECT name FROM artists WHERE key = ?", [key]) { d.name = $0.text(0) }
        // Not in the library: as last.fm spells them (most plays).
        if d.name.isEmpty {
            try db.query("SELECT artist FROM scrobbles WHERE artist_key = ? GROUP BY artist ORDER BY count(*) DESC LIMIT 1", [key]) { d.name = $0.text(0) }
        }
        try db.query("SELECT country FROM artist_places WHERE artist_key = ? AND country IS NOT NULL", [key]) { d.country = $0.text(0) }
        d.releases = try albums(artist: key, LibraryFilter())
        d.ownedTracks = d.releases.reduce(0) { $0 + $1.tracks }
        d.ownedSeconds = d.releases.reduce(0) { $0 + $1.duration }

        // Owned recordings per song (versions folded).
        var versions: [String: (title: String, n: Int)] = [:]
        try db.query("SELECT title_key, count(DISTINCT album_key) FROM files WHERE artist_key = ? GROUP BY title_key", [key]) { r in
            versions[r.text(0)] = ("", r.int(1))
        }
        var spellings: [String: [String: Int]] = [:]
        try db.query("SELECT title_key, title, count(*) FROM files WHERE artist_key = ? GROUP BY title_key, title", [key]) { r in
            spellings[r.text(0), default: [:]][r.text(1)] = r.int(2)
        }
        for (k, v) in versions { versions[k] = (Keys.displayTitle(spellings[k] ?? [:]), v.n) }
        d.mostRecorded = versions.filter { $0.value.n >= 2 && !CollectionDB.isPlaceholderTitle($0.value.title) }
            .sorted { ($0.value.n, $1.key) > ($1.value.n, $0.key) }.prefix(12)
            .map { .init(title: $0.value.title, titleKey: $0.key, plays: 0, versions: $0.value.n) }

        // Plays: per song, per album, per month, the first and the last.
        var songs: [String: (spellings: [String: Int], n: Int)] = [:], albumsPlayed: [String: (name: String, n: Int)] = [:], months: [String: Int] = [:]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        try db.query("SELECT ts, title, album FROM scrobbles WHERE artist_key = ? ORDER BY ts", [key]) { r in
            let date = Date(timeIntervalSince1970: TimeInterval(r.int(0))), title = r.text(1), album = r.text(2)
            d.plays += 1
            if d.firstPlay == nil { d.firstPlay = (date, title) }
            d.lastPlay = date
            let k = Keys.title(title)
            var entry = songs[k] ?? ([:], 0)
            entry.spellings[title, default: 0] += 1
            entry.n += 1
            songs[k] = entry
            if !album.isEmpty {
                let a = Keys.fold(album)
                albumsPlayed[a] = (albumsPlayed[a]?.name ?? album, (albumsPlayed[a]?.n ?? 0) + 1)
            }
            months[f.string(from: date), default: 0] += 1
        }
        d.topSongs = songs.sorted { ($0.value.n, $1.key) > ($1.value.n, $0.key) }.prefix(15)
            .map { .init(title: versions[$0.key]?.title ?? Keys.displayTitle($0.value.spellings), titleKey: $0.key, plays: $0.value.n,
                         versions: versions[$0.key]?.n ?? 0) }
        for a in d.releases { d.playedAlbumKinds[Keys.fold(a.title)] = d.playedAlbumKinds[Keys.fold(a.title)] ?? a.kind }
        d.playedAlbums = albumsPlayed.sorted { $0.value.n > $1.value.n }.prefix(12).map { k, v in
            .init(id: k, label: v.name, value: Double(v.n), detail: d.playedAlbumKinds[k] == nil ? "not in library" : "")
        }
        // Every month from the first play to the last, empty ones too (a gap is part of the story).
        if let first = d.firstPlay?.date, let last = d.lastPlay {
            var m = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: first))!
            while m <= last {
                let s = f.string(from: m)
                d.months.append((s, months[s] ?? 0))
                m = Calendar.current.date(byAdding: .month, value: 1, to: m)!
            }
        }
        let shows = Dictionary(grouping: d.releases.filter { $0.kind == .show }.compactMap(\.year), by: { $0 }).mapValues(\.count)
        d.showsPerYear = shows.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return d
    }
}
