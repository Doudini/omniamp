import AVFoundation
import Foundation

/// Tag/format readers for chunked containers: WAV (RIFF/RF64), AIFF/AIFC and MP4 (M4A: AAC/ALAC).
/// These keep metadata anywhere in the file, so they seek chunk by chunk instead of reading only the head.
enum ContainerTags {
    /// Random access helper over a file handle.
    private struct Reader {
        let fh: FileHandle
        let size: Int64

        func bytes(_ offset: Int64, _ count: Int) -> [UInt8] {
            guard offset >= 0, offset < size, count > 0 else { return [] }
            try? fh.seek(toOffset: UInt64(offset))
            return [UInt8]((try? fh.read(upToCount: min(count, Int(size - offset)))) ?? Data())
        }
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> Int { i + 2 <= b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
    private static func le32(_ b: [UInt8], _ i: Int) -> Int { i + 4 <= b.count ? le16(b, i) | le16(b, i + 2) << 16 : 0 }
    private static func be16(_ b: [UInt8], _ i: Int) -> Int { i + 2 <= b.count ? Int(b[i]) << 8 | Int(b[i + 1]) : 0 }
    private static func be32(_ b: [UInt8], _ i: Int) -> Int { i + 4 <= b.count ? be16(b, i) << 16 | be16(b, i + 2) : 0 }
    private static func be64(_ b: [UInt8], _ i: Int) -> Int64 { i + 8 <= b.count ? Int64(be32(b, i)) << 32 | Int64(be32(b, i + 4)) : 0 }
    private static func le64(_ b: [UInt8], _ i: Int) -> Int64 { i + 8 <= b.count ? Int64(le32(b, i)) | Int64(le32(b, i + 4)) << 32 : 0 }
    private static func fourCC(_ b: [UInt8], _ i: Int) -> String { i + 4 <= b.count ? String(bytes: b[i..<(i + 4)], encoding: .isoLatin1) ?? "" : "" }

    private static func text(_ b: [UInt8]) -> String? {
        var bytes = b
        while bytes.last == 0 { bytes.removeLast() }
        let s = (String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    private static func merge(_ tags: TagInfo, into info: inout TagInfo) {
        info.title = info.title ?? tags.title
        info.artist = info.artist ?? tags.artist
        info.album = info.album ?? tags.album
    }

    // MARK: WAV

    static func wav(_ fh: FileHandle, fileSize: Int64) -> TagInfo {
        let r = Reader(fh: fh, size: fileSize)
        var info = TagInfo()
        var byteRate = 0
        var dataSize: Int64 = 0
        var ds64DataSize: Int64?
        var p: Int64 = 12
        for _ in 0..<256 where p + 8 <= fileSize {
            let h = r.bytes(p, 8)
            let id = fourCC(h, 0)
            let len = Int64(le32(h, 4))
            let body = p + 8
            switch id {
            case "ds64":                       // RF64: real sizes live here
                let b = r.bytes(body, 28)
                ds64DataSize = le64(b, 8)
            case "fmt ":
                let b = r.bytes(body, 16)
                info.sampleRate = le32(b, 4)
                byteRate = le32(b, 8)
                info.bitDepth = le16(b, 14)
            case "data":
                dataSize = (len == 0xFFFF_FFFF ? ds64DataSize : nil) ?? min(len, fileSize - body)
            case "LIST":
                let b = r.bytes(body, Int(min(len, 64 * 1024)))
                if fourCC(b, 0) == "INFO" { parseRiffInfo(b, into: &info) }
            case "id3 ", "ID3 ":
                merge(TagReader.parseID3Tag(r.bytes(body, Int(min(len, 512 * 1024)))), into: &info)
            default: break
            }
            let chunk = id == "data" ? dataSize : len
            p = body + chunk + (chunk & 1)       // chunks are word aligned
        }
        if byteRate > 0, dataSize > 0 {
            info.duration = Double(dataSize) / Double(byteRate)
            info.bitrate = byteRate * 8 / 1000
        }
        return info
    }

    private static func parseRiffInfo(_ b: [UInt8], into info: inout TagInfo) {
        var p = 4
        while p + 8 <= b.count {
            let id = fourCC(b, p), len = le32(b, p + 4)
            let v = text(Array(b[(p + 8)..<min(p + 8 + len, b.count)]))
            switch id {
            case "INAM": info.title = info.title ?? v
            case "IART": info.artist = info.artist ?? v
            case "IPRD": info.album = info.album ?? v
            default: break
            }
            p += 8 + len + (len & 1)
        }
    }

    // MARK: AIFF / AIFC

    static func aiff(_ fh: FileHandle, fileSize: Int64) -> TagInfo {
        let r = Reader(fh: fh, size: fileSize)
        var info = TagInfo()
        var p: Int64 = 12
        for _ in 0..<256 where p + 8 <= fileSize {
            let h = r.bytes(p, 8)
            let id = fourCC(h, 0)
            let len = Int64(be32(h, 4))
            let body = p + 8
            switch id {
            case "COMM":
                let b = r.bytes(body, 18)
                let channels = be16(b, 0), frames = be32(b, 2)
                info.bitDepth = be16(b, 6)
                let sr = extended80(Array(b[min(8, b.count)..<min(18, b.count)]))
                if sr > 0 {
                    info.sampleRate = Int(sr.rounded())
                    info.duration = Double(frames) / sr
                    info.bitrate = Int(sr) * channels * (info.bitDepth ?? 16) / 1000
                }
            case "NAME": info.title = info.title ?? text(r.bytes(body, Int(min(len, 1024))))
            case "AUTH": info.artist = info.artist ?? text(r.bytes(body, Int(min(len, 1024))))
            case "ID3 ", "id3 ":
                merge(TagReader.parseID3Tag(r.bytes(body, Int(min(len, 512 * 1024)))), into: &info)
            default: break
            }
            p = body + len + (len & 1)
        }
        return info
    }

    /// IEEE 754 80-bit extended (AIFF sample rate).
    static func extended80(_ b: [UInt8]) -> Double {
        guard b.count == 10 else { return 0 }
        let exp = Int(b[0] & 0x7F) << 8 | Int(b[1])
        var mant: UInt64 = 0
        for i in 2..<10 { mant = mant << 8 | UInt64(b[i]) }
        guard exp != 0 || mant != 0 else { return 0 }
        let v = Double(mant) * pow(2, Double(exp - 16383 - 63))
        return b[0] & 0x80 != 0 ? -v : v
    }

    // MARK: MP4 / M4A

    static func mp4(_ fh: FileHandle, fileSize: Int64) -> TagInfo {
        let r = Reader(fh: fh, size: fileSize)
        var info = TagInfo()
        // Find moov at the top level (it may be after mdat, at the end of the file).
        var p: Int64 = 0
        var moov: [UInt8]?
        for _ in 0..<64 where p + 8 <= fileSize {
            let h = r.bytes(p, 16)
            var len = Int64(be32(h, 0))
            let type = fourCC(h, 4)
            var header: Int64 = 8
            if len == 1 { len = be64(h, 8); header = 16 } else if len == 0 { len = fileSize - p }
            guard len >= header else { break }
            if type == "moov" {
                moov = r.bytes(p + header, Int(min(len - header, 32 * 1024 * 1024)))
                break
            }
            p += len
        }
        guard let m = moov else { return info }
        var validSamples: Int64?
        walkMP4(m, 0, m.count, into: &info, validSamples: &validSamples)
        // AAC encoder priming/padding: iTunSMPB holds the real sample count.
        if let n = validSamples, n > 0, let sr = info.sampleRate, sr > 0 { info.duration = Double(n) / Double(sr) }
        if let d = info.duration, d > 0, info.bitrate == nil {
            info.bitrate = Int(Double(fileSize) * 8 / d / 1000)
        }
        return info
    }

    /// Recursive atom walk over the moov box.
    private static func walkMP4(_ b: [UInt8], _ start: Int, _ end: Int, into info: inout TagInfo, validSamples: inout Int64?) {
        var p = start
        while p + 8 <= end {
            var len = be32(b, p)
            let type = fourCC(b, p + 4)
            var header = 8
            if len == 1 { len = Int(be64(b, p + 8)); header = 16 } else if len == 0 { len = end - p }
            guard len >= header, p + len <= end else { return }
            let body = p + header
            let bodyEnd = p + len
            switch type {
            case "trak", "mdia", "minf", "stbl", "udta", "ilst":
                walkMP4(b, body, bodyEnd, into: &info, validSamples: &validSamples)
            case "meta":
                walkMP4(b, body + 4, bodyEnd, into: &info, validSamples: &validSamples)   // full box: skip version/flags
            case "----":
                // Freeform iTunes item: mean / name / data. We only want iTunSMPB.
                if let (name, value) = freeform(b, body, bodyEnd) {
                    if name == "iTunSMPB" {
                        let f = value.split(separator: " ")
                        if f.count > 3, let n = Int64(f[3], radix: 16) { validSamples = n }
                    } else {
                        info.setReplayGain(key: name, value: value)   // ----:com.apple.iTunes:replaygain_*
                    }
                }
            case "mdhd":
                // Audio track media header: timescale is usually the sample rate.
                let v1 = b[body] == 1
                let ts = be32(b, body + (v1 ? 20 : 12))
                let dur = v1 ? Double(be64(b, body + 24)) : Double(be32(b, body + 16))
                if ts > 0, info.duration == nil {
                    info.duration = dur / Double(ts)
                    info.sampleRate = info.sampleRate ?? ts
                }
            case "stsd":
                // First sample entry: format (e.g. "alac", "mp4a"), then the audio sample entry.
                let entry = body + 8
                let format = fourCC(b, entry + 4)
                let sampleSize = be16(b, entry + 8 + 18)
                if format == "alac" || format == "lpcm" || format == "sowt" || format == "twos" {
                    info.bitDepth = sampleSize > 0 ? sampleSize : info.bitDepth
                    // The ALAC magic cookie has the real sample rate (can exceed 65535 Hz).
                    let cookie = entry + 36
                    if format == "alac", fourCC(b, cookie + 4) == "alac" {
                        let c = cookie + 12
                        info.bitDepth = Int(b[min(c + 5, b.count - 1)])
                        let rate = be32(b, c + 20)
                        if rate > 0 { info.sampleRate = rate }
                    }
                }
            case "\u{A9}nam": if info.title == nil { info.title = mp4Text(b, body, bodyEnd) }
            case "\u{A9}ART": if info.artist == nil { info.artist = mp4Text(b, body, bodyEnd) }
            case "aART": if info.artist == nil { info.artist = mp4Text(b, body, bodyEnd) }
            case "\u{A9}alb": if info.album == nil { info.album = mp4Text(b, body, bodyEnd) }
            default: break
            }
            p = bodyEnd
        }
    }

    private static func freeform(_ b: [UInt8], _ start: Int, _ end: Int) -> (String, String)? {
        var p = start
        var name: String?, value: String?
        while p + 8 <= end {
            let len = be32(b, p)
            guard len >= 8, p + len <= end else { break }
            switch fourCC(b, p + 4) {
            case "name": name = text(Array(b[(p + 12)..<(p + len)]))           // 4 bytes version/flags
            case "data": value = len > 16 ? text(Array(b[(p + 16)..<(p + len)])) : nil
            default: break
            }
            p += len
        }
        guard let n = name, let v = value else { return nil }
        return (n, v)
    }

    /// ilst item → its "data" atom (type + locale header, then UTF-8 text).
    private static func mp4Text(_ b: [UInt8], _ start: Int, _ end: Int) -> String? {
        guard start + 16 <= end, fourCC(b, start + 4) == "data" else { return nil }
        let len = min(be32(b, start), end - start)
        guard len > 16 else { return nil }
        return text(Array(b[(start + 16)..<(start + len)]))
    }

    // MARK: Fallback

    /// Duration/format via Core Audio for files the fast parsers don't understand (raw AAC, CAF…). Slower.
    static func coreAudioInfo(path: String) -> TagInfo {
        var info = TagInfo()
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return info }
        let sr = f.fileFormat.sampleRate
        if sr > 0 {
            info.sampleRate = Int(sr)
            info.duration = Double(f.length) / sr
        }
        let bits = Int(f.fileFormat.streamDescription.pointee.mBitsPerChannel)
        if bits > 0 { info.bitDepth = bits }
        return info
    }
}
