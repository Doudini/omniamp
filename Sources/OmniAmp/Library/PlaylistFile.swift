import Foundation

/// Reading and writing .m3u / .m3u8 / .pls playlists, plus the "saved playlists" folder.
enum PlaylistFile {
    static let extensions: Set<String> = ["m3u", "m3u8", "pls"]

    static func isPlaylist(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Media file URLs referenced by a playlist (relative paths resolve against its folder).
    static func read(_ url: URL) -> [URL] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let base = url.deletingLastPathComponent()
        var refs: [String] = []
        if url.pathExtension.lowercased() == "pls" {
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.lowercased().hasPrefix("file"), let eq = t.firstIndex(of: "=") else { continue }
                refs.append(String(t[t.index(after: eq)...]))
            }
        } else {
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "")
                guard !t.isEmpty, !t.hasPrefix("#") else { continue }
                refs.append(t)
            }
        }
        return refs.compactMap { ref in
            if ref.hasPrefix("file://") { return URL(string: ref) }
            if ref.contains("://") { return nil } // streams not supported yet
            let path = ref.replacingOccurrences(of: "\\", with: "/")
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path).standardizedFileURL
        }
    }

    /// Writes an extended M3U (UTF-8) with durations and titles.
    static func writeM3U(_ tracks: [Track], to url: URL) throws {
        var out = "#EXTM3U\n"
        out.reserveCapacity(tracks.count * 120)
        for t in tracks {
            let secs = t.duration.map { Int($0.rounded()) } ?? -1
            out += "#EXTINF:\(secs),\(t.displayTitle.replacingOccurrences(of: "\n", with: " "))\n\(t.path)\n"
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
