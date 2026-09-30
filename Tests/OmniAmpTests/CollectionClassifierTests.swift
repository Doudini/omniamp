import XCTest
@testable import OmniAmp

final class CollectionClassifierTests: XCTestCase {
    private let root = "/Volumes/NAS/Music"

    private func classify(_ rel: String, _ tags: ReleaseClassifier.Tags = .init()) -> ReleaseClassifier.Result {
        ReleaseClassifier.classify(path: root + "/" + rel, root: root, tags: tags)
    }

    // MARK: Keys

    func testDiscFolderNames() {
        for n in ["CD1", "cd 2", "Disc_3", "disk-1", "Set 2", "d1", "D2", "d1 (sbd)"] { XCTAssertTrue(ReleaseClassifier.isDiscFolder(n), n) }
        for n in ["D12 - Devil's Night", "Discipline", "Setlist", "d123", "Dune"] { XCTAssertFalse(ReleaseClassifier.isDiscFolder(n), n) }
    }

    func testVariousArtistNames() {
        for name in ["VA", "Various", "various artists"] {
            let r = classify("Mixed/Now 42/01.flac", .init(artist: "Someone", albumArtist: name, album: "Now 42"))
            XCTAssertEqual(r.artist, "Various Artists", name)
            XCTAssertEqual(r.kind, .compilation)
        }
    }

    func testSortNamesFollowTheirLetter() {
        XCTAssertEqual(Keys.sortName("(Smog)"), "Smog)")
        XCTAssertEqual(Keys.letter("(Smog)"), "S")
        XCTAssertEqual(Keys.sortName("The Beatles"), "Beatles")
        XCTAssertEqual(Keys.sortName("...And You Will Know Us"), "And You Will Know Us")
    }

    func testArtistKeys() {
        XCTAssertEqual(Keys.artist("The Beatles"), "beatles")
        XCTAssertEqual(Keys.artist("Beatles, The"), "beatles")
        XCTAssertEqual(Keys.artist("BEATLES"), "beatles")
        XCTAssertEqual(Keys.artist("Björk"), "bjork")
        XCTAssertEqual(Keys.artist("Simon & Garfunkel"), Keys.artist("Simon and Garfunkel"))
        XCTAssertEqual(Keys.artist("The The"), "the")   // not emptied
        XCTAssertEqual(Keys.sortName("The Who"), "Who")
        XCTAssertEqual(Keys.letter("The Who"), "W")
        XCTAssertEqual(Keys.letter("Ólafur Arnalds"), "O")
        XCTAssertEqual(Keys.letter("2Pac"), "#")
        XCTAssertEqual(Keys.letter("坂本龍一"), "#")
    }

    func testTitleKeysGroupVersions() {
        let k = Keys.title("Sugar Magnolia")
        XCTAssertEqual(Keys.title("Sugar Magnolia (Live)"), k)
        XCTAssertEqual(Keys.title("Sugar Magnolia [Demo 1970]"), k)
        XCTAssertEqual(Keys.title("Sugar Magnolia - 2013 Remaster"), k)
        XCTAssertEqual(Keys.title("Sugar Magnolia - Live at Winterland"), k)
        XCTAssertNotEqual(Keys.title("Sugar Magnolia (Sunshine Daydream)"), k)   // not a version note
        XCTAssertEqual(Keys.title("The hover is ajar (Paris 4 mai 2002)"), Keys.title("The Hover Is Ajar"))
        XCTAssertEqual(Keys.title("Transmission [BBC Session 1979]"), Keys.title("Transmission"))
        XCTAssertNotEqual(Keys.title("1999"), "")   // a title that is a year stays
        XCTAssertEqual(Keys.displayTitle(["You hurry wonder (Paris 4 mai 2002)": 5, "You Hurry Wonder": 2]), "You Hurry Wonder")
        XCTAssertEqual(Keys.displayTitle(["Song (live)": 1]), "Song (live)")
        XCTAssertEqual(Keys.title("(Live)"), "live")   // nothing else left: keep it
    }

    func testYears() {
        XCTAssertEqual(Keys.year("1977-05-08"), 1977)
        XCTAssertEqual(Keys.year("Album (1999) [FLAC]"), 1999)
        XCTAssertNil(Keys.year("CAT-123456"))
        XCTAssertNil(Keys.year("1234"))
        XCTAssertNil(Keys.year(nil))
    }

    // MARK: Shows

    func testEtreeFolder() {
        let r = classify("Grateful Dead/gd1977-05-08.sbd.miller.flac16/gd77-05-08d1t01.flac")
        XCTAssertEqual(r.kind, .show)
        XCTAssertEqual(r.showDate, "1977-05-08")
        XCTAssertNil(r.venue)
        XCTAssertEqual(r.artist, "Grateful Dead")
        XCTAssertEqual(r.year, 1977)
    }

    func testTwoDigitEtreeYear() {
        XCTAssertEqual(classify("Phish/ph97-12-31/01.flac").showDate, "1997-12-31")
        XCTAssertEqual(classify("Phish/ph03-02-28/01.flac").showDate, "2003-02-28")
    }

    func testDateAndVenueFolder() {
        let r = classify("Grateful Dead/1977-05-08 Barton Hall, Cornell University, Ithaca, NY [SBD]/01 - New Minglewood Blues.flac",
                         .init(title: "New Minglewood Blues"))
        XCTAssertEqual(r.kind, .show)
        XCTAssertEqual(r.showDate, "1977-05-08")
        XCTAssertEqual(r.venue, "Barton Hall, Cornell University, Ithaca, NY")
        XCTAssertEqual(r.album, "1977-05-08 Barton Hall, Cornell University, Ithaca, NY")
    }

    func testArtistDashDateFolderWithDiscs() {
        let r = classify("Bootlegs/Radiohead - 2001.08.07 - Chicago Auditorium/CD2/03 Airbag.mp3")
        XCTAssertEqual(r.kind, .show)
        XCTAssertEqual(r.artist, "Radiohead")
        XCTAssertEqual(r.showDate, "2001-08-07")
        XCTAssertEqual(r.venue, "Chicago Auditorium")
        XCTAssertEqual(r.album, "2001-08-07 Chicago Auditorium")
        XCTAssertEqual(r.albumFolder, root + "/Bootlegs/Radiohead - 2001.08.07 - Chicago Auditorium")
    }

    func testBootlegsFolderAboveMakesLiveUnofficial() {
        let r = classify("Neil Young/Bootlegs/Live at the Fillmore East 1970/01.flac")
        XCTAssertEqual(r.kind, .show)
        XCTAssertEqual(r.artist, "Neil Young")
    }

    // MARK: Unreleased

    func testDemosAndUnreleased() {
        XCTAssertEqual(classify("Nirvana/Fecal Matter Demo/01.mp3").kind, .unreleased)
        XCTAssertEqual(classify("Prince/Unreleased/The Dream Factory/01.flac").kind, .unreleased)
        XCTAssertEqual(classify("Prince/Unreleased/The Dream Factory/01.flac").artist, "Prince")
        XCTAssertEqual(classify("Kanye West/Yandhi (Leak)/01.mp3").kind, .unreleased)
        XCTAssertEqual(classify("Beatles/Get Back Sessions/01.flac").kind, .unreleased)
        XCTAssertEqual(classify("Radiohead/OK Computer Outtakes/01.flac").kind, .unreleased)
    }

    // MARK: Official

    func testPlainAlbumsStayAlbums() {
        for p in ["Metallica/Master of Puppets/01.flac", "Hole/Live Through This/01.flac", "Kraftwerk/Tour de France/01.flac",
                  "Grateful Dead/American Beauty (1970) [FLAC]/01.flac"] {
            XCTAssertEqual(classify(p).kind, .album, p)
        }
        let r = classify("Grateful Dead/American Beauty (1970) [FLAC]/01.flac")
        XCTAssertEqual(r.album, "American Beauty")
        XCTAssertEqual(r.year, 1970)
    }

    func testOfficialLiveAndCompilation() {
        XCTAssertEqual(classify("Nirvana/MTV Unplugged in New York/01.flac").kind, .live)
        XCTAssertEqual(classify("Johnny Cash/At Folsom Prison - Live/01.flac").kind, .live)
        XCTAssertEqual(classify("Queen/Greatest Hits/01.flac").kind, .compilation)
        XCTAssertEqual(classify("Mixed/Now 42/01.flac", .init(albumArtist: "Various Artists")).kind, .compilation)
    }

    func testTagsWin() {
        // Picard tags: an official live album in a folder that looks like a show.
        let official = classify("Grateful Dead/1977-05-08 Cornell/01.flac",
                                .init(artist: "Grateful Dead", album: "Cornell 5/8/77", releaseType: "album; live", releaseStatus: "Official"))
        XCTAssertEqual(official.kind, .live)
        XCTAssertEqual(official.album, "Cornell 5/8/77")
        let boot = classify("Misc/Some Album/01.flac", .init(artist: "Pink Floyd", album: "Some Album", releaseType: "album",
                                                             releaseStatus: "bootleg"))
        XCTAssertEqual(boot.kind, .unreleased)
        XCTAssertEqual(boot.artist, "Pink Floyd")
        let liveBoot = classify("Misc/X/01.flac", .init(releaseType: "live", releaseStatus: "Bootleg"))
        XCTAssertEqual(liveBoot.kind, .show)
        XCTAssertEqual(classify("A/B/01.flac", .init(releaseType: "ep")).kind, .single)
        XCTAssertEqual(classify("A/B/01.flac", .init(releaseType: "album/compilation")).kind, .compilation)
    }

    func testAlbumArtistTagBeatsArtist() {
        let r = classify("x/y/01.flac", .init(artist: "Guest Singer", albumArtist: "Main Band", album: "Record"))
        XCTAssertEqual(r.artist, "Main Band")
        XCTAssertEqual(r.album, "Record")
    }

    // MARK: Messy folders

    func testArtistFromFolders() {
        XCTAssertEqual(classify("Rock/Pixies/Doolittle/01.flac").artist, "Pixies")
        XCTAssertEqual(classify("Downloads/Pixies - Doolittle (1989)/01.flac").artist, "Pixies")
        XCTAssertEqual(classify("Downloads/Pixies - Doolittle (1989)/01.flac").album, "Doolittle")
        XCTAssertEqual(classify("P/Pixies/Doolittle/01.flac").artist, "Pixies")
        XCTAssertEqual(classify("Grateful Dead/Europe '72 - Live/01.flac").artist, "Grateful Dead")
        XCTAssertEqual(classify("Grateful Dead/Europe '72 - Live/01.flac").kind, .live)
        XCTAssertEqual(classify("Pink Floyd/Animals - 2018 Remaster/01.flac").artist, "Pink Floyd")
        XCTAssertEqual(classify("FLAC/Albums/Doolittle/01.flac").artist, "Unknown Artist")
        XCTAssertEqual(classify("loose.flac").artist, "Unknown Artist")
        XCTAssertEqual(classify("loose.flac").album, "Unknown Album")
    }

    func testShowTagDate() {
        // Untitled bootleg folder, but a full date in the DATE tag.
        let r = classify("Springsteen/Bootlegs/Roxy/01.flac", .init(date: "1975-10-17"))
        XCTAssertEqual(r.kind, .show)
        XCTAssertEqual(r.showDate, "1975-10-17")
    }

    func testMoreDateStyles() {
        func dv(_ n: String) -> [String?] { ReleaseClassifier.dateAndVenue(n).map { [$0.0, $0.1] } ?? [] }
        XCTAssertEqual(dv("shannon wright - 30.04.04 - paris"), ["2004-04-30", "paris"])
        XCTAssertEqual(dv("café de la danse 04.05.2002"), ["2002-05-04", "café de la danse"])
        XCTAssertEqual(dv("shannon wright - café de la danse, paris, france, 30.04.2004"), ["2004-04-30", "café de la danse, paris, france"])
        XCTAssertEqual(dv("[20010905] paris, la guinguette pirate"), ["2001-09-05", "paris, la guinguette pirate"])
        XCTAssertEqual(dv("11-23-91-Vooruit_Gent_BE"), ["1991-11-23", "Vooruit Gent BE"])
        XCTAssertEqual(dv("26.10.89_-_share")[0], "1989-10-26")
        XCTAssertEqual(dv("092393")[0], "1993-09-23")
        XCTAssertEqual(dv("91-12-04 - Nirvana - Live at The Academy")[0], "1991-12-04")
        XCTAssertEqual(dv("shannon wright_2004-04-29_live, rock school barbey, bordeaux"), ["2004-04-29", "rock school barbey, bordeaux"])
        XCTAssertEqual(dv("Radiohead - OK Computer (1997)"), [])
        XCTAssertEqual(dv("Vol. 2"), [])
        XCTAssertEqual(dv("Track01"), [])
        let r = classify("Shannon Wright/shannon wright - 30.04.04 - paris/shannon wright - 01 - plea.wma")
        XCTAssertEqual(r.kind, .show)
        XCTAssertEqual(r.artist, "Shannon Wright")
        XCTAssertEqual(r.album, "2004-04-30 paris")
    }

    func testTitlesFromFileNames() {
        func t(_ n: String, _ a: String? = nil) -> String { let r = ReleaseClassifier.fromFileName(n, artist: a); return "\(r.title)|\(r.track ?? 0)|\(r.disc ?? 0)" }
        XCTAssertEqual(t("shannon wright - 01 - plea", "Shannon Wright"), "plea|1|0")
        XCTAssertEqual(t("03. Airbag"), "Airbag|3|0")
        XCTAssertEqual(t("01 - Box of Rain"), "Box of Rain|1|0")
        XCTAssertEqual(t("07_hunter"), "hunter|7|0")
        XCTAssertEqual(t("gd77-05-08d1t03"), "gd77-05-08d1t03|3|1")
        XCTAssertEqual(t("Airbag"), "Airbag|0|0")
        XCTAssertEqual(t("99 Problems"), "Problems|99|0")   // ambiguous; a tag title wins when there is one
    }
}
