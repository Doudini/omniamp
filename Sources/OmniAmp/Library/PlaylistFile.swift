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
    }

    /// Entries with their titles (#EXTINF / TitleN), station logos (tvg-logo) and podcast shows.
    static func entries(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let base = url.deletingLastPathComponent()
        var refs: [(String, String?, String?, String?, Double?)] = []
        if url.pathExtension.lowercased() == "pls" {
            var titles: [String: String] = [:], files: [(String, String)] = []
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let eq = t.firstIndex(of: "=") else { continue }
                let key = t[..<eq].lowercased(), val = String(t[t.index(after: eq)...])
                if key.hasPrefix("file") { files.append((String(key.dropFirst(4)), val)) }
                if key.hasPrefix("title") { titles[String(key.dropFirst(5))] = val }
            }
            refs = files.map { ($0.1, titles[$0.0], nil, nil, nil) }
        } else {
            var pendingTitle: String?, pendingLogo: String?, pendingShow: String?, pendingSecs: Double?
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "")
                if t.hasPrefix("#EXTINF:"), let comma = Self.titleComma(t) {
                    let head = String(t[t.index(t.startIndex, offsetBy: 8)..<comma])
                    pendingTitle = String(t[t.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                    pendingLogo = Self.attribute("tvg-logo", in: head)
                    pendingShow = Self.attribute("omniamp-podcast", in: head)
                    pendingSecs = Double(head.split(separator: " ").first ?? "").flatMap { $0 > 0 ? $0 : nil }
                    continue
                }
                guard !t.isEmpty, !t.hasPrefix("#") else { continue }
                refs.append((t, pendingTitle, pendingLogo, pendingShow, pendingSecs))
                pendingTitle = nil
                pendingLogo = nil
                pendingShow = nil
                pendingSecs = nil
            }
        }
        return refs.compactMap { ref, title, logo, show, secs in
            if ref.hasPrefix("file://") { return URL(string: ref).map { Entry(url: $0, title: title) } }
            if ref.hasPrefix("http://") || ref.hasPrefix("https://") {   // radio or podcast
                return URL(string: ref).map { Entry(url: $0, title: title, logo: logo, podcast: show, seconds: secs) }
            }
            if ref.contains("://") { return nil }
            let path = ref.replacingOccurrences(of: "\\", with: "/")
            let u = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path).standardizedFileURL
            return Entry(url: u, title: title)
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
    static func writeM3U(_ tracks: [Track], to url: URL) throws {
        var out = "#EXTM3U\n"
        out.reserveCapacity(tracks.count * 120)
        for t in tracks {
            let secs = t.duration.map { Int($0.rounded()) } ?? -1
            let logo = t.logo.map { " tvg-logo=\"\($0)\"" } ?? ""
            let show = t.podcast.map { " omniamp-podcast=\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? ""
            out += "#EXTINF:\(secs)\(logo)\(show),\(t.displayTitle.replacingOccurrences(of: "\n", with: " "))\n\(t.path)\n"
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
