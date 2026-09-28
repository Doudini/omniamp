import XCTest
@testable import OmniAmp

private struct Answers: HTTPTransport {
    let answers: [(String, String)]
    func send(_ req: URLRequest) async throws -> (Data, Int) {
        let url = req.url!.absoluteString.removingPercentEncoding ?? ""
        guard let body = answers.first(where: { url.contains($0.0) })?.1 else { return (Data(), 404) }
        return (Data(body.utf8), 200)
    }
}

final class IdentifyTests: XCTestCase {
    func testGuessesFromNames() {
        let g1 = ReleaseGuess.guesses(folder: "/m/Sophie Hunger - 1983 (2010)", albumTitle: "Sophie Hunger - 1983",
                                      fileNames: ["09 - Breaking the waves.flac"], titles: ["Breaking the waves"])
        XCTAssertEqual(g1.first, .init(artist: "Sophie Hunger", album: "1983", year: 2010, why: "from the folder name"))
        let g2 = ReleaseGuess.guesses(folder: "/m/Human_Tetris", albumTitle: "Human_Tetris",
                                      fileNames: ["Human Tetris - Things I Don&#039;t Need (320  kbps).mp3", "Human Tetris - Rain.mp3"],
                                      titles: ["Human Tetris - Things I Don&#039;t Need (320  kbps)", "Human Tetris - Rain"])
        XCTAssertEqual(g2.first?.artist, "Human Tetris")
        XCTAssertEqual(g2.first?.album, "")
        // Numbered files ("07 - Song") and "artist - Track 9" don't make an artist.
        let g3 = ReleaseGuess.guesses(folder: "/m/Catie Curtis", albumTitle: "Catie Curtis",
                                      fileNames: ["03 - River Winding.mp3", "04 - Falling Silent.mp3"], titles: ["River Winding", "Falling Silent"])
        XCTAssertEqual(g3, [.init(artist: "Catie Curtis", album: "", year: nil, why: "the folder's name, as the artist")])
        XCTAssertNil(ReleaseGuess.guesses(folder: "/m/NIRVANA", albumTitle: "NIRVANA", fileNames: ["artist - Track 15.wma", "artist - Track 9.wma"],
                                          titles: ["Track 15", "Track 9"]).first { $0.artist == "artist" })
    }

    func testSearchTitles() {
        let t = ReleaseGuess.searchTitles([("Track  7", 187), ("River Winding", 229), ("Human Tetris - Things I Don&#039;t Need (320  kbps)", 244),
                                           ("01", nil), ("Mega Drive - 198XAD [Full Album]", nil)], artist: nil)
        XCTAssertEqual(t.map(\.title), ["River Winding", "Things I Don't Need", "198XAD"])
    }

    func testIdentifyRanksReleasesWithMostSongs() async {
        let lookup = MetadataLookup(http: Answers(answers: [
            ("recording:\"River Winding\"", """
                {"recordings":[{"score":100,"title":"River Winding","artist-credit":[{"name":"Catie Curtis"}],
                  "releases":[{"date":"1997","release-group":{"id":"cc97","title":"Catie Curtis","primary-type":"Album"}},
                              {"date":"2005","release-group":{"id":"best","title":"Best Of","primary-type":"Album"}}]}]}
                """),
            ("recording:\"Falling Silent\"", """
                {"recordings":[{"score":100,"title":"Falling Silent","artist-credit":[{"name":"Catie Curtis"}],
                  "releases":[{"date":"1997-05","release-group":{"id":"cc97","title":"Catie Curtis","primary-type":"Album"}}]}]}
                """),
        ]), pace: 0)
        let found = await lookup.identify([("River Winding", 229), ("Falling Silent", 221)], artistHint: "Catie Curtis")
        XCTAssertEqual(found.first?.album, "Catie Curtis")
        XCTAssertEqual(found.first?.year, 1997)
        XCTAssertGreaterThanOrEqual(found.first?.score ?? 0, 0.8, "selected on its own")
        XCTAssertEqual(found.map(\.album), ["Catie Curtis", "Best Of"])
    }
}
