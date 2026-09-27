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
