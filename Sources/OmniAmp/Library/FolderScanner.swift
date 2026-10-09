import AudioToolbox
import Foundation
import os

/// Stage 1: walk folders/files and produce bare tracks (no tag reading).
enum FolderScanner {
    /// What OmniAmp plays: every audio file type this Mac's macOS can read (asked once, so Ogg Vorbis and Opus
    /// count only where the system opens them), plus spellings it opens without listing them.
    static let audioExtensions: Set<String> = readableBySystem().map { $0.union(["alac", "wave"]) } ?? fallbackExtensions
    /// Music OmniAmp can't play (no decoder in macOS, or copy-protected): the library still lists it, marked,
    /// so nothing in a collection is silently missing. The playlist leaves it out.
    static let unplayableExtensions: Set<String> = Set(["wma", "shn", "ape", "wv", "mpc", "m4p", "ra", "rm", "tta", "dsf", "dff", "aa", "aax",
                                                        "ogg", "oga", "opus"]).subtracting(audioExtensions)

    /// If macOS can't be asked: the formats every supported version plays.
    static let fallbackExtensions: Set<String> = ["mp3", "flac", "m4a", "m4b", "mp4", "aac", "alac", "wav", "wave", "aif", "aiff", "aifc", "caf"]
    /// Types macOS reads that are video containers, or names that are mostly video files ("mpeg").
    private static let notMusic: Set<String> = ["mov", "qt", "3gp", "3gpp", "3g2", "3gp2", "mpeg"]

    /// The file name extensions of every type Core Audio can read here.
    static func readableBySystem() -> Set<String>? {
        var size: UInt32 = 0
        guard AudioFileGetGlobalInfoSize(kAudioFileGlobalInfo_ReadableTypes, 0, nil, &size) == noErr, size > 0 else { return nil }
        var types = [AudioFileTypeID](repeating: 0, count: Int(size) / MemoryLayout<AudioFileTypeID>.size)
        guard AudioFileGetGlobalInfo(kAudioFileGlobalInfo_ReadableTypes, 0, nil, &size, &types) == noErr else { return nil }
        var out = Set<String>()
        for var type in types {
            var list: Unmanaged<CFArray>?
            var listSize = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
            guard AudioFileGetGlobalInfo(kAudioFileGlobalInfo_ExtensionsForType, UInt32(MemoryLayout<AudioFileTypeID>.size), &type,
                                         &listSize, &list) == noErr, let exts = list?.takeRetainedValue() as? [String] else { continue }
            out.formUnion(exts.map { $0.lowercased() })
        }
        out.subtract(notMusic)
        // Something went wrong if even the basics are missing: keep to the known list.
        return fallbackExtensions.subtracting(["alac", "wave"]).isSubset(of: out) ? out : nil
    }

    static func scan(_ urls: [URL]) -> [Track] {
        var out: [Track] = []
        scan(urls) { out += $0 }
        return out
    }

    /// Also returns the folders that couldn't be listed (permission denied, network error…): their contents
    /// are unknown, which is not the same as empty.
    static func scan(_ urls: [URL], unreadable: inout [String]) -> [Track] {
        var out: [Track] = [], failed: [String] = []
        scan(urls, batch: { out += $0 }, unreadable: { failed.append($0) })
        unreadable += failed
        return out
    }

    /// Only keys a directory listing delivers in bulk: on NFS/SMB, `isPackage` or `isHidden` cost a round trip
    /// per file (0.45 s instead of 0.005 s for a 127-file folder). Hidden files are skipped by the listing;
    /// the package check is asked of folders only.
    private static let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                                         .contentModificationDateKey]

    /// Walks `urls` and hands over tracks as they are found, one folder at a time and in playlist order, so a
    /// big (or network) library starts showing up at once instead of after the whole tree has been read.
    /// Folders are listed with their file attributes in one request each (fast on NFS/SMB too).
    /// `includeUnplayable`: also list files in formats OmniAmp can't play (for the library).
    static func scan(_ urls: [URL], includeUnplayable: Bool = false, batch emit: ([Track]) -> Void, unreadable: ((String) -> Void)? = nil) {
        func track(_ url: URL, _ v: URLResourceValues?) -> Track {
            Track(path: url.path, size: Int64(v?.fileSize ?? 0), mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }

        /// A symlink's target's values (links to files and folders are followed, like Finder aliases aren't).
        @Sendable func values(_ url: URL) -> URLResourceValues? {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isSymbolicLink == true else { return v }
            return try? URL(exactPath: ExactPath.resolved(url.path)).resourceValues(forKeys: Set(keys))
        }

        // Every folder's real path: a link back up the tree must neither loop nor add a folder twice. Only links
        // and roots are resolved (a lookup per folder is a round trip on a network share); a plain subfolder's
        // real path is its parent's plus its name.
        var visited = Set<String>()

        /// One folder: its audio files (with CUE sheets applied), sorted, then its subfolders in name order.
        /// `underLink`: the folder is a link or inside one.
        func walk(_ dir: URL, real: String, linked: Bool = false, underLink: Bool = false) {
            guard visited.insert(real).inserted else { return }
            // The listing doesn't follow a linked folder: list its target, keep the paths under the link.
            let listFrom = linked ? URL(exactPath: real, isDirectory: true) : dir
            guard let listed = try? FileManager.default.contentsOfDirectory(at: listFrom, includingPropertiesForKeys: keys,
                                                                          options: [.skipsHiddenFiles]) else {
                unreadable?(dir.path)
                return
            }
            var files: [Track] = [], cues: [URL] = [], subdirs: [(url: URL, linked: Bool)] = []
            for item in listed {
                // In and below a linked folder, the listing gives the link target's paths, which would put those files
                // outside their library folder: keep the path under the link. appendingExact, not appendingPathComponent,
                // which would decompose accented names (NFC on the NAS) and lose them. The attributes come from the
                // listed URL, which has them already (no round trip per file).
                let url = underLink ? dir.appendingExact(item.lastPathComponent, isDirectory: item.hasDirectoryPath) : item
                let v = values(item)
                // Still a link: its target can't be reached (its volume offline). Unknown, like a folder that can't be listed.
                if v?.isSymbolicLink == true {
                    unreadable?(url.path)
                    continue
                }
                if v?.isDirectory == true {
                    if (try? item.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true {
                        subdirs.append((url, (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true))
                    }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                if ext == "cue" { cues.append(url); continue }
                guard audioExtensions.contains(ext) || includeUnplayable && unplayableExtensions.contains(ext), v?.isRegularFile == true
                else { continue }
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
            for d in subdirs.sorted(by: { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }) {
                walk(d.url, real: d.linked ? ExactPath.resolved(d.url.path) : real + "/" + d.url.lastPathComponent,
                     linked: d.linked, underLink: underLink || d.linked)
            }
        }

        /// The CUE track starting at `start` in `file`, from the sheets next to it (read once per folder).
        var sheetTracks: [String: [Track]] = [:]
        func cueTrack(_ file: URL, start: Double) -> Track? {
            let dir = file.deletingLastPathComponent()
            if sheetTracks[dir.path] == nil {
                let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                sheetTracks[dir.path] = items.filter { $0.pathExtension.lowercased() == "cue" }
                    .flatMap { c in CueSheet.load(c)?.tracks(cueURL: c).tracks ?? [] }
            }
            return sheetTracks[dir.path]?.first { $0.path == file.path && abs(($0.cueStart ?? -1) - start) < 0.001 }
        }

        var loose: [Track] = []   // single files and playlists, handed over in the order given
        func flushLoose() { if !loose.isEmpty { emit(loose); loose.removeAll() } }

        for root in urls {
            let rv = values(root)
            if rv?.isDirectory == true {
                flushLoose()
                let isLink = (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                walk(root, real: ExactPath.resolved(root.path), linked: isLink, underLink: isLink)
            } else if root.pathExtension.lowercased() == "cue" {
                if let sheet = CueSheet.load(root) { loose += sheet.tracks(cueURL: root).tracks }
            } else if PlaylistFile.isPlaylist(root) {
                // Keep the playlist's own order; skip entries whose files are gone. Each file is looked up (a round
                // trip on a network share, ~3.5 ms on NFS), so a few at a time and in slices: a 10k-entry playlist
                // starts showing at once instead of after the last lookup.
                let entries = PlaylistFile.entries(root)
                // What a lookup found: a file's size and date (URLResourceValues itself can't cross threads).
                struct Found: Sendable { let size: Int64, mtime: Double }
                var looked: [Found?] = []
                for (n, e) in entries.enumerated() {
                    if n % 256 == 0 {
                        flushLoose()
                        let slice = entries[n..<min(n + 256, entries.count)].map(\.url)
                        // Each lookup fills its own slot; the lock is a few nanoseconds against a network round trip.
                        let results = OSAllocatedUnfairLock(initialState: [Found?](repeating: nil, count: slice.count))
                        DispatchQueue.concurrentPerform(iterations: slice.count) { i in
                            guard slice[i].isFileURL, let v = values(slice[i]), v.isRegularFile == true else { return }
                            let found = Found(size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
                            results.withLock { $0[i] = found }
                        }
                        looked = results.withLock { $0 }
                    }
                    let url = e.url
                    if let remote = PlaylistFile.remoteTrack(e) { loose.append(remote); continue }
                    guard let f = looked[n % 256], audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                    let found = Track(path: url.path, size: f.size, mtime: f.mtime)
                    if let start = e.cueStart {
                        // A saved CUE track: take it from its sheet again (titles), else rebuild it from the range.
                        if let t = cueTrack(url, start: start) { loose.append(t); continue }
                        var t = found
                        t.cueStart = start
                        t.cueEnd = e.cueEnd
                        t.cueNumber = e.cueNumber
                        t.title = e.title
                        loose.append(t)
                        continue
                    }
                    loose.append(found)
                }
            } else if audioExtensions.contains(root.pathExtension.lowercased()) {
                loose.append(track(root, rv))
            }
        }
        flushLoose()
    }

}
