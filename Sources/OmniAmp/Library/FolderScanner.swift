import Foundation

/// Stage 1: walk folders/files and produce bare tracks (no tag reading).
enum FolderScanner {
    static let audioExtensions: Set<String> = ["mp3", "flac", "m4a", "m4b", "mp4", "aac", "alac", "wav", "wave", "aif", "aiff", "aifc", "caf"]

    static func scan(_ urls: [URL]) -> [Track] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var out: [Track] = []
        out.reserveCapacity(1024)

        func add(_ url: URL, _ values: URLResourceValues?) {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { return }
            out.append(Track(path: url.path,
                             size: Int64(values?.fileSize ?? 0),
                             mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }

        for root in urls {
            let rv = try? root.resourceValues(forKeys: Set(keys))
            if rv?.isDirectory == true {
                let before = out.count
                guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                var cues: [URL] = []
                for case let url as URL in en {
                    let ext = url.pathExtension.lowercased()
                    if ext == "cue" { cues.append(url); continue }
                    guard audioExtensions.contains(ext) else { continue }
                    let v = try? url.resourceValues(forKeys: Set(keys))
                    guard v?.isRegularFile == true else { continue }
                    add(url, v)
                }
                // CUE sheets: their tracks replace the whole-file entries they split up.
                if !cues.isEmpty {
                    var covered = Set<String>()
                    var cueTracks: [Track] = []
                    for c in cues {
                        guard let sheet = CueSheet.load(c) else { continue }
                        let r = sheet.tracks(cueURL: c)
                        let fresh = r.covered.subtracting(covered)   // two cues for one file: first wins
                        cueTracks += r.tracks.filter { fresh.contains($0.path) }
                        covered.formUnion(fresh)
                    }
                    let plain = out[before...].filter { !covered.contains($0.path) }
                    out.replaceSubrange(before..., with: plain + cueTracks)
                }
                // Sort each dropped folder by path (then CUE position) so albums stay in track order.
                var batch = Array(out[before...])
                batch.sort {
                    let r = $0.path.localizedStandardCompare($1.path)
                    return r == .orderedSame ? ($0.cueStart ?? 0) < ($1.cueStart ?? 0) : r == .orderedAscending
                }
                out.replaceSubrange(before..., with: batch)
            } else if root.pathExtension.lowercased() == "cue" {
                if let sheet = CueSheet.load(root) { out += sheet.tracks(cueURL: root).tracks }
            } else if PlaylistFile.isPlaylist(root) {
                // Keep the playlist's own order; skip entries whose files are gone.
                for (url, title, logo) in PlaylistFile.entries(root) {
                    if !url.isFileURL { out.append(.stream(url.absoluteString, name: title, logo: logo)); continue }
                    let v = try? url.resourceValues(forKeys: Set(keys))
                    guard v?.isRegularFile == true else { continue }
                    add(url, v)
                }
            } else {
                add(root, rv)
            }
        }
        return out
    }

}
