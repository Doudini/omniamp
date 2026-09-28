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
        info.albumArtist = info.albumArtist ?? tags.albumArtist
        info.date = info.date ?? tags.date
        info.originalDate = info.originalDate ?? tags.originalDate
        info.genre = info.genre ?? tags.genre
        info.trackNumber = info.trackNumber ?? tags.trackNumber
        info.discNumber = info.discNumber ?? tags.discNumber
        info.mbArtistID = info.mbArtistID ?? tags.mbArtistID
        info.mbReleaseGroupID = info.mbReleaseGroupID ?? tags.mbReleaseGroupID
        info.releaseType = info.releaseType ?? tags.releaseType
        info.releaseStatus = info.releaseStatus ?? tags.releaseStatus
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
                dataSize = min(max((len == 0xFFFF_FFFF ? ds64DataSize : nil) ?? len, 0), fileSize - body)
            case "LIST":
                let b = r.bytes(body, Int(min(len, 64 * 1024)))
                if fourCC(b, 0) == "INFO" { parseRiffInfo(b, into: &info) }
            case "id3 ", "ID3 ":
                merge(TagReader.parseID3Tag(r.bytes(body, Int(min(len, 512 * 1024)))), into: &info)
            default: break
            }
            // Sizes come from the file: clamp so a bogus ds64 value can't overflow.
            let chunk = min(max(id == "data" ? dataSize : len, 0), fileSize - body)
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
            case "IGNR": if let v { info.setNamed(key: "GENRE", value: v) }
            case "ICRD": if let v { info.setNamed(key: "DATE", value: v) }
            case "ITRK", "IPRT": if let v { info.setNamed(key: "TRACKNUMBER", value: v) }
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
                if sr > 0, sr.isFinite, sr < 10_000_000 {
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
            guard len >= header, len <= fileSize - p else { break }
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
            info.bitrate = Sane.kbps(bytes: fileSize, seconds: d)
        }
        return info
    }

    /// Recursive atom walk over the moov box.
    /// Real files nest boxes 6–8 deep; a crafted one could nest thousands and overflow the stack.
    static let maxBoxDepth = 16

    private static func walkMP4(_ b: [UInt8], _ start: Int, _ end: Int, into info: inout TagInfo, validSamples: inout Int64?,
                                depth: Int = 0) {
        guard depth < maxBoxDepth else { return }
        var p = start
        while p + 8 <= end {
            var len = be32(b, p)
            let type = fourCC(b, p + 4)
            var header = 8
            if len == 1 { len = Int(be64(b, p + 8)); header = 16 } else if len == 0 { len = end - p }
            guard len >= header, len <= end - p else { return }
            let body = p + header
            let bodyEnd = p + len
            switch type {
            case "trak", "mdia", "minf", "stbl", "udta", "ilst":
                walkMP4(b, body, bodyEnd, into: &info, validSamples: &validSamples, depth: depth + 1)
            case "meta":
                walkMP4(b, body + 4, bodyEnd, into: &info, validSamples: &validSamples, depth: depth + 1)   // full box: skip version/flags
            case "----":
                // Freeform iTunes item: mean / name / data. We only want iTunSMPB.
                if let (name, value) = freeform(b, body, bodyEnd) {
                    if name == "iTunSMPB" {
                        let f = value.split(separator: " ")
                        if f.count > 3, let n = Int64(f[3], radix: 16) { validSamples = n }
                    } else {
                        info.setNamed(key: name, value: value)   // replaygain_*, MusicBrainz IDs, release type…
                    }
                }
            case "mdhd":
                // Audio track media header: timescale is usually the sample rate.
                guard body < bodyEnd else { break }
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
            case "aART": if info.albumArtist == nil { info.albumArtist = mp4Text(b, body, bodyEnd) }
            case "\u{A9}alb": if info.album == nil { info.album = mp4Text(b, body, bodyEnd) }
            case "\u{A9}day": if info.date == nil { info.date = mp4Text(b, body, bodyEnd) }
            case "\u{A9}gen": if info.genre == nil { info.genre = mp4Text(b, body, bodyEnd) }
            case "gnre":
                if info.genre == nil, let v = mp4Data(b, body, bodyEnd), v.count >= 2, be16(v, 0) > 0 {
                    info.genre = DetailsReader.genreName(String(be16(v, 0) - 1))
                }
            case "trkn": if let v = mp4Data(b, body, bodyEnd), v.count >= 4, be16(v, 2) > 0 { info.trackNumber = be16(v, 2) }
            case "disk": if let v = mp4Data(b, body, bodyEnd), v.count >= 4, be16(v, 2) > 0 { info.discNumber = be16(v, 2) }
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
            case "name": name = len > 12 ? text(Array(b[(p + 12)..<(p + len)])) : nil           // 4 bytes version/flags
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
        mp4Data(b, start, end).flatMap(text)
    }

    /// ilst item → the raw value of its "data" atom.
    private static func mp4Data(_ b: [UInt8], _ start: Int, _ end: Int) -> [UInt8]? {
        guard start + 16 <= end, fourCC(b, start + 4) == "data" else { return nil }
        let len = min(be32(b, start), end - start)
        guard len > 16 else { return nil }
        return Array(b[(start + 16)..<(start + len)])
    }

    // MARK: ASF (WMA)

    static let asfHeader: [UInt8] = [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C]
    private static let asfFileProperties: [UInt8] = [0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, 0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65]
    private static let asfStreamProperties: [UInt8] = [0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65]
    private static let asfContent: [UInt8] = [0x33, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C]
    private static let asfExtendedContent: [UInt8] = [0x40, 0xA4, 0xD0, 0xD2, 0x07, 0xE3, 0xD2, 0x11, 0x97, 0xF0, 0x00, 0xA0, 0xC9, 0x5E, 0xA8, 0x50]

    /// Windows Media tags and length, from the ASF header objects (OmniAmp can't play WMA; the library lists it).
    static func asf(_ fh: FileHandle, fileSize: Int64) -> TagInfo {
        let r = Reader(fh: fh, size: fileSize)
        var info = TagInfo()
        let h = r.bytes(0, 30)
        guard h.count == 30, Array(h[0..<16]) == asfHeader else { return info }
        let headerSize = Int(min(le64(h, 16), 4 << 20))
        let count = le32(h, 24)
        var p: Int64 = 30
        func utf16(_ b: ArraySlice<UInt8>) -> String? {
            var bytes = Array(b)
            if bytes.count % 2 == 1 { bytes.removeLast() }
            while bytes.count >= 2, bytes[bytes.count - 1] == 0, bytes[bytes.count - 2] == 0 { bytes.removeLast(2) }
            let t = String(bytes: bytes, encoding: .utf16LittleEndian)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        for _ in 0..<min(count, 64) where p + 24 <= Int64(headerSize) {
            let oh = r.bytes(p, 24)
            guard oh.count == 24 else { break }
            let guid = Array(oh[0..<16]), size = le64(oh, 16)
            guard size >= 24, p + size <= Int64(headerSize) else { break }
            // Pictures can make an object large; the tag objects themselves are small.
            let body = guid == asfExtendedContent || guid == asfContent || guid == asfFileProperties || guid == asfStreamProperties
                ? r.bytes(p + 24, Int(min(size - 24, 1 << 20))) : []
            if guid == asfFileProperties, body.count >= 64 {
                let duration = Double(le64(body, 40)) / 10_000_000 - Double(le64(body, 56)) / 1000
                info.duration = duration > 0 ? duration : nil
                info.bitrate = Sane.kbps(bytes: fileSize, seconds: info.duration)
            } else if guid == asfStreamProperties, body.count >= 54 + 8 {
                let rate = le32(body, 54 + 4)
                if rate > 0, info.sampleRate == nil { info.sampleRate = rate }
            } else if guid == asfContent, body.count >= 10 {
                let lens = (0..<5).map { le16(body, $0 * 2) }
                var at = 10
                var fields: [String?] = []
                for l in lens {
                    fields.append(at + l <= body.count ? utf16(body[at..<(at + l)]) : nil)
                    at += l
                }
                info.title = info.title ?? fields[0]
                info.artist = info.artist ?? fields[1]
            } else if guid == asfExtendedContent, body.count >= 2 {
                var at = 2
                for _ in 0..<min(le16(body, 0), 512) {
                    guard at + 2 <= body.count else { break }
                    let nl = le16(body, at)
                    guard at + 2 + nl + 4 <= body.count else { break }
                    let name = utf16(body[(at + 2)..<(at + 2 + nl)]) ?? ""
                    at += 2 + nl
                    let type = le16(body, at), vl = le16(body, at + 2)
                    at += 4
                    guard at + vl <= body.count else { break }
                    let raw = body[at..<(at + vl)]
                    at += vl
                    let value: String?
                    switch type {
                    case 0: value = utf16(raw)
                    case 3: value = String(le32(Array(raw), 0))
                    case 5: value = String(le16(Array(raw), 0))
                    default: value = nil
                    }
                    guard let v = value else { continue }
                    switch name {
                    case "WM/AlbumTitle": info.album = info.album ?? v
                    case "WM/AlbumArtist": info.albumArtist = info.albumArtist ?? v
                    case "WM/Year": info.date = info.date ?? v
                    case "WM/OriginalReleaseYear": info.originalDate = info.originalDate ?? v
                    case "WM/Genre": info.genre = info.genre ?? v
                    case "WM/TrackNumber", "WM/Track":
                        info.trackNumber = info.trackNumber ?? TagInfo.leadingInt(v).map { name == "WM/Track" ? $0 + 1 : $0 }
                    case "WM/PartOfSet": info.discNumber = info.discNumber ?? TagInfo.leadingInt(v)
                    default: info.setNamed(key: name.replacingOccurrences(of: "/", with: ""), value: v)   // MusicBrainz/…, replaygain_…
                    }
                }
            }
            p += size
        }
        return info
    }

    // MARK: Fallback

    /// Duration/format via Core Audio for files the fast parsers don't understand (raw AAC, CAF…). Slower.
    static func coreAudioInfo(path: String) -> TagInfo {
        var info = TagInfo()
        guard let f = try? AVAudioFile(forReading: URL(exactPath: path)) else { return info }
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
