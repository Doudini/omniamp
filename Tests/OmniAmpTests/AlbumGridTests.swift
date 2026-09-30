import XCTest
@testable import OmniAmp

final class AlbumGridTests: XCTestCase {
    private func album(_ artist: String, _ title: String, year: Int?, kind: ReleaseKind = .album, date: String? = nil,
                       added: Double = 0) -> LibraryAlbum {
        LibraryAlbum(key: artist + "|" + title, artistKey: Keys.artist(artist), artist: artist, title: title, year: year, kind: kind,
                     folder: "/m/\(artist)/\(title)", tracks: 10, duration: 2400, firstPath: "/m/\(artist)/\(title)/01.flac",
                     lossless: false, added: added, showDate: date, venue: nil)
    }

    private lazy var albums = [
        album("The Cure", "Disintegration", year: 1989),
        album("Björk", "Homogenic", year: 1997),
        album("The Cure", "1992-05-01 Paris", year: 1992, kind: .show, date: "1992-05-01"),
        album("The Cure", "Pornography", year: 1982),
        album("Beirut", "Gulag Orkestar", year: nil),
        album("Björk", "Debut", year: 1993),
    ]

    private func titles(_ s: [AlbumGrid.Section]) -> [String] { s.map { "\($0.title): " + $0.albums.map(\.title).joined(separator: ", ") } }

    func testByArtist() {
        // "The Cure" under C; each artist's official releases by year, then the shows by date.
        XCTAssertEqual(titles(AlbumGrid.sections(albums, by: .artist)), [
            "Beirut: Gulag Orkestar",
            "Björk: Debut, Homogenic",
            "The Cure: Pornography, Disintegration, 1992-05-01 Paris",
        ])
    }

    func testByYearAndDecade() {
        XCTAssertEqual(AlbumGrid.sections(albums, by: .year).map(\.title), ["1997", "1993", "1992", "1989", "1982", "Unknown year"])
        XCTAssertEqual(titles(AlbumGrid.sections(albums, by: .decade)), [
            "1990s: Homogenic, Debut, 1992-05-01 Paris",
            "1980s: Disintegration, Pornography",
            "Unknown year: Gulag Orkestar",
        ])
    }

    func testByKindAndNone() {
        let kinds = AlbumGrid.sections(albums, by: .kind)
        XCTAssertEqual(kinds.map(\.title), [ReleaseKind.album.title, ReleaseKind.show.title])
        XCTAssertEqual(kinds.map(\.kind), [.album, .show])
        XCTAssertEqual(AlbumGrid.sections(albums, by: .none).map(\.title), [""])
        XCTAssertEqual(AlbumGrid.sections([], by: .none), [])
    }

    func testByAddedNewestFirst() {
        let s = AlbumGrid.sections([album("A", "old", year: 1, added: 1_600_000_000), album("B", "new", year: 1, added: 1_750_000_000)], by: .added)
        XCTAssertEqual(s.map { $0.albums.map(\.title) }, [["new"], ["old"]])
    }

    func testMoves() {
        typealias P = AlbumGrid.Position
        let counts = [5, 2, 7], cols = 3
        func go(_ s: Int, _ i: Int, _ d: AlbumGrid.Direction) -> [Int]? {
            AlbumGrid.move(P(section: s, index: i), d, counts: counts, columns: cols).map { [$0.section, $0.index] }
        }
        XCTAssertEqual(go(0, 1, .down), [0, 4])
        XCTAssertEqual(go(0, 2, .down), [0, 4])      // a shorter last row below: its last album
        XCTAssertEqual(go(0, 4, .down), [1, 1])      // next section, same column
        XCTAssertEqual(go(1, 1, .down), [2, 1])
        XCTAssertEqual(go(2, 0, .up), [1, 0])
        XCTAssertEqual(go(1, 0, .up), [0, 3])        // the last row above, same column
        XCTAssertEqual(go(1, 0, .left), [0, 4])
        XCTAssertEqual(go(0, 4, .right), [1, 0])
        XCTAssertNil(go(0, 0, .left))
        XCTAssertNil(go(2, 6, .down))
        XCTAssertNil(go(0, 0, .up))
    }

    func testPanelGoesUnderTheRow() {
        XCTAssertEqual(AlbumGrid.panelSlot(index: 0, count: 7, columns: 3), 3)
        XCTAssertEqual(AlbumGrid.panelSlot(index: 5, count: 7, columns: 3), 6)
        XCTAssertEqual(AlbumGrid.panelSlot(index: 6, count: 7, columns: 3), 7)   // the last, short row
        XCTAssertEqual(AlbumGrid.panelSlot(index: 1, count: 2, columns: 4), 2)
    }
}
