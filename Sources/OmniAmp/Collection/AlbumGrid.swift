import Foundation

/// How the album grid groups its covers.
enum AlbumGrouping: String, CaseIterable {
    case artist, year, decade, kind, added, none

    var title: String {
        switch self {
        case .artist: "Artist"
        case .year: "Year"
        case .decade: "Decade"
        case .kind: "Kind"
        case .added: "Added"
        case .none: "A–Z"
        }
    }
}

/// The album grid's contents and moves, apart from the views: sections of albums in order, where the arrow keys
/// go, and where an opened album's panel goes (under the row it's in).
enum AlbumGrid {
    struct Section: Equatable {
        let title: String
        /// The section's kind of recording (Kind grouping): shown as its color.
        let kind: ReleaseKind?
        var albums: [LibraryAlbum]
    }

    /// An album's place: its section, and its index there.
    struct Position: Equatable {
        var section: Int
        var index: Int
    }

    enum Direction { case left, right, up, down }

    // MARK: Sections

    static func sections(_ albums: [LibraryAlbum], by grouping: AlbumGrouping) -> [Section] {
        switch grouping {
        case .artist:
            return runs(albums.sorted(by: byArtist), key: \.artistKey) { a, list in
                Section(title: a.artist, kind: nil, albums: list.sorted(by: withinArtist))
            }
        case .year:
            let sorted = albums.sorted { x, y in
                x.year != y.year ? (x.year ?? .min) > (y.year ?? .min) : byArtist(x, y)
            }
            return runs(sorted, key: { $0.year }) { a, list in Section(title: a.year.map(String.init) ?? "Unknown year", kind: nil, albums: list) }
        case .decade:
            let sorted = albums.sorted { x, y in
                x.year != y.year ? (x.year ?? .min) > (y.year ?? .min) : byArtist(x, y)
            }
            return runs(sorted, key: { $0.year.map { $0 / 10 } }) { a, list in
                Section(title: a.year.map { "\($0 / 10 * 10)s" } ?? "Unknown year", kind: nil, albums: list)
            }
        case .kind:
            let sorted = albums.sorted { x, y in x.kind != y.kind ? x.kind.rawValue < y.kind.rawValue : byArtist(x, y) }
            return runs(sorted, key: \.kind) { a, list in Section(title: a.kind.title, kind: a.kind, albums: list) }
        case .added:
            let sorted = albums.sorted { $0.added != $1.added ? $0.added > $1.added : byArtist($0, $1) }
            return runs(sorted, key: { month($0.added) }) { a, list in Section(title: month(a.added), kind: nil, albums: list) }
        case .none:
            return albums.isEmpty ? [] : [Section(title: "", kind: nil, albums: albums.sorted(by: byArtist))]
        }
    }

    /// Consecutive albums with the same key, each run made into a section.
    private static func runs<K: Equatable>(_ sorted: [LibraryAlbum], key: (LibraryAlbum) -> K,
                                           make: (LibraryAlbum, [LibraryAlbum]) -> Section) -> [Section] {
        var out: [Section] = []
        var i = 0
        while i < sorted.count {
            let k = key(sorted[i])
            var j = i
            while j < sorted.count, key(sorted[j]) == k { j += 1 }
            out.append(make(sorted[i], Array(sorted[i..<j])))
            i = j
        }
        return out
    }

    /// Artists A–Z as the lists sort them ("The Cure" under C), then each artist's releases.
    private static func byArtist(_ x: LibraryAlbum, _ y: LibraryAlbum) -> Bool {
        if x.artistKey != y.artistKey {
            let r = Keys.sortName(x.artist).localizedCaseInsensitiveCompare(Keys.sortName(y.artist))
            return r != .orderedSame ? r == .orderedAscending : x.artistKey < y.artistKey
        }
        return withinArtist(x, y)
    }

    /// One artist's releases: the official ones first, by year, then the unofficial ones by date (a hundred shows
    /// don't bury the five albums).
    private static func withinArtist(_ x: LibraryAlbum, _ y: LibraryAlbum) -> Bool {
        if x.kind.isOfficial != y.kind.isOfficial { return x.kind.isOfficial }
        let wx = x.showDate ?? x.year.map(String.init) ?? "~", wy = y.showDate ?? y.year.map(String.init) ?? "~"
        if wx != wy { return wx < wy }
        let t = x.title.localizedCaseInsensitiveCompare(y.title)
        return t != .orderedSame ? t == .orderedAscending : x.key < y.key
    }

    private static func month(_ t: Double) -> String {
        t > 0 ? monthFormat.string(from: Date(timeIntervalSince1970: t)) : "Unknown"
    }
    private static let monthFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f
    }()

    // MARK: Moves

    /// Where an arrow key goes from `p` in sections holding `counts` albums, `columns` to a row. nil: nowhere.
    /// Up and down keep the column, across sections too; left and right run on through the sections.
    static func move(_ p: Position, _ d: Direction, counts: [Int], columns: Int) -> Position? {
        guard p.section < counts.count, columns > 0 else { return nil }
        let count = counts[p.section], col = p.index % columns
        func previous() -> Int? { (0..<p.section).last { counts[$0] > 0 } }
        func next() -> Int? { (p.section + 1..<counts.count).first { counts[$0] > 0 } }
        switch d {
        case .left:
            if p.index > 0 { return Position(section: p.section, index: p.index - 1) }
            return previous().map { Position(section: $0, index: counts[$0] - 1) }
        case .right:
            if p.index + 1 < count { return Position(section: p.section, index: p.index + 1) }
            return next().map { Position(section: $0, index: 0) }
        case .up:
            if p.index >= columns { return Position(section: p.section, index: p.index - columns) }
            return previous().map { s in Position(section: s, index: min(counts[s] - 1, (counts[s] - 1) / columns * columns + col)) }
        case .down:
            if p.index + columns < count { return Position(section: p.section, index: p.index + columns) }
            // A shorter last row below: its last album.
            if p.index / columns < (count - 1) / columns { return Position(section: p.section, index: count - 1) }
            return next().map { s in Position(section: s, index: min(counts[s] - 1, col)) }
        }
    }

    /// The item index an opened album's panel takes: right after the last album of its row.
    static func panelSlot(index: Int, count: Int, columns: Int) -> Int {
        min(count, (index / max(1, columns) + 1) * max(1, columns))
    }
}
