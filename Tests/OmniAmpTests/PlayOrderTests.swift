import XCTest
@testable import OmniAmp

/// Which track comes next: order, filter, queue, repeat, shuffle and history. (The tracks don't exist, so
/// nothing reaches the audio device; the controller still moves to the track it chose.)
@MainActor
final class PlayOrderTests: XCTestCase {
    private var cacheDir: URL!

    override func setUp() {
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-order-\(UUID().uuidString)")
        setenv("OMNIAMP_CACHE_DIR", cacheDir.path, 1)
    }

    override func tearDown() {
        unsetenv("OMNIAMP_CACHE_DIR")
        try? FileManager.default.removeItem(at: cacheDir)
    }

    private func controller(_ n: Int) -> PlayerController {
        let c = PlayerController()
        c.store.restore((0..<n).map { i in
            var t = Track(path: "/nonexistent/order/\(i).mp3", size: 1, mtime: 0)
            t.title = "t\(i)"
            t.tagsLoaded = true
            return t
        })
        return c
    }

    func testPlaylistOrderAndRepeat() {
        let c = controller(3)
        c.play(index: 0)
        c.next(); XCTAssertEqual(c.currentIndex, 1)
        c.next(); XCTAssertEqual(c.currentIndex, 2)
        XCTAssertTrue(c.repeatAll)
        c.next(); XCTAssertEqual(c.currentIndex, 0, "repeat: back to the top")
        c.toggleRepeat()
        c.play(index: 2)
        c.next(); XCTAssertEqual(c.currentIndex, 2, "no repeat: the end stays the end")
    }

    func testFilterDecidesTheOrder() {
        let c = controller(6)
        c.setFilter("t")   // everything
        c.play(index: 1)
        c.setFilter("t4")
        c.next(); XCTAssertEqual(c.currentIndex, 4, "the next visible track")
        c.setFilter("")
        c.next(); XCTAssertEqual(c.currentIndex, 5)
    }

    func testQueueComesFirstThenTheOrderGoesOnFromThere() {
        let c = controller(6)
        c.play(index: 0)
        c.toggleQueue(trackIndices: [4])
        c.toggleQueue(trackIndices: [2])
        c.next(); XCTAssertEqual(c.currentIndex, 4, "queued first, in queue order")
        c.next(); XCTAssertEqual(c.currentIndex, 2)
        XCTAssertTrue(c.playQueue.isEmpty)
        c.next(); XCTAssertEqual(c.currentIndex, 3, "then on from where it is")
    }

    func testShuffleNeverRepeatsTheCurrentTrackAndPreviousRetraces() {
        let c = controller(8)
        c.toggleShuffle()
        c.setFilter("t")   // shuffle within the view
        c.play(index: 0)
        var played = [0]
        for _ in 0..<20 {
            let before = c.currentIndex
            c.next()
            XCTAssertNotEqual(c.currentIndex, before)
            played.append(c.currentIndex!)
        }
        // Previous walks back through what actually played.
        for expected in played.dropLast().suffix(5).reversed() {
            c.previous()
            XCTAssertEqual(c.currentIndex, expected)
        }
    }

    func testRemovingTheCurrentTrackKeepsTheRestOfTheOrder() {
        let c = controller(5)
        c.play(index: 2)
        c.remove(trackIndices: [0])
        XCTAssertEqual(c.currentTrack?.title, "t2", "still the same track after rows above it went")
        c.next(); XCTAssertEqual(c.currentTrack?.title, "t3")
    }
}
