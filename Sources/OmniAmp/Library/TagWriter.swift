import Foundation

/// The few tags OmniAmp writes: nil leaves a field as it is.
struct BasicTags: Equatable, Sendable {
    /// Written as the album artist; as the track artist only where a file has none (compilations keep theirs).
    var artist: String?
    var album: String?
    var year: String?
    var genre: String?
    /// Per track (downloads that come untagged): the song's title and its number ("3" or "3/12").
    var title: String?
    var track: String?

    var isEmpty: Bool { [artist, album, year, genre, title, track].allSatisfy { ($0 ?? "").isEmpty } }
}

/// Writes album artist, album, year and genre (and a track's title and number) into MP3 (ID3v2.3/2.4) and FLAC files. Every other tag,
/// picture and the audio stay as they are.
///
/// When the new tag fits in the space the old one had (tags usually carry padding), only the tag is
/// rewritten in place; otherwise the file is copied to a temporary file next to it, with room to spare, and
/// swapped in. The old tag bytes are saved in the cache folder first (TagBackups/), so a change can be undone.
///
/// The file keeps its modification date: it's when the music came into the collection (Recently Added, the Tracks
/// list), not when a tag was fixed. Whoever writes tells the library to read the file again (the date won't).
enum TagWriter {
    enum Outcome: Equatable {
        case written
        case unchanged
        case unsupported(String)
        case failed(String)
    }

    static func write(_ tags: BasicTags, to path: String, backupDir: URL? = TagWriter.backupDir, keepDate: Bool = true) -> Outcome {
        guard !tags.isEmpty else { return .unchanged }
        let before = keepDate ? times(path) : nil
        let outcome = writeTags(tags, to: path, backupDir: backupDir)
        // Set back by path, after the file is closed: a rewrite swapped in a new file, and NFS writes at close.
        if outcome == .written, let t = before {
            var ts = [t.0, t.1]
            _ = utimensat(AT_FDCWD, path, &ts, 0)
        }
        return outcome
    }

    /// Access and modification times, as utimensat wants them.
    private static func times(_ path: String) -> (timespec, timespec)? {
        var st = stat()
        return stat(path, &st) == 0 ? (st.st_atimespec, st.st_mtimespec) : nil
    }

    private static func writeTags(_ tags: BasicTags, to path: String, backupDir: URL?) -> Outcome {
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { return .failed(String(cString: strerror(errno))) }
        defer { close(fd) }
        var head = [UInt8](repeating: 0, count: 10)
        let n = pread(fd, &head, 10, 0)
        let ext = (path as NSString).pathExtension.lowercased()
        if n >= 4, head.starts(with: Array("fLaC".utf8)) { return writeFLAC(tags, fd: fd, path: path, backupDir: backupDir) }
        // FLAC behind an ID3 tag (some rippers put one in front): the FLAC part, the ID3 tag left as it is.
        if n == 10, let base = flacAfterID3(fd, head: head) { return writeFLAC(tags, fd: fd, path: path, backupDir: backupDir, base: base) }
        if ext == "mp3" { return writeID3(tags, fd: fd, head: n == 10 ? head : [], path: path, backupDir: backupDir) }
        return .unsupported(ext.uppercased())
    }

    static var backupDir: URL {
        LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("TagBackups", isDirectory: true)
    }

    // MARK: File helpers

    private static func size(_ fd: Int32) -> Int64 {
        var st = stat()
        return fstat(fd, &st) == 0 ? Int64(st.st_size) : 0
    }

    private static func read(_ fd: Int32, _ offset: Int64, _ count: Int) -> [UInt8]? {
        guard count >= 0 else { return nil }
        var b = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let r = b.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, count - got, off_t(offset) + off_t(got)) }
            if r <= 0 { break }
            got += r
        }
        return got == count ? b : nil
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], at offset: Int64) -> Bool {
        var done = 0
        while done < bytes.count {
            let w = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress! + done, bytes.count - done, off_t(offset) + off_t(done)) }
            if w <= 0 { return false }
            done += w
        }
        return true
    }

    /// Writes over the tag in place and makes sure it reached the disk: on a network share, a failed write often
    /// only shows up at the flush, and "written" must not be reported for a tag that isn't.
    private static func writeInPlace(_ fd: Int32, _ bytes: [UInt8], at offset: Int64) -> Outcome {
        writeAll(fd, bytes, at: offset) && fsync(fd) == 0 ? .written : .failed("couldn't write the tag")
    }

    /// The old tag, kept before it's replaced: <backups>/<day>/<name>.<n>.tag plus a line in index.tsv.
    private static func backup(_ bytes: [UInt8], of path: String, in dir: URL?) {
        guard let dir, bytes.count <= 32 << 20 else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let day = dir.appendingPathComponent(f.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString.prefix(8))-\((path as NSString).lastPathComponent).tag"
        guard (try? Data(bytes).write(to: day.appendingPathComponent(name))) != nil else { return }
        let line = "\(name)\t\(path)\n"
        let index = day.appendingPathComponent("index.tsv")
        if let h = try? FileHandle(forWritingTo: index) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: index)
        }
    }

    /// `prefix` followed by the original file from `from` to its end, into a temporary file next to it, then
    /// renamed over it (same permissions). A failure leaves the original untouched.
    /// Temporary files a crash left in a folder (".omniamp-….tmp", over an hour old).
    private static func removeStaleTemporaries(in dir: String) {
        for name in ExactPath.contents(ofDirectory: dir) ?? [] where name.hasPrefix(".omniamp-") && name.hasSuffix(".tmp") {
            let p = dir + "/" + name
            var st = stat()
            if stat(p, &st) == 0, Date().timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec) > 3600 { unlink(p) }
        }
    }

    private static func rewrite(_ fd: Int32, path: String, prefix: [UInt8], from: Int64) -> Outcome {
        let dir = (path as NSString).deletingLastPathComponent
        removeStaleTemporaries(in: dir)
        let tmp = dir + "/.omniamp-\(UUID().uuidString.prefix(8)).tmp"
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failed("couldn't read the file's size") }
        let total = Int64(st.st_size)
        let out = open(tmp, O_WRONLY | O_CREAT | O_EXCL, st.st_mode & 0o7777)
        guard out >= 0 else { return .failed("can't create a file in the folder: \(String(cString: strerror(errno)))") }
        var ok = writeAll(out, prefix, at: 0)
        var at = from, dest = Int64(prefix.count)
        let chunk = 1 << 20
        while ok, at < total {
            let n = Int(min(Int64(chunk), total - at))
            guard let b = read(fd, at, n) else { ok = false; break }
            ok = writeAll(out, b, at: dest)
            at += Int64(n); dest += Int64(n)
        }
        ok = ok && fsync(out) == 0
        // All of the audio made it (a short read would otherwise replace the file with less of it).
        var written = stat()
        ok = ok && fstat(out, &written) == 0 && Int64(written.st_size) == Int64(prefix.count) + max(0, total - from)
        close(out)
        guard ok, rename(tmp, path) == 0 else {
            unlink(tmp)
            return .failed("couldn't write the file")
        }
        return .written
    }

    // MARK: ID3v2

    private static func synchsafe(_ n: Int) -> [UInt8] { [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)] }
    private static func unsynch(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i] & 0x7F) << 21 | Int(b[i + 1] & 0x7F) << 14 | Int(b[i + 2] & 0x7F) << 7 | Int(b[i + 3] & 0x7F)
    }
    private static func be32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }

    /// A text frame in the tag's version: UTF-16 with BOM for v2.3, UTF-8 for v2.4.
    private static func textFrame(_ id: String, _ text: String, version: UInt8) -> [UInt8] {
        let body: [UInt8] = version == 4 ? [3] + Array(text.utf8) : [1, 0xFF, 0xFE] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let n = body.count
        let size = version == 4 ? synchsafe(n) : [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        return Array(id.utf8) + size + [0, 0] + body
    }

    /// The frames from `start`: nil unless each has a valid ID and a size that fits, and the walk ends exactly at
    /// the tag's end or its padding.
    static func frames(_ tag: [UInt8], from start: Int, synchsafe: Bool) -> [(id: String, raw: [UInt8])]? {
        var out: [(id: String, raw: [UInt8])] = [], p = start
        while p + 10 <= tag.count, tag[p] != 0 {
            let idBytes = tag[p..<(p + 4)]
            guard idBytes.allSatisfy({ (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }) else { return nil }
            let len = synchsafe ? unsynch(tag, p + 4) : be32(tag, p + 4)
            guard len >= 0, p + 10 + len <= tag.count else { return nil }
            out.append((String(decoding: idBytes, as: UTF8.self), Array(tag[p..<(p + 10 + len)])))
            p += 10 + len
        }
        // What's left is padding (zeros) or nothing.
        guard tag[min(p, tag.count)...].allSatisfy({ $0 == 0 }) else { return nil }
        return out
    }

    static func writeID3(_ tags: BasicTags, fd: Int32, head: [UInt8], path: String, backupDir: URL?) -> Outcome {
        var version: UInt8 = 3
        var frames: [(id: String, raw: [UInt8])] = []
        var oldEnd: Int64 = 0   // where the audio starts (0: no tag yet)
        if head.count == 10, head.starts(with: Array("ID3".utf8)) {
            version = head[3]
            guard version == 3 || version == 4 else { return .unsupported("ID3v2.\(version) tag") }
            let flags = head[5]
            guard flags & 0x80 == 0 else { return .unsupported("unsynchronised ID3 tag") }
            let size = unsynch(head, 6)
            oldEnd = 10 + Int64(size) + (flags & 0x10 != 0 ? 10 : 0)
            guard let tag = read(fd, 0, 10 + size) else { return .failed("couldn't read the tag") }
            var start = 10
            if flags & 0x40 != 0, start + 4 <= tag.count { start += version == 4 ? unsynch(tag, start) : be32(tag, start) + 4 }
            // Every frame must be read, or the rewritten tag would lose the ones after a misread (often the cover).
            // v2.4 sizes are synchsafe, but some taggers (older iTunes) wrote plain ones: try both, else don't write.
            guard let all = Self.frames(tag, from: start, synchsafe: version == 4) ?? (version == 4 ? Self.frames(tag, from: start, synchsafe: false) : nil)
            else { return .unsupported("ID3 tag it can't read safely") }
            frames = all
        }
        let hasArtist = frames.contains { $0.id == "TPE1" }
        var replace = Set<String>(), add: [[UInt8]] = []
        if let a = tags.artist, !a.isEmpty {
            replace.insert("TPE2"); add.append(textFrame("TPE2", a, version: version))
            if !hasArtist { add.append(textFrame("TPE1", a, version: version)) }
        }
        if let a = tags.album, !a.isEmpty { replace.insert("TALB"); add.append(textFrame("TALB", a, version: version)) }
        if let y = tags.year, !y.isEmpty {
            replace.formUnion(["TYER", "TDRC"])
            // v2.3's year frame holds four digits ("1994-05-12" → 1994); v2.4's takes a whole date.
            add.append(textFrame(version == 4 ? "TDRC" : "TYER", version == 4 ? y : Keys.year(y).map(String.init) ?? y, version: version))
        }
        if let g = tags.genre, !g.isEmpty { replace.insert("TCON"); add.append(textFrame("TCON", g, version: version)) }
        if let t = tags.title, !t.isEmpty { replace.insert("TIT2"); add.append(textFrame("TIT2", t, version: version)) }
        if let n = tags.track, !n.isEmpty { replace.insert("TRCK"); add.append(textFrame("TRCK", n, version: version)) }
        let body = add.flatMap { $0 } + frames.filter { !replace.contains($0.id) }.flatMap(\.raw)
        func tag(padding: Int) -> [UInt8] {
            Array("ID3".utf8) + [version, 0, 0] + synchsafe(body.count + padding) + body + [UInt8](repeating: 0, count: padding)
        }
        if oldEnd > 0, let old = read(fd, 0, Int(oldEnd)) { backup(old, of: path, in: backupDir) }
        // Fits where the old tag was: rewrite just the tag.
        if oldEnd >= 10, body.count <= Int(oldEnd) - 10 {
            return writeInPlace(fd, tag(padding: Int(oldEnd) - 10 - body.count), at: 0)
        }
        return rewrite(fd, path: path, prefix: tag(padding: 2048), from: oldEnd)
    }

    // MARK: FLAC

    /// Where FLAC starts when an ID3v2 tag comes first ("ID3…" then "fLaC"), else nil.
    static func flacAfterID3(_ fd: Int32, head: [UInt8]) -> Int64? {
        guard head.count >= 10, head.starts(with: Array("ID3".utf8)) else { return nil }
        let size = Int64(head[6] & 0x7F) << 21 | Int64(head[7] & 0x7F) << 14 | Int64(head[8] & 0x7F) << 7 | Int64(head[9] & 0x7F)
        let base = 10 + size + (head[5] & 0x10 != 0 ? 10 : 0)
        return read(fd, base, 4) == Array("fLaC".utf8) ? base : nil
    }

    /// `base`: where "fLaC" is (after a leading ID3 tag, which is kept).
    static func writeFLAC(_ tags: BasicTags, fd: Int32, path: String, backupDir: URL?, base: Int64 = 0) -> Outcome {
        var blocks: [(type: UInt8, body: [UInt8])] = []
        var p: Int64 = base + 4
        var last = false
        while !last {
            guard let h = read(fd, p, 4) else { return .failed("couldn't read the FLAC header") }
            last = h[0] & 0x80 != 0
            let len = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            let type = h[0] & 0x7F
            if type == 1 {
                blocks.append((1, []))   // padding: only its place matters
            } else {
                guard let b = read(fd, p + 4, len) else { return .failed("couldn't read the FLAC header") }
                blocks.append((type, b))
            }
            p += 4 + Int64(len)
            if blocks.count > 1000 { return .failed("damaged FLAC header") }
        }
        let audio = p
        guard blocks.first?.type == 0 else { return .unsupported("FLAC without stream info") }

        // The comments: vendor, then KEY=value pairs. Ours replace theirs; the rest stay in order.
        // Every comment must be read, or the rewritten block would lose the ones after a misread (as with ID3).
        var vendor: [UInt8] = Array("OmniAmp".utf8), comments: [String] = []
        if let c = blocks.first(where: { $0.type == 4 })?.body {
            func le32(_ i: Int) -> Int { i + 4 <= c.count ? Int(c[i]) | Int(c[i + 1]) << 8 | Int(c[i + 2]) << 16 | Int(c[i + 3]) << 24 : -1 }
            let vl = le32(0)
            guard vl >= 0, 4 + vl + 4 <= c.count else { return .unsupported("FLAC comments it can't read safely") }
            vendor = Array(c[4..<(4 + vl)])
            var q = 4 + vl + 4
            for _ in 0..<le32(4 + vl) {
                let l = le32(q)
                guard l >= 0, q + 4 + l <= c.count else { return .unsupported("FLAC comments it can't read safely") }
                comments.append(String(decoding: c[(q + 4)..<(q + 4 + l)], as: UTF8.self))
                q += 4 + l
            }
        }
        func key(_ s: String) -> String { String(s.prefix { $0 != "=" }).uppercased() }
        let hasArtist = comments.contains { key($0) == "ARTIST" }
        var drop = Set<String>(), add: [String] = []
        if let a = tags.artist, !a.isEmpty {
            drop.formUnion(["ALBUMARTIST", "ALBUM ARTIST"]); add.append("ALBUMARTIST=\(a)")
            if !hasArtist { add.append("ARTIST=\(a)") }
        }
        if let a = tags.album, !a.isEmpty { drop.insert("ALBUM"); add.append("ALBUM=\(a)") }
        if let y = tags.year, !y.isEmpty { drop.formUnion(["DATE", "YEAR"]); add.append("DATE=\(y)") }
        if let g = tags.genre, !g.isEmpty { drop.insert("GENRE"); add.append("GENRE=\(g)") }
        if let t = tags.title, !t.isEmpty { drop.insert("TITLE"); add.append("TITLE=\(t)") }
        if let n = tags.track, !n.isEmpty { drop.insert("TRACKNUMBER"); add.append("TRACKNUMBER=\(n)") }
        let list = comments.filter { !drop.contains(key($0)) } + add
        func le(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)] }
        var comment = le(vendor.count) + vendor + le(list.count)
        for c in list { comment += le(c.utf8.count) + Array(c.utf8) }

        // Blocks in their order, the comments where they were (or after the stream info), padding dropped.
        var out: [(UInt8, [UInt8])] = []
        for b in blocks where b.type != 1 {
            out.append(b.type == 4 ? (4, comment) : (b.type, b.body))
            if b.type == 0, !blocks.contains(where: { $0.type == 4 }) { out.append((4, comment)) }
        }
        let maxBlock = (1 << 24) - 1
        guard out.allSatisfy({ $0.1.count <= maxBlock }) else { return .failed("tag too large") }
        /// `room`: bytes for padding, block headers included (0 or at least 4). A block holds at most 16 MB, so
        /// more room (big pictures removed earlier) becomes several padding blocks.
        func header(room: Int) -> [UInt8] {
            var bytes: [UInt8] = Array("fLaC".utf8)
            let n = room > 0 ? (room + maxBlock + 4 - 1) / (maxBlock + 4) : 0
            let pads = (0..<n).map { i in (UInt8(1), [UInt8](repeating: 0, count: (room - 4 * n) / n + (i < (room - 4 * n) % n ? 1 : 0))) }
            let all = out + pads
            for (i, (type, body)) in all.enumerated() {
                bytes.append(type | (i == all.count - 1 ? 0x80 : 0))
                bytes += [UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
            }
            return bytes
        }
        if let old = read(fd, 0, Int(audio)) { backup(old, of: path, in: backupDir) }
        let exact = header(room: 0).count
        let room = Int(audio - base) - exact
        // Same size exactly, or room left for padding (a 4-byte block header included): in place.
        if room == 0 || room >= 4 { return writeInPlace(fd, header(room: room), at: base) }
        guard let lead = base > 0 ? read(fd, 0, Int(base)) : [] else { return .failed("couldn't read the file") }
        return rewrite(fd, path: path, prefix: lead + header(room: 4100), from: audio)
    }
}
