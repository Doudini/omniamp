import XCTest
@testable import OmniAmp

final class LibrarySearchTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Queries

    func testWordsAndPhrases() {
        XCTAssertEqual(LibrarySearch.query("bjork hom"), #""bjork"* "hom"*"#)
        XCTAssertEqual(LibrarySearch.query(#"live "wild is the wind""#), #""live"* "wild is the wind""#)
        XCTAssertEqual(LibrarySearch.query(#"say "open"#), #""say"* "open""#)   // a quote left open runs to the end
        XCTAssertEqual(LibrarySearch.query("   "), #""""#)
        XCTAssertEqual(LibrarySearch.query("AND OR NOT *"), #""AND"* "OR"* "NOT"* "*"*"#)   // no operators from the user
    }

    func testDates() {
        XCTAssertEqual(LibrarySearch.dates("1977-05-08"), ["1977 05 08"])
        XCTAssertEqual(LibrarySearch.dates("2003.09.07"), ["2003 09 07"])
        XCTAssertEqual(LibrarySearch.dates("gd77-05-08"), ["1977 05 08"])
        XCTAssertEqual(LibrarySearch.dates("05-08-07"), ["2005 08 07", "2007 05 08", "2007 08 05"])   // etree's reading first
        XCTAssertEqual(LibrarySearch.dates("02-14-94"), ["1994 02 14"])                    // only one reading fits
        XCTAssertEqual(LibrarySearch.dates("14.02.1994"), ["1994 02 14"])
        XCTAssertEqual(LibrarySearch.dates("5/8/1977"), ["1977 08 05", "1977 05 08"])      // day first, then month first
        XCTAssertEqual(LibrarySearch.dates("1977"), [])
        XCTAssertEqual(LibrarySearch.dates("1977-13-40"), [])
        XCTAssertEqual(LibrarySearch.query("1977-05-08"), #"("1977 05 08" OR "1977-05-08"*)"#)
    }

    func testDistance() {
        XCTAssertEqual(LibrarySearch.distance("nirvna", "nirvana"), 1)
        XCTAssertEqual(LibrarySearch.distance("portihsead", "portishead"), 1)   // two letters swapped
        XCTAssertEqual(LibrarySearch.distance("bjrok", "bjork"), 1)
        XCTAssertEqual(LibrarySearch.distance("cat", "dog"), 3)
        XCTAssertEqual(LibrarySearch.folded("Björk"), "bjork")
    }

    // MARK: In a library

    private func row(_ i: Int, artist: String, album: String, title: String, folder: String, date: String? = nil, venue: String? = nil,
                     kind: ReleaseKind = .album, genre: String? = nil, number: Int? = nil) -> LibraryFile {
        var info = TagInfo()
        info.genre = genre
        info.trackNumber = number
        info.duration = 200
        let path = "/m/\(folder)/\(i).flac"
        return LibraryFile(key: path, path: path, root: "/m", size: 1, mtime: 1, cueStart: nil, cueEnd: nil, cueNumber: nil, info: info,
                           result: .init(kind: kind, artist: artist, album: album, year: date.flatMap { Int($0.prefix(4)) }, showDate: date,
                                         venue: venue, albumFolder: "/m/\(folder)"),
                           title: title)
    }

    private func library(_ name: String = "lib.sqlite") throws -> CollectionDB {
        let d = try CollectionDB(url: tmp.appendingPathComponent(name))
        try d.upsert([
            row(1, artist: "Brant Bjork", album: "Live", title: "Lazy Bones", folder: "Brant Bjork/brant bjork and the bros - 2003.09.07 - san francisco, ca"),
            row(2, artist: "Grateful Dead", album: "1977-05-08 Barton Hall", title: "Scarlet Begonias", folder: "Grateful Dead/gd77-05-08",
                date: "1977-05-08", venue: "Barton Hall", kind: .show),
            row(3, artist: "Nirvana", album: "Bleach", title: "Blew", folder: "Nirvana/Bleach", genre: "Grunge"),
            row(4, artist: "Björk", album: "Homogenic", title: "Jóga", folder: "Björk/Homogenic", genre: "Electronic"),
        ])
        return d
    }

    private func titles(_ d: CollectionDB, _ q: String) throws -> [String] {
        try d.albums(matching: q, LibraryFilter()).map(\.title).sorted()
    }

    func testFoldersGenresAndDates() throws {
        let d = try library()
        XCTAssertEqual(try titles(d, "san francisco"), ["Live"])          // only the folder says so
        XCTAssertEqual(try titles(d, "grunge"), ["Bleach"])
        XCTAssertEqual(try titles(d, "barton"), ["1977-05-08 Barton Hall"])
        for q in ["1977-05-08", "77-05-08", "8.5.1977", "5/8/77", "gd77-05-08", "2003-09-07", "07.09.2003"] {
            XCTAssertEqual(try titles(d, q).count, 1, q)
        }
        XCTAssertEqual(try titles(d, "1978-05-08"), [])
        XCTAssertEqual(try titles(d, #""scarlet begonias""#), ["1977-05-08 Barton Hall"])
        XCTAssertEqual(try titles(d, #""begonias scarlet""#), [])          // a phrase keeps its order
        XCTAssertEqual(try titles(d, "joga"), ["Homogenic"])
    }

    func testDidYouMean() throws {
        let d = try library()
        XCTAssertEqual(try d.suggestion(for: "nirvna"), "nirvana")
        XCTAssertEqual(try d.suggestion(for: "grateful daed"), "grateful dead")   // only the word that finds nothing
        XCTAssertNil(try d.suggestion(for: "nirv"))                                // the start of a word: it's found
        XCTAssertNil(try d.suggestion(for: "zzzzzz"))
        XCTAssertNil(try d.suggestion(for: #""nirvna""#))
    }

    /// Search results inside an album keep the album's order: a bonus file without a number stays last, though on
    /// their own the hits ("2" and the bonus) would read as a gap it fills.
    func testHitsKeepTheAlbumsOrder() throws {
        let d = try library()
        try d.upsert([row(11, artist: "Mazzy Star", album: "Metro", title: "Fade Into You", folder: "Mazzy Star/Metro", number: 1),
                      row(12, artist: "Mazzy Star", album: "Metro", title: "Ride It On", folder: "Mazzy Star/Metro", number: 2),
                      row(13, artist: "Mazzy Star", album: "Metro", title: "Into Dust", folder: "Mazzy Star/Metro", number: 3),
                      row(14, artist: "Mazzy Star", album: "Metro", title: "Ride Bonus", folder: "Mazzy Star/Metro")])
        let album = try XCTUnwrap(d.albums(matching: "metro", LibraryFilter()).first)
        XCTAssertEqual(try d.tracks(album: album.key).map(\.title), ["Fade Into You", "Ride It On", "Into Dust", "Ride Bonus"])
        XCTAssertEqual(try d.tracks(album: album.key, matching: "ride").map(\.title), ["Ride It On", "Ride Bonus"])
    }

    /// A connection opened before the index was built (another one was building it) finds it afterwards, instead of
    /// searching without it for the rest of the run.
    func testLateIndexIsFound() throws {
        _ = try library("early.sqlite")
        let copy = tmp.appendingPathComponent("late.sqlite")
        try FileManager.default.copyItem(at: tmp.appendingPathComponent("early.sqlite"), to: copy)
        let raw = try SQLiteDB(path: copy.path, readOnly: false)
        try raw.exec("DROP TRIGGER files_ai; DROP TRIGGER files_ad; DROP TRIGGER files_au; DROP TABLE search_terms; DROP TABLE search; DELETE FROM meta WHERE key = 'search';")
        let early = try CollectionDB(url: copy, readOnly: true)
        XCTAssertFalse(early.hasFTS)
        _ = try CollectionDB(url: copy)   // builds it
        XCTAssertTrue(early.hasFTS)
        XCTAssertEqual(try early.albums(matching: "san francisco", LibraryFilter()).map(\.title), ["Live"])
    }

    /// A library from before: its old index gives way to the new one, built from what's stored (nothing read).
    func testOldIndexIsReplaced() throws {
        _ = try library("old.sqlite")
        let copy = tmp.appendingPathComponent("upgraded.sqlite")
        try FileManager.default.copyItem(at: tmp.appendingPathComponent("old.sqlite"), to: copy)
        let raw = try SQLiteDB(path: copy.path, readOnly: false)
        try raw.exec("""
            DROP TRIGGER files_ai; DROP TRIGGER files_ad; DROP TRIGGER files_au; DROP TABLE search_terms; DROP TABLE search;
            CREATE VIRTUAL TABLE fts USING fts5(title, artist, album, venue, content='files', content_rowid='id');
            DELETE FROM meta WHERE key = 'search';
            """)
        let d = try CollectionDB(url: copy)
        XCTAssertTrue(d.hasFTS)
        XCTAssertEqual(try titles(d, "san francisco"), ["Live"])
        XCTAssertEqual(try d.db.scalar("SELECT count(*) FROM sqlite_master WHERE name = 'fts'"), 0)
        // Kept in step from then on.
        try d.upsert([row(5, artist: "Portishead", album: "Roseland", title: "Glory Box", folder: "Portishead/Roseland NYC")])
        XCTAssertEqual(try titles(d, "roseland"), ["Roseland"])
    }
}
