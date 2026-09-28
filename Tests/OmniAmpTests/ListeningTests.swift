import XCTest
@testable import OmniAmp

private struct CannedLastFM: HTTPTransport {
    let body: String
    func send(_ req: URLRequest) async throws -> (Data, Int) {
        let url = req.url!.absoluteString
        XCTAssertTrue(url.contains("method=user.getRecentTracks"))
        XCTAssertFalse(url.contains("api_sig"), "reading history needs no signature")
        return (Data(body.utf8), 200)
    }
}

final class ListeningTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-listening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func db() throws -> CollectionDB { try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite")) }

    func testRecentTracksParsing() async throws {
        let lf = LastFM(apiKey: "k", secret: "s")
        lf.transport = CannedLastFM(body: """
            {"recenttracks":{"@attr":{"totalPages":"3","total":"5","page":"1"},"track":[
              {"@attr":{"nowplaying":"true"},"artist":{"#text":"Björk","mbid":""},"name":"Hunter","album":{"#text":"Homogenic"}},
              {"artist":{"#text":"Björk","mbid":"87c5dedd"},"name":"Jóga","album":{"#text":"Homogenic"},"date":{"uts":"1000"}},
              {"artist":{"#text":"Nirvana","mbid":""},"name":"Polly","album":{"#text":""},"date":{"uts":"900"}}]}}
            """)
        let r = try await lf.recentTracks(user: "someone")
        XCTAssertEqual(r.pages, 3)
        XCTAssertEqual(r.total, 5)
        XCTAssertEqual(r.tracks, [LastFM.Play(ts: 1000, artist: "Björk", album: "Homogenic", title: "Jóga", artistMBID: "87c5dedd"),
                                  LastFM.Play(ts: 900, artist: "Nirvana", album: "", title: "Polly", artistMBID: nil)],
                       "the track playing now has no date and is left out")
        // A single track comes as an object, not an array.
        lf.transport = CannedLastFM(body: """
            {"recenttracks":{"@attr":{"totalPages":"1","total":"1"},"track":{"artist":{"#text":"A"},"name":"B","album":{"#text":"C"},
             "date":{"uts":"5"}}}}
            """)
        let one = try await lf.recentTracks(user: "someone")
        XCTAssertEqual(one.tracks.map(\.title), ["B"])
    }

    func testPlaysPlacesAndFigures() throws {
        let d = try db()
        let plays = (0..<10).map { LastFM.Play(ts: 1_600_000_000 + $0 * 3600, artist: $0 < 7 ? "The Beatles" : "Björk", album: "",
                                              title: "Song \($0)", artistMBID: nil) }
        XCTAssertEqual(try d.addPlays(plays), 10)
        XCTAssertEqual(try d.addPlays(plays), 0, "the same plays again are skipped")
        let range = try d.playRange()
        XCTAssertEqual(range.count, 10)
        XCTAssertEqual(range.oldest, 1_600_000_000)

        // Most played first; "The Beatles" folded to one artist.
        let pending = try d.pendingArtists(limit: 10)
        XCTAssertEqual(pending.map(\.key), ["beatles", "bjork"])
        try d.savePlace(pending[0], mbid: "b1", country: "GB", found: true)
        try d.savePlace(pending[1], mbid: nil, country: nil, found: false)
        XCTAssertEqual(try d.pendingArtists(limit: 10).count, 0, "a miss isn't retried right away")
        XCTAssertEqual(try d.pendingArtists(limit: 10, retryAfter: -1).map(\.key), ["bjork"], "…but later")
        try d.savePlace(pending[1], mbid: nil, country: nil, found: false, retryInDays: 1)
        XCTAssertEqual(try d.pendingArtists(limit: 10, retryAfter: 90 * 86400 - 2 * 86400).map(\.key), ["bjork"],
                       "a failed lookup comes back after a day")

        d.saveArea("city", country: "US")
        d.saveArea("nowhere", country: nil)
        XCTAssertEqual(d.areaCountry("city"), .some("US"))
        XCTAssertEqual(d.areaCountry("nowhere"), .some(nil))
        XCTAssertNil(d.areaCountry("unknown") as String??)

        let s = try d.listeningStats()
        XCTAssertEqual(s.plays, 10)
        XCTAssertEqual(s.artists, 2)
        XCTAssertEqual(s.playsByCountry, ["GB": 7])
        XCTAssertEqual(s.mappedPlays, 7)
        XCTAssertEqual(s.topArtists.map(\.label), ["The Beatles", "Björk"])
        XCTAssertEqual(s.notOwned.count, 2, "nothing in the library yet")
        XCTAssertEqual(s.clock.flatMap { $0 }.reduce(0, +), 10)
        XCTAssertEqual(try d.artists(country: "GB", owned: false).map(\.value), [7])

        try d.forgetPlays()
        XCTAssertEqual(try d.playRange().count, 0)
    }

    func testWorldMap() {
        let map = WorldMap.shared
        XCTAssertGreaterThan(map.countries.count, 170)
        XCTAssertFalse(map.countries.contains { $0.iso == "AQ" })
        for iso in ["CH", "US", "GB", "FR", "NO", "IS", "JP", "BR"] { XCTAssertTrue(map.countries.contains { $0.iso == iso }, iso) }
        // Bern is inside Switzerland; Paris isn't.
        let ch = map.countries.first { $0.iso == "CH" }!
        XCTAssertTrue(ch.path.contains(WorldMap.project(lon: 7.45, lat: 46.95)))
        XCTAssertFalse(ch.path.contains(WorldMap.project(lon: 2.35, lat: 48.86)))
        // Equal Earth: the origin stays put, east is right, north is up.
        XCTAssertEqual(WorldMap.project(lon: 0, lat: 0), .zero)
        XCTAssertGreaterThan(WorldMap.project(lon: 90, lat: 0).x, 0)
        XCTAssertGreaterThan(WorldMap.project(lon: 0, lat: 45).y, 0)
        XCTAssertEqual(WorldMapView.step(0, max: 100), -1)
        XCTAssertEqual(WorldMapView.step(100, max: 100), 4)
        XCTAssertEqual(WorldMapView.step(1, max: 100_000), 0, "one play is still lit")
    }

    func testPeriodsRiverAndOnThisDay() throws {
        let d = try db()
        let c = Calendar.current
        func ts(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 12) -> Int {
            Int(c.date(from: DateComponents(year: y, month: m, day: day, hour: h))!.timeIntervalSince1970)
        }
        var plays: [LastFM.Play] = []
        for i in 0..<6 { plays.append(.init(ts: ts(2008, 3, 1 + i), artist: "Nirvana", album: "Bleach", title: "Swap Meet", artistMBID: nil)) }
        for i in 0..<3 { plays.append(.init(ts: ts(2008, 5, 1 + i), artist: "Björk", album: "Homogenic", title: "Jóga", artistMBID: nil)) }
        for i in 0..<4 { plays.append(.init(ts: ts(2019, 6, 1 + i), artist: "Björk", album: "Homogenic", title: "Hunter", artistMBID: nil)) }
        plays.append(.init(ts: ts(2019, 9, 28), artist: "Low", album: "", title: "Lullaby", artistMBID: nil))
        plays.append(.init(ts: ts(2019, 9, 28, 13), artist: "Low", album: "", title: "Lullaby", artistMBID: nil))
        plays.append(.init(ts: ts(2012, 9, 28), artist: "Nirvana", album: "", title: "Polly", artistMBID: nil))
        try d.addPlays(plays)

        // A year: 2008's top artists.
        let y2008 = try d.topArtists(from: ts(2008, 1, 1, 0), to: ts(2009, 1, 1, 0))
        XCTAssertEqual(y2008.map(\.label), ["Nirvana", "Björk"])
        XCTAssertEqual(y2008.map(\.value), [6, 3])
        XCTAssertEqual(try d.topArtists(from: nil, to: nil).prefix(2).map(\.value), [7, 7], "all time: Björk and Nirvana, 7 each")
        XCTAssertEqual(try d.playYears(), [2019, 2012, 2008])

        // River: the top 2 and everyone else, per year.
        let r = try d.river(top: 2)
        XCTAssertEqual(r.years, [2008, 2012, 2019])
        XCTAssertEqual(r.series.map(\.name), ["Björk", "Nirvana"])
        XCTAssertEqual(r.series[0].plays, [3, 0, 4])
        XCTAssertEqual(r.series[1].plays, [6, 1, 0])
        XCTAssertEqual(r.other, [0, 0, 2])

        // On this day: 28 September in other years.
        let o = try d.onThisDay(c.date(from: DateComponents(year: 2026, month: 9, day: 28))!)
        XCTAssertEqual(o.days.map(\.year), [2019, 2012])
        XCTAssertEqual(o.days.first?.artist, "Low")
        XCTAssertEqual(o.days.first?.plays, 2)
        XCTAssertEqual(o.days.first?.title, "Lullaby")
    }

    func testPlayCalendarFilledForOlderPlays() throws {
        let d = try db()
        // A play stored before the calendar columns existed: no year, date, weekday or hour.
        try d.db.run("INSERT INTO scrobbles(ts, artist, album, title, artist_key) VALUES (?, 'Low', '', 'Lullaby', 'low')", [1_200_000_000])
        XCTAssertEqual(try d.playYears(), [], "not in the calendar yet")
        let v1 = try d.listeningVersion()
        try d.fillPlayCalendar()
        let local = Calendar.current.component(.year, from: Date(timeIntervalSince1970: 1_200_000_000))
        XCTAssertEqual(try d.playYears(), [local])
        try d.addPlays([LastFM.Play(ts: 1_300_000_000, artist: "Low", album: "", title: "Words", artistMBID: nil)])
        XCTAssertNotEqual(try d.listeningVersion(), v1, "new plays: the page's figures are computed again")
        XCTAssertEqual(try d.listeningStats().clock.flatMap { $0 }.reduce(0, +), 2)
    }
}
