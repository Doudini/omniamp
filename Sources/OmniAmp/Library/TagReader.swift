import Foundation

struct TagInfo: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var bitrate: Int?
    var sampleRate: Int?
    var bitDepth: Int?
    // ReplayGain (dB / linear peak).
    var rgTrackGain: Float?
    var rgAlbumGain: Float?
    var rgTrackPeak: Float?
    var rgAlbumPeak: Float?

    /// REPLAYGAIN_TRACK_GAIN = "-6.54 dB", REPLAYGAIN_TRACK_PEAK = "0.98" … (any container, any case).
    mutating func setReplayGain(key: String, value: String) {
        let k = key.uppercased()
        guard k.hasPrefix("REPLAYGAIN_") else { return }
        let num = Float(value.replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        switch k {
        case "REPLAYGAIN_TRACK_GAIN": rgTrackGain = num
        case "REPLAYGAIN_ALBUM_GAIN": rgAlbumGain = num
        case "REPLAYGAIN_TRACK_PEAK": rgTrackPeak = num
        case "REPLAYGAIN_ALBUM_PEAK": rgAlbumPeak = num
        default: break
        }
    }
}

/// A read buffer to reuse across files. Tag loading reads the head of every file in a folder; a fresh
/// 128 KB allocation per file (10,000 files = over a gigabyte of churn) left ~300 MB of freed-but-dirty
/// malloc pages that macOS took a minute to reclaim.
final class TagReadBuffer {
    fileprivate var bytes = [UInt8](repeating: 0, count: TagReader.headSize)
}

/// Minimal, fast tag reader: reads only the head (and for ID3v1 the tail) of a file.
enum TagReader {
    static let headSize = 128 * 1024

    static func read(path: String, fileSize: Int64, buffer: TagReadBuffer? = nil) -> TagInfo {
        autoreleasepool { readHead(path: path, fileSize: fileSize, buffer: buffer ?? TagReadBuffer()) }
    }

    private static func readHead(path: String, fileSize: Int64, buffer: TagReadBuffer) -> TagInfo {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return TagInfo() }
        defer { close(fd) }
        let n = buffer.bytes.withUnsafeMutableBytes { p -> Int in
            var got = 0
            while got < p.count {
                let r = Darwin.read(fd, p.baseAddress! + got, p.count - got)
                if r <= 0 { break }
                got += r
            }
            return got
        }
        // Full buffer (any real audio file): parse it in place, no copy.
        let head = n == buffer.bytes.count ? buffer.bytes : Array(buffer.bytes[0..<n])
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "flac" || head.starts(with: [0x66, 0x4C, 0x61, 0x43]) {
            return parseFLAC(head)
        }
        // Container formats may keep tags/indexes anywhere in the file, so they seek.
        let magic = Array(head.prefix(12))
        if magic.count == 12 {
            let tag4 = String(decoding: magic[0..<4], as: UTF8.self), form = String(decoding: magic[8..<12], as: UTF8.self)
            let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            if (tag4 == "RIFF" || tag4 == "RF64") && form == "WAVE" { return ContainerTags.wav(fh, fileSize: fileSize) }
            if tag4 == "FORM" && (form == "AIFF" || form == "AIFC") { return ContainerTags.aiff(fh, fileSize: fileSize) }
            if String(decoding: magic[4..<8], as: UTF8.self) == "ftyp" { return ContainerTags.mp4(fh, fileSize: fileSize) }
        }
        if ext != "mp3" {
            // Raw AAC, CAF and other odd files: let Core Audio work it out (slower, but rare).
            var info = parseID3Tag(head)
            let ca = ContainerTags.coreAudioInfo(path: path)
            info.duration = ca.duration
            info.sampleRate = ca.sampleRate
            info.bitDepth = ext == "aac" ? nil : ca.bitDepth
            if let d = info.duration, d > 0 { info.bitrate = Int(Double(fileSize) * 8 / d / 1000) }
            return info
        }
        var info = parseMP3(head, fileSize: fileSize)
        if info.title == nil, fileSize > 128 {
            var tail = [UInt8](repeating: 0, count: 128)
            if tail.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, 128, off_t(fileSize - 128)) }) == 128 {
                let v1 = parseID3v1(tail)
                info.title = info.title ?? v1.title
                info.artist = info.artist ?? v1.artist
                info.album = info.album ?? v1.album
            }
        }
        return info
    }

    // MARK: FLAC

    static func parseFLAC(_ b: [UInt8]) -> TagInfo {
        var info = TagInfo()
        guard b.count >= 8, b[0] == 0x66, b[1] == 0x4C, b[2] == 0x61, b[3] == 0x43 else { return info }
        var p = 4
        while p + 4 <= b.count {
            let hdr = b[p]
            let isLast = hdr & 0x80 != 0
            let type = hdr & 0x7F
            let len = Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
            let start = p + 4
            let end = start + len
            if type == 0, end <= b.count, len >= 18 {
                // STREAMINFO: sample rate 20 bits, channels 3, bps 5, total samples 36
                let s = start + 10
                let sr = Int(b[s]) << 12 | Int(b[s + 1]) << 4 | Int(b[s + 2]) >> 4
                let total = Int64(b[s + 3] & 0x0F) << 32 | Int64(b[s + 4]) << 24 | Int64(b[s + 5]) << 16 | Int64(b[s + 6]) << 8 | Int64(b[s + 7])
                info.bitDepth = Int((b[s + 2] & 0x01) << 4 | b[s + 3] >> 4) + 1
                if sr > 0 {
                    info.sampleRate = sr
                    if total > 0 { info.duration = Double(total) / Double(sr) }
                }
            } else if type == 4 {
                parseVorbisComments(b, start, min(end, b.count), into: &info)
            }
            if isLast || end > b.count { break }
            p = end
        }
        return info
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> Int? {
        guard i + 4 <= b.count else { return nil }
        return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }

    private static func parseVorbisComments(_ b: [UInt8], _ start: Int, _ end: Int, into info: inout TagInfo) {
        var p = start
        guard let vlen = le32(b, p) else { return }
        p += 4 + vlen
        guard p <= end, let count = le32(b, p) else { return }
        p += 4
        for _ in 0..<min(count, 1000) {
            guard let l = le32(b, p), p + 4 + l <= end else { return }
            let s = String(decoding: b[(p + 4)..<(p + 4 + l)], as: UTF8.self)
            p += 4 + l
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = s[..<eq].uppercased()
            let val = String(s[s.index(after: eq)...])
            switch key {
            case "TITLE": if info.title == nil { info.title = val }
            case "ARTIST": if info.artist == nil { info.artist = val }
            case "ALBUM": if info.album == nil { info.album = val }
            case let k where k.hasPrefix("REPLAYGAIN_"): info.setReplayGain(key: k, value: val)
            default: break
            }
        }
    }

    // MARK: MP3

    static func parseMP3(_ b: [UInt8], fileSize: Int64) -> TagInfo {
        var info = TagInfo()
        var audioStart = 0
        if b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { // "ID3"
            let ver = b[3]
            let flags = b[5]
            let size = Int(b[6] & 0x7F) << 21 | Int(b[7] & 0x7F) << 14 | Int(b[8] & 0x7F) << 7 | Int(b[9] & 0x7F)
            audioStart = 10 + size + (flags & 0x10 != 0 ? 10 : 0)
            parseID3v2(b, version: ver, flags: flags, tagEnd: min(10 + size, b.count), into: &info)
        }
        parseMPEGAudio(b, from: audioStart, fileSize: fileSize, into: &info)
        return info
    }

    /// Parse a standalone ID3v2 tag (e.g. the "id3 " chunk inside WAV/AIFF).
    static func parseID3Tag(_ b: [UInt8]) -> TagInfo {
        var info = TagInfo()
        guard b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return info }
        let size = Int(b[6] & 0x7F) << 21 | Int(b[7] & 0x7F) << 14 | Int(b[8] & 0x7F) << 7 | Int(b[9] & 0x7F)
        parseID3v2(b, version: b[3], flags: b[5], tagEnd: min(10 + size, b.count), into: &info)
        return info
    }

    private static func parseID3v2(_ b: [UInt8], version: UInt8, flags: UInt8, tagEnd: Int, into info: inout TagInfo) {
        var p = 10
        if flags & 0x40 != 0, p + 4 <= tagEnd { // extended header
            let n = version == 4
                ? Int(b[p] & 0x7F) << 21 | Int(b[p + 1] & 0x7F) << 14 | Int(b[p + 2] & 0x7F) << 7 | Int(b[p + 3] & 0x7F)
                : Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3]) + 4
            p += n
        }
        if version == 2 {
            while p + 6 <= tagEnd {
                let id = String(decoding: b[p..<(p + 3)], as: UTF8.self)
                let size = Int(b[p + 3]) << 16 | Int(b[p + 4]) << 8 | Int(b[p + 5])
                if b[p] == 0 || size <= 0 { break }
                let s = p + 6, e = min(s + size, tagEnd)
                switch id {
                case "TT2": info.title = decodeText(b, s, e)
                case "TP1": info.artist = decodeText(b, s, e)
                case "TAL": info.album = decodeText(b, s, e)
                default: break
                }
                p = s + size
            }
            return
        }
        while p + 10 <= tagEnd {
            if b[p] == 0 { break }
            let id = String(decoding: b[p..<(p + 4)], as: UTF8.self)
            let size = version == 4
                ? Int(b[p + 4] & 0x7F) << 21 | Int(b[p + 5] & 0x7F) << 14 | Int(b[p + 6] & 0x7F) << 7 | Int(b[p + 7] & 0x7F)
                : Int(b[p + 4]) << 24 | Int(b[p + 5]) << 16 | Int(b[p + 6]) << 8 | Int(b[p + 7])
            if size <= 0 { break }
            let s = p + 10, e = min(s + size, tagEnd)
            if s < e {
                switch id {
                case "TIT2": info.title = decodeText(b, s, e)
                case "TPE1": info.artist = decodeText(b, s, e)
                case "TALB": info.album = decodeText(b, s, e)
                case "TLEN":
                    if info.duration == nil, let ms = Double(decodeText(b, s, e) ?? ""), ms > 0 { info.duration = ms / 1000 }
                case "TXXX":
                    // User text: description\0value (ReplayGain lives here).
                    let parts = decodeParts(b, s, e)
                    if parts.count >= 2 { info.setReplayGain(key: parts[0], value: parts[1]) }
                default: break
                }
            }
            p = s + size
        }
    }

    static func decodeText(_ b: [UInt8], _ s: Int, _ e: Int) -> String? {
        guard s < e else { return nil }
        let enc = b[s]
        var bytes = Array(b[(s + 1)..<e])
        let str: String?
        switch enc {
        case 0: // ISO-8859-1
            while bytes.last == 0 { bytes.removeLast() }
            str = String(bytes: bytes, encoding: .isoLatin1)
        case 1: // UTF-16 with BOM
            str = String(bytes: stripUTF16Null(bytes), encoding: .utf16)
        case 2:
            str = String(bytes: stripUTF16Null(bytes), encoding: .utf16BigEndian)
        default:
            while bytes.last == 0 { bytes.removeLast() }
            str = String(bytes: bytes, encoding: .utf8)
        }
        // Multiple values are NUL-separated; keep the first.
        let first = str?.split(separator: "\0", omittingEmptySubsequences: true).first.map(String.init)
        let t = first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    /// All NUL-separated values of a text frame (TXXX needs description + value).
    static func decodeParts(_ b: [UInt8], _ s: Int, _ e: Int) -> [String] {
        guard s < e else { return [] }
        let enc = b[s]
        let bytes = Array(b[(s + 1)..<e])
        let str: String?
        switch enc {
        case 0: str = String(bytes: bytes, encoding: .isoLatin1)
        case 1: str = String(bytes: bytes.count % 2 == 1 ? Array(bytes.dropLast()) : bytes, encoding: .utf16)
        case 2: str = String(bytes: bytes.count % 2 == 1 ? Array(bytes.dropLast()) : bytes, encoding: .utf16BigEndian)
        default: str = String(bytes: bytes, encoding: .utf8)
        }
        return (str ?? "").components(separatedBy: "\0")
            .map { $0.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func stripUTF16Null(_ bytes: [UInt8]) -> [UInt8] {
        var b = bytes
        if b.count % 2 == 1 { b.removeLast() }
        while b.count >= 2, b[b.count - 1] == 0, b[b.count - 2] == 0 { b.removeLast(2) }
        return b
    }

    static func parseID3v1(_ b: [UInt8]) -> TagInfo {
        var info = TagInfo()
        guard b.count == 128, b[0] == 0x54, b[1] == 0x41, b[2] == 0x47 else { return info } // "TAG"
        func field(_ r: Range<Int>) -> String? {
            var bytes = Array(b[r])
            if let z = bytes.firstIndex(of: 0) { bytes = Array(bytes[..<z]) }
            let s = String(bytes: bytes, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespaces)
            return (s?.isEmpty ?? true) ? nil : s
        }
        info.title = field(3..<33)
        info.artist = field(33..<63)
        info.album = field(63..<93)
        return info
    }

    private static let bitrateTable: [[Int]] = [
        // MPEG1 Layer III
        [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0],
        // MPEG2/2.5 Layer III
        [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0],
    ]
    private static let sampleRateTable: [[Int]] = [
        [44100, 48000, 32000], // MPEG1
        [22050, 24000, 16000], // MPEG2
        [11025, 12000, 8000],  // MPEG2.5
    ]

    private static func parseMPEGAudio(_ b: [UInt8], from start: Int, fileSize: Int64, into info: inout TagInfo) {
        var p = max(0, start)
        // Find the first frame sync.
        while p + 4 <= b.count {
            if b[p] == 0xFF, b[p + 1] & 0xE0 == 0xE0 {
                let verBits = (b[p + 1] >> 3) & 0x03   // 3=MPEG1, 2=MPEG2, 0=MPEG2.5
                let layer = (b[p + 1] >> 1) & 0x03     // 1=Layer III
                let brIdx = Int(b[p + 2] >> 4)
                let srIdx = Int((b[p + 2] >> 2) & 0x03)
                if verBits != 1, layer == 1, brIdx != 0, brIdx != 15, srIdx != 3 {
                    let isV1 = verBits == 3
                    let sr = sampleRateTable[verBits == 3 ? 0 : (verBits == 2 ? 1 : 2)][srIdx]
                    let br = bitrateTable[isV1 ? 0 : 1][brIdx]
                    let mono = (b[p + 3] >> 6) == 3
                    let samplesPerFrame = isV1 ? 1152 : 576
                    info.sampleRate = sr
                    // Xing/Info header lives after the side info.
                    let sideInfo = isV1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
                    let x = p + 4 + sideInfo
                    if x + 12 <= b.count {
                        let tag = String(decoding: b[x..<(x + 4)], as: UTF8.self)
                        if tag == "Xing" || tag == "Info" {
                            let flags = be32(b, x + 4)
                            if flags & 1 != 0, let frames = Optional(be32(b, x + 8)), frames > 0 {
                                let d = Double(frames) * Double(samplesPerFrame) / Double(sr)
                                info.duration = d
                                let audioBytes = flags & 2 != 0 && x + 16 <= b.count ? Double(be32(b, x + 12)) : Double(fileSize - Int64(p))
                                if d > 0 { info.bitrate = Int((audioBytes * 8 / d / 1000).rounded()) }
                                return
                            }
                        }
                    }
                    let v = p + 4 + 32
                    if v + 18 <= b.count, String(decoding: b[v..<(v + 4)], as: UTF8.self) == "VBRI" {
                        let bytes = be32(b, v + 10), frames = be32(b, v + 14)
                        if frames > 0 {
                            let d = Double(frames) * Double(samplesPerFrame) / Double(sr)
                            info.duration = d
                            if d > 0 { info.bitrate = Int((Double(bytes) * 8 / d / 1000).rounded()) }
                            return
                        }
                    }
                    // CBR estimate.
                    info.bitrate = br
                    if info.duration == nil, br > 0 {
                        info.duration = Double(fileSize - Int64(p)) * 8 / Double(br * 1000)
                    }
                    return
                }
            }
            p += 1
        }
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 4 <= b.count else { return 0 }
        return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }
}
