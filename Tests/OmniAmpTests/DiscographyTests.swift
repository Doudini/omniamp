import XCTest
@testable import OmniAmp

/// Canned answers, first matching URL fragment wins.
private struct Answers: HTTPTransport {
    let answers: [(String, String)]
    func send(_ req: URLRequest) async throws -> (Data, Int) {
        let url = req.url!.absoluteString
        guard let body = answers.first(where: { url.contains($0.0) })?.1 else { return (Data(), 404) }
        return (Data(body.utf8), 200)
    }
}

final class DiscographyTests: XCTestCase {
    private func album(_ title: String, kind: ReleaseKind = .album, show: String? = nil) -> LibraryAlbum {
        LibraryAlbum(key: "/m/\(title)", artistKey: "nirvana", artist: "Nirvana", title: title, year: nil, kind: kind, folder: "/m/\(title)",
                     tracks: 10, duration: 1, firstPath: "/m/\(title)/1.flac", lossless: true, added: 0, showDate: show, venue: nil)
    }

    private func release(_ title: String, _ date: String? = nil, secondary: [String] = []) -> ArtistDiscography.Release {
        .init(id: title, title: title, date: date, type: "Album", secondary: secondary)
    }

    func testMatchesOwnedReleases() {
        let owned = [album("Nevermind (Remastered)"), album("Unplugged In New York", kind: .live),
                     album("1991-10-31 Paramount Theatre", kind: .show, show: "1991-10-31")]
        typealias D = ArtistDiscography
        XCTAssertEqual(D.owned(release("Nevermind"), in: owned)?.title, "Nevermind (Remastered)")
        XCTAssertEqual(D.owned(release("MTV Unplugged in New York", secondary: ["Live"]), in: owned)?.title, "Unplugged In New York")
        XCTAssertEqual(D.owned(release("1991-10-31: Paramount, Seattle"), in: owned)?.showDate, "1991-10-31")
        XCTAssertNil(D.owned(release("In Utero"), in: owned))
        // A short owned title isn't taken for a longer release ("Bleach" ≠ "Bleach Deluxe Demos").
        XCTAssertNil(D.owned(release("Bleach Deluxe Demos"), in: [album("Bleach")]))
        XCTAssertEqual(D.withoutDate("1991-10-31: Paramount Theatre", "1991-10-31"), "Paramount Theatre")
        XCTAssertEqual(D.withoutDate("Live in Belgium", nil), "Live in Belgium")
    }

    func testListsCompilationsOnlyWhenOwned() {
        var d = ArtistDiscography(mbid: "x")
        d.official = [release("In Utero", "1993-09-21"), release("Nevermind", "1991-09-24"),
                      release("ICON", "2010", secondary: ["Compilation"]), release("Incesticide", "1992", secondary: ["Compilation"])]
        let listed = d.listed(owned: [album("Incesticide")])
        XCTAssertEqual(listed.map(\.release.title), ["Nevermind", "Incesticide", "In Utero"])
        XCTAssertEqual(listed.map { $0.owned != nil }, [false, true, false])
    }

    func testFetchSplitsOfficialAndBootlegs() async {
        let lookup = MetadataLookup(http: Answers(answers: [
            ("release-group-status=website-default", """
                {"release-group-count":1,"release-groups":[{"id":"a","title":"Nevermind","first-release-date":"1991-09-24","primary-type":"Album","secondary-types":[]}]}
                """),
            ("release-group-status=all", """
                {"release-group-count":3,"release-groups":[
                 {"id":"a","title":"Nevermind","first-release-date":"1991-09-24","primary-type":"Album","secondary-types":[]},
                 {"id":"b","title":"1991-10-31: Paramount","first-release-date":"1993","primary-type":"Album","secondary-types":["Live"]},
                 {"id":"c","title":"Outcesticide","first-release-date":"1994","primary-type":"Album","secondary-types":["Compilation"]}]}
                """),
            ("archive.org/advancedsearch", #"{"response":{"numFound":7,"docs":[]}}"#),
        ]), pace: 0)
        let d = await lookup.discography(mbid: "m", artist: "Nirvana")
        XCTAssertEqual(d?.official.map(\.title), ["Nevermind"])
        XCTAssertEqual(d?.bootlegs.map(\.id), ["b", "c"], "by concert date")
        XCTAssertEqual(d?.bootlegs.first?.showDate, "1991-10-31")
        XCTAssertEqual(d?.bootlegTotal, 2)
        XCTAssertEqual(d?.liveArchive, 7)
        let offline = await MetadataLookup(http: Answers(answers: []), pace: 0).discography(mbid: "m", artist: "Nirvana")
        XCTAssertNil(offline, "unreachable: nothing kept, asked again next time")
    }

    func testCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-disco-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try CollectionDB(url: dir.appendingPathComponent("lib.sqlite"))
        XCTAssertNil(try db.discography("nirvana").0)
        var d = ArtistDiscography(mbid: "m")
        d.official = [release("Nevermind", "1991")]
        try db.saveDiscography("nirvana", d)
        let (kept, stale) = try db.discography("nirvana")
        XCTAssertEqual(kept, d)
        XCTAssertFalse(stale)
        XCTAssertTrue(try db.discography("nirvana", maxAge: -1).stale)
    }
}
