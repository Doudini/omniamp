import XCTest
@testable import OmniAmp

final class CollectionDBTests: XCTestCase {
    private var tmp: URL!
    private var music: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-collection-\(UUID().uuidString)")
        music = tmp.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func db() throws -> CollectionDB { try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite")) }

    @discardableResult
    private func file(_ rel: String, bytes: Int = 10) throws -> URL {
        let url = music.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: url)
        return url
    }

    private func scan(_ scanner: CollectionScanner, _ scopes: [String]? = nil) {
        let done = expectation(description: "scan")
        scanner.scan(scopes ?? [music.path], roots: [music.path]) { done.fulfill() }
        wait(for: [done], timeout: 20)
    }

    // MARK: Scanning

    func testScanBuildsArtistsAlbumsAndShows() throws {
        try file("Grateful Dead/American Beauty/01 Box of Rain.flac")
        try file("Grateful Dead/American Beauty/02 Friend of the Devil.flac")
        try file("Grateful Dead/gd1977-05-08.sbd.miller/d1t01.flac")
        try file("Grateful Dead/Bootlegs/1972-05-04 Olympia Theatre, Paris/01.flac")
        try file("Pixies - Doolittle (1989)/01 Debaser.mp3")
        let writer = try db()
        let scanner = CollectionScanner(db: writer)
        scan(scanner)
        let reader = try db()
        XCTAssertEqual(try reader.summary().tracks, 5)
        let artists = try reader.artists(LibraryFilter())
        XCTAssertEqual(artists.map(\.name), ["Grateful Dead", "Pixies"])
        XCTAssertEqual(artists.map(\.letter), ["G", "P"])

        let dead = try reader.albums(artist: Keys.artist("Grateful Dead"), LibraryFilter())
        XCTAssertEqual(dead.map(\.kind), [.album, .show, .show])
        XCTAssertEqual(dead.first?.tracks, 2)
        XCTAssertEqual(dead.filter { $0.kind == .show }.compactMap(\.showDate), ["1972-05-04", "1977-05-08"])
        XCTAssertEqual(dead.first { $0.showDate == "1972-05-04" }?.venue, "Olympia Theatre, Paris")

        XCTAssertEqual(try reader.albums(artist: Keys.artist("Grateful Dead"), LibraryFilter(scope: .official)).count, 1)
        XCTAssertEqual(try reader.albums(artist: Keys.artist("Grateful Dead"), LibraryFilter(scope: .unofficial)).count, 2)
        XCTAssertEqual(try reader.artists(LibraryFilter(scope: .unofficial)).map(\.name), ["Grateful Dead"])
        XCTAssertEqual(try reader.artists(LibraryFilter(losslessOnly: true)).map(\.name), ["Grateful Dead"])
        XCTAssertEqual(try reader.years(LibraryFilter()).map(\.title), ["1989", "1977", "1972", "Unknown"])

        let tracks = try reader.tracks(album: dead[0].key)
        XCTAssertEqual(tracks.map(\.title), ["Box of Rain", "Friend of the Devil"])   // no tags: from the file names
        XCTAssertEqual(tracks.map(\.number), [1, 2])
    }

    func testRescanReadsOnlyChangesAndRemovesDeleted() throws {
        let a = try file("Artist/Album/01.flac")
        try file("Artist/Album/02.flac")
        try file("Artist/Other/01.flac")
        let writer = try db()
        let scanner = CollectionScanner(db: writer)
        scan(scanner)
        XCTAssertEqual(scanner.current.toRead, 3)

        scan(scanner)
        XCTAssertEqual(scanner.current.toRead, 0, "unchanged files aren't read again")

        try Data(repeating: 1, count: 20).write(to: a)
        try FileManager.default.removeItem(at: music.appendingPathComponent("Artist/Other"))
        scan(scanner)
        XCTAssertEqual(scanner.current.toRead, 1)
        XCTAssertEqual(scanner.current.removed, 1)
        let reader = try db()
        XCTAssertEqual(try reader.summary(), CollectionDB.Summary(tracks: 2, albums: 1, artists: 1, duration: 0))

        // A deleted folder, rescanned by itself (as an FSEvents event would).
        try FileManager.default.removeItem(at: music.appendingPathComponent("Artist/Album"))
        scan(scanner, [music.appendingPathComponent("Artist/Album").path])
        XCTAssertEqual(try reader.summary().tracks, 0)
        XCTAssertEqual(try reader.artists(LibraryFilter()), [])
    }

    func testUnplayableListedAndHiddenOnceConverted() throws {
        try file("Shannon Wright/shannon wright - 30.04.04 - paris/shannon wright - 01 - plea.wma")
        try file("Shannon Wright/shannon wright - 30.04.04 - paris/shannon wright - 02 - portray.wma")
        let scanner = CollectionScanner(db: try db())
        scan(scanner)
        let reader = try db()
        let album = try reader.albums(artist: Keys.artist("Shannon Wright"), LibraryFilter())
        XCTAssertEqual(album.count, 1)
        XCTAssertEqual(album[0].kind, .show)
        XCTAssertEqual(album[0].unplayable, 2)
        XCTAssertEqual(album[0].unplayableFormat, "WMA")
        XCTAssertFalse(album[0].lossless)
        let tracks = try reader.tracks(album: album[0].key)
        XCTAssertEqual(tracks.map(\.title), ["plea", "portray"])
        XCTAssertEqual(tracks.map(\.playable), [false, false])

        // One converted: the FLAC shows, its WMA doesn't.
        try file("Shannon Wright/shannon wright - 30.04.04 - paris/shannon wright - 01 - plea.flac")
        scan(scanner)
        let after = try reader.albums(artist: Keys.artist("Shannon Wright"), LibraryFilter())[0]
        XCTAssertEqual(after.tracks, 2)
        XCTAssertEqual(after.unplayable, 1)
        XCTAssertEqual(try reader.tracks(album: after.key).map(\.format), ["FLAC", "WMA"])
    }

    func testUnavailableRootKeepsItsFiles() throws {
        try file("Artist/Album/01.flac")
        let writer = try db()
        let scanner = CollectionScanner(db: writer)
        scan(scanner)
        // The share went away and an empty folder is left at the mount point.
        try FileManager.default.removeItem(at: music.appendingPathComponent("Artist"))
        scan(scanner)
        XCTAssertEqual(try db().summary().tracks, 1)
        // Or it's gone entirely.
        try FileManager.default.removeItem(at: music)
        scan(scanner)
        XCTAssertEqual(try db().summary().tracks, 1)
    }

    func testForgetRoot() throws {
        try file("Artist/Album/01.flac")
        let writer = try db()
        let scanner = CollectionScanner(db: writer)
        scan(scanner)
        let done = expectation(description: "forget")
        scanner.onChange = { done.fulfill() }
        scanner.forget(root: music.path)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try db().summary().tracks, 0)
    }

    // MARK: Database

    private func row(_ i: Int, artist: String, album: String, title: String, kind: ReleaseKind = .album, genre: String? = nil,
                     year: Int? = 1990) -> LibraryFile {
        var info = TagInfo()
        info.genre = genre
        info.duration = 200
        let path = "/m/\(artist)/\(album)/\(i).flac"
        return LibraryFile(key: path, path: path, root: "/m", size: 1, mtime: 1, cueStart: nil, cueEnd: nil, cueNumber: nil, info: info,
                           result: .init(kind: kind, artist: artist, album: album, year: year, showDate: nil, venue: nil,
                                         albumFolder: "/m/\(artist)/\(album)"),
                           title: title)
    }

    func testGenresAndSearch() throws {
        let d = try db()
        try d.upsert([row(1, artist: "Björk", album: "Homogenic", title: "Jóga", genre: "Electronic; Art Pop"),
                      row(2, artist: "Björk", album: "Homogenic", title: "Hunter", genre: "electronic"),
                      row(3, artist: "Slowdive", album: "Souvlaki", title: "Alison", genre: "Shoegaze/Dream Pop")])
        XCTAssertEqual(try d.genres(LibraryFilter()).map(\.title).sorted(), ["Art Pop", "Dream Pop", "Electronic", "Shoegaze"])
        XCTAssertEqual(try d.albums(genre: "electronic", LibraryFilter()).map(\.title), ["Homogenic"])
        XCTAssertEqual(try d.artists(matching: "bjork", LibraryFilter()).map(\.name), ["Björk"])   // accents folded
        XCTAssertEqual(try d.artists(matching: "joga", LibraryFilter()).map(\.name), ["Björk"])
        XCTAssertEqual(try d.albums(matching: "souv", LibraryFilter()).map(\.title), ["Souvlaki"])   // prefix
        XCTAssertEqual(try d.albums(matching: "bjork hunt", LibraryFilter()).map(\.title), ["Homogenic"])
        XCTAssertEqual(try d.albums(matching: "bjork alison", LibraryFilter()), [])
        let album = try d.albums(artist: Keys.artist("Björk"), LibraryFilter())[0]
        XCTAssertEqual(try d.tracks(album: album.key, matching: "hunter").map(\.title), ["Hunter"])
        XCTAssertEqual(try d.albums(matching: "\"quoted OR", LibraryFilter()), [])   // no FTS syntax errors
    }

    func testAttention() throws {
        let d = try db()
        try d.upsert([row(1, artist: "Nirvana", album: "Bleach", title: "Blew", genre: "Grunge"),
                      row(2, artist: "NIRVANA", album: "Bleach", title: "School", genre: "Grunge"),
                      row(3, artist: "Slowdive", album: "Souvlaki", title: "Alison", genre: "Shoegaze", year: nil),
                      row(4, artist: "Slowdive", album: "1992-05-01 Paris", title: "Alison", kind: .show, genre: "Shoegaze", year: nil)])
        let a = try d.attention()
        let groups = Dictionary(uniqueKeysWithValues: a.groups.map { ($0.id, $0) })
        // No year: only the official album; a show without a year is normal.
        XCTAssertEqual(groups["year"]?.entries.map(\.title), ["Slowdive — Souvlaki"])
        XCTAssertNil(groups["genre"])
        XCTAssertEqual(groups["spelling"]?.total, 1)
        XCTAssertEqual(groups["spelling"]?.entries.first?.fix, .artist(Keys.artist("Nirvana")))
        XCTAssertEqual(groups["dupes"]?.entries.first?.lead, "×2")
        XCTAssertEqual(a.total, a.groups.reduce(0) { $0 + $1.total })
    }

    func testReleasesSharingAFolder() throws {
        let d = try db()
        var a = row(1, artist: "Scout Niblett", album: "Calcination", title: "a"), b = row(2, artist: "Scout Niblett", album: "Emma", title: "b")
        // Loose files in one folder, told apart by their tags.
        for i in [0, 1] {
            var r = i == 0 ? a : b
            r.result = .init(kind: .album, artist: "Scout Niblett", album: i == 0 ? "Calcination" : "Emma", year: 2010, showDate: nil, venue: nil,
                             albumFolder: "/m/scout niblett")
            if i == 0 { a = r } else { b = r }
        }
        try d.upsert([a, b, row(3, artist: "Scout Niblett", album: "I Am", title: "c")])
        let shared = try d.albums(artist: Keys.artist("Scout Niblett"), LibraryFilter()).map { ($0.title, $0.sharedFolder) }
        XCTAssertEqual(shared.sorted { $0.0 < $1.0 }.map(\.1), [true, true, false])   // Calcination, Emma, I Am
        let group = try d.attention().groups.first { $0.id == "folders" }
        XCTAssertEqual(group?.total, 1)
        XCTAssertEqual(group?.entries.first?.lead, "×2")
        XCTAssertEqual(group?.entries.first?.title, "scout niblett")
    }

    /// A track in a folder, with its own artist and no album-artist tag.
    private func track(_ i: Int, _ artist: String, album: String, folder: String) -> LibraryFile {
        var r = row(i, artist: artist, album: album, title: "t\(i)")
        r.key = "\(folder)/\(i).flac"
        r.path = r.key
        r.result = .init(kind: .album, artist: artist, album: album, year: 2020, showDate: nil, venue: nil, albumFolder: folder)
        return r
    }

    func testVariousArtistsCompilationIsOneRelease() throws {
        let d = try db()
        let artists = ["Frightened Rabbit", "Biffy Clyro", "Manchester Orchestra", "Julien Baker", "Craig Finn"]
        try d.upsert(artists.enumerated().map { track($0 + 1, $1, album: "Tiny Changes", folder: "/m/Tiny Changes") })
        let va = try d.albums(artist: Keys.artist("Various Artists"), LibraryFilter())
        XCTAssertEqual(va.map(\.title), ["Tiny Changes"])
        XCTAssertEqual(va.first?.tracks, 5)
        XCTAssertEqual(va.first?.kind, .compilation)
        XCTAssertEqual(try d.tracks(album: va[0].key).map(\.artist).sorted(), artists.sorted(), "each track keeps its artist")
        XCTAssertTrue(try d.albums(artist: Keys.artist("Biffy Clyro"), LibraryFilter()).isEmpty)
        // A track read again (its own artist) goes back into the compilation.
        try d.upsert([track(3, "Manchester Orchestra", album: "Tiny Changes", folder: "/m/Tiny Changes")])
        XCTAssertEqual(try d.albums(artist: Keys.artist("Various Artists"), LibraryFilter()).first?.tracks, 5)

        // A band's album with one "feat." track stays the band's.
        try d.upsert((1...10).map { track(100 + $0, "Wye Oak", album: "Shriek", folder: "/m/Shriek") }
                     + [track(111, "Wye Oak feat. Someone", album: "Shriek", folder: "/m/Shriek")])
        XCTAssertEqual(try d.albums(artist: Keys.artist("Wye Oak"), LibraryFilter()).first?.tracks, 10)
        XCTAssertEqual(try d.albums(artist: Keys.artist("Various Artists"), LibraryFilter()).count, 1)

        // Tagged with its album artist: "Foo feat. X" tracks on Foo's album stay Foo's, however many guests.
        let guests = ["Foo", "Foo feat. A", "Foo feat. B", "Foo feat. C", "Foo feat. D"]
        try d.upsert(guests.enumerated().map { i, performer in
            var t = track(200 + i, "Foo", album: "Rap Album", folder: "/m/Rap Album")   // release artist: the album-artist tag
            t.info.artist = performer
            return t
        })
        XCTAssertEqual(try d.albums(artist: Keys.artist("Foo"), LibraryFilter()).first?.tracks, 5)
        XCTAssertEqual(try d.albums(artist: Keys.artist("Various Artists"), LibraryFilter()).count, 1)
    }

    /// /m/A added first, then /m (which replaced it), then /m removed: /m/A's files go too.
    func testRemovingAParentRootRemovesFilesReadUnderAChild() throws {
        let d = try db()
        var child = row(1, artist: "A", album: "X", title: "t")
        child.root = "/m/A"
        try d.upsert([child, row(2, artist: "B", album: "Y", title: "u")])
        try d.removeRoot("/m")
        XCTAssertEqual(try d.summary().tracks, 0)
    }

    func testRetagMovesTrackBetweenAlbums() throws {
        let d = try db()
        try d.upsert([row(1, artist: "A", album: "X", title: "t")])
        var moved = row(1, artist: "B", album: "Y", title: "t")
        moved.key = "/m/A/X/1.flac"
        try d.upsert([moved])
        XCTAssertEqual(try d.artists(LibraryFilter()).map(\.name), ["B"])
        XCTAssertEqual(try d.summary().albums, 1)
    }

    func testFormats() {
        XCTAssertEqual(CollectionDB.format("/a.flac", bitDepth: 24, rate: 96000, kbps: 3000), "FLAC 24/96")
        XCTAssertEqual(CollectionDB.format("/a.flac", bitDepth: 16, rate: 44100, kbps: 900), "FLAC 16/44.1")
        XCTAssertEqual(CollectionDB.format("/a.mp3", bitDepth: nil, rate: 44100, kbps: 320), "MP3 320")
        XCTAssertEqual(CollectionDB.format("/a.m4a", bitDepth: nil, rate: 44100, kbps: 256), "AAC 256")
        XCTAssertEqual(CollectionDB.genres("Rock; rock/Pop ,  "), ["Rock", "Pop"])
    }

    func testStats() throws {
        let d = try db()
        var rows: [LibraryFile] = []
        // Two albums and three shows of one band; "Dark Star" on all five; one placeholder title everywhere.
        for (n, (album, kind, year)) in [("Aoxomoxoa", ReleaseKind.album, 1969), ("Live/Dead", .live, 1969),
                                         ("1972-05-04 Paris", .show, 1972), ("1977-05-08 Ithaca", .show, 1977),
                                         ("1977-05-09 Buffalo", .show, 1977)].enumerated() {
            rows.append(row(n * 10, artist: "Grateful Dead", album: album, title: n % 2 == 0 ? "Dark Star" : "Dark Star (Live)",
                            kind: kind, genre: "Rock", year: year))
            rows.append(row(n * 10 + 1, artist: "Grateful Dead", album: album, title: "Track 01", kind: kind, genre: "Rock", year: year))
        }
        rows.append(row(99, artist: "Björk", album: "Homogenic", title: "Jóga", genre: "Electronic", year: 1997))
        for i in rows.indices where rows[i].result.kind == .show {
            rows[i].result.showDate = String(rows[i].result.album.prefix(10))
        }
        try d.upsert(rows)
        let s = try d.stats(LibraryFilter())
        XCTAssertEqual(s.tracks, 11)
        XCTAssertEqual(s.releases, 6)
        XCTAssertEqual(s.artists, 2)
        XCTAssertEqual(s.shows, 3)
        XCTAssertEqual(s.losslessTracks, 11)
        XCTAssertEqual(s.kinds.map(\.label), ["Albums", "Live Albums", "Shows & Bootlegs"])
        XCTAssertEqual(s.kinds.map(\.value), [2, 1, 3])
        XCTAssertEqual(s.genres.map(\.label), ["Rock", "Electronic"])
        XCTAssertEqual(s.years.map(\.year), [1969, 1972, 1977, 1997])
        XCTAssertEqual(s.showMonths, ["1972-05": 1, "1977-05": 2])
        XCTAssertEqual(s.formats.map(\.label), ["FLAC"])
        XCTAssertEqual(s.songs.map(\.title), ["Dark Star"], "versions folded; placeholder titles left out")
        XCTAssertEqual(s.songs.first?.versions, 5)
        XCTAssertEqual(s.songs.first?.unofficial, 3)
        XCTAssertEqual(s.topArtists.first?.label, "Grateful Dead")
        XCTAssertEqual(s.growth.last?.total, 11)
        // Filters apply.
        XCTAssertEqual(try d.stats(LibraryFilter(scope: .official)).tracks, 5)
        XCTAssertEqual(try d.stats(LibraryFilter(scope: .unofficial)).songs.first?.versions, 3)
    }

    func testFormatGroups() {
        XCTAssertEqual(CollectionDB.formatGroup(ext: "flac", bits: 24, rate: 96000, kbps: nil), "FLAC 24-bit")
        XCTAssertEqual(CollectionDB.formatGroup(ext: "flac", bits: 16, rate: 44100, kbps: nil), "FLAC 16-bit")
        XCTAssertEqual(CollectionDB.formatGroup(ext: "mp3", bits: nil, rate: nil, kbps: 320), "MP3 256–320")
        XCTAssertEqual(CollectionDB.formatGroup(ext: "mp3", bits: nil, rate: nil, kbps: 128), "MP3 under 160")
        XCTAssertEqual(CollectionDB.formatGroup(ext: "m4a", bits: nil, rate: nil, kbps: 256), "AAC")
        XCTAssertEqual(CollectionDB.formatGroup(ext: "wma", bits: nil, rate: nil, kbps: 128), "WMA")
        XCTAssertTrue(CollectionDB.isPlaceholderTitle("Track 03"))
        XCTAssertTrue(CollectionDB.isPlaceholderTitle("07"))
        XCTAssertFalse(CollectionDB.isPlaceholderTitle("Set Me Free"))
        XCTAssertFalse(CollectionDB.isPlaceholderTitle("Dark Star"))
    }

    /// A 100,000-track library: browsing queries stay interactive.
    func testQueriesAt100kTracks() throws {
        let d = try db()
        var rows: [LibraryFile] = []
        let genres = ["Rock", "Jazz", "Electronic", "Folk", "Hip-Hop", "Classical"]
        for i in 0..<100_000 {
            let artist = "Artist \(i / 100)", album = "Album \(i / 10)"
            rows.append(row(i, artist: artist, album: album, title: "Song \(i) word\(i % 997)",
                            kind: ReleaseKind(rawValue: (i / 10) % 6)!, genre: genres[i % genres.count], year: 1960 + (i / 10) % 60))
        }
        let t0 = Date()
        for start in stride(from: 0, to: rows.count, by: CollectionScanner.batchSize) {
            try d.upsert(Array(rows[start..<min(start + CollectionScanner.batchSize, rows.count)]))
        }
        NSLog("library: 100k rows written in %.1fs", Date().timeIntervalSince(t0))

        func timed<T>(_ name: String, _ f: () throws -> T) rethrows -> T {
            let t = Date()
            let r = try f()
            let ms = Date().timeIntervalSince(t) * 1000
            NSLog("library: %@ %.1f ms", name, ms)
            XCTAssertLessThan(ms, 150, name)   // debug build; release is several times faster
            return r
        }
        let artists = try timed("artists") { try d.artists(LibraryFilter()) }
        XCTAssertEqual(artists.count, 1000)
        _ = try timed("artists unofficial") { try d.artists(LibraryFilter(scope: .unofficial)) }
        _ = try timed("albums of artist") { try d.albums(artist: artists[500].key, LibraryFilter()) }
        _ = try timed("years") { try d.years(LibraryFilter()) }
        _ = try timed("albums of year") { try d.albums(year: 1999, LibraryFilter()) }
        _ = try timed("search") { try d.albums(matching: "word42", LibraryFilter()) }
        _ = try timed("search artists") { try d.artists(matching: "song 777", LibraryFilter()) }
        _ = try timed("months") { try d.addedMonths(LibraryFilter()) }
        _ = try timed("summary") { try d.summary() }
        let st = Date()
        let stats = try d.stats(LibraryFilter())
        NSLog("library: stats page %.1f ms", Date().timeIntervalSince(st) * 1000)
        XCTAssertEqual(stats.tracks, 100_000)
        // Genres join every file: the slowest; allowed a little more.
        let t = Date()
        XCTAssertEqual(try d.genres(LibraryFilter()).count, 6)
        NSLog("library: genres %.1f ms", Date().timeIntervalSince(t) * 1000)
    }
}
