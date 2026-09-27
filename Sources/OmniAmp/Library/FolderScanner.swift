import Foundation

/// Stage 1: walk folders/files and produce bare tracks (no tag reading).
enum FolderScanner {
    static let audioExtensions: Set<String> = ["mp3", "flac", "m4a", "m4b", "mp4", "aac", "alac", "wav", "wave", "aif", "aiff", "aifc", "caf"]

    static func scan(_ urls: [URL]) -> [Track] {
        var out: [Track] = []
        scan(urls) { out += $0 }
        return out
    }

    /// Only keys a directory listing delivers in bulk: on NFS/SMB, `isPackage` or `isHidden` cost a round trip
    /// per file (0.45 s instead of 0.005 s for a 127-file folder). Hidden files are skipped by the listing;
    /// the package check is asked of folders only.
    private static let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

    /// Walks `urls` and hands over tracks as they are found, one folder at a time and in playlist order, so a
    /// big (or network) library starts showing up at once instead of after the whole tree has been read.
    /// Folders are listed with their file attributes in one request each (fast on NFS/SMB too).
    static func scan(_ urls: [URL], batch emit: ([Track]) -> Void) {
        func track(_ url: URL, _ v: URLResourceValues?) -> Track {
            Track(path: url.path, size: Int64(v?.fileSize ?? 0), mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }

        /// One folder: its audio files (with CUE sheets applied), sorted, then its subfolders in name order.
        func walk(_ dir: URL) {
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                         options: [.skipsHiddenFiles]) else { return }
            var files: [Track] = [], cues: [URL] = [], subdirs: [URL] = []
            for url in items {
                let v = try? url.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true {
                    if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true { subdirs.append(url) }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                if ext == "cue" { cues.append(url); continue }
                guard audioExtensions.contains(ext), v?.isRegularFile == true else { continue }
                files.append(track(url, v))
            }
            // CUE sheets: their tracks replace the whole-file entries they split up.
            if !cues.isEmpty {
                var covered = Set<String>()
                var cueTracks: [Track] = []
                for c in cues.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                    guard let sheet = CueSheet.load(c) else { continue }
                    let r = sheet.tracks(cueURL: c)
                    let fresh = r.covered.subtracting(covered)   // two cues for one file: first wins
                    cueTracks += r.tracks.filter { fresh.contains($0.path) }
                    covered.formUnion(fresh)
                }
                files = files.filter { !covered.contains($0.path) } + cueTracks
            }
            // Sorted by name (then CUE position) so albums stay in track order.
            files.sort {
                let r = $0.path.localizedStandardCompare($1.path)
                return r == .orderedSame ? ($0.cueStart ?? 0) < ($1.cueStart ?? 0) : r == .orderedAscending
            }
            if !files.isEmpty { emit(files) }
            for d in subdirs.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                walk(d)
            }
        }

        var loose: [Track] = []   // single files and playlists, handed over in the order given
        func flushLoose() { if !loose.isEmpty { emit(loose); loose.removeAll() } }

        for root in urls {
            let rv = try? root.resourceValues(forKeys: Set(keys))
            if rv?.isDirectory == true {
                flushLoose()
                walk(root)
            } else if root.pathExtension.lowercased() == "cue" {
                if let sheet = CueSheet.load(root) { loose += sheet.tracks(cueURL: root).tracks }
            } else if PlaylistFile.isPlaylist(root) {
                // Keep the playlist's own order; skip entries whose files are gone.
                for e in PlaylistFile.entries(root) {
                    let url = e.url
                    if !url.isFileURL, let show = e.podcast {
                        // Saved as "Show - Episode": keep just the episode title.
                        var title = e.title ?? url.lastPathComponent
                        if title.hasPrefix(show + " - ") { title.removeFirst(show.count + 3) }
                        loose.append(.episode(url.absoluteString, title: title, show: show, artwork: e.logo, duration: e.seconds,
                                              published: nil, summary: nil))
                        continue
                    }
                    if !url.isFileURL { loose.append(.stream(url.absoluteString, name: e.title, logo: e.logo)); continue }
                    let v = try? url.resourceValues(forKeys: Set(keys))
                    guard v?.isRegularFile == true, audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                    loose.append(track(url, v))
                }
            } else if audioExtensions.contains(root.pathExtension.lowercased()) {
                loose.append(track(root, rv))
            }
        }
        flushLoose()
    }

}
