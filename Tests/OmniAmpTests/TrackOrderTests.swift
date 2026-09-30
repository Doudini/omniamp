import XCTest
@testable import OmniAmp

/// Album track order, from albums in a real, loosely kept collection.
final class TrackOrderTests: XCTestCase {
    private var nextID: Int64 = 0

    /// A track: its file name (in `folder`), disc and number tags, and a CUE start when it's a sheet's track.
    private func t(_ name: String, disc: Int? = nil, _ number: Int? = nil, folder: String = "/Volumes/MUSIC/Artist/Album",
                   cue: Double? = nil) -> LibraryTrack {
        nextID += 1
        return LibraryTrack(id: nextID, key: "\(nextID)", path: folder + "/" + name, size: 1, mtime: 0, cueStart: cue, cueEnd: nil,
                            cueNumber: nil, title: name, artist: "Artist", album: "Album", albumKey: "album", disc: disc, number: number,
                            duration: nil, format: "MP3")
    }

    private func order(_ tracks: [LibraryTrack]) -> [String] {
        TrackOrder.sorted(tracks.shuffled()).map { ($0.path as NSString).lastPathComponent }
    }

    func testTagsWhenTheyAgree() {
        XCTAssertEqual(order([t("b.mp3", 2), t("a.mp3", 10), t("c.mp3", 1)]), ["c.mp3", "b.mp3", "a.mp3"])
        XCTAssertEqual(order([t("x.flac", disc: 2, 1), t("y.flac", disc: 1, 2), t("z.flac", disc: 1, 1)]), ["z.flac", "y.flac", "x.flac"])
    }

    /// Live on Planet Claire: three files without a number used to play before "01 intro".
    func testUnnumberedTracksComeLast() {
        XCTAssertEqual(order([t("A Good Woman.mp3"), t("01 intro.mp3", 1), t("02 The Winter Wind.mp3", 2), t("Schizophrenia.mp3")]),
                       ["01 intro.mp3", "02 The Winter Wind.mp3", "A Good Woman.mp3", "Schizophrenia.mp3"])
    }

    /// Last Valentine: "02"–"20" and the opener without a number: it fills the gap. Two files, one gap: last.
    func testUnnumberedTracksFillTheOnlyGaps() {
        XCTAssertEqual(order([t("03 Breed.mp3", 3), t("Radio Friendly Unit Shifter.mp3"), t("02 Drain You.mp3", 2)]),
                       ["Radio Friendly Unit Shifter.mp3", "02 Drain You.mp3", "03 Breed.mp3"])
        XCTAssertEqual(order([t("b.mp3"), t("01 x.mp3", 1), t("a.mp3"), t("03 y.mp3", 3)]), ["01 x.mp3", "03 y.mp3", "a.mp3", "b.mp3"])
        XCTAssertEqual(order([t("b.mp3"), t("a.mp3", 0)]), ["a.mp3", "b.mp3"])   // a track 0: no gaps to fill (no crash)
    }

    /// The Best Of The 4 Skins: tagged files had no disc number, the others "disc 1" from their names ("1-02 …").
    func testMissingDiscIsDiscOne() {
        XCTAssertEqual(order([t("01 One Law.mp3", 1), t("1-02 Yesterday's Heroes.mp3", disc: 1, 2), t("06 Wonderful World.mp3", 6),
                              t("1-03 Clockwork Skinhead.mp3", disc: 1, 3)]),
                       ["01 One Law.mp3", "1-02 Yesterday's Heroes.mp3", "1-03 Clockwork Skinhead.mp3", "06 Wonderful World.mp3"])
    }

    /// Brant Bjork 2003-09-07: files 08–11 were tagged 2–5 and played between the first ones.
    func testClashingTagsFollowFileNames() {
        let tracks = [t("01- lazy bones.mp3", 1), t("02- cobra jab.mp3", 2), t("03- low desert punk.mp3", 3),
                      t("08- rock n' rol 'e.mp3", 2), t("09- sun brother.mp3", 3), t("10- sounds of liberation.mp3", 4)]
        XCTAssertEqual(order(tracks), ["01- lazy bones.mp3", "02- cobra jab.mp3", "03- low desert punk.mp3",
                                       "08- rock n' rol 'e.mp3", "09- sun brother.mp3", "10- sounds of liberation.mp3"])
        // Ane Brun, Duets: "08 - common bird" tagged 9, next to the real 9.
        XCTAssertEqual(order([t("09 - love & misery.mp3", 9), t("08 - common bird.mp3", 9), t("07 - easier.mp3", 7)]),
                       ["07 - easier.mp3", "08 - common bird.mp3", "09 - love & misery.mp3"])
    }

    /// Clashing tags and names without numbers of their own: the tags still order the folder, a tie in Finder order
    /// ("2" before "10"). A copy tagged 12 next to a good 1–12 doesn't make the album play A–Z.
    func testClashingTagsWithoutNumberedNamesKeepTheTags() {
        XCTAssertEqual(order([t("say.mp3", 1), t("metal heart.mp3", 1), t("free.mp3", 4)]), ["metal heart.mp3", "say.mp3", "free.mp3"])
        XCTAssertEqual(order([t("part 10.mp3", 1), t("part 2.mp3", 1)]), ["part 2.mp3", "part 10.mp3"])
        XCTAssertEqual(order([t("Zebra.flac", 1), t("Apple.flac", 2), t("Mango.flac", 3), t("Mango (copy).flac", 3)]),
                       ["Zebra.flac", "Apple.flac", "Mango (copy).flac", "Mango.flac"])
    }

    /// Two disc folders with no disc tags: each disc's 1, 2, 3 used to be interleaved.
    func testDiscFoldersWithoutDiscTags() {
        let cd1 = "/Volumes/MUSIC/Artist/Album/CD1", cd2 = "/Volumes/MUSIC/Artist/Album/CD2"
        let tracks = [t("01 a.flac", 1, folder: cd1), t("02 b.flac", 2, folder: cd1), t("01 c.flac", 1, folder: cd2), t("02 d.flac", 2, folder: cd2)]
        XCTAssertEqual(TrackOrder.sorted(tracks.shuffled()).map(\.path), tracks.map(\.path))
    }

    /// Two CUE images of one album (no disc tags): one image after the other, each in its sheet's order.
    func testCueImagesStayWhole() {
        let tracks = [t("Album CD1.flac", 1, cue: 0), t("Album CD1.flac", 2, cue: 200), t("Album CD2.flac", 1, cue: 0), t("Album CD2.flac", 2, cue: 180)]
        XCTAssertEqual(TrackOrder.sorted(tracks.shuffled()).map(\.id), tracks.map(\.id))
    }
}
