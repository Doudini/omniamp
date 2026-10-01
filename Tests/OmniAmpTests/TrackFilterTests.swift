import XCTest
@testable import OmniAmp

final class TrackFilterTests: XCTestCase {
    /// 2026-10-01 noon, local time: every relative condition is worked out from here.
    private let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 1; c.hour = 12
        return Calendar.current.date(from: c)!
    }()
    private func ts(_ year: Int, _ month: Int = 6) -> Int {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = 15
        return Int(Calendar.current.date(from: c)!.timeIntervalSince1970)
    }

    private func row(_ id: Int64, artist: String = "Nirvana", album: String = "Bleach", title: String = "Blew", year: Int? = 1989,
                     genre: String = "Grunge", kind: ReleaseKind = .album, added: Double = 0, albumArtist: String? = nil) -> TrackRow {
        let t = LibraryTrack(id: id, key: "k\(id)", path: "/m/\(id).flac", size: 1, mtime: 1, cueStart: nil, cueEnd: nil, cueNumber: nil,
                             title: title, artist: artist, album: album, albumKey: Keys.artist(albumArtist ?? artist) + "\u{1}" + Keys.fold(album),
                             disc: nil, number: 1, duration: 200, format: "FLAC")
        var r = TrackRow(track: t, genre: genre, year: year, added: added, artistKey: Keys.artist(albumArtist ?? artist))
        r.kind = kind
        return r
    }

    private func titles(_ rows: [TrackRow], _ f: TrackFilter, counts: [String: PlayCount] = [:]) -> [String] {
        TrackRow.visible(rows, filter: LibraryFilter(), ids: nil, tracks: f, counts: counts, now: now).map(\.track.title)
    }

    // MARK: Conditions

    func testYearsKindsGenresArtistAlbum() {
        let rows = [
            row(1, title: "Blew", year: 1989),
            row(2, album: "Nevermind", title: "Lithium", year: 1991, genre: "Rock; Grunge"),
            row(3, artist: "Cat Power", album: "Moon Pix", title: "Metal Heart", year: 1998, genre: "Indie"),
            row(4, album: "1991-11-25 Amsterdam", title: "Drain You", year: 1991, genre: "", kind: .show),
            row(5, artist: "Brant Bjork", album: "Desert Sessions", title: "Lazy Bones", year: nil, albumArtist: "Various Artists"),
        ]
        XCTAssertEqual(titles(rows, TrackFilter(years: 1990...1992)), ["Lithium", "Drain You"])
        XCTAssertEqual(titles(rows, TrackFilter(years: 1991...1991, kinds: [.shows])), ["Drain You"])
        XCTAssertEqual(titles(rows, TrackFilter(kinds: [.albums])), ["Blew", "Lithium", "Metal Heart", "Lazy Bones"])
        // "Rock; Grunge" is both; genres are matched however they're spelled.
        XCTAssertEqual(titles(rows, TrackFilter(genres: ["grunge"])), ["Blew", "Lithium", "Lazy Bones"])
        XCTAssertEqual(titles(rows, TrackFilter(genres: ["Rock", "Indie"])), ["Lithium", "Metal Heart"])
        // A compilation's track belongs to its own artist (and the release's).
        XCTAssertEqual(titles(rows, TrackFilter(artist: .init(key: "brant bjork", name: "Brant Bjork"))), ["Lazy Bones"])
        XCTAssertEqual(titles(rows, TrackFilter(artist: .init(key: "various artists", name: "Various Artists"))), ["Lazy Bones"])
        XCTAssertEqual(titles(rows, TrackFilter(album: .init(key: rows[1].track.albumKey, name: "Nevermind"))), ["Lithium"])
        XCTAssertEqual(titles(rows, TrackFilter()).count, 5)
    }

    func testPlaysAndLastPlayed() {
        let rows = [row(1, title: "Often, long ago"), row(2, title: "Often, lately"), row(3, title: "Once, this year"), row(4, title: "Never")]
        let counts = [rows[0].countKey: PlayCount(plays: 40, last: ts(2015)),
                      rows[1].countKey: PlayCount(plays: 25, last: ts(2026, 3)),
                      rows[2].countKey: PlayCount(plays: 1, last: ts(2026, 2))]
        func t(_ f: TrackFilter) -> [String] { titles(rows, f, counts: counts) }
        XCTAssertEqual(t(.forgottenFavourites), ["Often, long ago"])
        XCTAssertEqual(t(.neverPlayed), ["Never"])
        XCTAssertEqual(t(TrackFilter(plays: .atLeast(10))), ["Often, long ago", "Often, lately"])
        XCTAssertEqual(t(TrackFilter(plays: .atLeast(1))).count, 3)
        XCTAssertEqual(t(TrackFilter(lastPlayed: .thisYear)), ["Often, lately", "Once, this year"])
        // Never played isn't "not played in a year".
        XCTAssertEqual(t(TrackFilter(lastPlayed: .yearsAgo(1))), ["Often, long ago"])
        XCTAssertEqual(t(TrackFilter(lastPlayed: .never)), ["Never"])
        XCTAssertTrue(TrackFilter.forgottenFavourites.usesCounts)
        XCTAssertFalse(TrackFilter(years: 1990...1991).usesCounts)
    }

    func testPlayedYearsCountOnlyThoseYears() {
        let rows = [row(1, title: "Then"), row(2, title: "Always"), row(3, title: "Lately"), row(4, title: "Never")]
        let counts = [rows[0].countKey: PlayCount(plays: 30, last: ts(2010), byYear: [2008: 20, 2009: 8, 2010: 2]),
                      rows[1].countKey: PlayCount(plays: 60, last: ts(2026), byYear: [2008: 3, 2015: 27, 2026: 30]),
                      rows[2].countKey: PlayCount(plays: 12, last: ts(2026), byYear: [2025: 5, 2026: 7])]
        func t(_ f: TrackFilter) -> [String] { titles(rows, f, counts: counts) }
        // Played in those years at all; with Plays, only the plays in them count.
        XCTAssertEqual(t(TrackFilter(playedYears: 2008...2009)), ["Then", "Always"])
        XCTAssertEqual(t(TrackFilter(playedYears: 2008...2009, plays: .atLeast(10))), ["Then"])
        XCTAssertEqual(t(TrackFilter(playedYears: 2008...2009, plays: .never)), ["Lately", "Never"])
        XCTAssertEqual(t(TrackFilter(playedYears: 2025...TrackFilter.latest)), ["Always", "Lately"])
        // Never played (all time) stays all time.
        XCTAssertEqual(t(TrackFilter(playedYears: 2008...2009, lastPlayed: .never)), [])
        // Sorted by plays in the range: "my top songs of 2008".
        let top = TrackSort(column: .plays, ascending: false).sorted(rows, counts: counts, played: 2008...2008).map(\.track.title)
        XCTAssertEqual(Array(top.prefix(2)), ["Then", "Always"])
        let allTime = TrackSort(column: .plays, ascending: false).sorted(rows, counts: counts).map(\.track.title)
        XCTAssertEqual(Array(allTime.prefix(2)), ["Always", "Then"])
        XCTAssertEqual(counts[rows[1].countKey]?.plays(in: 2008...2015), 30)
        // Chips and typed words.
        XCTAssertEqual(TrackFilter(playedYears: 2008...2010).title(.playedYears), "Played 2008–2010")
        XCTAssertEqual(TrackFilter(playedYears: 2008...2008).title(.playedYears), "Played in 2008")
        XCTAssertEqual(TrackFilter(playedYears: 2015...TrackFilter.latest).title(.playedYears), "Played since 2015")
        XCTAssertEqual(TrackFilter.parse("played:2008-2010 plays:10+").filter, TrackFilter(playedYears: 2008...2010, plays: .atLeast(10)))
        XCTAssertEqual(TrackFilter.parse("played:never").filter, TrackFilter(plays: .never))
        XCTAssertTrue(TrackFilter(playedYears: 2008...2009).usesCounts)
        XCTAssertEqual(YearRangeSlider.span([2005: 3, 2008: 900, 2026: 40], decadeStart: false), 2005...2026)
    }

    func testAdded() {
        let day = 86400.0, n = now.timeIntervalSince1970
        let rows = [row(1, title: "Yesterday", added: n - day), row(2, title: "Two months", added: n - 60 * day),
                    row(3, title: "Last year", added: Double(ts(2025)))]
        XCTAssertEqual(titles(rows, TrackFilter(added: .days(30))), ["Yesterday"])
        XCTAssertEqual(titles(rows, TrackFilter(added: .thisYear)), ["Yesterday", "Two months"])
    }

    // MARK: Chips

    func testChipsAndRemoving() {
        var f = TrackFilter(years: 1990...1992, plays: .atLeast(10), genres: ["Shoegaze", "Dream Pop"], kinds: [.shows])
        XCTAssertEqual(f.conditions.map(f.title), ["1990–1992", "Played 10+ times", "Shoegaze", "Dream Pop", "Shows"])
        f = f.removing(.genre("Shoegaze")).removing(.plays)
        XCTAssertEqual(f.conditions.map(f.title), ["1990–1992", "Dream Pop", "Shows"])
        XCTAssertEqual(TrackFilter(years: 1990...1999).title(.years), "1990s")
        XCTAssertEqual(TrackFilter(years: 1991...1991).title(.years), "Year 1991")
        XCTAssertEqual(TrackFilter.forgottenFavourites.conditions.map(TrackFilter.forgottenFavourites.title), ["Played 10+ times", "Not played in 5 years"])
        XCTAssertTrue(f.removing(.years).removing(.genre("Dream Pop")).removing(.kind(.shows)).isEmpty)
    }

    // MARK: Typed

    func testParse() {
        var (f, rest) = TrackFilter.parse("cat power year:1998-2003 kind:show plays:10+")
        XCTAssertEqual(rest, "cat power")
        XCTAssertEqual(f, TrackFilter(years: 1998...2003, plays: .atLeast(10), kinds: [.shows]))
        (f, rest) = TrackFilter.parse(#"genre:"post punk" last:5y+ added:30d"#)
        XCTAssertEqual(rest, "")
        XCTAssertEqual(f, TrackFilter(lastPlayed: .yearsAgo(5), added: .days(30), genres: ["post punk"]))
        XCTAssertEqual(TrackFilter.parse("year:90s").filter.years, 1990...1999)
        XCTAssertEqual(TrackFilter.parse("year:1980s").filter.years, 1980...1989)
        XCTAssertEqual(TrackFilter.parse("year:1992..1990").filter.years, 1990...1992)
        XCTAssertEqual(TrackFilter.parse("year:-1992").filter.years, TrackFilter.earliest...1992)
        XCTAssertEqual(TrackFilter.parse("year:1990-").filter.years, 1990...TrackFilter.latest)
        XCTAssertEqual(TrackFilter(years: TrackFilter.earliest...1992).title(.years), "Up to 1992")
        XCTAssertEqual(TrackFilter(years: 1990...TrackFilter.latest).title(.years), "1990 and later")
        XCTAssertEqual(YearRangeSlider.span([1901: 1, 1965: 50, 1991: 900, 2024: 300]), 1960...2024)
        XCTAssertEqual(TrackFilter.parse("played:never").filter.plays, .never)
        XCTAssertEqual(TrackFilter.parse("last:thisyear").filter.lastPlayed, .thisYear)
        // Words it doesn't know stay search words, quotes and all.
        (f, rest) = TrackFilter.parse(#"live:yes year:abc "wild is the wind""#)
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(rest, #"live:yes year:abc "wild is the wind""#)
        XCTAssertEqual(TrackFilter.parse("1977-05-08 barton").rest, "1977-05-08 barton")
    }

    func testTextRoundTrip() {
        let filters = [TrackFilter.forgottenFavourites, .neverPlayed,
                       TrackFilter(years: 1990...1992, added: .thisYear, genres: ["Post Punk", "Grunge"], kinds: [.live, .demos]),
                       TrackFilter(years: 1977...1977, lastPlayed: .thisYear, added: .days(7)),
                       TrackFilter(playedYears: 2008...2010, plays: .atLeast(10)), TrackFilter(playedYears: 2015...TrackFilter.latest)]
        for f in filters { XCTAssertEqual(TrackFilter.parse(f.text).filter, f, f.text) }
    }

    @MainActor func testLastWordStaysWhileTyped() {
        XCTAssertEqual(TracksPage.splitLast("cat power year:1990", finished: false).last, "year:1990")
        XCTAssertEqual(TracksPage.splitLast("cat power year:1990", finished: false).head, "cat power ")
        XCTAssertEqual(TracksPage.splitLast("year:1990-1992 ", finished: false).last, "")
        XCTAssertEqual(TracksPage.splitLast("year:1990", finished: true).last, "")
        XCTAssertEqual(TracksPage.splitLast(#"plays:10+ genre:"post pu"#, finished: false).last, #"genre:"post pu"#)
    }

    func testMerged() {
        let set = TrackFilter(years: 1990...1992, genres: ["Grunge"])
        let typed = TrackFilter.parse("plays:10+ genre:grunge genre:Rock").filter
        XCTAssertEqual(set.merged(with: typed), TrackFilter(years: 1990...1992, plays: .atLeast(10), genres: ["Grunge", "Rock"]))
    }

    func testLargeLibraryFiltersQuickly() {
        let rows = (0..<100_000).map { i in row(Int64(i), title: "Song \(i)", year: 1960 + i % 60, genre: i % 3 == 0 ? "Rock; Pop" : "Jazz") }
        var counts: [String: PlayCount] = [:]
        for r in rows.prefix(5000) { counts[r.countKey] = PlayCount(plays: 20, last: ts(2010)) }
        let t0 = Date()
        let found = TrackRow.visible(rows, filter: LibraryFilter(), ids: nil, tracks: TrackFilter(years: 1990...1999, genres: ["Pop"]),
                                     counts: counts, now: now)
        let ff = TrackRow.visible(rows, filter: LibraryFilter(), ids: nil, tracks: .forgottenFavourites, counts: counts, now: now)
        let took = Date().timeIntervalSince(t0)
        print("TrackFilter 100k twice: \(took)s")
        XCTAssertGreaterThan(found.count, 0)
        XCTAssertEqual(ff.count, 5000)   // the songs played 20 times, last in 2010
        XCTAssertLessThan(took, 1)
    }
}
