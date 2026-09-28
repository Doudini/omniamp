import XCTest
@testable import OmniAmp

final class TagReaderTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func synchsafe(_ n: Int) -> [UInt8] {
        [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
    }

    private func frame23(_ id: String, _ text: String) -> [UInt8] {
        let body: [UInt8] = [3] + Array(text.utf8) // UTF-8 encoding byte
        let n = body.count
        return Array(id.utf8) + [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF), 0, 0] + body
    }

    func testID3v23WithCBRFrame() throws {
        var frames = frame23("TIT2", "Llama Song") + frame23("TPE1", "Nullsoft") + frame23("TALB", "Whipping")
        frames += [UInt8](repeating: 0, count: 16) // padding
        var bytes: [UInt8] = Array("ID3".utf8) + [3, 0, 0] + synchsafe(frames.count) + frames
        // MPEG1 Layer III, 128 kbps, 44.1 kHz, stereo: FF FB 90 00
        let audioStart = bytes.count
        let frameLen = 417
        for _ in 0..<100 { bytes += [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: frameLen - 4) }
        let info = TagReader.parseMP3(bytes, fileSize: Int64(bytes.count))
        XCTAssertEqual(info.title, "Llama Song")
        XCTAssertEqual(info.artist, "Nullsoft")
        XCTAssertEqual(info.album, "Whipping")
        XCTAssertEqual(info.bitrate, 128)
        XCTAssertEqual(info.sampleRate, 44100)
        let expected = Double(bytes.count - audioStart) * 8 / 128_000
        XCTAssertEqual(info.duration ?? 0, expected, accuracy: 0.01)
    }

    func testID3v24UTF16() throws {
        let text: [UInt8] = [1, 0xFF, 0xFE] + Array("Héllo".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [0, 0]
        let fr: [UInt8] = Array("TIT2".utf8) + synchsafe(text.count) + [0, 0] + text
        let bytes: [UInt8] = Array("ID3".utf8) + [4, 0, 0] + synchsafe(fr.count) + fr
        XCTAssertEqual(TagReader.parseMP3(bytes, fileSize: Int64(bytes.count)).title, "Héllo")
    }

    func testID3v1() {
        var b = [UInt8](repeating: 0, count: 128)
        b.replaceSubrange(0..<3, with: Array("TAG".utf8))
        b.replaceSubrange(3..<(3 + 5), with: Array("Title".utf8))
        b.replaceSubrange(33..<(33 + 6), with: Array("Artist".utf8))
        let info = TagReader.parseID3v1(b)
        XCTAssertEqual(info.title, "Title")
        XCTAssertEqual(info.artist, "Artist")
        XCTAssertNil(info.album)
    }

    func testXingVBR() {
        // MPEG1 L3 stereo frame header, then 32 bytes side info, then "Xing" with frames flag.
        var b: [UInt8] = [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 32)
        b += Array("Xing".utf8) + [0, 0, 0, 1] + [0, 0, 0x03, 0xE8] // 1000 frames
        b += [UInt8](repeating: 0, count: 400)
        let info = TagReader.parseMP3(b, fileSize: 5_000_000)
        XCTAssertEqual(info.duration ?? 0, 1000 * 1152 / 44100, accuracy: 0.001)
    }

    func testRealFLACFromAfconvert() throws {
        let aiff = tmp.appendingPathComponent("t.aiff")
        let flac = tmp.appendingPathComponent("t.flac")
        try run("/usr/bin/say", ["-o", aiff.path, "hello omni amp"])
        try run("/usr/bin/afconvert", ["-f", "flac", "-d", "flac", aiff.path, flac.path])
        let size = try FileManager.default.attributesOfItem(atPath: flac.path)[.size] as! Int64
        let info = TagReader.read(path: flac.path, fileSize: size)
        XCTAssertNotNil(info.sampleRate)
        XCTAssertGreaterThan(info.duration ?? 0, 0.3)
        XCTAssertLessThan(info.duration ?? 99, 5)
    }

    func testVorbisComments() {
        func le(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)] }
        let vendor = Array("test".utf8)
        let comments = ["TITLE=Song", "artist=Band", "ALBUM=Record"].map { Array($0.utf8) }
        var block = le(vendor.count) + vendor + le(comments.count)
        for c in comments { block += le(c.count) + c }
        var streaminfo = [UInt8](repeating: 0, count: 34)
        // 44100 Hz = 0x0AC44 → 20 bits at byte 10; total samples 441000 in low 36 bits of bytes 13..17
        streaminfo[10] = 0x0A; streaminfo[11] = 0xC4; streaminfo[12] = 0x42
        let total = 441_000
        streaminfo[14] = UInt8((total >> 24) & 0xFF); streaminfo[15] = UInt8((total >> 16) & 0xFF)
        streaminfo[16] = UInt8((total >> 8) & 0xFF); streaminfo[17] = UInt8(total & 0xFF)
        var b: [UInt8] = Array("fLaC".utf8)
        b += [0x00, 0, 0, 34] + streaminfo
        b += [0x84, UInt8(block.count >> 16), UInt8((block.count >> 8) & 0xFF), UInt8(block.count & 0xFF)] + block
        let info = TagReader.parseFLAC(b)
        XCTAssertEqual(info.title, "Song")
        XCTAssertEqual(info.artist, "Band")
        XCTAssertEqual(info.album, "Record")
        XCTAssertEqual(info.sampleRate, 44100)
        XCTAssertEqual(info.duration ?? 0, 10, accuracy: 0.001)
    }

    func testScannerFollowsSymlinksWithoutLooping() throws {
        let fm = FileManager.default
        let real = tmp.appendingPathComponent("real"), lib = tmp.appendingPathComponent("lib")
        try fm.createDirectory(at: real.appendingPathComponent("Album"), withIntermediateDirectories: true)
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)
        fm.createFile(atPath: real.appendingPathComponent("Album/1.mp3").path, contents: Data([0]))
        fm.createFile(atPath: real.appendingPathComponent("single.flac").path, contents: Data([0, 0]))
        try fm.createSymbolicLink(at: lib.appendingPathComponent("Album"), withDestinationURL: real.appendingPathComponent("Album"))
        try fm.createSymbolicLink(at: lib.appendingPathComponent("single.flac"), withDestinationURL: real.appendingPathComponent("single.flac"))
        try fm.createSymbolicLink(at: lib.appendingPathComponent("Album/loop"), withDestinationURL: lib)   // lib/Album/loop → lib
        let names = FolderScanner.scan([lib]).map { $0.path.components(separatedBy: "/lib/").last ?? "" }
        XCTAssertEqual(names, ["single.flac", "Album/1.mp3"])
        XCTAssertEqual(FolderScanner.scan([lib]).first?.size, 2, "size of the link's target")
        // A linked folder dropped in directly.
        XCTAssertEqual(FolderScanner.scan([lib.appendingPathComponent("Album")]).map(\.path).first.map { ($0 as NSString).lastPathComponent }, "1.mp3")
    }

    func testLinkToAnAncestorDoesNotAddItsFilesTwice() throws {
        let fm = FileManager.default
        let root = tmp.appendingPathComponent("anc")
        try fm.createDirectory(at: root.appendingPathComponent("x/y"), withIntermediateDirectories: true)
        fm.createFile(atPath: root.appendingPathComponent("x/s.mp3").path, contents: Data([0]))
        try fm.createSymbolicLink(at: root.appendingPathComponent("x/y/link"), withDestinationURL: root.appendingPathComponent("x"))
        let names = FolderScanner.scan([root]).map { ($0.path as NSString).lastPathComponent }
        XCTAssertEqual(names, ["s.mp3"], "x/y/link/s.mp3 is the same file")
    }

    func testScannerFindsNestedFilesSorted() throws {
        let sub = tmp.appendingPathComponent("b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for p in ["b/c/2.mp3", "b/c/10.flac", "a.MP3", "skip.txt", ".hidden.mp3"] {
            FileManager.default.createFile(atPath: tmp.appendingPathComponent(p).path, contents: Data([0]))
        }
        let names = FolderScanner.scan([tmp]).map { ($0.path as NSString).lastPathComponent }
        XCTAssertEqual(names, ["a.MP3", "2.mp3", "10.flac"])
    }

    private func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(exe) failed")
    }

    // MARK: Library fields

    func testID3LibraryFields() {
        func txxx(_ desc: String, _ value: String) -> [UInt8] {
            let body: [UInt8] = [3] + Array(desc.utf8) + [0] + Array(value.utf8)
            let n = body.count
            return Array("TXXX".utf8) + [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF), 0, 0] + body
        }
        let frames = frame23("TIT2", "Song") + frame23("TPE1", "Guest") + frame23("TPE2", "Band") + frame23("TYER", "1977")
            + frame23("TCON", "(17)") + frame23("TRCK", "3/12") + frame23("TPOS", "2/2")
            + txxx("MusicBrainz Album Type", "album; live") + txxx("MusicBrainz Album Status", "Bootleg")
            + txxx("MusicBrainz Artist Id", "abc-123") + txxx("ORIGINALYEAR", "1975")
        let bytes: [UInt8] = Array("ID3".utf8) + [3, 0, 0] + synchsafe(frames.count) + frames
        let info = TagReader.parseID3Tag(bytes)
        XCTAssertEqual(info.albumArtist, "Band")
        XCTAssertEqual(info.date, "1977")
        XCTAssertEqual(info.originalDate, "1975")
        XCTAssertEqual(info.genre, "Rock")
        XCTAssertEqual(info.trackNumber, 3)
        XCTAssertEqual(info.discNumber, 2)
        XCTAssertEqual(info.releaseType, "album; live")
        XCTAssertEqual(info.releaseStatus, "Bootleg")
        XCTAssertEqual(info.mbArtistID, "abc-123")
    }

    func testVorbisLibraryFields() {
        let comments = ["TITLE=Song", "ALBUMARTIST=Band", "DATE=1977-05-08", "GENRE=Rock", "GENRE=Jam", "TRACKNUMBER=07",
                        "RELEASETYPE=live", "RELEASESTATUS=bootleg", "MUSICBRAINZ_RELEASEGROUPID=rg-1"]
        func le32(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)] }
        var body = le32(6) + Array("vendor".utf8) + le32(comments.count)
        for c in comments { body += le32(c.utf8.count) + Array(c.utf8) }
        let bytes: [UInt8] = Array("fLaC".utf8) + [0x84, UInt8(body.count >> 16), UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
        let info = TagReader.parseFLAC(bytes)
        XCTAssertEqual(info.title, "Song")
        XCTAssertEqual(info.albumArtist, "Band")
        XCTAssertEqual(info.date, "1977-05-08")
        XCTAssertEqual(info.genre, "Rock; Jam")
        XCTAssertEqual(info.trackNumber, 7)
        XCTAssertEqual(info.releaseType, "live")
        XCTAssertEqual(info.releaseStatus, "bootleg")
        XCTAssertEqual(info.mbReleaseGroupID, "rg-1")
    }

    func testOggVorbis() throws {
        func le32(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)] }
        func page(_ packets: [[UInt8]], granule: Int64, seq: Int) -> [UInt8] {
            var lacing: [UInt8] = [], body: [UInt8] = []
            for p in packets {
                var n = p.count
                while n >= 255 { lacing.append(255); n -= 255 }
                lacing.append(UInt8(n))
                body += p
            }
            var h: [UInt8] = Array("OggS".utf8) + [0, 0]
            for k in 0..<8 { h.append(UInt8((granule >> (8 * Int64(k))) & 0xFF)) }
            return h + [1, 2, 3, 4] + le32(seq) + [0, 0, 0, 0] + [UInt8(lacing.count)] + lacing + body
        }
        let ident: [UInt8] = [1] + Array("vorbis".utf8) + le32(0) + [2] + le32(44100) + le32(0) + le32(128_000) + le32(0) + [0xB8, 1]
        var comment: [UInt8] = [3] + Array("vorbis".utf8) + le32(3) + Array("abc".utf8)
        let fields = ["TITLE=Reeling", "ARTIST=PJ Harvey", "ALBUM=The B Sides", "TRACKNUMBER=1", "DATE=1995"]
        comment += le32(fields.count)
        for f in fields { comment += le32(f.utf8.count) + Array(f.utf8) }
        comment += Array(repeating: 0x41, count: 600)   // a long comment packet spans several lacing values
        var bytes = page([ident], granule: 0, seq: 0) + page([comment], granule: 0, seq: 1)
        bytes += page([Array(repeating: 0, count: 4000)], granule: 44100 * 180, seq: 2)
        let url = tmp.appendingPathComponent("a.ogg")
        try Data(bytes).write(to: url)
        let info = TagReader.read(path: url.path, fileSize: Int64(bytes.count))
        XCTAssertEqual(info.title, "Reeling")
        XCTAssertEqual(info.artist, "PJ Harvey")
        XCTAssertEqual(info.album, "The B Sides")
        XCTAssertEqual(info.trackNumber, 1)
        XCTAssertEqual(info.sampleRate, 44100)
        XCTAssertEqual(info.duration ?? 0, 180, accuracy: 0.01)
    }
}
