import AVFoundation
import XCTest
@testable import OmniAmp

final class TagWriterTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-tagwriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private let tags = BasicTags(artist: "Shannon Wright", album: "Flightsafety", year: "1999", genre: "Indie Rock")

    private func synchsafe(_ n: Int) -> [UInt8] { [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)] }
    private func frame(_ id: String, _ text: String, v4: Bool = false) -> [UInt8] {
        let body: [UInt8] = [3] + Array(text.utf8)
        let n = body.count
        return Array(id.utf8) + (v4 ? synchsafe(n) : [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]) + [0, 0] + body
    }
    /// 50 frames of 128 kbps MPEG audio with a recognizable pattern.
    private var audio: [UInt8] {
        var a: [UInt8] = []
        for i in 0..<50 { a += [0xFF, 0xFB, 0x90, 0x00] + (0..<413).map { UInt8(($0 + i) & 0xFF) } }
        return a
    }

    private func mp3(_ frames: [UInt8], padding: Int, version: UInt8 = 3) throws -> URL {
        let url = tmp.appendingPathComponent("t\(UUID().uuidString.prefix(4)).mp3")
        let tag: [UInt8] = frames.isEmpty && padding == 0 ? [] :
            Array("ID3".utf8) + [version, 0, 0] + synchsafe(frames.count + padding) + frames + [UInt8](repeating: 0, count: padding)
        try Data(tag + audio).write(to: url)
        return url
    }

    private func read(_ url: URL) -> TagInfo {
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        return TagReader.read(path: url.path, fileSize: size)
    }

    private func audioIntact(_ url: URL) throws {
        let d = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(Array(d.suffix(audio.count)), audio, "audio bytes changed")
    }

    // MARK: The file's date

    func testWritingKeepsTheFilesDate() throws {
        // The date the music came into the collection stays, whether the tag fits in place or the file is rewritten.
        let old = Date(timeIntervalSince1970: 1_262_304_000)   // 2010-01-01
        let inPlace = try mp3(frame("TIT2", "Plea"), padding: 1024)
        let grown = try mp3(frame("TIT2", "Plea"), padding: 0)
        for url in [inPlace, grown] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            XCTAssertEqual(TagWriter.write(tags, to: url.path, backupDir: nil), .written)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, old, url.lastPathComponent)
            XCTAssertEqual(read(url).album, "Flightsafety")
        }
        // Asked not to (keepDate: false), the date is the write's.
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: inPlace.path)
        XCTAssertEqual(TagWriter.write(BasicTags(genre: "Rock"), to: inPlace.path, backupDir: nil, keepDate: false), .written)
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: inPlace.path)[.modificationDate] as? Date, old)
    }

    // MARK: MP3

    func testMP3InPlaceKeepsOtherFramesAndArtist() throws {
        let url = try mp3(frame("TIT2", "Plea") + frame("TPE1", "Guest") + frame("TCON", "Rock"), padding: 1024)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual(TagWriter.write(tags, to: url.path, backupDir: tmp.appendingPathComponent("bk")), .written)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, before, "rewritten in place")
        let i = read(url)
        XCTAssertEqual(i.title, "Plea")
        XCTAssertEqual(i.artist, "Guest", "an existing track artist stays")
        XCTAssertEqual(i.albumArtist, "Shannon Wright")
        XCTAssertEqual(i.album, "Flightsafety")
        XCTAssertEqual(i.date, "1999")
        XCTAssertEqual(i.genre, "Indie Rock", "replaced, not doubled")
        XCTAssertEqual(i.bitrate, 128)
        try audioIntact(url)
        let backups = try FileManager.default.subpathsOfDirectory(atPath: tmp.appendingPathComponent("bk").path)
        XCTAssertTrue(backups.contains { $0.hasSuffix(".tag") })
        XCTAssertTrue(backups.contains { $0.hasSuffix("index.tsv") })
    }

    func testMP3WithoutTagGetsOne() throws {
        let url = try mp3([], padding: 0)
        XCTAssertEqual(TagWriter.write(tags, to: url.path, backupDir: nil), .written)
        let i = read(url)
        XCTAssertEqual(i.artist, "Shannon Wright", "no track artist: the album artist fills it")
        XCTAssertEqual(i.album, "Flightsafety")
        XCTAssertEqual(i.genre, "Indie Rock")
        try audioIntact(url)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: tmp.path).contains { $0.hasSuffix(".tmp") })
    }

    func testMP3TagTooSmallIsRewritten() throws {
        let url = try mp3(frame("TIT2", "Plea"), padding: 0)
        XCTAssertEqual(TagWriter.write(tags, to: url.path, backupDir: nil), .written)
        XCTAssertEqual(read(url).title, "Plea")
        XCTAssertEqual(read(url).album, "Flightsafety")
        try audioIntact(url)
        // Twice: now it fits (the rewrite left padding).
        XCTAssertEqual(TagWriter.write(BasicTags(album: "Other"), to: url.path, backupDir: nil), .written)
        XCTAssertEqual(read(url).album, "Other")
        XCTAssertEqual(read(url).albumArtist, "Shannon Wright")
        try audioIntact(url)
    }

    func testID3v24WritesUTF8AndTDRC() throws {
        let url = try mp3(frame("TIT2", "Jóga", v4: true) + frame("TDRC", "1996", v4: true), padding: 512, version: 4)
        XCTAssertEqual(TagWriter.write(BasicTags(artist: "Björk", year: "1997"), to: url.path, backupDir: nil), .written)
        let i = read(url)
        XCTAssertEqual(i.title, "Jóga")
        XCTAssertEqual(i.albumArtist, "Björk")
        XCTAssertEqual(i.date, "1997")
        try audioIntact(url)
    }

    func testUnsupported() throws {
        let url = tmp.appendingPathComponent("a.wma")
        try Data(repeating: 1, count: 100).write(to: url)
        XCTAssertEqual(TagWriter.write(tags, to: url.path, backupDir: nil), .unsupported("WMA"))
        let v22 = try mp3([], padding: 100, version: 2)
        XCTAssertEqual(TagWriter.write(tags, to: v22.path, backupDir: nil), .unsupported("ID3v2.2 tag"))
        XCTAssertEqual(TagWriter.write(BasicTags(), to: v22.path, backupDir: nil), .unchanged)
    }

    /// v2.4 tags with plain (not synchsafe) frame sizes, as older iTunes wrote them: every frame kept.
    /// A tag that can't be read either way is left alone.
    func testID3v24WithPlainFrameSizes() throws {
        let long = String(repeating: "Long comment ", count: 30)   // over 127 bytes: the two size readings differ
        let frames = frame("TXXX", long, v4: false) + frame("TIT2", "Keep Me", v4: false)
        let url = try mp3(frames, padding: 64, version: 4)
        XCTAssertEqual(TagWriter.write(tags, to: url.path, backupDir: nil), .written)
        let bytes = try Data(contentsOf: url)
        XCTAssertNotNil(bytes.range(of: Data("Keep Me".utf8)), "the frame after the long one survives")
        XCTAssertNotNil(bytes.range(of: Data(long.utf8)))
        XCTAssertNotNil(bytes.range(of: Data("Flightsafety".utf8)))

        let broken = try mp3(frame("TIT2", "x") + [0x74, 0x69, 0x74, 0x32, 0, 0, 0, 9, 0, 0, 1, 2, 3], padding: 0, version: 3)
        let before = try Data(contentsOf: broken)
        XCTAssertEqual(TagWriter.write(tags, to: broken.path, backupDir: nil), .unsupported("ID3 tag it can't read safely"))
        XCTAssertEqual(try Data(contentsOf: broken), before)
    }

    /// An extended header whose size points past the tag: left alone, not rewritten with only the new fields.
    func testDamagedExtendedHeaderIsNotRewritten() throws {
        let frames = frame("TIT2", "Keep Me") + frame("TPE1", "Guest")
        for (version, size) in [(UInt8(3), [UInt8(0x7F), 0xFF, 0xFF, 0xF0]), (UInt8(4), synchsafe(100_000))] {
            let ext: [UInt8] = size + [0, 0]
            let body = ext + frames
            let url = tmp.appendingPathComponent("ext\(version).mp3")
            try Data(Array("ID3".utf8) + [version, 0, 0x40] + synchsafe(body.count + 64) + body + [UInt8](repeating: 0, count: 64) + audio).write(to: url)
            let before = try Data(contentsOf: url)
            XCTAssertEqual(TagWriter.write(BasicTags(genre: "Rock"), to: url.path, backupDir: nil), .unsupported("ID3 tag it can't read safely"))
            XCTAssertEqual(try Data(contentsOf: url), before, "v2.\(version) untouched")
        }
    }

    /// A valid extended header is skipped and every frame after it kept.
    func testExtendedHeaderKeepsFrames() throws {
        let frames = frame("TIT2", "Keep Me") + frame("TPE1", "Guest")
        let ext: [UInt8] = [0, 0, 0, 6, 0, 0, 0, 0, 0, 0]   // v2.3: size 6 (without itself), flags, padding size
        let body = ext + frames
        let url = tmp.appendingPathComponent("ext-ok.mp3")
        try Data(Array("ID3".utf8) + [3, 0, 0x40] + synchsafe(body.count + 256) + body + [UInt8](repeating: 0, count: 256) + audio).write(to: url)
        XCTAssertEqual(TagWriter.write(BasicTags(genre: "Rock"), to: url.path, backupDir: nil), .written)
        let i = read(url)
        XCTAssertEqual(i.title, "Keep Me")
        XCTAssertEqual(i.artist, "Guest")
        XCTAssertEqual(i.genre, "Rock")
        try audioIntact(url)
    }

    /// ID3v2.3's year frame holds a year: a full date is cut to it (v2.4 keeps the date).
    func testYearFrameHoldsFourDigits() throws {
        let url = try mp3([], padding: 256, version: 3)
        XCTAssertEqual(TagWriter.write(BasicTags(year: "1994-05-12"), to: url.path, backupDir: nil), .written)
        let bytes = try Data(contentsOf: url)
        // Text frames are written as UTF-16.
        func utf16(_ t: String) -> Data { Data(t.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }) }
        XCTAssertNotNil(bytes.range(of: Data("TYER".utf8)))
        XCTAssertNotNil(bytes.range(of: utf16("1994")))
        XCTAssertNil(bytes.range(of: utf16("1994-05")))
    }

    /// A tiny PNG: header bytes and padding, enough to be told apart.
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 7, count: 2000))

    func testMP3TrackArtistDiscAndCover() throws {
        let url = try mp3(frame("TIT2", "Plea") + frame("TPE1", "Guest"), padding: 64)
        let t = BasicTags(artist: "Shannon Wright", trackArtist: "Someone Else", disc: "2/2", cover: png)
        XCTAssertEqual(TagWriter.write(t, to: url.path, backupDir: nil), .written)
        let i = read(url)
        XCTAssertEqual(i.artist, "Someone Else", "the track's own artist replaces it")
        XCTAssertEqual(i.albumArtist, "Shannon Wright")
        XCTAssertEqual(i.discNumber, 2)
        XCTAssertEqual(i.title, "Plea")
        XCTAssertEqual(DetailsReader.read(path: url.path, folderArt: false).artwork, png)
        // A second cover replaces the first.
        let other = Data([0xFF, 0xD8] + [UInt8](repeating: 9, count: 1500))
        XCTAssertEqual(TagWriter.write(BasicTags(cover: other), to: url.path, backupDir: nil), .written)
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(DetailsReader.read(path: url.path, folderArt: false).artwork, other)
        XCTAssertNil(bytes.range(of: png.prefix(8)), "old picture gone")
        try audioIntact(url)
    }

    func testCommentReplacesOnlyThePlainOne() throws {
        // A described comment (iTunes' volume data) stays; the plain one is replaced.
        func comm(_ desc: String, _ text: String) -> [UInt8] {
            let body: [UInt8] = [0] + Array("eng".utf8) + Array(desc.utf8) + [0] + Array(text.utf8)
            let n = body.count
            return Array("COMM".utf8) + [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + [0, 0] + body
        }
        let url = try mp3(comm("iTunNORM", "0000 1111") + comm("", "old note"), padding: 256)
        XCTAssertEqual(TagWriter.write(BasicTags(comment: "Recorded live"), to: url.path, backupDir: nil), .written)
        let bytes = try Data(contentsOf: url)
        XCTAssertNotNil(bytes.range(of: Data("iTunNORM".utf8)))
        XCTAssertNil(bytes.range(of: Data("old note".utf8)))
        XCTAssertEqual(DetailsReader.read(path: url.path, folderArt: false).comment, "Recorded live")
        let flacURL = try flac()
        XCTAssertEqual(TagWriter.write(BasicTags(comment: "Recorded live"), to: flacURL.path, backupDir: nil), .written)
        XCTAssertEqual(DetailsReader.read(path: flacURL.path, folderArt: false).comment, "Recorded live")
    }

    // MARK: FLAC

    private func flac() throws -> URL {
        let wav = tmp.appendingPathComponent("t.wav"), out = tmp.appendingPathComponent("t\(UUID().uuidString.prefix(4)).flac")
        // One second of 16-bit stereo sine, as a plain WAV.
        func le(_ n: Int, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8((n >> (8 * $0)) & 0xFF) } }
        var pcm: [UInt8] = []
        for i in 0..<44100 { let v = Int(sin(Double(i) * 0.05) * 9000); pcm += le(v & 0xFFFF, 2) + le(v & 0xFFFF, 2) }
        let wavBytes = Array("RIFF".utf8) + le(36 + pcm.count, 4) + Array("WAVEfmt ".utf8) + le(16, 4) + le(1, 2) + le(2, 2)
            + le(44100, 4) + le(44100 * 4, 4) + le(4, 2) + le(16, 2) + Array("data".utf8) + le(pcm.count, 4) + pcm
        try Data(wavBytes).write(to: wav)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "flac", "-d", "flac", wav.path, out.path]
        try p.run()
        p.waitUntilExit()
        return out
    }

    /// Everything after the metadata: the audio frames.
    private func flacAudio(_ url: URL) throws -> [UInt8] {
        let d = [UInt8](try Data(contentsOf: url))
        var p = 4
        while true {
            let last = d[p] & 0x80 != 0
            p += 4 + (Int(d[p + 1]) << 16 | Int(d[p + 2]) << 8 | Int(d[p + 3]))
            if last { break }
        }
        return Array(d[p...])
    }

    func testFLACTagsAndAudioIntact() throws {
        let url = try flac()
        let audioBefore = try flacAudio(url)
        XCTAssertEqual(TagWriter.write(tags, to: url.path, backupDir: nil), .written)
        var i = read(url)
        XCTAssertEqual(i.albumArtist, "Shannon Wright")
        XCTAssertEqual(i.artist, "Shannon Wright")
        XCTAssertEqual(i.album, "Flightsafety")
        XCTAssertEqual(i.date, "1999")
        XCTAssertEqual(i.genre, "Indie Rock")
        XCTAssertEqual(i.sampleRate, 44100)
        XCTAssertEqual(try flacAudio(url), audioBefore)
        // Again, with a shorter value: fits in place; nothing doubled.
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual(TagWriter.write(BasicTags(genre: "Rock"), to: url.path, backupDir: nil), .written)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size)
        i = read(url)
        XCTAssertEqual(i.genre, "Rock")
        XCTAssertEqual(i.album, "Flightsafety")
        XCTAssertEqual(try flacAudio(url), audioBefore)
        let decoded = try AVAudioFile(forReading: url)
        XCTAssertEqual(decoded.length, 44100)
    }

    func testFLACTrackArtistDiscAndCover() throws {
        let url = try flac()
        let audioBefore = try flacAudio(url)
        XCTAssertEqual(TagWriter.write(BasicTags(title: "Plea", trackArtist: "Guest", disc: "1", cover: png), to: url.path, backupDir: nil), .written)
        let i = read(url)
        XCTAssertEqual(i.artist, "Guest")
        XCTAssertEqual(i.title, "Plea")
        XCTAssertEqual(i.discNumber, 1)
        XCTAssertEqual(DetailsReader.read(path: url.path, folderArt: false).artwork, png)
        XCTAssertEqual(try flacAudio(url), audioBefore)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 44100)
    }

    /// The test FLAC with its metadata replaced: STREAMINFO, then `blocks` (type, body), then the audio.
    private func flac(blocks: [(UInt8, [UInt8])]) throws -> (url: URL, audio: [UInt8]) {
        let plain = try flac()
        let d = [UInt8](try Data(contentsOf: plain)), audio = try flacAudio(plain)
        let info = Array(d[8..<(8 + 34)])
        var bytes = Array("fLaC".utf8)
        for (i, (type, body)) in ([(UInt8(0), info)] + blocks).enumerated() {
            bytes.append(type | (i == blocks.count ? 0x80 : 0))
            bytes += [UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
        }
        let url = tmp.appendingPathComponent("b\(UUID().uuidString.prefix(4)).flac")
        try Data(bytes + audio).write(to: url)
        return (url, audio)
    }

    /// Two big padding blocks (pictures removed earlier) merge into more room than one block can hold (16 MB).
    func testFLACWithHugePaddingStaysValid() throws {
        let pad = [UInt8](repeating: 0, count: 9 << 20)
        let (url, audio) = try flac(blocks: [(1, pad), (1, pad)])
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual(TagWriter.write(tags, to: url.path, backupDir: nil), .written)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size, "in place")
        XCTAssertTrue(try flacAudio(url) == audio, "the metadata blocks still end where the audio starts")
        XCTAssertEqual(read(url).album, "Flightsafety")
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 44100)
    }

    /// A comment block that says 3 comments but holds 1: refused, instead of rewriting it with only ours.
    func testFLACDamagedCommentsAreNotRewritten() throws {
        func le(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)] }
        let title = Array("TITLE=Plea".utf8)
        let comments = le(3) + Array("abc".utf8) + le(3) + le(title.count) + title
        let (url, _) = try flac(blocks: [(4, comments), (1, [UInt8](repeating: 0, count: 1024))])
        let before = try Data(contentsOf: url)
        guard case .unsupported = TagWriter.write(tags, to: url.path, backupDir: nil) else { return XCTFail("should refuse") }
        XCTAssertEqual(try Data(contentsOf: url), before, "file untouched")
    }

    /// Like some rippers' files: an ID3v2.3 tag (unsynchronisation flag set) in front of the FLAC.
    func testFLACBehindID3Tag() throws {
        let plain = try flac()
        let frames = frame("TIT2", "Leave Me With the Monkeys") + frame("TPE1", "Sophie Hunger") + frame("TALB", "1983")
        let id3 = Array("ID3".utf8) + [3, 0, 0x80] + synchsafe(frames.count + 64) + frames + [UInt8](repeating: 0, count: 64)
        let url = tmp.appendingPathComponent("behind.flac")
        try Data(id3 + [UInt8](try Data(contentsOf: plain))).write(to: url)
        let audio = try flacAudio(plain)

        // Read: the FLAC part (length, rate), the ID3 tag's names where the FLAC has none.
        var i = read(url)
        XCTAssertEqual(i.artist, "Sophie Hunger")
        XCTAssertEqual(i.title, "Leave Me With the Monkeys")
        XCTAssertEqual(i.sampleRate, 44100)
        XCTAssertEqual(i.duration ?? 0, 1, accuracy: 0.01)

        // Written into the FLAC part (grown: no padding to use), the ID3 tag and the audio as they were.
        XCTAssertEqual(TagWriter.write(BasicTags(artist: "Sophie Hunger", album: "1983", year: "2010"), to: url.path, backupDir: nil), .written)
        XCTAssertEqual(TagWriter.write(BasicTags(genre: "Alternative"), to: url.path, backupDir: nil), .written)   // in place
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(Array(bytes.prefix(id3.count)), id3)
        XCTAssertEqual(Array(bytes.suffix(audio.count)), audio)
        i = read(url)
        XCTAssertEqual(i.albumArtist, "Sophie Hunger")
        XCTAssertEqual(i.album, "1983")
        XCTAssertEqual(i.date, "2010")
        XCTAssertEqual(i.genre, "Alternative")
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 44100)
    }

    // MARK: Find Missing Info: applying

    /// A release sharing its folder with others: its cover is kept for it alone, no cover.jpg for all of them.
    func testApplyCoverForReleaseInSharedFolder() throws {
        let jpeg = Data([0xFF, 0xD8]) + Data(repeating: 9, count: 2000)
        let release = "scout niblett\u{1}calcination-\(UUID().uuidString)"
        let msg = FindInfoSheet.write(BasicTags(), paths: [], cover: jpeg, folder: tmp.path, release: release)
        XCTAssertEqual(msg, "Cover kept for this release.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("cover.jpg").path))
        XCTAssertEqual(try Data(contentsOf: LibraryArt.chosenFile(release: release)), jpeg)
        try? FileManager.default.removeItem(at: LibraryArt.chosenFile(release: release))
    }

    func testApplyWritesTagsAndCover() throws {
        let a = try mp3(frame("TIT2", "One"), padding: 256), b = try mp3([], padding: 0)
        let wma = tmp.appendingPathComponent("c.wma")
        try Data(repeating: 1, count: 100).write(to: wma)
        let jpeg = Data([0xFF, 0xD8]) + Data(repeating: 7, count: 2000)
        let msg = FindInfoSheet.write(tags, paths: [a.path, b.path, wma.path], cover: jpeg, folder: tmp.path)
        XCTAssertEqual(msg, "Tags written into 2 files · saved cover.jpg · 1 skipped (WMA).")
        XCTAssertEqual(read(a).album, "Flightsafety")
        XCTAssertEqual(read(b).genre, "Indie Rock")
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent("cover.jpg")), jpeg)
        XCTAssertEqual(DetailsReader.folderArtName(in: tmp.path), "cover.jpg")
    }

    // MARK: Tag editor fixes

    private func comm(_ desc: String, _ text: String) -> [UInt8] {
        let body: [UInt8] = [0] + Array("eng".utf8) + Array(desc.utf8) + [0] + Array(text.utf8)
        let n = body.count
        return Array("COMM".utf8) + [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + [0, 0] + body
    }

    private func le(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)] }
    private func vorbis(_ comments: [String]) -> [UInt8] {
        le(4) + Array("test".utf8) + le(comments.count) + comments.flatMap { le($0.utf8.count) + Array($0.utf8) }
    }

    /// A v2.4 tag read with plain sizes gets synchsafe ones throughout once a cover is added, so it can be written
    /// again (a mix of the two can't be read either way).
    func testID3v24PlainSizesWithCoverStaysWritable() throws {
        let long = String(repeating: "Long comment ", count: 30)
        let url = try mp3(frame("TXXX", long, v4: false) + frame("TIT2", "Keep Me", v4: false), padding: 64, version: 4)
        XCTAssertEqual(TagWriter.write(BasicTags(cover: png), to: url.path, backupDir: nil), .written)
        XCTAssertEqual(TagWriter.write(BasicTags(genre: "Rock"), to: url.path, backupDir: nil), .written)
        let i = read(url)
        XCTAssertEqual(i.title, "Keep Me")
        XCTAssertEqual(i.genre, "Rock")
        XCTAssertEqual(DetailsReader.read(path: url.path, folderArt: false).artwork, png)
        XCTAssertNotNil(try Data(contentsOf: url).range(of: Data(long.utf8)))
        try audioIntact(url)
    }

    /// The comment shown is the one without a description; iTunes' data comments never are.
    func testCommentShownSkipsITunesData() throws {
        let both = try mp3(comm("iTunNORM", " 0000041A 00000384") + comm("", "My note"), padding: 64)
        XCTAssertEqual(DetailsReader.read(path: both.path, folderArt: false).comment, "My note")
        let data = try mp3(comm("iTunNORM", " 0000041A 00000384") + comm("iTunSMPB", " 00000000"), padding: 64)
        XCTAssertNil(DetailsReader.read(path: data.path, folderArt: false).comment)
        let described = try mp3(comm("Comment", "Older tagger"), padding: 64)
        XCTAssertEqual(DetailsReader.read(path: described.path, folderArt: false).comment, "Older tagger")
    }

    /// A new FLAC comment replaces COMMENT only: a DESCRIPTION (a show's lineage) stays, and the comment is shown.
    func testFLACCommentKeepsDescription() throws {
        let (url, audio) = try flac(blocks: [(4, vorbis(["DESCRIPTION=Lineage: SBD > DAT > FLAC", "COMMENT=old"])), (1, [UInt8](repeating: 0, count: 512))])
        XCTAssertEqual(TagWriter.write(BasicTags(comment: "Great show"), to: url.path, backupDir: nil), .written)
        XCTAssertNotNil(try Data(contentsOf: url).range(of: Data("DESCRIPTION=Lineage: SBD > DAT > FLAC".utf8)))
        XCTAssertNil(try Data(contentsOf: url).range(of: Data("COMMENT=old".utf8)))
        XCTAssertEqual(DetailsReader.read(path: url.path, folderArt: false).comment, "Great show")
        XCTAssertTrue(try flacAudio(url) == audio)
    }

    /// A new track or disc number keeps the file's total.
    func testNumbersKeepTheirTotals() throws {
        let url = try mp3(frame("TRCK", "3/12") + frame("TPOS", "1/2"), padding: 64)
        XCTAssertEqual(TagWriter.write(BasicTags(track: "4", disc: "2"), to: url.path, backupDir: nil), .written)
        var d = DetailsReader.read(path: url.path, folderArt: false)
        XCTAssertEqual(d.track, 4); XCTAssertEqual(d.trackTotal, 12)
        XCTAssertEqual(d.disc, 2); XCTAssertEqual(d.discTotal, 2)
        XCTAssertEqual(TagWriter.write(BasicTags(track: "5/13"), to: url.path, backupDir: nil), .written)
        d = DetailsReader.read(path: url.path, folderArt: false)
        XCTAssertEqual(d.track, 5); XCTAssertEqual(d.trackTotal, 13, "a total given is written as it is")

        let (f, _) = try flac(blocks: [(4, vorbis(["TRACKNUMBER=3/12"])), (1, [UInt8](repeating: 0, count: 512))])
        XCTAssertEqual(TagWriter.write(BasicTags(track: "4"), to: f.path, backupDir: nil), .written)
        XCTAssertNotNil(try Data(contentsOf: f).range(of: Data("TRACKNUMBER=4/12".utf8)))
        XCTAssertEqual(BasicTags.keepingTotal("4", old: nil), "4")
        XCTAssertEqual(BasicTags.keepingTotal("4", old: "3"), "4")
    }

    /// Emptied fields are taken out of the files; the others stay.
    func testRemovingFields() throws {
        let url = try mp3(frame("TIT2", "Plea") + frame("TCON", "Rock") + comm("", "a note") + comm("iTunNORM", " 0000041A"), padding: 64)
        XCTAssertFalse(BasicTags(remove: [.genre]).isEmpty)
        XCTAssertEqual(TagWriter.write(BasicTags(remove: [.genre, .comment]), to: url.path, backupDir: nil), .written)
        let d = DetailsReader.read(path: url.path, folderArt: false)
        XCTAssertNil(d.genre)
        XCTAssertNil(d.comment)
        XCTAssertEqual(d.title, "Plea")
        XCTAssertNotNil(try Data(contentsOf: url).range(of: Data("iTunNORM".utf8)), "a described comment isn't the comment")

        let (f, _) = try flac(blocks: [(4, vorbis(["TITLE=Plea", "GENRE=Rock", "COMMENT=a note", "DESCRIPTION=lineage"])),
                                        (1, [UInt8](repeating: 0, count: 512))])
        XCTAssertEqual(TagWriter.write(BasicTags(remove: [.genre, .comment]), to: f.path, backupDir: nil), .written)
        let fd = DetailsReader.read(path: f.path, folderArt: false)
        XCTAssertNil(fd.genre)
        XCTAssertEqual(fd.title, "Plea")
        XCTAssertEqual(fd.comment, "lineage", "DESCRIPTION stays")
    }

    /// A new cover takes the name of the folder's cover file (its extension changing with the image's kind), and
    /// the old file is kept with the backups.
    func testFolderCoverReplacesTheOneThere() throws {
        let old = Data([0xFF, 0xD8]) + Data(repeating: 3, count: 1500)
        try old.write(to: tmp.appendingPathComponent("cover.jpg"))
        let msg = FindInfoSheet.write(BasicTags(), paths: [], cover: png, folder: tmp.path)
        XCTAssertEqual(msg, "Replaced cover.jpg with cover.png.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("cover.jpg").path))
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent("cover.png")), png)
        XCTAssertEqual(DetailsReader.folderArtName(in: tmp.path), "cover.png")
        let backups = FileManager.default.enumerator(atPath: TagWriter.backupDir.path)?.compactMap { $0 as? String } ?? []
        XCTAssertTrue(backups.contains { $0.hasSuffix("-cover.jpg")
            && (try? Data(contentsOf: TagWriter.backupDir.appendingPathComponent($0))) == old }, "the old cover is in the backups")

        let jpeg = Data([0xFF, 0xD8]) + Data(repeating: 5, count: 1500)
        let other = tmp.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try old.write(to: other.appendingPathComponent("Folder.jpeg"))
        XCTAssertEqual(FindInfoSheet.write(BasicTags(), paths: [], cover: jpeg, folder: other.path), "Replaced Folder.jpeg.")
        XCTAssertEqual(try Data(contentsOf: other.appendingPathComponent("Folder.jpeg")), jpeg)
    }
}
