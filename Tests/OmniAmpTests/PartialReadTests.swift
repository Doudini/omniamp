import XCTest
@testable import OmniAmp

/// Tags past the 32 KB head (big cover art first) are still read, with the art skipped.
final class PartialReadTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func syncsafe(_ n: Int) -> [UInt8] { [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)] }
    private func be32(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] }

    private func id3Frame(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + be32(body.count) + [0, 0] + body }
    private func text(_ id: String, _ s: String) -> [UInt8] { id3Frame(id, [0] + Array(s.utf8)) }

    /// ID3v2.3 tag (optionally with a big APIC first) followed by 500 CBR frames (MPEG1 L3, 128 kbps, 44.1 kHz).
    private func mp3(art: Int) -> [UInt8] {
        var frames: [UInt8] = []
        if art > 0 { frames += id3Frame("APIC", [0] + Array("image/jpeg".utf8) + [0, 3, 0] + [UInt8](repeating: 0xAB, count: art)) }
        frames += text("TIT2", "Big Art Song") + text("TPE1", "The Band") + text("TALB", "The Album")
        var file: [UInt8] = Array("ID3".utf8) + [3, 0, 0] + syncsafe(frames.count) + frames
        let frameBytes = 144 * 128_000 / 44_100   // 417
        for _ in 0..<500 { file += [0xFF, 0xFB, 0x90, 0x64] + [UInt8](repeating: 0, count: frameBytes - 4) }
        return file
    }

    private func read(_ bytes: [UInt8], _ name: String) throws -> TagInfo {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return TagReader.read(path: url.path, fileSize: Int64(bytes.count))
    }

    func testMP3WithBigArtBeforeTheText() throws {
        let plain = try read(mp3(art: 0), "plain.mp3")
        let art = try read(mp3(art: 200_000), "art.mp3")
        XCTAssertEqual(plain.title, "Big Art Song")
        XCTAssertEqual(art.title, "Big Art Song", "text frames after 200 KB of art")
        XCTAssertEqual(art.artist, "The Band")
        XCTAssertEqual(art.album, "The Album")
        XCTAssertNotNil(plain.duration)
        XCTAssertEqual(art.duration ?? 0, plain.duration ?? -1, accuracy: 0.05, "the art isn't counted as audio")
        XCTAssertEqual(art.bitrate, plain.bitrate)
        XCTAssertEqual(art.sampleRate, 44_100)
    }

    /// fLaC + STREAMINFO + PICTURE (big) + VORBIS_COMMENT (last).
    private func flac(art: Int) -> [UInt8] {
        var si = [UInt8](repeating: 0, count: 34)
        // 44.1 kHz, 2 ch, 16 bit, 441,000 samples (10 s): 20 bits rate | 3 bits ch-1 | 5 bits bps-1 | 36 bits total.
        let rate = 44_100, total = 441_000
        si[10] = UInt8(rate >> 12 & 0xFF); si[11] = UInt8(rate >> 4 & 0xFF)
        si[12] = UInt8((rate & 0x0F) << 4) | (1 << 1) | 0   // channels-1 = 1, bps-1 high bit 0
        si[13] = UInt8(15 << 4) | UInt8(total >> 32 & 0x0F)
        si[14] = UInt8(total >> 24 & 0xFF); si[15] = UInt8(total >> 16 & 0xFF); si[16] = UInt8(total >> 8 & 0xFF); si[17] = UInt8(total & 0xFF)
        func le32(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)] }
        let comments = ["TITLE=Flac Song", "ARTIST=Flac Band"].map { Array($0.utf8) }
        var vc = le32(4) + Array("test".utf8) + le32(comments.count)
        for c in comments { vc += le32(c.count) + c }
        func block(_ type: UInt8, _ body: [UInt8], last: Bool) -> [UInt8] {
            [type | (last ? 0x80 : 0), UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
        }
        var out: [UInt8] = Array("fLaC".utf8) + block(0, si, last: false)
        if art > 0 { out += block(6, [UInt8](repeating: 0xCD, count: art), last: false) }
        out += block(4, vc, last: true)
        return out + [UInt8](repeating: 0, count: 1000)
    }

    func testFLACWithBigPictureBeforeTheComments() throws {
        let plain = try read(flac(art: 0), "plain.flac")
        let art = try read(flac(art: 200_000), "art.flac")
        XCTAssertEqual(plain.title, "Flac Song")
        XCTAssertEqual(art.title, "Flac Song", "comments after a 200 KB picture")
        XCTAssertEqual(art.artist, "Flac Band")
        XCTAssertEqual(art.duration ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(art.sampleRate, 44_100)
    }

    /// Folders stream out one at a time, files sorted inside each, subfolders after in name order.
    func testScannerStreamsFoldersInOrder() throws {
        let fm = FileManager.default
        for p in ["b.mp3", "a.mp3", "Disc 2/x.mp3", "Disc 10/y.mp3", "Disc 1/z.mp3", "notes.txt"] {
            let u = dir.appendingPathComponent(p)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: u)
        }
        var batches: [[String]] = []
        let marker = dir.lastPathComponent + "/"   // temp paths come back as /private/var/…, so cut at the folder name
        FolderScanner.scan([dir]) { batch in batches.append(batch.map { $0.path.components(separatedBy: marker).last ?? $0.path }) }
        XCTAssertEqual(batches, [["a.mp3", "b.mp3"], ["Disc 1/z.mp3"], ["Disc 2/x.mp3"], ["Disc 10/y.mp3"]])
    }
}
