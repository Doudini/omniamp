import XCTest
@testable import OmniAmp

final class DetailsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-details-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let fakeJPEG: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x42, count: 60) + [0xFF, 0xD9]

    private func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    private func write(_ name: String, _ bytes: [UInt8]) -> String {
        let p = dir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: p, contents: Data(bytes))
        return p
    }

    func testFLACCommentsAndPicture() {
        let tags = ["TITLE=Song", "ALBUMARTIST=Various", "DATE=2003-04-05", "GENRE=Jazz", "TRACKNUMBER=3/12",
                    "DISCNUMBER=2", "DISCTOTAL=3", "COMPOSER=Monk", "COMMENT=hello"]
        var vc = le32(4) + Array("test".utf8) + le32(tags.count)
        for t in tags { vc += le32(t.utf8.count) + Array(t.utf8) }
        let mime = Array("image/jpeg".utf8)
        let pic = be32(3) + be32(mime.count) + mime + be32(0) + be32(10) + be32(10) + be32(24) + be32(0) + be32(fakeJPEG.count) + fakeJPEG
        var b: [UInt8] = Array("fLaC".utf8)
        b += [0x00, 0, 0, 34] + [UInt8](repeating: 0, count: 34)
        b += [0x04] + [UInt8(vc.count >> 16), UInt8((vc.count >> 8) & 0xFF), UInt8(vc.count & 0xFF)] + vc
        b += [0x86] + [UInt8(pic.count >> 16), UInt8((pic.count >> 8) & 0xFF), UInt8(pic.count & 0xFF)] + pic
        let d = DetailsReader.read(path: write("a.flac", b))
        XCTAssertEqual(d.title, "Song")
        XCTAssertEqual(d.albumArtist, "Various")
        XCTAssertEqual(d.year, "2003")
        XCTAssertEqual(d.genre, "Jazz")
        XCTAssertEqual(d.track, 3); XCTAssertEqual(d.trackTotal, 12)
        XCTAssertEqual(d.disc, 2); XCTAssertEqual(d.discTotal, 3)
        XCTAssertEqual(d.composer, "Monk")
        XCTAssertEqual(d.comment, "hello")
        XCTAssertEqual(d.artwork.map([UInt8].init), fakeJPEG)
        XCTAssertEqual(d.artworkSource, "embedded")
    }

    func testID3FramesAndAPIC() {
        func frame(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + be32(body.count) + [0, 0] + body }
        func text(_ s: String) -> [UInt8] { [3] + Array(s.utf8) }
        var frames = frame("TIT2", text("Track")) + frame("TPE2", text("Band")) + frame("TCON", text("(17)"))
        frames += frame("TRCK", text("7/10")) + frame("TYER", text("1997"))
        frames += frame("COMM", [3] + Array("eng".utf8) + [0] + Array("nice one".utf8))
        frames += frame("APIC", [0] + Array("image/jpeg".utf8) + [0, 3] + Array("cover".utf8) + [0] + fakeJPEG)
        let n = frames.count
        let tag: [UInt8] = Array("ID3".utf8) + [3, 0, 0] + [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)] + frames
        let d = DetailsReader.read(path: write("a.mp3", tag + [0xFF, 0xFB, 0x90, 0x00]))
        XCTAssertEqual(d.title, "Track")
        XCTAssertEqual(d.albumArtist, "Band")
        XCTAssertEqual(d.genre, "Rock")
        XCTAssertEqual(d.track, 7); XCTAssertEqual(d.trackTotal, 10)
        XCTAssertEqual(d.year, "1997")
        XCTAssertEqual(d.comment, "nice one")
        XCTAssertEqual(d.artwork.map([UInt8].init), fakeJPEG)
    }

    func testMP4NumbersAndCover() {
        func atom(_ type: [UInt8], _ body: [UInt8]) -> [UInt8] { be32(body.count + 8) + type + body }
        func item(_ type: String, _ flags: UInt8, _ value: [UInt8]) -> [UInt8] {
            atom(Array(type.unicodeScalars.map { UInt8($0.value) }), atom(Array("data".utf8), [0, 0, 0, flags, 0, 0, 0, 0] + value))
        }
        let ilst = atom(Array("ilst".utf8), item("trkn", 0, [0, 0, 0, 4, 0, 11, 0, 0]) + item("disk", 0, [0, 0, 0, 1, 0, 2])
                        + item("aART", 1, Array("Album Artist".utf8)) + item("\u{A9}day", 1, Array("2011-01-01".utf8))
                        + item("covr", 13, fakeJPEG))
        let moov = atom(Array("moov".utf8), atom(Array("udta".utf8), atom(Array("meta".utf8), [0, 0, 0, 0] + ilst)))
        let file = atom(Array("ftyp".utf8), Array("M4A ".utf8) + [0, 0, 0, 0]) + moov
        let d = DetailsReader.read(path: write("a.m4a", file))
        XCTAssertEqual(d.track, 4); XCTAssertEqual(d.trackTotal, 11)
        XCTAssertEqual(d.disc, 1); XCTAssertEqual(d.discTotal, 2)
        XCTAssertEqual(d.albumArtist, "Album Artist")
        XCTAssertEqual(d.year, "2011")
        XCTAssertEqual(d.artwork.map([UInt8].init), fakeJPEG)
    }

    func testFolderArtPrefersCoverNames() {
        let track = write("song.mp3", [0])
        _ = write("scan-back.jpg", fakeJPEG)
        _ = write("Folder.JPG", fakeJPEG)
        _ = write("cover.png", fakeJPEG)
        XCTAssertEqual(DetailsReader.folderArt(for: track)?.1, "cover.png")
    }

    func testFolderArtIgnoresUnrelatedImagesWhenSeveral() {
        let track = write("song.mp3", [0])
        _ = write("scan1.jpg", fakeJPEG)
        _ = write("scan2.jpg", fakeJPEG)
        XCTAssertNil(DetailsReader.folderArt(for: track))
    }
}
