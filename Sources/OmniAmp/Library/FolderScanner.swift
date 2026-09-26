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
                for case let url as URL in en {
                    guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                    let v = try? url.resourceValues(forKeys: Set(keys))
                    guard v?.isRegularFile == true else { continue }
                    add(url, v)
                }
                // Sort each dropped folder by path so albums stay in track order.
                var batch = Array(out[before...])
                batch.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                out.replaceSubrange(before..., with: batch)
            } else if PlaylistFile.isPlaylist(root) {
                // Keep the playlist's own order; skip entries whose files are gone.
                for url in PlaylistFile.read(root) {
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
