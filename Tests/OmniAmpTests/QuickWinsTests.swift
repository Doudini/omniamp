import XCTest
@testable import OmniAmp

final class QuickWinsTests: XCTestCase {
    private var cacheDir: URL!

    override func setUp() {
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-qw-\(UUID().uuidString)")
        setenv("OMNIAMP_CACHE_DIR", cacheDir.path, 1)
        UserDefaults.standard.removeObject(forKey: "replayGain")
    }

    override func tearDown() {
        unsetenv("OMNIAMP_CACHE_DIR")
        UserDefaults.standard.removeObject(forKey: "replayGain")
        try? FileManager.default.removeItem(at: cacheDir)
    }

    // MARK: ReplayGain tags

    func testVorbisReplayGain() {
        func le(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)] }
        let tags = ["REPLAYGAIN_TRACK_GAIN=-7.25 dB", "replaygain_album_gain=-6.50 dB", "REPLAYGAIN_TRACK_PEAK=0.988", "REPLAYGAIN_ALBUM_PEAK=1.000"]
        var vc = le(1) + [0x61] + le(tags.count)
        for t in tags { vc += le(t.utf8.count) + Array(t.utf8) }
        var b: [UInt8] = Array("fLaC".utf8) + [0x00, 0, 0, 34] + [UInt8](repeating: 0, count: 34)
        b += [0x84, UInt8(vc.count >> 16), UInt8((vc.count >> 8) & 0xFF), UInt8(vc.count & 0xFF)] + vc
        let i = TagReader.parseFLAC(b)
        XCTAssertEqual(i.rgTrackGain ?? 0, -7.25, accuracy: 0.001)
        XCTAssertEqual(i.rgAlbumGain ?? 0, -6.5, accuracy: 0.001)
        XCTAssertEqual(i.rgTrackPeak ?? 0, 0.988, accuracy: 0.001)
        XCTAssertEqual(i.rgAlbumPeak ?? 0, 1.0, accuracy: 0.001)
    }

    func testID3TXXXReplayGain() {
        func synchsafe(_ n: Int) -> [UInt8] { [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)] }
        func txxx(_ d: String, _ v: String) -> [UInt8] {
            let body: [UInt8] = [0] + Array(d.utf8) + [0] + Array(v.utf8)
            return Array("TXXX".utf8) + [0, 0, 0, UInt8(body.count)] + [0, 0] + body
        }
        let frames = txxx("REPLAYGAIN_TRACK_GAIN", "+2.10 dB") + txxx("replaygain_album_peak", "0.75")
        let tag = Array("ID3".utf8) + [3, 0, 0] + synchsafe(frames.count) + frames
        let i = TagReader.parseMP3(tag, fileSize: Int64(tag.count))
        XCTAssertEqual(i.rgTrackGain ?? 0, 2.1, accuracy: 0.001)
        XCTAssertEqual(i.rgAlbumPeak ?? 0, 0.75, accuracy: 0.001)
    }

    // MARK: Gain math

    private func track(gain: Float?, peak: Float?, album: Float? = nil) -> Track {
        var t = Track(path: "/x.flac", size: 1, mtime: 0)
        t.rgTrackGain = gain; t.rgTrackPeak = peak; t.rgAlbumGain = album
        return t
    }

    func testReplayGainFactor() {
        let c = PlayerController()
        c.replayGainMode = .off
        XCTAssertEqual(c.replayGainFactor(for: track(gain: -6.02, peak: 0.5)), 1)
        c.replayGainMode = .track
        XCTAssertEqual(c.replayGainFactor(for: track(gain: -6.02, peak: 0.5)), 0.5, accuracy: 0.001)
        // +6 dB on a track peaking at 0.9 would clip → limited to 1/0.9.
        XCTAssertEqual(c.replayGainFactor(for: track(gain: 6.02, peak: 0.9)), 1 / 0.9, accuracy: 0.001)
        // Album mode falls back to the track gain when there is no album gain.
        c.replayGainMode = .album
        XCTAssertEqual(c.replayGainFactor(for: track(gain: -6.02, peak: nil)), 0.5, accuracy: 0.001)
        XCTAssertEqual(c.replayGainFactor(for: track(gain: -6.02, peak: nil, album: 0)), 1, accuracy: 0.001)
        XCTAssertEqual(c.replayGainFactor(for: track(gain: nil, peak: nil)), 1)
    }

    // MARK: Duplicates

    func testRemoveDuplicatesKeepsFirst() {
        let c = PlayerController()
        let paths = ["/a.mp3", "/b.mp3", "/a.mp3", "/c.mp3", "/b.mp3"]
        c.store.restore(paths.map { var t = Track(path: $0, size: 1, mtime: 0); t.tagsLoaded = true; return t })
        XCTAssertEqual(c.removeDuplicates(), 2)
        XCTAssertEqual(c.tracks.map(\.path), ["/a.mp3", "/b.mp3", "/c.mp3"])
    }

    // MARK: Visualizer modes

    func testAnalyzerCyclesThroughModes() {
        let saved = UserDefaults.standard.string(forKey: "analyzerMode")
        defer { UserDefaults.standard.set(saved, forKey: "analyzerMode") }
        Analyzer.mode = .spectrum
        Analyzer.toggle(); XCTAssertEqual(Analyzer.mode, .oscilloscope)
        Analyzer.toggle(); XCTAssertEqual(Analyzer.mode, .off)
        Analyzer.toggle(); XCTAssertEqual(Analyzer.mode, .spectrum)
    }
}
