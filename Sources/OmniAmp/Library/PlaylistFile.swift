import Foundation

/// Reading and writing .m3u / .m3u8 / .pls playlists, plus the "saved playlists" folder.
enum PlaylistFile {
    static let extensions: Set<String> = ["m3u", "m3u8", "pls"]

    static func isPlaylist(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Media file URLs referenced by a playlist (relative paths resolve against its folder).
    static func read(_ url: URL) -> [URL] { entries(url).map(\.url) }

    /// Entries with their titles (#EXTINF / TitleN) and station logos (tvg-logo), needed for radio.
    static func entries(_ url: URL) -> [(url: URL, title: String?, logo: String?)] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let base = url.deletingLastPathComponent()
        var refs: [(String, String?, String?)] = []
        if url.pathExtension.lowercased() == "pls" {
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
            var pendingTitle: String?, pendingLogo: String?
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "")
                if t.hasPrefix("#EXTINF:"), let comma = Self.titleComma(t) {
                    pendingTitle = String(t[t.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                    pendingLogo = Self.attribute("tvg-logo", in: String(t[..<comma]))
                    continue
                }
                guard !t.isEmpty, !t.hasPrefix("#") else { continue }
                refs.append((t, pendingTitle, pendingLogo))
                pendingTitle = nil
                pendingLogo = nil
            }
        }
        return refs.compactMap { ref, title, logo in
            if ref.hasPrefix("file://") { return URL(string: ref).map { ($0, title, nil) } }
            if ref.hasPrefix("http://") || ref.hasPrefix("https://") { return URL(string: ref).map { ($0, title, logo) } }   // radio
            if ref.contains("://") { return nil }
            let path = ref.replacingOccurrences(of: "\\", with: "/")
            let u = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path).standardizedFileURL
            return (u, title, nil)
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
            out += "#EXTINF:\(secs)\(logo),\(t.displayTitle.replacingOccurrences(of: "\n", with: " "))\n\(t.path)\n"
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
