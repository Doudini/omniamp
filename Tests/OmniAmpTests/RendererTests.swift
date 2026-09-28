import AVFoundation
import XCTest
@testable import OmniAmp

/// The file renderer, driven like the audio device would, without one: joins must be sample-exact.
final class RendererTests: XCTestCase {
    private var dir: URL!
    private let rate = 44_100.0

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-render-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A 16-bit stereo WAV whose every sample is distinct: left = seed + i, right = -(seed + i) (in 1/32768 steps).
    private func wav(_ name: String, frames: Int, seed: Int) throws -> URL {
        let url = dir.appendingPathComponent(name + ".wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            buf.int16ChannelData![0][i] = Int16(truncatingIfNeeded: (seed + i) % 30000)
            buf.int16ChannelData![1][i] = -Int16(truncatingIfNeeded: (seed + i) % 30000)
        }
        try f.write(from: buf)
        return url
    }

    /// What the file holds, as the renderer should play it (float).
    private func samples(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: b)
        return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
    }

    private func renderer() -> FileRenderer {
        FileRenderer(format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!)!
    }

    /// Pull `frames` frames through the render callback in device-sized pieces (left channel), letting the
    /// reader thread keep up in between.
    private func pull(_ r: FileRenderer, _ frames: Int, piece: Int = 512) -> [Float] {
        let buf = AVAudioPCMBuffer(pcmFormat: r.format, frameCapacity: AVAudioFrameCount(piece))!
        var out: [Float] = []
        var silent = ObjCBool(false)
        var ts = AudioTimeStamp()
        while out.count < frames {
            let n = min(piece, frames - out.count)
            buf.frameLength = AVAudioFrameCount(n)
            _ = r.renderBlock(&silent, &ts, AVAudioFrameCount(n), buf.mutableAudioBufferList)
            out += UnsafeBufferPointer(start: buf.floatChannelData![0], count: n)
            usleep(300)
        }
        return out
    }

    private func settle() { usleep(150_000) }   // the reader decodes ahead

    func testGaplessJoinIsSampleExact() throws {
        let a = try wav("a", frames: 20_000, seed: 1), b = try wav("b", frames: 15_000, seed: 5000)
        let r = renderer()
        defer { r.shutdown() }
        r.start(.init(id: 1, url: a, start: 0, end: 20_000, gain: 1))
        r.enqueue(.init(id: 2, url: b, start: 0, end: 15_000, gain: 1))
        settle()
        let out = pull(r, 36_000)
        let expected = try samples(a) + samples(b)
        XCTAssertEqual(Array(out.prefix(35_000)), expected, "A then B, every sample, nothing between")
        XCTAssertEqual(Array(out.suffix(1000)), [Float](repeating: 0, count: 1000), "silence after the end")
    }

    func testCueSlicesOfOneFileJoinExactly() throws {
        let f = try wav("album", frames: 30_000, seed: 7)
        let r = renderer()
        defer { r.shutdown() }
        r.start(.init(id: 1, url: f, start: 0, end: 12_345, gain: 1))
        r.enqueue(.init(id: 2, url: f, start: 12_345, end: 30_000, gain: 1))
        settle()
        XCTAssertEqual(pull(r, 30_000), try samples(f))
    }

    func testNextTrackLevelAppliesFromItsFirstSample() throws {
        let a = try wav("a", frames: 10_000, seed: 1), b = try wav("b", frames: 10_000, seed: 20_000)
        let r = renderer()
        defer { r.shutdown() }
        r.start(.init(id: 1, url: a, start: 0, end: 10_000, gain: 1))
        r.enqueue(.init(id: 2, url: b, start: 0, end: 10_000, gain: 0.5))
        settle()
        let out = pull(r, 20_000)
        XCTAssertEqual(Array(out.prefix(10_000)), try samples(a), "untouched at 1.0 (bit-exact)")
        XCTAssertEqual(Array(out.suffix(10_000)), try samples(b).map { $0 * 0.5 }, "B at its own level from frame 0")
    }

    func testTakingBackTheQueuedTrackLeavesTheCurrentOneAlone() throws {
        let a = try wav("a", frames: 20_000, seed: 1), b = try wav("b", frames: 20_000, seed: 9000)
        let r = renderer()
        defer { r.shutdown() }
        r.start(.init(id: 1, url: a, start: 0, end: 20_000, gain: 1))
        r.enqueue(.init(id: 2, url: b, start: 0, end: 20_000, gain: 1))
        settle()
        var out = pull(r, 5_000)          // B is already decoded behind A in the ring
        r.cancelQueued()
        // Keep "playing" while the reader takes it back (it waits for two callbacks).
        let done = Date().addingTimeInterval(1)
        while out.count < 15_000 && Date() < done { out += pull(r, 500) }
        out += pull(r, 25_000 - out.count)
        XCTAssertEqual(Array(out.prefix(20_000)), try samples(a), "A played on without a gap or a jump")
        XCTAssertEqual(Array(out.suffix(5_000)), [Float](repeating: 0, count: 5_000), "nothing of B")
    }

    func testPositionCountsFramesAndSurvivesPauseAndSeek() throws {
        let a = try wav("a", frames: 20_000, seed: 1), b = try wav("b", frames: 20_000, seed: 3)
        let r = renderer()
        defer { r.shutdown() }
        r.start(.init(id: 1, url: a, start: 1_000, end: 20_000, gain: 1))   // resumed at frame 1000
        r.enqueue(.init(id: 2, url: b, start: 0, end: 20_000, gain: 1))
        settle()
        r.setPaused(true)
        XCTAssertEqual(r.position()?.frame, 1_000)
        XCTAssertEqual(pull(r, 2_000), [Float](repeating: 0, count: 2_000), "paused: silence, nothing consumed")
        XCTAssertEqual(r.position()?.frame, 1_000)
        r.setPaused(false)
        _ = pull(r, 21_000)
        r.setPaused(true)
        XCTAssertEqual(r.position()?.id, 2)
        XCTAssertEqual(r.position()?.frame, 2_000, "19000 of A, then 2000 of B")
        r.start(.init(id: 2, url: b, start: 10_000, end: 20_000, gain: 1))   // seek while paused
        XCTAssertEqual(r.position()?.frame, 10_000, "the new place at once")
        r.setPaused(false)
        settle()
        let out = pull(r, 100)
        XCTAssertEqual(out, Array(try samples(b)[10_000..<10_100]))
    }

    func testAdvanceAndEndAreReported() throws {
        let a = try wav("a", frames: 4_000, seed: 1), b = try wav("b", frames: 4_000, seed: 2)
        let r = renderer()
        defer { r.shutdown() }
        var advanced: [Int] = [], ended = 0
        r.onAdvance = { id, _ in advanced.append(id) }
        r.onEnd = { _ in ended += 1 }
        r.start(.init(id: 1, url: a, start: 0, end: 4_000, gain: 1))
        r.enqueue(.init(id: 2, url: b, start: 0, end: 4_000, gain: 1))
        settle()
        _ = pull(r, 10_000)
        let exp = expectation(description: "events")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(advanced, [2])
        XCTAssertEqual(ended, 1)
    }
}
