import XCTest
@testable import OmniAmp

/// Crafted, broken files: the readers must return what they can and never trap.
final class MalformedFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ bytes: [UInt8]) -> String {
        let url = dir.appendingPathComponent(name)
        try? Data(bytes).write(to: url)
        return url.path
    }

    private func read(_ name: String, _ bytes: [UInt8]) -> TagInfo {
        TagReader.read(path: write(name, bytes), fileSize: Int64(bytes.count))
    }

    private func be32(_ n: Int) -> [UInt8] { [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }
    private func le32(_ n: Int) -> [UInt8] { be32(n).reversed() }
    private func atom(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(body.count + 8) + Array(type.utf8) + body }
    private let ftyp: [UInt8] = [0, 0, 0, 16] + Array("ftypM4A ".utf8) + [0, 0, 0, 0]

    func testMP4HugeTopLevelLength() {
        // 64-bit size near Int64.max right after ftyp: skipping it must not overflow.
        let huge: [UInt8] = [0, 0, 0, 1] + Array("free".utf8) + [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0]
        _ = read("a.m4a", ftyp + huge + [UInt8](repeating: 0, count: 32))
        _ = DetailsReader.read(path: write("d.m4a", ftyp + huge + [UInt8](repeating: 0, count: 32)))
    }

    func testMP4HugeInnerLength() {
        let inner: [UInt8] = [0, 0, 0, 1] + Array("trak".utf8) + [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        _ = read("b.m4a", ftyp + atom("moov", atom("free", [0, 0]) + inner))
    }

    func testASFHugeObjectSize() {
        // Header object (size 4 KB, 1 child), then a child whose 64-bit size is near Int64.max.
        let size = le32(4096) + le32(0), one = le32(1) + [1, 2]
        let child = [UInt8](repeating: 0x11, count: 16) + [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]
        _ = read("h.wma", ContainerTags.asfHeader + size + one + child + [UInt8](repeating: 0, count: 64))
    }

    func testMP4EmptyMdhdAndShortFreeformName() {
        let freeform = atom("----", atom("mean", []) + [0, 0, 0, 10] + Array("name".utf8) + [0, 0])
        let moov = atom("moov", atom("trak", atom("mdia", atom("mdhd", []))) + atom("udta", atom("ilst", freeform)))
        _ = read("c.m4a", ftyp + moov)
    }

    func testMP4GenreZero() {
        let data = atom("data", [0, 0, 0, 0, 0, 0, 0, 0] + [0, 0])
        let moov = atom("moov", atom("udta", atom("meta", [0, 0, 0, 0] + atom("ilst", atom("gnre", data)))))
        let d = DetailsReader.read(path: write("g.m4a", ftyp + moov))
        XCTAssertNil(d.genre)
    }

    func testRF64HugeDataSize() {
        var b: [UInt8] = Array("RF64".utf8) + [0xFF, 0xFF, 0xFF, 0xFF] + Array("WAVE".utf8)
        b += Array("ds64".utf8) + le32(28) + [UInt8](repeating: 0, count: 8)
            + [0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F] + [UInt8](repeating: 0, count: 12)
        b += Array("fmt ".utf8) + le32(16) + [1, 0, 2, 0] + le32(44100) + le32(176_400) + [4, 0, 16, 0]
        b += Array("data".utf8) + [0xFF, 0xFF, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 64)
        b += Array("LIST".utf8) + le32(4) + Array("INFO".utf8)
        let i = read("r.wav", b)
        XCTAssertEqual(i.sampleRate, 44100)
    }

    func testAIFFInfiniteSampleRate() {
        let comm: [UInt8] = [0, 2, 0, 0, 0, 100, 0, 16] + [0x7F, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0]
        let body = Array("AIFF".utf8) + Array("COMM".utf8) + be32(18) + comm
        let i = read("i.aiff", Array("FORM".utf8) + be32(body.count) + body)
        XCTAssertNil(i.sampleRate)
    }

    func testZipCentralDirectoryPastEnd() {
        // A central record signature 4 bytes before EOCD: its 46-byte header runs past the end.
        let eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 1, 0, 1, 0, 46, 0, 0, 0] + le32(8) + [0, 0]
        let head: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0x50, 0x4B, 0x01, 0x02]
        XCTAssertThrowsError(try ZipArchive(data: Data(head + eocd)))
    }
}

/// Lengths and times from damaged or crafted sources must never reach an Int conversion unchecked.
final class AbsurdDurationTests: XCTestCase {
    func testTimeFormattingNeverTraps() {
        for v in [1e19, 1e300, Double.infinity, -Double.infinity, Double.nan, -5, 9.22e18] {
            _ = TimeFormat.mmss(v)
            _ = Sane.int(v)
        }
        XCTAssertEqual(TimeFormat.mmss(1e19), "")
        XCTAssertEqual(TimeFormat.mmss(3723), "1:02:03")
        XCTAssertNil(Sane.kbps(bytes: 1_000_000, seconds: 1e-300), "a tiny length doesn't make an absurd bitrate")
        XCTAssertEqual(Sane.kbps(bytes: 1_000_000, seconds: 8), 1000)
    }

    func testMP3LengthTagIsChecked() {
        func frame(_ id: String, _ text: String) -> [UInt8] {
            let body: [UInt8] = [3] + Array(text.utf8)
            return Array(id.utf8) + [0, 0, 0, UInt8(body.count), 0, 0] + body
        }
        let frames = frame("TIT2", "Huge") + frame("TLEN", "1e25")
        let n = frames.count
        let bytes: [UInt8] = Array("ID3".utf8) + [3, 0, 0, 0, 0, UInt8(n >> 7), UInt8(n & 0x7F)] + frames
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tlen-\(UUID().uuidString).mp3")
        try? Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let info = TagReader.read(path: url.path, fileSize: Int64(bytes.count))
        XCTAssertEqual(info.title, "Huge")
        XCTAssertNil(info.duration, "1e25 ms isn't a length")
    }

    func testCueAndPlaylistTimesAreChecked() throws {
        XCTAssertNil(CueSheet.time("inf:00:00"))
        XCTAssertNil(CueSheet.time("-5:00:00"))
        XCTAssertEqual(CueSheet.time("01:02:00"), 62)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("absurd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m3u = dir.appendingPathComponent("x.m3u")
        try """
        #EXTM3U
        #EXTINF:1e30 omniamp-podcast="Show",Show - Episode
        https://example.com/e.mp3
        #EXTINF:5 omniamp-cue="inf,1e40,1",Split
        /music/album.flac
        """.write(to: m3u, atomically: true, encoding: .utf8)
        let e = PlaylistFile.entries(m3u)
        XCTAssertNil(e[0].seconds)
        XCTAssertNil(e[1].cueStart)
        XCTAssertNil(e[1].cueEnd)

        var t = Track.episode("https://example.com/e.mp3", title: "E", show: "S", artwork: nil, duration: 1e30, published: nil, summary: nil)
        t.duration = .infinity
        XCTAssertNoThrow(try PlaylistFile.writeM3U([t], to: dir.appendingPathComponent("out.m3u")), "writing doesn't trap")
        XCTAssertNil(PodcastFeedParser.duration("99999999999:00:00"))
    }
}

final class NestedBoxTests: XCTestCase {
    func testDeeplyNestedMP4DoesNotOverflowTheStack() throws {
        func be32(_ n: Int) -> [UInt8] { [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }
        let depth = 200_000   // 1.6 MB of boxes inside boxes: overflows any stack without a depth limit
        var inner = [UInt8]()
        inner.reserveCapacity(depth * 8)
        for i in 0..<depth { inner += be32(8 * (depth - i)) + Array("udta".utf8) }
        let moov = be32(inner.count + 8) + Array("moov".utf8) + inner
        let file = [0, 0, 0, 16] + Array("ftypM4A ".utf8) + [0, 0, 0, 0] + moov
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nested-\(UUID().uuidString).m4a")
        try Data(file).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = TagReader.read(path: url.path, fileSize: Int64(file.count))
        _ = DetailsReader.read(path: url.path)
    }
}
