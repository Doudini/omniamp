import Foundation

/// A parsed .cue file: one or more audio files split into tracks by INDEX 01 times.
struct CueSheet {
    struct Entry {
        var file: String            // as written in the cue (relative or absolute)
        var number: Int
        var title: String?
        var performer: String?
        var songwriter: String?
        var start: Double           // INDEX 01, seconds into `file`
    }

    var title: String?              // album
    var performer: String?          // album artist
    var date: String?
    var genre: String?
    var entries: [Entry] = []

    /// mm:ss:ff (75 frames per second).
    static func time(_ s: String) -> Double? {
        let p = s.split(separator: ":").compactMap { Double($0) }
        guard p.count == 3 else { return nil }
        return p[0] * 60 + p[1] + p[2] / 75
    }

    /// Cue files are often not UTF-8: older rips use Windows-1252. UTF-16 only with a byte-order mark
    /// (without one it "decodes" almost anything into garbage).
    static func decode(_ d: Data) -> String? {
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: d.dropFirst(3), encoding: .utf8) }
        if d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]) { return String(data: d, encoding: .utf16) }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252) ?? String(data: d, encoding: .isoLatin1)
    }

    /// Splits a cue line into its command and arguments, honouring quotes: TITLE "A \"B\" C".
    private static func tokens(_ line: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false, had = false
        for ch in line {
            if ch == "\"" { quoted.toggle(); had = true; continue }
            if ch.isWhitespace && !quoted {
                if !cur.isEmpty || had { out.append(cur); cur = ""; had = false }
                continue
            }
            cur.append(ch)
        }
        if !cur.isEmpty || had { out.append(cur) }
        return out
    }

    static func parse(_ text: String) -> CueSheet {
        var sheet = CueSheet()
        var file: String?
        var current: Entry?
        func finish() { if let c = current, c.start >= 0 { sheet.entries.append(c) }; current = nil }
        for raw in text.components(separatedBy: .newlines) {
            let t = tokens(raw.trimmingCharacters(in: .whitespaces))
            guard let cmd = t.first?.uppercased() else { continue }
            let arg = t.count > 1 ? t[1] : nil
            switch cmd {
            case "FILE":
                finish()
                file = arg
            case "TRACK":
                finish()
                if let f = file, let n = arg.flatMap({ Int($0) }), t.count < 3 || t[2].uppercased() == "AUDIO" {
                    current = Entry(file: f, number: n, start: -1)
                }
            case "TITLE": if current != nil { current?.title = arg } else { sheet.title = arg }
            case "PERFORMER": if current != nil { current?.performer = arg } else { sheet.performer = arg }
            case "SONGWRITER": if current != nil { current?.songwriter = arg }
            case "INDEX":
                if t.count >= 3, Int(t[1]) == 1, let s = time(t[2]) { current?.start = s }
            case "REM":
                guard t.count >= 3 else { break }
                switch t[1].uppercased() {
                case "DATE": sheet.date = t[2]
                case "GENRE": sheet.genre = t[2...].joined(separator: " ")
                default: break
                }
            default: break
            }
        }
        finish()
        return sheet
    }

    static func load(_ url: URL) -> CueSheet? {
        guard let d = try? Data(contentsOf: url), let text = decode(d) else { return nil }
        let s = parse(text)
        return s.entries.isEmpty ? nil : s
    }

    /// The audio file a FILE line refers to. Cue files often name a .wav that was later converted to .flac,
    /// or differ in case, so fall back to a same-name file with any supported audio extension.
    static func resolve(_ name: String, relativeTo dir: URL) -> URL? {
        let fm = FileManager.default
        let clean = name.replacingOccurrences(of: "\\", with: "/")
        let direct = clean.hasPrefix("/") ? URL(fileURLWithPath: clean) : dir.appendingPathComponent(clean)
        if fm.fileExists(atPath: direct.path) { return direct }
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let want = (clean as NSString).lastPathComponent.lowercased()
        if let f = files.first(where: { $0.lowercased() == want }) { return dir.appendingPathComponent(f) }
        let stem = (want as NSString).deletingPathExtension
        if let f = files.first(where: {
            ($0.lowercased() as NSString).deletingPathExtension == stem
                && FolderScanner.audioExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }) { return dir.appendingPathComponent(f) }
        return nil
    }

    /// Playlist tracks for this sheet. Each ends where the next track in the same file starts
    /// (the last one runs to the end of its file). Also returns the audio files it covers.
    func tracks(cueURL: URL) -> (tracks: [Track], covered: Set<String>) {
        let dir = cueURL.deletingLastPathComponent()
        var resolved: [String: URL] = [:]
        var out: [Track] = []
        var covered = Set<String>()
        for (i, e) in entries.enumerated() {
            if resolved[e.file] == nil, let u = Self.resolve(e.file, relativeTo: dir) { resolved[e.file] = u }
            guard let url = resolved[e.file] else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            var t = Track(path: url.path, size: Int64(values?.fileSize ?? 0),
                          mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            t.cueStart = e.start
            if i + 1 < entries.count, entries[i + 1].file == e.file { t.cueEnd = entries[i + 1].start }
            t.cueNumber = e.number
            t.title = e.title
            t.artist = e.performer ?? performer
            t.album = title
            out.append(t)
            covered.insert(url.path)
        }
        return (out, covered)
    }
}
