import Accelerate
import AVFoundation
import Foundation
import os

/// DSD (SACD's 1-bit audio) in DSF (Sony) and DSDIFF (Philips, .dff) files, converted to PCM natively: macOS has
/// no DSD decoder. The player plays the converted copy (see `DecodedFiles`), so seeking, gapless, EQ and
/// bit-perfect output work as for any file.
///
/// The conversion is two low-pass filter stages, as in good DSD converters. Stage 1 runs on the bits themselves,
/// eight at a time through lookup tables, down to 1/8 of the DSD rate (352.8 kHz for DSD64). Stage 2 is a sharp
/// filter (vDSP) down to 176.4 kHz: flat to 20 kHz, ~100 dB down from 40 kHz, where DSD's shaped noise rises.
/// Both are linear phase and centred on the samples, so a track converts to exactly its length (gapless timing
/// holds). Each track is filtered on its own, over DSD silence at its ends. The level is DSD's own: its reference
/// (50% modulation) comes out at -6 dBFS, leaving room for DSD's peaks above it.
enum DSD {
    static let extensions: Set<String> = ["dsf", "dff"]

    enum Container: Sendable { case dsf, dff }

    /// "DSD64", "DSD128"… (DSD at 48 kHz multiples is named by the same factor).
    static func label(rate: Int) -> String { "DSD\(rate / (rate % 44_100 == 0 ? 44_100 : 48_000))" }

    struct Info: Equatable, Sendable {
        var container: Container
        var channels: Int
        /// Bits per second per channel: 2,822,400 for DSD64.
        var rate: Int
        /// Per channel.
        var samples: Int64
        var dataOffset: Int64
        var dataBytes: Int64
        /// DSF: bytes per channel per block (channels take turns block by block). DSDIFF: 1 (byte by byte).
        var blockSize: Int
        /// DSF stores the oldest bit in a byte's lowest bit; DSDIFF in its highest.
        var lsbFirst: Bool
        /// Where an ID3v2 tag is (DSF's metadata, or DSDIFF's unofficial "ID3 " chunk).
        var tagOffset: Int64?
        var tagSize: Int64?
        /// DSDIFF's own tags ("DIIN").
        var title: String?
        var artist: String?
        /// DSDIFF compressed with DST (SACD's lossless packing): not decodable here.
        var compressed = false

        var seconds: Double { Double(samples) / Double(rate) }
        var label: String { DSD.label(rate: rate) }
        /// The PCM it converts to: 176.4 kHz (192 kHz for the 48 kHz family).
        var outputRate: Int { rate % 44_100 == 0 ? 176_400 : 192_000 }
        var decimation: Int { rate / outputRate }
        var decodable: Bool {
            !compressed && channels > 0 && channels <= 8 && samples > 0 && dataBytes > 0
                && rate % outputRate == 0 && decimation >= 16 && decimation % 8 == 0
        }
    }

    enum DecodeError: Error, LocalizedError {
        case unreadable, unsupported(String), writeFailed
        var errorDescription: String? {
            switch self {
            case .unreadable: "not a DSD file it can read"
            case .unsupported(let why): why
            case .writeFailed: "couldn't write the converted copy"
            }
        }
    }

    // MARK: Reading the header

    static func info(path: String) -> Info? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return info(fd: fd)
    }

    static func info(fd: Int32) -> Info? {
        guard let head = read(fd, 0, 16), head.count == 16 else { return nil }
        if head.starts(with: Array("DSD ".utf8)) { return dsfInfo(fd) }
        if head.starts(with: Array("FRM8".utf8)), Array(head[12..<16]) == Array("DSD ".utf8) { return dffInfo(fd) }
        return nil
    }

    /// DSF: "DSD " (file size, metadata pointer), "fmt " (channels, rate, bits, samples, block size), "data".
    private static func dsfInfo(_ fd: Int32) -> Info? {
        guard let d = read(fd, 0, 28), let fmtHead = read(fd, 28, 12), fmtHead.starts(with: Array("fmt ".utf8)) else { return nil }
        let fmtSize = le(fmtHead, 4, 8)
        guard (52...4096).contains(fmtSize), let f = read(fd, 28, Int(fmtSize)), f.count >= 52 else { return nil }
        let bits = le(f, 32, 4)
        guard le(f, 16, 4) == 0, bits == 1 || bits == 8 else { return nil }   // format 0: raw DSD
        let dataAt = 28 + fmtSize
        guard let dh = read(fd, dataAt, 12), dh.starts(with: Array("data".utf8)) else { return nil }
        let meta = le(d, 20, 8)
        return Info(container: .dsf, channels: Int(le(f, 24, 4)), rate: Int(le(f, 28, 4)), samples: le(f, 36, 8),
                    dataOffset: dataAt + 12, dataBytes: max(0, le(dh, 4, 8) - 12), blockSize: Int(le(f, 44, 4)),
                    lsbFirst: bits == 1, tagOffset: meta > 0 ? meta : nil, tagSize: nil)
    }

    /// DSDIFF: big-endian chunks with 64-bit sizes inside "FRM8"…"DSD ".
    private static func dffInfo(_ fd: Int32) -> Info? {
        guard let h = read(fd, 0, 16) else { return nil }
        let end = 12 + be(h, 4, 8)
        var info = Info(container: .dff, channels: 0, rate: 0, samples: 0, dataOffset: 0, dataBytes: 0, blockSize: 1, lsbFirst: false)
        var at: Int64 = 16, seen = 0
        while at + 12 <= end, seen < 512, let c = read(fd, at, 12), c.count == 12 {
            seen += 1
            let id = String(decoding: c[0..<4], as: UTF8.self), size = be(c, 4, 8), body = at + 12
            guard size >= 0 else { return nil }
            switch id {
            case "PROP":
                if size <= 1 << 20, let p = read(fd, body, Int(size)) { readProperties(p, into: &info) }
            case "DSD ":
                info.dataOffset = body
                info.dataBytes = size
            case "DST ":
                info.compressed = true
                info.dataOffset = body
                info.dataBytes = size
            case "DIIN":
                if size <= 1 << 20, let p = read(fd, body, Int(size)) { readDIIN(p, into: &info) }
            case "ID3 ", "id3 ":
                info.tagOffset = body
                info.tagSize = size
            default: break
            }
            at = body + size + (size & 1)   // chunks are padded to an even length
        }
        guard info.channels > 0, info.rate > 0 else { return nil }
        info.samples = info.dataBytes * 8 / Int64(info.channels)
        return info
    }

    /// "SND " then "FS  " (rate), "CHNL" (channel count), "CMPR" (compression).
    private static func readProperties(_ p: [UInt8], into info: inout Info) {
        guard p.count >= 4, p.starts(with: Array("SND ".utf8)) else { return }
        var at = 4
        while at + 12 <= p.count {
            let id = String(decoding: p[at..<(at + 4)], as: UTF8.self), size = Int(be(p, at + 4, 8)), body = at + 12
            guard size >= 0, body + size <= p.count else { return }
            switch id {
            case "FS  " where size >= 4: info.rate = Int(be(p, body, 4))
            case "CHNL" where size >= 2: info.channels = Int(be(p, body, 2))
            case "CMPR" where size >= 4: info.compressed = String(decoding: p[body..<(body + 4)], as: UTF8.self) != "DSD "
            default: break
            }
            at = body + size + (size & 1)
        }
    }

    /// "DIAR" (artist) and "DITI" (title): a 32-bit length, then the text.
    private static func readDIIN(_ p: [UInt8], into info: inout Info) {
        var at = 0
        while at + 12 <= p.count {
            let id = String(decoding: p[at..<(at + 4)], as: UTF8.self), size = Int(be(p, at + 4, 8)), body = at + 12
            guard size >= 0, body + size <= p.count else { return }
            if (id == "DIAR" || id == "DITI"), size >= 4 {
                let n = min(Int(be(p, body, 4)), size - 4)
                let bytes = Array(p[(body + 4)..<(body + 4 + n)])
                let text = (String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1))?
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                if let text, !text.isEmpty { if id == "DIAR" { info.artist = text } else { info.title = text } }
            }
            at = body + size + (size & 1)
        }
    }

    private static func read(_ fd: Int32, _ offset: Int64, _ count: Int) -> [UInt8]? {
        guard count > 0, offset >= 0 else { return nil }
        var out = [UInt8](repeating: 0, count: count)
        let got = out.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        return got == count ? out : nil
    }

    private static func le(_ b: [UInt8], _ at: Int, _ n: Int) -> Int64 {
        var v: Int64 = 0
        for i in (0..<n).reversed() { v = v << 8 | Int64(b[at + i]) }
        return v
    }

    private static func be(_ b: [UInt8], _ at: Int, _ n: Int) -> Int64 {
        var v: Int64 = 0
        for i in 0..<n { v = v << 8 | Int64(b[at + i]) }
        return v
    }

    // MARK: Converting

    /// Converts the DSD file at `path` to a 24-bit PCM CAF at `output`. Blocks until done (a few seconds for a
    /// track at DSD64), so it runs off the main thread. `cancelled` is checked between chunks.
    static func decode(path: String, to output: URL, cancelled: () -> Bool = { false }) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw DecodeError.unreadable }
        defer { close(fd) }
        guard let info = info(fd: fd) else { throw DecodeError.unreadable }
        guard !info.compressed else { throw DecodeError.unsupported("DST-compressed DSD isn't supported") }
        guard info.decodable else { throw DecodeError.unsupported("this DSD file's format isn't supported") }

        let channels = info.channels
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(info.outputRate),
                                      channels: AVAudioChannelCount(channels), interleaved: false) else { throw DecodeError.writeFailed }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(info.outputRate),
                                       AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 24,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file: AVAudioFile
        do { file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw DecodeError.writeFailed }

        let filter = Filter.shared(rate: info.rate, decimation: info.decimation)
        var states = (0..<channels).map { _ in Converter(filter: filter) }
        var expected = Int(info.samples / Int64(info.decimation))
        var written = 0
        let bytesPerChannel = Int((info.samples + 7) / 8)
        var reader = Reader(info: info, fd: fd, bytesPerChannel: bytesPerChannel)

        func write(_ outs: [[Float]]) throws {
            let n = min(outs.first?.count ?? 0, expected - written)
            guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(n)) else { return }
            buf.frameLength = AVAudioFrameCount(n)
            for c in 0..<channels { outs[c].withUnsafeBufferPointer { buf.floatChannelData![c].update(from: $0.baseAddress!, count: n) } }
            try file.write(from: buf)
            written += n
        }

        while let chunk = try reader.next() {
            if cancelled() { throw CancellationError() }
            var outs = [[Float]](repeating: [], count: channels)
            // The channels side by side, each touching only its own state and output.
            states.withUnsafeMutableBufferPointer { st in
                outs.withUnsafeMutableBufferPointer { out in
                    let st = PerChannel(st), out = PerChannel(out)
                    DispatchQueue.concurrentPerform(iterations: channels) { c in out.p[c] = st.p[c].feed(chunk[c]) }
                }
            }
            try write(outs)
        }
        // The last samples: the filters' second halves run over DSD silence.
        var outs = [[Float]](repeating: [], count: channels)
        for c in 0..<channels { outs[c] = states[c].finish() }
        // A file cut short (an interrupted copy) plays up to where its audio ends.
        expected = min(expected, Int(Int64(reader.done) * 8 / Int64(info.decimation)))
        try write(outs)
        guard written > 0 else { throw DecodeError.unreadable }
    }

    /// Per-channel slots shared with the threads that convert the channels side by side: each thread only ever
    /// touches its own channel's slot.
    private struct PerChannel<T>: @unchecked Sendable {
        let p: UnsafeMutableBufferPointer<T>
        init(_ p: UnsafeMutableBufferPointer<T>) { self.p = p }
    }

    /// The audio bytes, per channel, a chunk (~0.75 s at DSD64) at a time, oldest bit first in each byte.
    private struct Reader {
        let info: Info
        let fd: Int32
        let bytesPerChannel: Int
        var done = 0   // bytes per channel handed out
        var offset: Int64
        static let reversed: [UInt8] = (0..<256).map { v in
            var r: UInt8 = 0
            for i in 0..<8 where v & (1 << i) != 0 { r |= 1 << (7 - i) }
            return r
        }

        init(info: Info, fd: Int32, bytesPerChannel: Int) {
            self.info = info
            self.fd = fd
            self.bytesPerChannel = bytesPerChannel
            offset = info.dataOffset
        }

        mutating func next() throws -> [[UInt8]]? {
            guard done < bytesPerChannel else { return nil }
            let ch = info.channels
            // DSF: whole blocks (channels take turns per block); DSDIFF: bytes interleaved channel by channel.
            let perChannel = info.container == .dsf ? info.blockSize * max(1, 262_144 / max(info.blockSize, 1)) : 262_144
            let available = info.dataOffset + info.dataBytes - offset
            let want = Int(min(Int64(perChannel * ch), available))
            guard want > 0 else { return nil }
            var raw = [UInt8](repeating: 0, count: want)
            let got = raw.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(offset)) }
            guard got >= 0 else { throw DecodeError.unreadable }
            guard got > 0 else { return nil }   // the file ends before its header says (cut short)
            var out = [[UInt8]](repeating: [], count: ch)
            if info.container == .dsf {
                let block = max(info.blockSize, 1)
                let blocks = got / (block * ch)
                guard blocks > 0 else { return nil }
                offset += Int64(blocks * block * ch)   // a part read is read again next time
                for c in 0..<ch {
                    out[c].reserveCapacity(blocks * block)
                    for b in 0..<blocks {
                        let start: Int = (b * ch + c) * block
                        out[c] += raw[start..<(start + block)]
                    }
                }
            } else {
                let frames = got / ch
                guard frames > 0 else { return nil }
                offset += Int64(frames * ch)
                for c in 0..<ch { out[c] = stride(from: c, to: frames * ch, by: ch).map { raw[$0] } }
            }
            // The padding after the last sample (DSF fills the last block) isn't audio.
            let keep = min(out[0].count, bytesPerChannel - done)
            done += keep
            for c in 0..<ch {
                if out[c].count > keep { out[c].removeLast(out[c].count - keep) }
                if info.lsbFirst { out[c] = out[c].map { Self.reversed[Int($0)] } }
            }
            return out
        }
    }

    // MARK: The filters

    /// DSD "silence": as many ones as zeros, used before the first and after the last byte.
    static let idle: UInt8 = 0x69

    final class Filter: @unchecked Sendable {   // immutable after init
        /// Stage 1: per byte position, the filter's response to each of its 256 values.
        let table: [Float]
        let groups: Int
        /// Stage 2, applied with vDSP_desamp.
        let taps: [Float]
        let factor: Int

        private static let cache = OSAllocatedUnfairLock(initialState: [Int: Filter]())
        static func shared(rate: Int, decimation: Int) -> Filter {
            let key = rate * 1000 + decimation
            if let f = cache.withLock({ $0[key] }) { return f }
            let f = Filter(rate: rate, decimation: decimation)
            cache.withLock { $0[key] = f }
            return f
        }

        init(rate: Int, decimation: Int) {
            let fs = Double(rate), mid = fs / 8
            // Stage 1 keeps 0–40 kHz and removes what would fold onto it at 1/8 of the rate (from mid − 40 kHz).
            let n1 = Self.length(attenuation: 110, width: (mid - 80_000) / fs)
            groups = (n1 + 7) / 8 + ((n1 + 7) / 8) % 2   // whole bytes, an even number of them
            let h1 = Self.lowpass(count: groups * 8, cutoff: (mid / 2) / fs, attenuation: 110)
            var t = [Float](repeating: 0, count: groups * 256)
            for g in 0..<groups {
                for v in 0..<256 {
                    var sum = 0.0
                    for k in 0..<8 { sum += h1[g * 8 + k] * ((v >> (7 - k)) & 1 == 1 ? 1 : -1) }
                    t[g * 256 + v] = Float(sum)
                }
            }
            table = t
            // Stage 2: flat to 20 kHz, ~100 dB down from 40 kHz.
            factor = decimation / 8
            var n2 = Self.length(attenuation: 100, width: 20_000 / mid)
            if n2 % 2 == 0 { n2 += 1 }   // odd: centred on a sample
            taps = Self.lowpass(count: n2, cutoff: 30_000 / mid, attenuation: 100).map(Float.init)
        }

        /// Kaiser's estimate of the taps needed for this attenuation (dB) over this transition (fraction of fs).
        private static func length(attenuation a: Double, width: Double) -> Int {
            Int(((a - 8) / (2.285 * 2 * .pi * width)).rounded(.up)) + 1
        }

        /// A windowed-sinc low-pass (Kaiser window), its gain at DC 1. `cutoff` is a fraction of the sample rate.
        private static func lowpass(count n: Int, cutoff: Double, attenuation a: Double) -> [Double] {
            let beta = a > 50 ? 0.1102 * (a - 8.7) : 0.5842 * pow(a - 21, 0.4) + 0.07886 * (a - 21)
            let centre = Double(n - 1) / 2
            var h = (0..<n).map { i -> Double in
                let x = Double(i) - centre
                let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
                let r = centre > 0 ? x / centre : 0
                return sinc * bessel0(beta * (1 - r * r).squareRoot()) / bessel0(beta)
            }
            let sum = h.reduce(0, +)
            for i in h.indices { h[i] /= sum }
            return h
        }

        private static func bessel0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-12 * sum {
                term *= (x / (2 * k)) * (x / (2 * k))
                sum += term
                k += 1
            }
            return sum
        }
    }

    /// One channel's conversion, fed byte chunks in order.
    struct Converter {
        let filter: Filter
        /// Bytes still needed by stage 1's next windows (starts with half a window of silence: centred output).
        private var bytes: [UInt8]
        /// Stage 1's output waiting for stage 2 (starts with half its window of zeros, for the same reason).
        private var mid: [Float]

        init(filter: Filter) {
            self.filter = filter
            bytes = [UInt8](repeating: DSD.idle, count: filter.groups / 2)
            mid = [Float](repeating: 0, count: (filter.taps.count - 1) / 2)
        }

        mutating func feed(_ new: [UInt8]) -> [Float] {
            bytes += new
            stage1()
            return stage2()
        }

        /// Runs the filters out over silence: the last real samples come out.
        mutating func finish() -> [Float] {
            bytes += [UInt8](repeating: DSD.idle, count: filter.groups / 2)
            stage1()
            mid += [Float](repeating: 0, count: (filter.taps.count - 1) / 2)
            return stage2()
        }

        private mutating func stage1() {
            let g = filter.groups, count = bytes.count - g + 1
            guard count > 0 else { return }
            var out = [Float](repeating: 0, count: count)
            filter.table.withUnsafeBufferPointer { t in
                bytes.withUnsafeBufferPointer { b in
                    for j in 0..<count {
                        var acc: Float = 0
                        for k in 0..<g { acc += t[k << 8 | Int(b[j + k])] }
                        out[j] = acc
                    }
                }
            }
            mid += out
            bytes.removeFirst(count)
        }

        private mutating func stage2() -> [Float] {
            let p = filter.taps.count, d = filter.factor
            guard mid.count >= p else { return [] }
            let n = (mid.count - p) / d + 1
            var out = [Float](repeating: 0, count: n)
            vDSP_desamp(mid, vDSP_Stride(d), filter.taps, &out, vDSP_Length(n), vDSP_Length(p))
            mid.removeFirst(n * d)
            return out
        }
    }
}
