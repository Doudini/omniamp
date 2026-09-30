import XCTest
@testable import OmniAmp

@MainActor
final class PlaylistEditingTests: XCTestCase {
    private var cacheDir: URL!

    override func setUp() {
        // Keep the controller away from the real playlist cache.
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-edit-\(UUID().uuidString)")
        setenv("OMNIAMP_CACHE_DIR", cacheDir.path, 1)
    }

    override func tearDown() {
        unsetenv("OMNIAMP_CACHE_DIR")
        try? FileManager.default.removeItem(at: cacheDir)
    }

    private func track(_ name: String, artist: String? = nil, duration: Double? = nil) -> Track {
        var t = Track(path: "/nonexistent/\(name).mp3", size: 1, mtime: 0)
        t.title = name
        t.artist = artist
        t.duration = duration
        t.tagsLoaded = true
        return t
    }

    private func names(_ s: PlaylistStore) -> [String] { s.tracks.map { $0.title ?? "" } }

    func testGroupedInsertInOnePass() {
        let s = PlaylistStore()
        s.restore(["a", "b", "c"].map { track($0) })
        let ids = (0..<3).map { s.id(at: $0) }
        s.insert(groups: [(at: 3, tracks: [track("end")]), (at: 1, tracks: [track("x"), track("y")]),
                          (at: 3, tracks: [track("end2")]), (at: 0, tracks: [])])
        XCTAssertEqual(names(s), ["a", "x", "y", "b", "c", "end", "end2"], "each group at its place, same-place groups in order")
        XCTAssertEqual([0, 3, 4].map { s.id(at: $0) }, ids, "existing rows keep their IDs")
        XCTAssertEqual(Set((0..<7).map { s.id(at: $0) }).count, 7)
    }

    func testStoreMoveDown() {
        let s = PlaylistStore()
        s.restore(["a", "b", "c", "d", "e"].map { track($0) })
        let moved = s.move([0, 1], to: 4)            // a,b before e
        XCTAssertEqual(names(s), ["c", "d", "a", "b", "e"])
        XCTAssertEqual(moved, IndexSet(2...3))
    }

    func testStoreMoveUpNonContiguous() {
        let s = PlaylistStore()
        s.restore(["a", "b", "c", "d", "e"].map { track($0) })
        let moved = s.move([2, 4], to: 0)
        XCTAssertEqual(names(s), ["c", "e", "a", "b", "d"])
        XCTAssertEqual(moved, IndexSet(0...1))
    }

    func testIDsSurviveMoves() {
        let s = PlaylistStore()
        s.restore(["a", "b", "c"].map { track($0) })
        let idC = s.id(at: 2)
        s.move([2], to: 0)
        XCTAssertEqual(s.index(ofID: idC), 0)
        s.remove(at: [1])
        XCTAssertEqual(s.index(ofID: idC), 0)
    }

    func testFilterNarrowsAsYouTypeAndFollowsChanges() {
        let c = PlayerController()
        c.store.restore([track("Alpha", artist: "Band"), track("Alpine", artist: "Other"), track("Beta", artist: "Band")])
        func shown() -> [String] { (0..<c.rowCount).map { c.tracks[c.trackIndex(forRow: $0)].title ?? "" } }
        c.setFilter("al")
        XCTAssertEqual(shown(), ["Alpha", "Alpine"])
        c.setFilter("alp band")
        XCTAssertEqual(shown(), ["Alpha"], "typing on narrows (words in any order)")
        c.setFilter("a")
        XCTAssertEqual(shown(), ["Alpha", "Alpine", "Beta"], "deleting widens again")
        c.store.restore(c.tracks.enumerated().map { i, x in var x = x; if i == 2 { x.title = "Gamma" }; return x })
        c.setFilter("gam")
        XCTAssertEqual(shown(), ["Gamma"], "rows replaced: the search text is rebuilt")
        c.store.insert([track("Gamma two")], at: 0)
        XCTAssertEqual(shown(), ["Gamma two", "Gamma"], "added rows are filtered too")
        c.setFilter("")
        XCTAssertEqual(c.rowCount, 4)
    }

    func testQueueFollowsTracksThroughReorder() {
        let c = PlayerController()
        c.store.restore(["a", "b", "c", "d"].map { track($0) })
        c.toggleQueue(trackIndices: [3])
        c.toggleQueue(trackIndices: [1])
        XCTAssertEqual(c.queuePosition(of: 3), 1)
        XCTAssertEqual(c.queuePosition(of: 1), 2)
        c.reverse()                                   // d c b a
        XCTAssertEqual(c.queuePosition(of: 0), 1)     // d still first in queue
        XCTAssertEqual(c.queuePosition(of: 2), 2)     // b second
        c.toggleQueue(trackIndices: [0])              // unqueue d
        XCTAssertEqual(c.queuePosition(of: 2), 1)
        XCTAssertNil(c.queuePosition(of: 0))
    }

    func testShiftClampsAtEdges() {
        let c = PlayerController()
        c.store.restore(["a", "b", "c"].map { track($0) })
        XCTAssertEqual(c.shift(trackIndices: [0], by: -1), [0])  // already at top
        XCTAssertEqual(c.shift(trackIndices: [0], by: 5), [2])   // clamps to bottom
        XCTAssertEqual(names(c.store), ["b", "c", "a"])
    }

    func testSortByArtistPutsUnknownLast() {
        let c = PlayerController()
        c.store.restore([track("x"), track("y", artist: "Zappa"), track("z", artist: "ABBA")])
        c.sort(by: .artist)
        XCTAssertEqual(names(c.store), ["z", "y", "x"])
        c.sort(by: .title)
        XCTAssertEqual(names(c.store), ["x", "y", "z"])
    }

    func testSortByDuration() {
        let c = PlayerController()
        c.store.restore([track("long", duration: 300), track("none"), track("short", duration: 60)])
        c.sort(by: .duration)
        XCTAssertEqual(names(c.store), ["short", "long", "none"])
    }
}

@MainActor
final class UnplayableLoopTests: XCTestCase {
    func testAPlaylistOfMissingFilesStopsAfterOneRound() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-unplayable-\(UUID().uuidString)")
        setenv("OMNIAMP_CACHE_DIR", dir.path, 1)
        defer { unsetenv("OMNIAMP_CACHE_DIR"); try? FileManager.default.removeItem(at: dir) }
        let c = PlayerController()
        c.store.restore((0..<3).map { var t = Track(path: "/Volumes/Gone-\(UUID().uuidString)/\($0).mp3", size: 1, mtime: 0); t.tagsLoaded = true; return t })
        if !c.repeatAll { c.toggleRepeat() }
        c.play(index: 0)
        let settled = expectation(description: "stops")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertEqual(c.player.state, .stopped)
        XCTAssertNotNil(c.playbackProblem, "says why")
        XCTAssertTrue(c.statusText.hasPrefix("Stopped"))
    }
}

final class PausedSeekTests: XCTestCase {
    @MainActor   // AudioPlayer is main-thread only (XCTest runs synchronous tests there anyway)
    func testSeekingWhilePausedStaysPaused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-seek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("OMNIAMP_CACHE_DIR", dir.path, 1)
        setenv("OMNIAMP_VOLUME", "0", 1)
        defer { unsetenv("OMNIAMP_CACHE_DIR"); unsetenv("OMNIAMP_VOLUME"); try? FileManager.default.removeItem(at: dir) }
        // 10 s of silence, 44.1 kHz mono 16-bit.
        let sr = 44_100, n = sr * 10
        var wav = Data("RIFF".utf8)
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        wav += le32(36 + n * 2) + Data("WAVEfmt ".utf8) + le32(16) + [1, 0, 1, 0] + le32(sr) + le32(sr * 2) + [2, 0, 16, 0]
        wav += Data("data".utf8) + le32(n * 2) + Data(count: n * 2)
        let file = dir.appendingPathComponent("silence.wav")
        try wav.write(to: file)

        let p = AudioPlayer()
        var ok = false
        let opened = expectation(description: "opened")
        p.play(url: file) { ok = $0; opened.fulfill() }   // files open in the background
        wait(for: [opened], timeout: 5)
        guard ok else { throw XCTSkip("no audio output here") }
        p.pause()
        var states: [AudioPlayer.State] = []
        p.onStateChange = { states.append(p.state) }
        p.seek(to: 5)
        XCTAssertEqual(p.state, .paused)
        XCTAssertTrue(states.isEmpty, "no playing → paused flicker")
        XCTAssertEqual(p.currentTime, 5, accuracy: 0.05)
        p.resume()
        XCTAssertEqual(p.state, .playing)
        XCTAssertEqual(p.currentTime, 5, accuracy: 0.2, "resumes from the new place")
        p.stop()
    }
}
