import AVFoundation
import XCTest
@testable import OmniAmp

/// DSD files made here (a sigma-delta modulator, as a DSD recorder makes them), read and converted to PCM.
final class DSDTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-dsd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Making DSD

    /// 1-bit audio of sines (frequency, amplitude) per channel, oldest bit first in each byte. Second-order
    /// sigma-delta: its noise rises with frequency, like real DSD, and stays far below the tones up to 20 kHz.
    private func modulate(rate: Int, bits: Int, tones: [(Double, Double)]) -> [[UInt8]] {
        tones.map { tone in
            var out = [UInt8](repeating: 0, count: (bits + 7) / 8)
            var i1 = 0.0, i2 = 0.0, y = 1.0
            let w = 2 * Double.pi * tone.0 / Double(rate)
            for n in 0..<bits {
                let x = tone.1 * sin(w * Double(n))
                i1 += x - y
                i2 += i1 - y
                y = i2 >= 0 ? 1 : -1
                if y > 0 { out[n >> 3] |= 0x80 >> UInt8(n & 7) }
            }
            return out
        }
    }

    private func reversed(_ b: UInt8) -> UInt8 {
        var r: UInt8 = 0
        for i in 0..<8 where b & (1 << i) != 0 { r |= 1 << (7 - i) }
        return r
    }

    private func le(_ v: Int64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private func be(_ v: Int64, _ n: Int) -> [UInt8] { (0..<n).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    /// DSF: blocks of 4096 bytes per channel in turn, oldest bit in the lowest bit, an ID3 tag at the end.
    private func dsf(_ name: String, rate: Int, bits: Int, channels: [[UInt8]], id3: [UInt8]? = nil) throws -> URL {
        let block = 4096, blocks = (channels[0].count + block - 1) / block
        var data: [UInt8] = []
        for b in 0..<blocks {
            for ch in channels {
                var part = Array(ch[min(b * block, ch.count)..<min((b + 1) * block, ch.count)]).map(reversed)
                part += [UInt8](repeating: 0, count: block - part.count)
                data += part
            }
        }
        let dataChunk = 12 + data.count, total = 28 + 52 + dataChunk + (id3?.count ?? 0)
        var f: [UInt8] = Array("DSD ".utf8) + le(28, 8) + le(Int64(total), 8) + le(id3 == nil ? 0 : Int64(28 + 52 + dataChunk), 8)
        f += Array("fmt ".utf8) + le(52, 8) + le(1, 4) + le(0, 4) + le(2, 4) + le(Int64(channels.count), 4) + le(Int64(rate), 4)
        f += le(1, 4) + le(Int64(bits), 8) + le(Int64(block), 4) + le(0, 4)
        f += Array("data".utf8) + le(Int64(dataChunk), 8) + data + (id3 ?? [])
        let url = dir.appendingPathComponent(name)
        try Data(f).write(to: url)
        return url
    }

    private func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
        Array(id.utf8) + be(Int64(body.count), 8) + body + (body.count % 2 == 1 ? [0] : [])
    }

    /// DSDIFF: big-endian chunks; the audio byte by byte, channel by channel.
    private func dff(_ name: String, rate: Int, channels: [[UInt8]], compression: String = "DSD ", artist: String? = nil, title: String? = nil) throws -> URL {
        let ids = ["SLFT", "SRGT", "C   ", "LFE ", "LS  ", "RS  "]
        let chnl = be(Int64(channels.count), 2) + channels.indices.flatMap { Array(ids[$0].utf8) }
        let cmprName = Array("not compressed".utf8)
        let prop = Array("SND ".utf8) + chunk("FS  ", be(Int64(rate), 4)) + chunk("CHNL", chnl)
            + chunk("CMPR", Array(compression.utf8) + [UInt8(cmprName.count)] + cmprName)
        var text: [UInt8] = []
        if let artist { text += chunk("DIAR", be(Int64(artist.utf8.count), 4) + Array(artist.utf8)) }
        if let title { text += chunk("DITI", be(Int64(title.utf8.count), 4) + Array(title.utf8)) }
        var audio: [UInt8] = []
        for i in 0..<channels[0].count { for ch in channels { audio.append(ch[i]) } }
        var body = Array("DSD ".utf8) + chunk("FVER", [1, 5, 0, 0]) + chunk("PROP", prop)
        if !text.isEmpty { body += chunk("DIIN", text) }
        body += chunk(compression == "DSD " ? "DSD " : "DST ", audio)
        let url = dir.appendingPathComponent(name)
        try Data(Array("FRM8".utf8) + be(Int64(body.count), 8) + body).write(to: url)
        return url
    }

    /// An ID3v2.3 tag with a title and an artist.
    private func id3(title: String, artist: String) -> [UInt8] {
        func frame(_ id: String, _ s: String) -> [UInt8] { let b = [0] + Array(s.utf8); return Array(id.utf8) + be(Int64(b.count), 4) + [0, 0] + b }
        let frames = frame("TIT2", title) + frame("TPE1", artist)
        let n = frames.count
        return Array("ID3".utf8) + [3, 0, 0] + [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)] + frames
    }

    // MARK: Measuring

    private func decoded(_ url: URL) throws -> AVAudioPCMBuffer {
        let out = dir.appendingPathComponent(url.lastPathComponent + ".caf")
        try DSD.decode(path: url.path, to: out)
        let f = try AVAudioFile(forReading: out)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return buf
    }

    /// The amplitude of one frequency over `from..<to` (a whole number of its cycles).
    private func amplitude(_ b: AVAudioPCMBuffer, channel: Int, _ freq: Double, from: Int, to: Int) -> Double {
        let x = b.floatChannelData![channel], w = 2 * Double.pi * freq / b.format.sampleRate
        var re = 0.0, im = 0.0
        for n in from..<to { re += Double(x[n]) * cos(w * Double(n)); im -= Double(x[n]) * sin(w * Double(n)) }
        return 2 * (re * re + im * im).squareRoot() / Double(to - from)
    }

    // MARK: Tests

    func testDSFStereoBecomesPCMAtItsExactLength() throws {
        let rate = 2_822_400, bits = rate   // one second of DSD64
        let url = try dsf("tones.dsf", rate: rate, bits: bits, channels: modulate(rate: rate, bits: bits, tones: [(1000, 0.5), (3000, 0.25)]))
        let info = try XCTUnwrap(DSD.info(path: url.path))
        XCTAssertEqual(info.label, "DSD64")
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.samples, Int64(bits))
        let b = try decoded(url)
        XCTAssertEqual(b.format.sampleRate, 176_400)
        XCTAssertEqual(Int(b.frameLength), 176_400, "exactly one second")
        let from = 17_640, to = from + 88_200   // half a second: whole cycles of 1 and 3 kHz
        XCTAssertEqual(amplitude(b, channel: 0, 1000, from: from, to: to), 0.5, accuracy: 0.01)
        XCTAssertEqual(amplitude(b, channel: 1, 3000, from: from, to: to), 0.25, accuracy: 0.005)
        XCTAssertLessThan(amplitude(b, channel: 0, 3000, from: from, to: to), 0.0005, "the channels stay apart")
        XCTAssertLessThan(amplitude(b, channel: 1, 1000, from: from, to: to), 0.0005)
        XCTAssertLessThan(amplitude(b, channel: 0, 15_000, from: from, to: to), 0.0005, "nothing else in the audio band")
    }

    func testDSFTagsAndFormatForTheLibrary() throws {
        let rate = 2_822_400, bits = rate / 4
        let url = try dsf("tagged.dsf", rate: rate, bits: bits, channels: modulate(rate: rate, bits: bits, tones: [(1000, 0.3), (1000, 0.3)]),
                          id3: id3(title: "Spanish Harlem", artist: "Rebecca Pidgeon"))
        let t = TagReader.read(path: url.path, fileSize: Int64(try Data(contentsOf: url).count))
        XCTAssertEqual(t.title, "Spanish Harlem")
        XCTAssertEqual(t.artist, "Rebecca Pidgeon")
        XCTAssertEqual(try XCTUnwrap(t.duration), 0.25, accuracy: 0.001)
        XCTAssertEqual(t.sampleRate, rate)
        XCTAssertEqual(t.bitDepth, 1)
        XCTAssertEqual(CollectionDB.format(url.path, bitDepth: 1, rate: rate, kbps: t.bitrate), "DSD64")
        XCTAssertTrue(CollectionDB.isLossless(url.path, bitDepth: 1))
        XCTAssertTrue(FolderScanner.audioExtensions.isSuperset(of: ["dsf", "dff"]))
        XCTAssertFalse(FolderScanner.unplayableExtensions.contains("dsf"))
    }

    func testDSDIFFAtDSD128WithItsOwnTags() throws {
        let rate = 5_644_800, bits = rate / 2   // half a second of DSD128
        let url = try dff("tones.dff", rate: rate, channels: modulate(rate: rate, bits: bits, tones: [(2000, 0.4), (500, 0.4)]),
                          artist: "Test Artist", title: "Test Title")
        let info = try XCTUnwrap(DSD.info(path: url.path))
        XCTAssertEqual(info.label, "DSD128")
        XCTAssertEqual(info.container, .dff)
        XCTAssertFalse(info.lsbFirst)
        let t = TagReader.read(path: url.path, fileSize: Int64(try Data(contentsOf: url).count))
        XCTAssertEqual(t.artist, "Test Artist")
        XCTAssertEqual(t.title, "Test Title")
        let b = try decoded(url)
        XCTAssertEqual(b.format.sampleRate, 176_400, "DSD128 converts to the same rate")
        XCTAssertEqual(Int(b.frameLength), 88_200)
        XCTAssertEqual(amplitude(b, channel: 0, 2000, from: 8820, to: 8820 + 44_100), 0.4, accuracy: 0.01)
        XCTAssertEqual(amplitude(b, channel: 1, 500, from: 8820, to: 8820 + 44_100), 0.4, accuracy: 0.01)
    }

    func testDSTCompressedDSDIsNotPlayed() throws {
        let url = try dff("packed.dff", rate: 2_822_400, channels: [[UInt8](repeating: DSD.idle, count: 4096)], compression: "DST ")
        let info = try XCTUnwrap(DSD.info(path: url.path))
        XCTAssertTrue(info.compressed)
        XCTAssertFalse(info.decodable)
        XCTAssertThrowsError(try DSD.decode(path: url.path, to: dir.appendingPathComponent("x.caf")))
    }

    func testOddLengthsAndCutFiles() throws {
        let rate = 2_822_400, bits = rate / 10 + 13   // not a whole byte, not a whole output sample
        let url = try dsf("odd.dsf", rate: rate, bits: bits, channels: modulate(rate: rate, bits: bits, tones: [(1000, 0.3)]))
        XCTAssertEqual(Int(try decoded(url).frameLength), bits / 16)
        // An interrupted copy: plays up to where the audio stops.
        let whole = try Data(contentsOf: url), cut = dir.appendingPathComponent("cut.dsf")
        try whole.prefix(28 + 52 + 12 + 4096 * 3).write(to: cut)
        let b = try decoded(cut)
        XCTAssertGreaterThan(b.frameLength, 0)
        XCTAssertLessThanOrEqual(Int(b.frameLength), 4096 * 3 * 8 / 16)
    }

    func testThePlayerGetsAConvertedCopyOnce() throws {
        let rate = 2_822_400, bits = rate / 4
        let url = try dsf("cached.dsf", rate: rate, bits: bits, channels: modulate(rate: rate, bits: bits, tones: [(1000, 0.3), (1000, 0.3)]))
        let first = try DecodedFiles.playable(url)
        XCTAssertEqual(first.pathExtension, "caf")
        XCTAssertTrue(first.path.hasPrefix(DecodedFiles.directory.path))
        XCTAssertEqual(try AVAudioFile(forReading: first).length, AVAudioFramePosition(bits / 16))
        XCTAssertEqual(try DecodedFiles.playable(url), first, "kept: not converted again")
        let flac = dir.appendingPathComponent("plain.flac")
        XCTAssertEqual(try DecodedFiles.playable(flac), flac, "other files are played as they are")
        try FileManager.default.removeItem(at: first)
    }
}
