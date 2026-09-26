import XCTest
@testable import OmniAmp

/// Real files produced by afconvert, checked for format, duration and tags.
final class FormatTests: XCTestCase {
    private var dir: URL!
    private var source: URL!   // 1.5 s, 24-bit / 96 kHz stereo WAV

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-fmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = dir.appendingPathComponent("src.wav")
        try Self.wav24(seconds: 1.5, rate: 96000, info: ["INAM": "Wave Title", "IART": "Wave Artist"]).write(to: source)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func info(_ url: URL) -> TagInfo {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return TagReader.read(path: url.path, fileSize: size ?? 0)
    }

    private func convert(_ name: String, _ args: [String]) throws -> URL {
        let out = dir.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = args + [source.path, out.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "afconvert \(args) failed")
        return out
    }

    func testWAVWithInfoChunk() {
        let i = info(source)
        XCTAssertEqual(i.sampleRate, 96000)
        XCTAssertEqual(i.bitDepth, 24)
        XCTAssertEqual(i.duration ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(i.bitrate, 4608)
        XCTAssertEqual(i.title, "Wave Title")
        XCTAssertEqual(i.artist, "Wave Artist")
    }

    func testAIFF() throws {
        let i = info(try convert("t.aiff", ["-f", "AIFF", "-d", "BEI24"]))
        XCTAssertEqual(i.sampleRate, 96000)
        XCTAssertEqual(i.bitDepth, 24)
        XCTAssertEqual(i.duration ?? 0, 1.5, accuracy: 0.001)
    }

    func testALAC() throws {
        let i = info(try convert("t.m4a", ["-f", "m4af", "-d", "alac"]))
        XCTAssertEqual(i.sampleRate, 96000)
        XCTAssertEqual(i.bitDepth, 24)
        XCTAssertEqual(i.duration ?? 0, 1.5, accuracy: 0.02)
    }

    func testAAC() throws {
        let i = info(try convert("t-aac.m4a", ["-f", "m4af", "-d", "aac@48000"]))
        XCTAssertEqual(i.sampleRate, 48000)
        XCTAssertNil(i.bitDepth)
        XCTAssertEqual(i.duration ?? 0, 1.5, accuracy: 0.05)
        XCTAssertNotNil(i.bitrate)
    }

    func testCAFFallsBackToCoreAudio() throws {
        let i = info(try convert("t.caf", ["-f", "caff", "-d", "LEI24"]))
        XCTAssertEqual(i.sampleRate, 96000)
        XCTAssertEqual(i.duration ?? 0, 1.5, accuracy: 0.001)
    }

    func testMP4Tags() {
        // moov › udta › meta › ilst › ©nam/©ART/©alb › data
        func atom(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let n = body.count + 8
            return [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + Array(type.utf8) + body
        }
        func item(_ type: [UInt8], _ text: String) -> [UInt8] {
            let data = atom("data", [0, 0, 0, 1, 0, 0, 0, 0] + Array(text.utf8))
            let n = data.count + 8
            return [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + type + data
        }
        let ilst = atom("ilst", item([0xA9] + Array("nam".utf8), "Song") + item([0xA9] + Array("ART".utf8), "Band")
                        + item([0xA9] + Array("alb".utf8), "Record"))
        let moov = atom("moov", atom("udta", atom("meta", [0, 0, 0, 0] + ilst)))
        let file = atom("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0]) + moov
        let url = dir.appendingPathComponent("tags.m4a")
        try? Data(file).write(to: url)
        let i = info(url)
        XCTAssertEqual(i.title, "Song")
        XCTAssertEqual(i.artist, "Band")
        XCTAssertEqual(i.album, "Record")
    }

    func testExtended80() {
        // 44100 Hz as an 80-bit extended float.
        XCTAssertEqual(ContainerTags.extended80([0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]), 44100)
    }

    /// Minimal 24-bit PCM WAV with a LIST/INFO chunk after the data (as many taggers write it).
    static func wav24(seconds: Double, rate: Int, info: [String: String]) -> Data {
        let frames = Int(Double(rate) * seconds), ch = 2
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var pcm = [UInt8]()
        pcm.reserveCapacity(frames * ch * 3)
        for i in 0..<frames {
            let v = Int(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 0x3FFFFF)
            for _ in 0..<ch { pcm += le(v & 0xFFFFFF, 3) }
        }
        var list = Array("INFO".utf8)
        for (k, v) in info.sorted(by: { $0.key < $1.key }) {
            var t = Array(v.utf8) + [0]
            if t.count % 2 == 1 { t.append(0) }
            list += Array(k.utf8) + le(t.count, 4) + t
        }
        let fmt = le(1, 2) + le(ch, 2) + le(rate, 4) + le(rate * ch * 3, 4) + le(ch * 3, 2) + le(24, 2)
        var body = Array("WAVE".utf8)
        body += Array("fmt ".utf8) + le(fmt.count, 4) + fmt
        body += Array("data".utf8) + le(pcm.count, 4) + pcm
        body += Array("LIST".utf8) + le(list.count, 4) + list
        return Data(Array("RIFF".utf8) + le(body.count, 4) + body)
    }
}
