import XCTest
@testable import OmniAmp

/// Canned answers per host, so the lookups are tested without the network.
private struct StubTransport: HTTPTransport {
    let answers: [String: String]
    func send(_ req: URLRequest) async throws -> (Data, Int) {
        let url = req.url!.absoluteString
        XCTAssertTrue(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("OmniAmp/") ?? false)
        guard let body = answers.first(where: { url.contains($0.key) })?.value else { return (Data(), 404) }
        return (Data(body.utf8), 200)
    }
}

final class MetadataLookupTests: XCTestCase {
    private let answers = [
        "musicbrainz.org/ws/2/release-group/?": """
            {"release-groups":[{"id":"rg1","score":100,"title":"Flightsafety","first-release-date":"1999-04-20","primary-type":"Album",
              "artist-credit":[{"name":"Shannon Wright","joinphrase":""}]},
             {"id":"rg2","score":60,"title":"Flightsafety Live","primary-type":"Album","secondary-types":["Live"],
              "artist-credit":[{"name":"Shannon Wright"}]}]}
            """,
        "musicbrainz.org/ws/2/release-group/rg1": #"{"genres":[{"name":"indie rock","count":1},{"name":"alternative rock","count":3}]}"#,
        "itunes.apple.com": """
            {"results":[{"collectionName":"Flightsafety","artistName":"Shannon Wright","releaseDate":"1999-04-20T07:00:00Z",
              "primaryGenreName":"Alternative","trackCount":11,"artworkUrl100":"https://a/x/100x100bb.jpg"}]}
            """,
        "api.deezer.com/search": #"{"data":[{"id":7,"title":"Flightsafety","artist":{"name":"Shannon Wright"},"nb_tracks":11,"cover_xl":"https://d/xl.jpg"}]}"#,
        "api.deezer.com/album/7": #"{"release_date":"1999-04-20","genres":{"data":[{"name":"Alternative"}]}}"#,
        "archive.org/advancedsearch": """
            {"response":{"docs":[{"identifier":"gd1977-05-08.sbd.cube.87486.flac16","venue":"Barton Hall","coverage":"Ithaca, NY",
              "source":"See info file"}]}}
            """,
    ]

    func testParsesEachSource() async {
        let lookup = MetadataLookup(http: StubTransport(answers: answers))
        let found = await lookup.candidates(artist: "shannon wright", album: "flightsafety")
        XCTAssertEqual(Set(found.prefix(3).map(\.source)), [.musicBrainz, .iTunes, .deezer], "exact matches first")
        let mb = found.first { $0.source == .musicBrainz }!
        XCTAssertEqual(mb.year, 1999)
        XCTAssertEqual(mb.genre, "Alternative Rock", "the most-voted genre, title-cased")
        XCTAssertEqual(mb.coverURL?.absoluteString, "https://coverartarchive.org/release-group/rg1/front-1200")
        let it = found.first { $0.source == .iTunes }!
        XCTAssertEqual(it.coverURL?.absoluteString, "https://a/x/1200x1200bb.jpg")
        XCTAssertEqual(it.genre, "Alternative")
        let dz = found.first { $0.source == .deezer }!
        XCTAssertEqual(dz.year, 1999)
        XCTAssertEqual(found.last?.album, "Flightsafety Live")
    }

    func testShowsFromArchive() async {
        let lookup = MetadataLookup(http: StubTransport(answers: answers))
        let found = await lookup.archive(artist: "Grateful Dead", date: "1977-05-08")
        XCTAssertEqual(found.first?.album, "1977-05-08 Barton Hall, Ithaca, NY")
        XCTAssertEqual(found.first?.year, 1977)
        XCTAssertTrue(found.first?.detail.hasPrefix("SBD") ?? false)
    }

    func testNothingFoundIsEmpty() async {
        let lookup = MetadataLookup(http: StubTransport(answers: [:]))
        let found = await lookup.candidates(artist: "x", album: "y", showDate: "2001-01-01")
        XCTAssertEqual(found, [])
    }

    func testSimilarity() {
        let c = InfoCandidate(source: .iTunes, artist: "The Beatles", album: "Abbey Road", detail: "", score: 0)
        XCTAssertEqual(MetadataLookup.similarity(artist: "beatles", album: "abbey road", to: c), 1)
        XCTAssertLessThan(MetadataLookup.similarity(artist: "Beatles", album: "Revolver", to: c), 0.6)
    }
}
