import Foundation

/// Everything the INFO drawer / hover card shows, read on demand for one track (never for the whole list).
struct TrackDetails {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var year: String?
    var genre: String?
    var track: Int?
    var trackTotal: Int?
    var disc: Int?
    var discTotal: Int?
    var composer: String?
    var comment: String?
    /// Compressed image bytes (JPEG/PNG), embedded or from a cover file next to the track.
    var artwork: Data?
    var artworkSource: String?   // "embedded" or the cover file name
}

/// Full-tag reader: ID3v2 (MP3, and inside WAV/AIFF), FLAC metadata blocks, MP4 ilst. Reads whole tags,
/// including pictures, so it is only used for the one or two tracks on screen.
enum DetailsReader {
    static func read(path: String) -> TrackDetails {
        var d = TrackDetails()
        guard let fh = FileHandle(forReadingAtPath: path) else { return d }
        defer { try? fh.close() }
        let size = Int64((try? fh.seekToEnd()) ?? 0)
        try? fh.seek(toOffset: 0)
        let head = [UInt8]((try? fh.read(upToCount: 12)) ?? Data())
        func bytes(_ offset: Int64, _ count: Int) -> [UInt8] {
            [UInt8](data(offset, count))
        }
        func data(_ offset: Int64, _ count: Int) -> Data {
            guard offset >= 0, offset < size, count > 0 else { return Data() }
            try? fh.seek(toOffset: UInt64(offset))
            return (try? fh.read(upToCount: min(count, Int(size - offset)))) ?? Data()
        }

        if head.starts(with: Array("fLaC".utf8)) {
            readFLAC(bytes, data, size: size, into: &d)
        } else if head.starts(with: Array("ID3".utf8)) {
            let h = bytes(0, 10)
            readID3(bytes(0, 10 + synchsafe(h, 6)), into: &d)
        } else if head.count == 12, String(decoding: head[4..<8], as: UTF8.self) == "ftyp" {
            readMP4(bytes, size: size, into: &d)
        } else if head.count == 12 {
            // WAV / AIFF: an embedded "id3 " chunk carries the tags.
            let tag4 = String(decoding: head[0..<4], as: UTF8.self)
            let littleEndian = tag4 == "RIFF" || tag4 == "RF64"
            if littleEndian || tag4 == "FORM" {
                var p: Int64 = 12
                for _ in 0..<256 where p + 8 <= size {
                    let h = bytes(p, 8)
                    let id = String(decoding: h[0..<4], as: UTF8.self)
                    let len = Int64(littleEndian ? le32(h, 4) : be32(h, 4))
                    if id.lowercased() == "id3 " { readID3(bytes(p + 8, Int(min(len, 32 << 20))), into: &d); break }
                    p += 8 + len + (len & 1)
                }
            }
        }
        if d.artwork == nil, let (data, name) = folderArt(for: path) {
            d.artwork = data
            d.artworkSource = name
        }
        return d
    }

    // MARK: Folder art

    private static let coverNames = ["cover", "folder", "front", "album", "albumart", "albumartsmall", "artwork"]

    /// cover.jpg / folder.png / front.jpeg … next to the file (case-insensitive).
    static func folderArt(for path: String) -> (Data, String)? {
        let dir = (path as NSString).deletingLastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let images = files.filter { ["jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }
        func rank(_ f: String) -> Int {
            let stem = (f as NSString).deletingPathExtension.lowercased()
            return coverNames.firstIndex { stem == $0 || stem.hasPrefix($0) } ?? (images.count == 1 ? 50 : 99)
        }
        guard let best = images.min(by: { rank($0) < rank($1) }), rank(best) < 99,
              let data = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent(best)) else { return nil }
        return (data, best)
    }

    // MARK: Helpers

    private static func be32(_ b: [UInt8], _ i: Int) -> Int { i + 4 <= b.count ? Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) : 0 }
    private static func le32(_ b: [UInt8], _ i: Int) -> Int { i + 4 <= b.count ? Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 : 0 }
    private static func be16(_ b: [UInt8], _ i: Int) -> Int { i + 2 <= b.count ? Int(b[i]) << 8 | Int(b[i + 1]) : 0 }
    private static func synchsafe(_ b: [UInt8], _ i: Int) -> Int {
        i + 4 <= b.count ? Int(b[i] & 0x7F) << 21 | Int(b[i + 1] & 0x7F) << 14 | Int(b[i + 2] & 0x7F) << 7 | Int(b[i + 3] & 0x7F) : 0
    }

    /// "11/14" → (11, 14)
    private static func pair(_ s: String?) -> (Int?, Int?) {
        guard let s else { return (nil, nil) }
        let parts = s.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        return (parts.first ?? nil, parts.count > 1 ? parts[1] : nil)
    }

    /// ID3 genre "(17)" / "17" → "Rock" for the common numeric codes.
    private static func genreName(_ g: String) -> String {
        let digits = g.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        if let n = Int(digits), n >= 0, n < id3Genres.count { return id3Genres[n] }
        if g.hasPrefix("("), let close = g.firstIndex(of: ")"), let n = Int(g[g.index(after: g.startIndex)..<close]),
           n >= 0, n < id3Genres.count { return g[g.index(after: close)...].isEmpty ? id3Genres[n] : String(g[g.index(after: close)...]) }
        return g
    }

    private static let id3Genres = ["Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz",
        "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative",
        "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion",
        "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "Alternative Rock",
        "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave",
        "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave",
        "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock"]

    // MARK: ID3v2

    static func readID3(_ b: [UInt8], into d: inout TrackDetails) {
        guard b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return }
        let ver = b[3]
        let end = min(10 + synchsafe(b, 6), b.count)
        var p = 10
        if b[5] & 0x40 != 0 { p += ver == 4 ? synchsafe(b, 10) : be32(b, 10) + 4 } // extended header
        let idLen = ver == 2 ? 3 : 4, headerLen = ver == 2 ? 6 : 10
        while p + headerLen <= end, b[p] != 0 {
            let id = String(decoding: b[p..<(p + idLen)], as: UTF8.self)
            let size = ver == 2 ? (Int(b[p + 3]) << 16 | Int(b[p + 4]) << 8 | Int(b[p + 5]))
                     : (ver == 4 ? synchsafe(b, p + 4) : be32(b, p + 4))
            let s = p + headerLen, e = min(s + size, end)
            guard size > 0, s < e else { break }
            func text() -> String? { TagReader.decodeText(b, s, e) }
            switch id {
            case "TIT2", "TT2": d.title = d.title ?? text()
            case "TPE1", "TP1": d.artist = d.artist ?? text()
            case "TALB", "TAL": d.album = d.album ?? text()
            case "TPE2", "TP2": d.albumArtist = d.albumArtist ?? text()
            case "TDRC", "TYER", "TYE", "TORY": d.year = d.year ?? text().map { String($0.prefix(4)) }
            case "TCON", "TCO": d.genre = d.genre ?? text().map(genreName)
            case "TRCK", "TRK": (d.track, d.trackTotal) = pair(text())
            case "TPOS", "TPA": (d.disc, d.discTotal) = pair(text())
            case "TCOM", "TCM": d.composer = d.composer ?? text()
            case "COMM", "COM": if d.comment == nil { d.comment = id3Comment(b, s, e) }
            case "APIC", "PIC": if d.artwork == nil { d.artwork = id3Picture(b, s, e, v22: id == "PIC") ; d.artworkSource = "embedded" }
            default: break
            }
            p = s + size
        }
    }

    /// Skip a NUL-terminated string in the given ID3 text encoding; returns the index after the terminator.
    private static func skipString(_ b: [UInt8], _ from: Int, _ end: Int, encoding: UInt8) -> Int {
        var i = from
        if encoding == 1 || encoding == 2 {
            while i + 1 < end, !(b[i] == 0 && b[i + 1] == 0) { i += 2 }
            return min(i + 2, end)
        }
        while i < end, b[i] != 0 { i += 1 }
        return min(i + 1, end)
    }

    /// COMM: encoding, language(3), short description\0, text.
    private static func id3Comment(_ b: [UInt8], _ s: Int, _ e: Int) -> String? {
        guard s + 4 < e else { return nil }
        let enc = b[s]
        let textStart = skipString(b, s + 4, e, encoding: enc)
        guard textStart < e else { return nil }
        return TagReader.decodeText([enc] + Array(b[textStart..<e]), 0, e - textStart + 1)
    }

    /// APIC: encoding, MIME\0, picture type, description\0, data.  (v2.2 PIC: encoding, 3-char format, type, desc\0, data)
    private static func id3Picture(_ b: [UInt8], _ s: Int, _ e: Int, v22: Bool) -> Data? {
        guard s + 4 < e else { return nil }
        let enc = b[s]
        var i = s + 1
        if v22 { i += 3 } else { while i < e, b[i] != 0 { i += 1 }; i += 1 }
        i += 1 // picture type
        i = skipString(b, i, e, encoding: enc)
        guard i < e else { return nil }
        return Data(b[i..<e])
    }

    // MARK: FLAC

    private static func readFLAC(_ bytes: (Int64, Int) -> [UInt8], _ data: (Int64, Int) -> Data, size: Int64, into d: inout TrackDetails) {
        var p: Int64 = 4
        for _ in 0..<128 where p + 4 <= size {
            let h = bytes(p, 4)
            guard h.count == 4 else { break }
            let last = h[0] & 0x80 != 0, type = h[0] & 0x7F
            let len = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            if type == 4 { vorbisComments(bytes(p + 4, len), into: &d) }
            if type == 6, d.artwork == nil {
                // Header fields first (small), then the picture bytes in one read.
                let mimeLen = be32(bytes(p + 8, 4), 0)
                let descLen = be32(bytes(p + 12 + Int64(mimeLen), 4), 0)
                let lenAt = p + 16 + Int64(mimeLen) + Int64(descLen) + 16
                let dataLen = be32(bytes(lenAt, 4), 0)
                if dataLen > 0, lenAt + 4 + Int64(dataLen) <= p + 4 + Int64(len) {
                    d.artwork = data(lenAt + 4, dataLen)
                    d.artworkSource = "embedded"
                }
            }
            if last { break }
            p += 4 + Int64(len)
        }
    }

    private static func vorbisComments(_ b: [UInt8], into d: inout TrackDetails) {
        var p = 4 + le32(b, 0)
        let count = le32(b, p)
        p += 4
        for _ in 0..<min(count, 2000) {
            let l = le32(b, p)
            guard p + 4 + l <= b.count else { return }
            let s = String(decoding: b[(p + 4)..<(p + 4 + l)], as: UTF8.self)
            p += 4 + l
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = s[..<eq].uppercased(), v = String(s[s.index(after: eq)...])
            switch key {
            case "TITLE": d.title = d.title ?? v
            case "ARTIST": d.artist = d.artist ?? v
            case "ALBUM": d.album = d.album ?? v
            case "ALBUMARTIST", "ALBUM ARTIST": d.albumArtist = d.albumArtist ?? v
            case "DATE", "YEAR": d.year = d.year ?? String(v.prefix(4))
            case "GENRE": d.genre = d.genre ?? v
            case "TRACKNUMBER": let (t, n) = pair(v); d.track = t; if n != nil { d.trackTotal = n }
            case "TRACKTOTAL", "TOTALTRACKS": d.trackTotal = Int(v)
            case "DISCNUMBER": let (t, n) = pair(v); d.disc = t; if n != nil { d.discTotal = n }
            case "DISCTOTAL", "TOTALDISCS": d.discTotal = Int(v)
            case "COMPOSER": d.composer = d.composer ?? v
            case "COMMENT", "DESCRIPTION": d.comment = d.comment ?? v
            default: break
            }
        }
    }

    // MARK: MP4

    private static func readMP4(_ bytes: (Int64, Int) -> [UInt8], size: Int64, into d: inout TrackDetails) {
        var p: Int64 = 0
        for _ in 0..<64 where p + 8 <= size {
            let h = bytes(p, 16)
            var len = Int64(be32(h, 0)), header: Int64 = 8
            if len == 1 { len = Int64(be32(h, 8)) << 32 | Int64(be32(h, 12)); header = 16 } else if len == 0 { len = size - p }
            guard len >= header, len <= size - p else { return }
            if String(decoding: h[4..<8], as: UTF8.self) == "moov" {
                let m = bytes(p + header, Int(min(len - header, 64 << 20)))
                walk(m, 0, m.count, into: &d)
                return
            }
            p += len
        }
    }

    private static func fourCC(_ b: [UInt8], _ i: Int) -> String {
        i + 4 <= b.count ? String(bytes: b[i..<(i + 4)], encoding: .isoLatin1) ?? "" : ""
    }

    private static func walk(_ b: [UInt8], _ start: Int, _ end: Int, into d: inout TrackDetails, depth: Int = 0) {
        guard depth < ContainerTags.maxBoxDepth else { return }   // crafted files could nest thousands deep
        var p = start
        while p + 8 <= end {
            let len = be32(b, p)
            guard len >= 8, p + len <= end else { return }
            let type = fourCC(b, p + 4), body = p + 8, bodyEnd = p + len
            // ilst item → its "data" atom: 8-byte header + 4 type + 4 locale, then the value.
            func value() -> [UInt8]? {
                guard body + 16 <= bodyEnd, fourCC(b, body + 4) == "data" else { return nil }
                let dl = min(be32(b, body), bodyEnd - body)
                return dl > 16 ? Array(b[(body + 16)..<(body + dl)]) : nil
            }
            func text() -> String? { value().flatMap { String(bytes: $0, encoding: .utf8) } }
            switch type {
            case "udta", "ilst": walk(b, body, bodyEnd, into: &d, depth: depth + 1)
            case "meta": walk(b, body + 4, bodyEnd, into: &d, depth: depth + 1)
            case "\u{A9}nam": d.title = d.title ?? text()
            case "\u{A9}ART": d.artist = d.artist ?? text()
            case "\u{A9}alb": d.album = d.album ?? text()
            case "aART": d.albumArtist = d.albumArtist ?? text()
            case "\u{A9}day": d.year = d.year ?? text().map { String($0.prefix(4)) }
            case "\u{A9}gen": d.genre = d.genre ?? text()
            case "gnre": if d.genre == nil, let v = value(), v.count >= 2, be16(v, 0) > 0 { d.genre = genreName(String(be16(v, 0) - 1)) }
            case "\u{A9}wrt": d.composer = d.composer ?? text()
            case "\u{A9}cmt": d.comment = d.comment ?? text()
            case "trkn": if let v = value(), v.count >= 6 { d.track = be16(v, 2); d.trackTotal = be16(v, 4) > 0 ? be16(v, 4) : nil }
            case "disk": if let v = value(), v.count >= 6 { d.disc = be16(v, 2); d.discTotal = be16(v, 4) > 0 ? be16(v, 4) : nil }
            case "covr": if d.artwork == nil, let v = value() { d.artwork = Data(v); d.artworkSource = "embedded" }
            default: break
            }
            p = bodyEnd
        }
    }
}
