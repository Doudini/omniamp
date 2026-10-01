import XCTest
@testable import OmniAmp

final class TracksPageTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-tracks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Sorting

    private func row(_ id: Int64, artist: String, album: String, title: String, disc: Int? = nil, number: Int? = nil,
                     duration: Double? = 200, year: Int? = nil, genre: String = "", added: Double = 0) -> TrackRow {
        let t = LibraryTrack(id: id, key: "k\(id)", path: "/m/\(id).flac", size: 1, mtime: 1, cueStart: nil, cueEnd: nil, cueNumber: nil,
                             title: title, artist: artist, album: album, albumKey: Keys.artist(artist) + "\u{1}" + Keys.fold(album),
                             disc: disc, number: number, duration: duration, format: "FLAC")
        return TrackRow(track: t, genre: genre, year: year, added: added, artistKey: Keys.artist(artist))
    }

    private lazy var rows = [
        row(1, artist: "The Cure", album: "Disintegration", title: "Plainsong", number: 1, year: 1989),
        row(2, artist: "Björk", album: "Homogenic", title: "Hunter", number: 1, year: 1997, genre: "Electronic"),
        row(3, artist: "The Cure", album: "Disintegration", title: "Pictures of You", number: 2, year: 1989),
        row(4, artist: "Cure", album: "Wish", title: "Open", disc: 2, number: 1, duration: nil, year: nil),
        row(5, artist: "The Cure", album: "Wish", title: "High", disc: 1, number: 2, year: 1992),
        row(6, artist: "Beirut", album: "Gulag Orkestar", title: "Postcards", year: 2006, genre: "Folk"),
    ]

    private func titles(_ s: TrackSort) -> [String] { s.sorted(rows).map(\.track.title) }

    func testNaturalOrder() {
        // "The Cure" under C (with "Cure"); an album's discs, then its tracks; accents folded ("Björk" by "bjork").
        XCTAssertEqual(titles(TrackSort()), ["Postcards", "Hunter", "Plainsong", "Pictures of You", "High", "Open"])
        // Reversed, only the artist order turns; an album keeps its track order.
        XCTAssertEqual(titles(TrackSort(column: .artist, ascending: false)), ["Plainsong", "Pictures of You", "High", "Open", "Hunter", "Postcards"])
    }

    func testColumnsAndMissingValues() {
        XCTAssertEqual(titles(TrackSort(column: .title)), ["High", "Hunter", "Open", "Pictures of You", "Plainsong", "Postcards"])
        // No year sorts last either way; ties by artist, album, track.
        XCTAssertEqual(titles(TrackSort(column: .year)), ["Plainsong", "Pictures of You", "High", "Hunter", "Postcards", "Open"])
        XCTAssertEqual(titles(TrackSort(column: .year, ascending: false)), ["Postcards", "Hunter", "High", "Plainsong", "Pictures of You", "Open"])
        XCTAssertEqual(titles(TrackSort(column: .length)).last, "Open")
        XCTAssertEqual(titles(TrackSort(column: .length, ascending: false)).last, "Open")
        // Empty genres after the named ones.
        XCTAssertEqual(Array(titles(TrackSort(column: .genre)).prefix(2)), ["Hunter", "Postcards"])
    }

    func testPlaysAndLastPlayed() {
        let counts = [rows[1].countKey: PlayCount(plays: 7, last: 3000),   // Hunter
                      rows[2].countKey: PlayCount(plays: 2, last: 9000),   // Pictures of You
                      rows[5].countKey: PlayCount(plays: 7, last: 1000)]   // Postcards
        // Most played first (ties by artist), then the never played in their natural order.
        XCTAssertEqual(TrackSort(column: .plays, ascending: false).sorted(rows, counts: counts).map(\.track.title),
                       ["Postcards", "Hunter", "Pictures of You", "Plainsong", "High", "Open"])
        // Last played: never played at the end, either way.
        XCTAssertEqual(Array(TrackSort(column: .lastPlayed).sorted(rows, counts: counts).map(\.track.title).prefix(3)),
                       ["Postcards", "Hunter", "Pictures of You"])
        XCTAssertEqual(Array(TrackSort(column: .lastPlayed, ascending: false).sorted(rows, counts: counts).map(\.track.title).prefix(3)),
                       ["Pictures of You", "Hunter", "Postcards"])
        XCTAssertEqual(rows[2].countKey, "cure\u{1}" + Keys.title("Pictures of You"))
    }

    func testPrefRoundTrip() {
        XCTAssertEqual(TrackSort(pref: "year:desc"), TrackSort(column: .year, ascending: false))
        XCTAssertEqual(TrackSort(pref: TrackSort(column: .album).pref), TrackSort(column: .album))
        XCTAssertNil(TrackSort(pref: "nonsense:asc"))
        XCTAssertNil(TrackSort(pref: nil))
    }

    func testDiscShowsOnlyForMultiDiscAlbums() {
        var r = row(9, artist: "A", album: "B", title: "C", disc: 1, number: 5)
        XCTAssertEqual(r.trackNumber, "5")
        r.multiDisc = true
        XCTAssertEqual(r.trackNumber, "1-05")
        XCTAssertEqual(row(10, artist: "A", album: "B", title: "C").trackNumber, "")
    }

    // MARK: From the library

    private func file(_ i: Int, artist: String, album: String, title: String, disc: Int? = nil, number: Int? = nil,
                      kind: ReleaseKind = .album, genre: String? = nil, year: Int? = nil) -> LibraryFile {
        var info = TagInfo()
        info.genre = genre
        info.trackNumber = number
        info.discNumber = disc
        info.duration = 200
        let path = "/m/\(artist)/\(album)/\(i).flac"
        return LibraryFile(key: path, path: path, root: "/m", size: 1, mtime: 1, cueStart: nil, cueEnd: nil, cueNumber: nil, info: info,
                           result: .init(kind: kind, artist: artist, album: album, year: year, showDate: nil, venue: nil,
                                         albumFolder: "/m/\(artist)/\(album)"),
                           title: title)
    }

    func testTrackRowsFilterSearchAndDiscs() throws {
        let d = try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite"))
        try d.upsert([
            file(1, artist: "Nirvana", album: "Bleach", title: "Blew", number: 1, genre: "Grunge", year: 1989),
            file(2, artist: "Nirvana", album: "Bleach", title: "Floyd the Barber", number: 2, genre: "Grunge", year: 1989),
            file(3, artist: "Wilco", album: "Being There", title: "Misunderstood", disc: 1, number: 1, year: 1996),
            file(4, artist: "Wilco", album: "Being There", title: "Sunken Treasure", disc: 2, number: 1, year: 1996),
            file(5, artist: "Nirvana", album: "1991-11-25 Amsterdam", title: "Blew", kind: .show),
        ])
        let all = try d.trackRows()
        func visible(_ f: LibraryFilter, _ q: String? = nil) throws -> [TrackRow] {
            TrackRow.visible(all, filter: f, ids: try q.map { try d.fileIDs(matching: $0) })
        }
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(Set(all.filter(\.multiDisc).map(\.track.title)), ["Misunderstood", "Sunken Treasure"])
        XCTAssertEqual(all.first { $0.track.title == "Floyd the Barber" }?.genre, "Grunge")
        XCTAssertEqual(all.first { $0.track.title == "Misunderstood" }?.year, 1996)
        XCTAssertEqual(try visible(LibraryFilter(scope: .unofficial)).map(\.track.album), ["1991-11-25 Amsterdam"])
        XCTAssertEqual(try visible(LibraryFilter(scope: .official)).count, 4)
        XCTAssertEqual(Set(try visible(LibraryFilter(), "blew").map(\.track.album)), ["Bleach", "1991-11-25 Amsterdam"])
        XCTAssertEqual(try visible(LibraryFilter(scope: .official), "blew").map(\.track.album), ["Bleach"])
        XCTAssertEqual(try visible(LibraryFilter(), "grunge").count, 2)
        XCTAssertEqual(try visible(LibraryFilter(), "nothing like it").count, 0)
    }

    func testLargeLibraryLoadsAndSortsQuickly() throws {
        // 100,000 tracks: read and sorted (off the main thread in the app) well under a second each.
        let d = try CollectionDB(url: tmp.appendingPathComponent("big.sqlite"))
        var files: [LibraryFile] = []
        for i in 0..<100_000 {
            files.append(file(i, artist: "Artist \(i % 2000)", album: "Album \(i % 9000)", title: "Song \(i)", number: i % 14 + 1))
        }
        try d.upsert(files)
        var loaded: [TrackRow] = []
        let t0 = Date()
        loaded = try d.trackRows()
        let read = Date().timeIntervalSince(t0)
        let t1 = Date()
        let sorted = TrackSort(column: .title).sorted(loaded)
        let sort = Date().timeIntervalSince(t1)
        XCTAssertEqual(sorted.count, 100_000)
        let t2 = Date()
        let found = TrackRow.visible(sorted, filter: LibraryFilter(scope: .official), ids: try d.fileIDs(matching: "song 99"))
        let search = Date().timeIntervalSince(t2)
        // At least "song 99", "song 990"…, "song 99999" (1 + 10 + 100 + 1000); artists and albums with 99… too.
        XCTAssertGreaterThanOrEqual(found.count, 1111)
        XCTAssertLessThan(found.count, 100_000)
        print("trackRows 100k: read \(read)s, sort \(sort)s, search \(search)s")
        XCTAssertLessThan(search, 1)
        XCTAssertLessThan(read, 3)   // generous: debug build, shared CI machines
        XCTAssertLessThan(sort, 3)
    }
}
