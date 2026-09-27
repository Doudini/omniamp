import XCTest
@testable import OmniAmp

final class CueTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-cue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let sheet = """
    REM GENRE "Trip Hop"
    REM DATE 1994
    PERFORMER "Portishead"
    TITLE "Dummy"
    FILE "Portishead - Dummy.wav" WAVE
      TRACK 01 AUDIO
        TITLE "Mysterons"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "Sour Times"
        PERFORMER "Portishead & Friends"
        INDEX 00 05:01:50
        INDEX 01 05:02:00
      TRACK 03 AUDIO
        TITLE "Strangers"
        INDEX 01 09:14:37
    """

    func testParse() {
        let s = CueSheet.parse(sheet)
        XCTAssertEqual(s.title, "Dummy")
        XCTAssertEqual(s.performer, "Portishead")
        XCTAssertEqual(s.date, "1994")
        XCTAssertEqual(s.genre, "Trip Hop")
        XCTAssertEqual(s.entries.map(\.number), [1, 2, 3])
        XCTAssertEqual(s.entries[1].title, "Sour Times")
        XCTAssertEqual(s.entries[1].start, 302, accuracy: 0.0001)             // INDEX 01, not the pregap
        XCTAssertEqual(s.entries[2].start, 9 * 60 + 14 + 37.0 / 75, accuracy: 0.0001)
    }

    func testTime() {
        XCTAssertEqual(CueSheet.time("01:02:15"), 62.2)
        XCTAssertNil(CueSheet.time("1:2"))
    }

    func testWindows1252AndBOM() {
        let latin = "TITLE \"Caf\u{E9}\"\nFILE \"a.wav\" WAVE\nTRACK 01 AUDIO\nTITLE \"B\u{E9}b\u{E9}\"\nINDEX 01 00:00:00\n"
        let s = CueSheet.decode(latin.data(using: .windowsCP1252)!).map(CueSheet.parse)
        XCTAssertEqual(s?.title, "Café")
        XCTAssertEqual(s?.entries.first?.title, "Bébé")
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("TITLE \"x\"".utf8)
        XCTAssertEqual(CueSheet.decode(bom).map(CueSheet.parse)?.title, "x")
    }

    func testResolvesConvertedFile() throws {
        // The cue names a .wav, but the rip was converted to .flac (and the case differs).
        FileManager.default.createFile(atPath: dir.appendingPathComponent("portishead - dummy.FLAC").path, contents: Data([0]))
        XCTAssertEqual(CueSheet.resolve("Portishead - Dummy.wav", relativeTo: dir)?.lastPathComponent, "portishead - dummy.FLAC")
        XCTAssertNil(CueSheet.resolve("Missing.wav", relativeTo: dir))
    }

    func testFolderScanUsesCueInsteadOfWholeFile() throws {
        FileManager.default.createFile(atPath: dir.appendingPathComponent("Portishead - Dummy.flac").path, contents: Data([0]))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("bonus.mp3").path, contents: Data([0]))
        try sheet.write(to: dir.appendingPathComponent("Dummy.cue"), atomically: true, encoding: .utf8)
        let tracks = FolderScanner.scan([dir])
        // Sorted by file name (case-insensitive): bonus.mp3 comes before "Portishead - Dummy".
        XCTAssertEqual(tracks.map { $0.title ?? ($0.path as NSString).lastPathComponent },
                       ["bonus.mp3", "Mysterons", "Sour Times", "Strangers"])
        XCTAssertEqual(tracks[1].cueEnd, 302)
        XCTAssertNil(tracks[3].cueEnd, "last track runs to the end of the file")
        XCTAssertEqual(tracks[2].artist, "Portishead & Friends")
        XCTAssertEqual(tracks[3].artist, "Portishead", "falls back to the album performer")
        XCTAssertEqual(Set(tracks.map(\.key)).count, 4, "each CUE track has its own identity")
    }

    func testFolderScanMatchesCueWithDifferentCase() throws {
        // Windows rips: the sheet says "Portishead - Dummy.wav", the file is "PORTISHEAD - DUMMY.wav".
        FileManager.default.createFile(atPath: dir.appendingPathComponent("PORTISHEAD - DUMMY.wav").path, contents: Data([0]))
        try sheet.write(to: dir.appendingPathComponent("Dummy.cue"), atomically: true, encoding: .utf8)
        let tracks = FolderScanner.scan([dir])
        XCTAssertEqual(tracks.map(\.title), ["Mysterons", "Sour Times", "Strangers"], "no whole-file row next to the splits")
        XCTAssertEqual(tracks.first.map { ($0.path as NSString).lastPathComponent }, "PORTISHEAD - DUMMY.wav")
    }

    func testSavedPlaylistKeepsCueTracks() throws {
        FileManager.default.createFile(atPath: dir.appendingPathComponent("Portishead - Dummy.flac").path, contents: Data([0]))
        try sheet.write(to: dir.appendingPathComponent("Dummy.cue"), atomically: true, encoding: .utf8)
        let tracks = FolderScanner.scan([dir])
        let m3u = dir.appendingPathComponent("list.m3u")
        try PlaylistFile.writeM3U([tracks[2], tracks[0]], to: m3u)
        let back = FolderScanner.scan([m3u])
        XCTAssertEqual(back.map(\.title), ["Strangers", "Mysterons"], "the splits, in playlist order")
        XCTAssertEqual(back.map(\.key), [tracks[2].key, tracks[0].key])
        XCTAssertEqual(back[1].cueEnd, 302)

        // Without the sheet: rebuilt from the saved range and title.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Dummy.cue"))
        let bare = FolderScanner.scan([m3u])
        XCTAssertEqual(bare.map(\.cueStart), [tracks[2].cueStart, 0])
        XCTAssertEqual(bare[1].cueEnd, 302)
        XCTAssertEqual(bare[1].cueNumber, 1)
    }

    func testDuplicatesKeepCueTracks() {
        setenv("OMNIAMP_CACHE_DIR", dir.path, 1)
        defer { unsetenv("OMNIAMP_CACHE_DIR") }
        let c = PlayerController()
        var a = Track(path: "/album.flac", size: 1, mtime: 0); a.cueStart = 0; a.tagsLoaded = true
        var b = a; b.cueStart = 120
        c.store.restore([a, b, a])
        XCTAssertEqual(c.removeDuplicates(), 1)
        XCTAssertEqual(c.tracks.map(\.cueStart), [0, 120])
    }
}
