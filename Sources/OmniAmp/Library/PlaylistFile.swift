import Foundation

/// Reading and writing .m3u / .m3u8 / .pls playlists, plus the "saved playlists" folder.
enum PlaylistFile {
    static let extensions: Set<String> = ["m3u", "m3u8", "pls"]

    static func isPlaylist(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Media file URLs referenced by a playlist (relative paths resolve against its folder).
    static func read(_ url: URL) -> [URL] { entries(url).map(\.url) }

    /// One playlist line: the target plus what #EXTINF says about it (radio and podcasts need it).
    struct Entry {
        var url: URL
        var title: String?
        var logo: String?
        /// Podcast episodes are saved with the show's name (omniamp-podcast="…") and their length.
        var podcast: String?
        var seconds: Double?
        /// A web audio file added by URL (not a station, not a podcast episode).
        var web = false
        /// A CUE track's slice of its file (omniamp-cue="start,end,number"; end empty = to the end).
        var cueStart: Double?
        var cueEnd: Double?
        var cueNumber: Int?
    }

    /// The targets a playlist's text lists, in order, with their titles and #EXTINF attributes (`head`).
    static func refs(_ text: String, pls: Bool) -> [(ref: String, title: String?, head: String?)] {
        var refs: [(ref: String, title: String?, head: String?)] = []
        if pls {
            var titles: [String: String] = [:], files: [(String, String)] = []
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let eq = t.firstIndex(of: "=") else { continue }
                let key = t[..<eq].lowercased(), val = String(t[t.index(after: eq)...])
                if key.hasPrefix("file") { files.append((String(key.dropFirst(4)), val)) }
                if key.hasPrefix("title") { titles[String(key.dropFirst(5))] = val }
            }
            refs = files.map { ($0.1, titles[$0.0], nil) }
        } else {
            var pendingTitle: String?, pendingHead: String?
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "")
                if t.hasPrefix("#EXTINF:"), let comma = Self.titleComma(t) {
                    let head = String(t[t.index(t.startIndex, offsetBy: 8)..<comma])
                    pendingTitle = String(t[t.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                    pendingHead = head
                    continue
                }
                guard !t.isEmpty, !t.hasPrefix("#") else { continue }
                refs.append((t, pendingTitle, pendingHead))
                pendingTitle = nil
                pendingHead = nil
            }
        }
        return refs
    }

    /// Entries with their titles (#EXTINF / TitleN), station logos (tvg-logo) and podcast shows.
    static func entries(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let base = url.deletingLastPathComponent()
        return refs(text, pls: url.pathExtension.lowercased() == "pls").compactMap { ref, title, head in
            let h = head ?? ""
            if ref.hasPrefix("http://") || ref.hasPrefix("https://") {   // radio or podcast
                return URL(string: ref).map {
                    Entry(url: $0, title: title, logo: Self.attribute("tvg-logo", in: h), podcast: Self.attribute("omniamp-podcast", in: h),
                          seconds: Sane.duration(Double(h.split(separator: " ").first ?? "")), web: Self.attribute("omniamp-web", in: h) != nil)
                }
            }
            let u: URL
            if ref.hasPrefix("file://") {
                guard let f = URL(string: ref) else { return nil }
                u = f
            } else {
                if ref.contains("://") { return nil }
                let path = ref.replacingOccurrences(of: "\\", with: "/")
                u = URL(exactPath: path.hasPrefix("/") ? path : ((base.path as NSString).appendingPathComponent(path) as NSString).standardizingPath)
            }
            var e = Entry(url: u, title: title)
            if let cue = Self.attribute("omniamp-cue", in: h) {
                let f = cue.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                e.cueStart = Sane.offset(f.first.flatMap(Double.init))
                e.cueEnd = f.count > 1 ? Sane.offset(Double(f[1])) : nil
                e.cueNumber = f.count > 2 ? Int(f[2]) : nil
            }
            return e
        }
    }

    /// The comma that starts the title in `#EXTINF:-1 tvg-logo="a,b",Title` (commas inside quotes don't count).
    private static func titleComma(_ line: String) -> String.Index? {
        var quoted = false
        for i in line.indices {
            if line[i] == "\"" { quoted.toggle() } else if line[i] == ",", !quoted { return i }
        }
        return nil
    }

    /// key="value" inside an #EXTINF line.
    static func attribute(_ key: String, in s: String) -> String? {
        guard let r = s.range(of: key + "=\"") else { return nil }
        let rest = s[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let v = String(rest[..<end])
        return v.isEmpty ? nil : v
    }

    /// Writes an extended M3U (UTF-8) with durations and titles.
    /// One line: any line break (\r, U+2028…) in a tag would split the entry and inject a line of its own.
    private static func oneLine(_ s: String) -> String {
        String(s.unicodeScalars.map { CharacterSet.newlines.contains($0) ? " " : Character($0) })
    }

    /// An attribute value: one line, no double quotes (they end the value).
    private static func attr(_ s: String) -> String { oneLine(s).replacingOccurrences(of: "\"", with: "'") }

    static func writeM3U(_ tracks: [Track], to url: URL) throws {
        var out = "#EXTM3U\n"
        out.reserveCapacity(tracks.count * 120)
        for t in tracks {
            let secs = Sane.duration(t.duration).map { Int($0.rounded()) } ?? -1
            let logo = t.logo.map { " tvg-logo=\"\(attr($0))\"" } ?? ""
            let show = t.isWebFile ? " omniamp-web=\"1\"" : t.podcast.flatMap { $0.isEmpty ? nil : " omniamp-podcast=\"\(attr($0))\"" } ?? ""
            let cue = t.cueStart.map { " omniamp-cue=\"\($0),\(t.cueEnd.map { String($0) } ?? ""),\(t.cueNumber ?? 0)\"" } ?? ""
            out += "#EXTINF:\(secs)\(logo)\(show)\(cue),\(oneLine(t.displayTitle))\n\(oneLine(t.path))\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Folder for named playlists (Application Support/OmniAmp/Playlists).
    static var directory: URL {
        let d = LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("Playlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var saved: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter(isPlaylist)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
