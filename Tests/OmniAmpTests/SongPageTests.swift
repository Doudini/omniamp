import XCTest
@testable import OmniAmp

final class SongPageTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-song-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func file(_ n: Int, album: String, title: String, kind: ReleaseKind, year: Int?, show: String? = nil, date: String? = nil,
                      seconds: Double = 180) -> LibraryFile {
        var info = TagInfo()
        info.duration = seconds
        info.date = date
        let path = "/m/Nirvana/\(album)/\(n).flac"
        return LibraryFile(key: path, path: path, root: "/m", size: 1, mtime: 1, cueStart: nil, cueEnd: nil, cueNumber: nil, info: info,
                           result: .init(kind: kind, artist: "Nirvana", album: album, year: year, showDate: show, venue: show == nil ? nil : "Paradiso",
                                         albumFolder: "/m/Nirvana/\(album)"),
                           title: title)
    }

    func testVersionsInOrderWithPlays() throws {
        let d = try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite"))
        try d.upsert([
            file(1, album: "Unplugged in New York", title: "About a Girl (Live)", kind: .live, year: 1994, date: "1994-11-01"),
            file(2, album: "Bleach", title: "About a Girl", kind: .album, year: 1989),
            file(3, album: "1991-11-25 Paradiso", title: "About A Girl", kind: .show, year: 1991, show: "1991-11-25", seconds: 250),
            file(4, album: "Demos", title: "About a Girl [demo]", kind: .unreleased, year: nil),
            file(5, album: "Bleach", title: "Swap Meet", kind: .album, year: 1989),
        ])
        let v = try d.versions(artist: "nirvana", titleKey: Keys.title("About a Girl"))
        XCTAssertEqual(v.map(\.release), ["Bleach", "1991-11-25 Paradiso", "Unplugged in New York", "Demos"], "by date; undated last")
        XCTAssertEqual(v.map { VersionLane($0.kind) }, [.studio, .show, .live, .demo])
        XCTAssertEqual(v[1].label, "1991-11-25 Paradiso")
        XCTAssertEqual(v[0].label, "Bleach (1989)")
        XCTAssertEqual(v[1].when!, 1991 + (10 * 30.5 + 24) / 366, accuracy: 0.001)
        XCTAssertEqual(v[0].when, 1989.5)
        XCTAssertNil(v[3].when)
        XCTAssertEqual(SongPage.bestTitle(v), "About a Girl", "the studio spelling, no version note")

        try d.addPlays([
            LastFM.Play(ts: 1_200_000_000, artist: "Nirvana", album: "Bleach", title: "About a Girl", artistMBID: nil),
            LastFM.Play(ts: 1_300_000_000, artist: "Nirvana", album: "Bleach", title: "About A Girl", artistMBID: nil),
            LastFM.Play(ts: 1_400_000_000, artist: "Nirvana", album: "MTV Unplugged", title: "About a Girl (Live)", artistMBID: nil),
            LastFM.Play(ts: 1_500_000_000, artist: "Nirvana", album: "Bleach", title: "Swap Meet", artistMBID: nil),
        ])
        let p = try d.songPlays(artist: "nirvana", titleKey: Keys.title("About a Girl"))
        XCTAssertEqual(p.total, 3, "live and studio plays count; other songs don't")
        XCTAssertEqual(p.byAlbum[Keys.fold("Bleach")], 2)
        XCTAssertEqual(p.first, Date(timeIntervalSince1970: 1_200_000_000))
        XCTAssertEqual(p.byYear.map(\.releases).reduce(0, +), 3)
    }

    func testBestTitleWithoutStudioVersion() {
        func v(_ t: String, _ k: ReleaseKind) -> SongVersion {
            SongVersion(track: LibraryTrack(id: 0, key: t, path: "/x", size: 0, mtime: 0, cueStart: nil, cueEnd: nil, cueNumber: nil, title: t,
                                            artist: "A", album: "", albumKey: "", disc: nil, number: nil, duration: nil, format: ""),
                        kind: k, release: "", year: nil, showDate: nil, venue: nil, date: nil, artPath: "", folder: "")
        }
        XCTAssertEqual(SongPage.bestTitle([v("Dark Star (live)", .show), v("Dark Star", .show), v("Dark Star", .show)]), "Dark Star")
        XCTAssertEqual(SongPage.bestTitle([v("Song [demo]", .unreleased)]), "Song [demo]", "nothing plainer to choose")
    }

    func testArtistDashboard() throws {
        let d = try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite"))
        try d.upsert([
            file(1, album: "Bleach", title: "About a Girl", kind: .album, year: 1989),
            file(2, album: "Bleach", title: "Swap Meet", kind: .album, year: 1989),
            file(3, album: "1991-11-25 Paradiso", title: "About A Girl (Paris 4 mai 2002)", kind: .show, year: 1991, show: "1991-11-25"),
            file(4, album: "1993-12-13 Seattle", title: "About a Girl", kind: .show, year: 1993, show: "1993-12-13"),
        ])
        let jan2008 = 1_199_188_800   // 2008-01-01
        try d.addPlays([
            LastFM.Play(ts: jan2008, artist: "Nirvana", album: "Bleach", title: "About a Girl", artistMBID: nil),
            LastFM.Play(ts: jan2008 + 86400, artist: "Nirvana", album: "Bleach", title: "About A Girl", artistMBID: nil),
            LastFM.Play(ts: jan2008 + 70 * 86400, artist: "Nirvana", album: "Nevermind", title: "Lithium", artistMBID: nil),
        ])
        let a = try d.artistDashboard("nirvana")
        XCTAssertEqual(a.name, "Nirvana")
        XCTAssertEqual(a.releases.count, 3)
        XCTAssertEqual(a.ownedTracks, 4)
        XCTAssertEqual(a.plays, 3)
        XCTAssertEqual(a.firstPlay?.title, "About a Girl")
        XCTAssertEqual(a.months.map(\.plays), [2, 0, 1], "every month from first to last, empty ones too")
        XCTAssertEqual(a.topSongs.map(\.title), ["About a Girl", "Lithium"])
        XCTAssertEqual(a.topSongs.map(\.versions), [3, 0], "Lithium isn't in the library")
        XCTAssertEqual(a.mostRecorded.map(\.title), ["About a Girl"], "the plain spelling")
        XCTAssertEqual(a.playedAlbums.map(\.label), ["Bleach", "Nevermind"])
        XCTAssertEqual(a.playedAlbumKinds[Keys.fold("Bleach")], .album)
        XCTAssertEqual(a.showsPerYear.map(\.year), [1991, 1993])
    }
}
