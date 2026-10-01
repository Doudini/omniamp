import XCTest
@testable import OmniAmp

/// The play history on this Mac: plays the scrobbler counts are kept without any service, stored once when last.fm
/// has them too, and cleared on their own.
@MainActor
final class PlayHistoryTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func track(_ path: String = "/m/Nirvana/Bleach/01 Blew.flac") -> Track {
        var t = Track(path: path, size: 1, mtime: 1)
        t.artist = "Nirvana"
        t.title = "Blew"
        t.album = "Bleach"
        return t
    }

    // MARK: Counting

    func testCountsWithoutAnyService() {
        var kept: [(Scrobble, String?)] = []
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let s = Scrobbler(services: [], history: { kept.append(($0, $1)) }, keepsHistory: { true })
        s.now = { clock }
        s.trackStarted(track(), duration: 180)   // counts after 90 s
        clock += 60
        s.thresholdReached()
        XCTAssertTrue(kept.isEmpty, "not listened to long enough yet")
        clock += 40
        s.thresholdReached()
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.0.title, "Blew")
        XCTAssertEqual(kept.first?.0.timestamp, 1_000_000, "the time it started, as last.fm gets it")
        XCTAssertEqual(kept.first?.1, "/m/Nirvana/Bleach/01 Blew.flac")
        s.thresholdReached()
        XCTAssertEqual(kept.count, 1, "counted once")
        s.trackStarted(nil, duration: 0)
    }

    func testNothingKeptWhenTurnedOffOrTooShort() {
        var kept = 0
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let off = Scrobbler(services: [], history: { _, _ in kept += 1 }, keepsHistory: { false })
        off.now = { clock }
        off.trackStarted(track(), duration: 180)
        clock += 200
        off.thresholdReached()
        XCTAssertEqual(kept, 0)

        let on = Scrobbler(services: [], history: { _, _ in kept += 1 }, keepsHistory: { true })
        on.now = { clock }
        on.trackStarted(track(), duration: 25)   // 30 s or less never counts
        clock += 100
        on.thresholdReached()
        XCTAssertEqual(kept, 0)
        // A stream's URL isn't kept as a file.
        var urls: [String?] = []
        let stream = Scrobbler(services: [], history: { urls.append($1) }, keepsHistory: { true })
        stream.now = { clock }
        stream.trackStarted(track("https://example.com/show.mp3"), duration: 180)
        clock += 100
        stream.thresholdReached()
        XCTAssertEqual(urls, [nil])
        for s in [off, on, stream] { s.trackStarted(nil, duration: 0) }
    }

    // MARK: Storing

    private func play(_ ts: Int, title: String = "Blew", artist: String = "Nirvana") -> Scrobble {
        Scrobble(artist: artist, title: title, album: "Bleach", duration: 180, timestamp: ts)
    }

    func testImportTakesOverOwnPlaysInsteadOfDoubling() throws {
        let d = try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite"))
        try d.addOwnPlay(play(1000), path: "/m/blew.flac")
        try d.addOwnPlay(play(2000, title: "Love Buzz"), path: "/m/love buzz.flac")
        XCTAssertEqual(try d.ownPlays().count, 2)
        XCTAssertEqual(try d.ownPlays().since, 1000)
        // An import starts from scratch: own plays aren't last.fm's history.
        XCTAssertEqual(try d.playRange().count, 0)
        // Last.fm has the first one (same start, its own spelling), and one OmniAmp didn't count.
        let added = try d.addPlays([LastFM.Play(ts: 1000, artist: "Nirvana", album: "Bleach", title: "Blew (Remastered)", artistMBID: nil),
                                    LastFM.Play(ts: 500, artist: "Nirvana", album: "Bleach", title: "School", artistMBID: nil)])
        XCTAssertEqual(added, 2)
        XCTAssertEqual(try d.playRange().count, 2, "last.fm's history: both its plays")
        XCTAssertEqual(try d.ownPlays().count, 2, "the taken-over play is still this Mac's too")
        XCTAssertEqual(try d.songPlays(artist: "nirvana", titleKey: Keys.title("Blew")).total, 1, "stored once")
        // Importing the same page again changes nothing.
        XCTAssertEqual(try d.addPlays([LastFM.Play(ts: 1000, artist: "Nirvana", album: "Bleach", title: "Blew (Remastered)", artistMBID: nil)]), 0)
    }

    func testClearingIsSeparate() throws {
        let d = try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite"))
        try d.addOwnPlay(play(1000), path: "/m/blew.flac")
        try d.addOwnPlay(play(2000, title: "Love Buzz"), path: "/m/love buzz.flac")
        // Last.fm has one of them, and one OmniAmp didn't count.
        try d.addPlays([LastFM.Play(ts: 500, artist: "Nirvana", album: "Bleach", title: "School", artistMBID: nil),
                        LastFM.Play(ts: 2000, artist: "Nirvana", album: "Bleach", title: "Love Buzz", artistMBID: nil)])
        // Another last.fm account: its history goes, this Mac's plays stay (the one last.fm had too as well).
        try d.forgetPlays()
        XCTAssertEqual(try d.playRange().count, 0)
        XCTAssertEqual(try d.ownPlays().count, 2)
        // Clear in Settings: this Mac's plays go; one last.fm has too stays, as last.fm's.
        try d.addPlays([LastFM.Play(ts: 500, artist: "Nirvana", album: "Bleach", title: "School", artistMBID: nil),
                        LastFM.Play(ts: 2000, artist: "Nirvana", album: "Bleach", title: "Love Buzz", artistMBID: nil)])
        try d.forgetOwnPlays()
        XCTAssertEqual(try d.ownPlays().count, 0)
        XCTAssertEqual(try d.playRange().count, 2)
        XCTAssertEqual(try d.songPlays(artist: "nirvana", titleKey: Keys.title("Blew")).total, 0)
    }

    func testCorrectedArtistIsStillTheSamePlay() throws {
        // Last.fm corrected the artist (another key): the start time alone finds OmniAmp's play.
        let d = try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite"))
        try d.addOwnPlay(play(3000, title: "Purple Rain", artist: "Prince & The Revolution"), path: "/m/purple rain.flac")
        XCTAssertEqual(try d.addPlays([LastFM.Play(ts: 3000, artist: "Prince", album: "Purple Rain", title: "Purple Rain", artistMBID: nil)]), 1)
        XCTAssertEqual(try d.songPlays(artist: "prince", titleKey: Keys.title("Purple Rain")).total, 1)
        XCTAssertEqual(try d.songPlays(artist: Keys.artist("Prince & The Revolution"), titleKey: Keys.title("Purple Rain")).total, 0)
        XCTAssertEqual(try d.ownPlays().count, 1)
    }

    func testPlayCountsBySong() throws {
        let d = try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite"))
        try d.addPlays([LastFM.Play(ts: 100, artist: "Nirvana", album: "Bleach", title: "Blew (Remastered)", artistMBID: nil),
                        LastFM.Play(ts: 300, artist: "Nirvana", album: "Bleach", title: "Blew", artistMBID: nil)])
        try d.addOwnPlay(play(500), path: "/m/blew.flac")
        try d.addOwnPlay(play(200, title: "School"), path: nil)
        let c = try d.playCounts()
        // Every spelling and source of one song together, keyed like the Tracks list (artist key + title key).
        let blew = try XCTUnwrap(c["nirvana\u{1}" + Keys.title("Blew")])
        XCTAssertEqual([blew.plays, blew.last], [3, 500])
        XCTAssertEqual(blew.byYear, [1970: 3], "plays per year (all in 1970 here)")
        XCTAssertEqual(c["nirvana\u{1}" + Keys.title("School")]?.plays, 1)
        XCTAssertEqual(c.count, 2)
    }

    func testListeningStatsIncludeOwnPlays() throws {
        let d = try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite"))
        try d.addOwnPlay(play(1_700_000_000), path: nil)
        try d.addOwnPlay(play(1_700_000_300, title: "Love Buzz"), path: nil)
        try d.addOwnPlay(play(1_700_000_600, title: "Wish", artist: "The Cure"), path: nil)
        let s = try XCTUnwrap(try d.listeningStats())
        XCTAssertEqual(s.plays, 3)
        XCTAssertEqual(s.artists, 2)
    }
}
