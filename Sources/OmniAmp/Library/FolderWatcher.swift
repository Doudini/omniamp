import CoreServices
import Foundation

/// FSEvents stream over a set of folders, delivering changed paths on the main queue.
final class FolderWatcher {
    /// Changed paths, and whether FSEvents asked for a full rescan (dropped events, root changed…).
    var onEvents: (([String], Bool) -> Void)?
    private var stream: FSEventStreamRef?

    func watch(_ roots: [String]) {
        stop()
        guard !roots.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String]) ?? []
            let rescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                     | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            let rescan = (0..<count).contains { flags[$0] & rescanFlags != 0 }
            me.onEvents?(paths, rescan)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, roots as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

/// Keeps the playlist in sync with the user's watched folders.
///
/// Playlist-based: watched folders feed the playlist but never own it. New files are added next to their
/// folder-mates, deleted files are removed, edited files are re-tagged. OmniAmp remembers which files it has
/// already seen, so tracks the user removed by hand are not re-added on the next scan.
final class FolderSync {
    private unowned let controller: PlayerController
    private let watcher = FolderWatcher()
    private(set) var roots: [String]
    /// Files already seen per root (persisted).
    private var seen: [String: Set<String>] = [:]
    private var pending = Set<String>()
    private var flushWork: DispatchWorkItem?
    var onSynced: ((_ added: Int, _ removed: Int, _ updated: Int) -> Void)?

    private static var stateURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("watched.plist") }

    init(controller: PlayerController) {
        self.controller = controller
        roots = UserDefaults.standard.stringArray(forKey: "watchedFolders") ?? []
        if let d = try? Data(contentsOf: Self.stateURL),
           let s = try? PropertyListDecoder().decode([String: [String]].self, from: d) {
            seen = s.mapValues(Set.init)
        }
        watcher.onEvents = { [weak self] paths, rescan in self?.received(paths, rescan: rescan) }
        watcher.watch(roots)
    }

    // MARK: Folders

    /// Start watching a folder and add its music to the playlist.
    func add(_ url: URL) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { rescan([path]); return }
        // A new parent replaces watched subfolders.
        for r in roots where r.hasPrefix(path + "/") {
            seen[path, default: []].formUnion(seen.removeValue(forKey: r) ?? [])
        }
        roots.removeAll { $0.hasPrefix(path + "/") }
        roots.append(path)
        persistRoots()
        rescan([path])
    }

    func remove(_ root: String, removeTracks: Bool) {
        roots.removeAll { $0 == root }
        seen.removeValue(forKey: root)
        persistRoots()
        saveSeen()
        if removeTracks {
            let idx = IndexSet(controller.tracks.indices.filter { controller.tracks[$0].path.hasPrefix(root + "/") })
            controller.remove(trackIndices: idx)
        }
    }

    func rescanAll() { rescan(roots) }

    private func persistRoots() {
        UserDefaults.standard.set(roots, forKey: "watchedFolders")
        watcher.watch(roots)
    }

    private func root(of path: String) -> String? {
        roots.first { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Rewrite a path into its root's stored spelling. The file system hands out several spellings of
    /// the same folder (e.g. /var/… vs /private/var/… from the enumerator and FSEvents).
    static func canonical(_ path: String, roots: [String]) -> String {
        for r in roots {
            var forms = [r, r.hasPrefix("/private/") ? String(r.dropFirst(8)) : "/private" + r]
            let resolved = URL(fileURLWithPath: r).resolvingSymlinksInPath().path
            if !forms.contains(resolved) { forms.append(resolved) }
            for f in forms where path == f || path.hasPrefix(f + "/") { return r + path.dropFirst(f.count) }
        }
        return path
    }

    // MARK: Events

    private func received(_ paths: [String], rescan: Bool) {
        if rescan {
            pending.formUnion(roots)
        } else {
            for p in paths.map({ Self.canonical($0, roots: roots) }) where root(of: p) != nil {
                let name = (p as NSString).lastPathComponent
                guard !name.hasPrefix(".") else { continue }  // .DS_Store, temp files
                // A changed file is rescanned with its folder: a .cue there may split it into tracks.
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
                pending.insert(exists && !isDir.boolValue ? (p as NSString).deletingLastPathComponent : p)
            }
        }
        // Coalesce bursts (copying an album fires one event per file).
        flushWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let scopes = self.pending
            self.pending.removeAll()
            self.rescan(Array(scopes))
        }
        flushWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    // MARK: Reconcile

    /// Re-read the given folders/files and bring the playlist in line with them.
    private func rescan(_ rawScopes: [String]) {
        // Drop scopes already covered by an ancestor scope.
        let sorted = Set(rawScopes).sorted()
        var scopes: [String] = []
        for s in sorted where !scopes.contains(where: { s.hasPrefix($0 + "/") }) { scopes.append(s) }
        guard !scopes.isEmpty else { return }

        let rootsSnapshot = roots
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var dirs: [String] = [], gone: [String] = [], found: [Track] = []
            for s in scopes {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: s, isDirectory: &isDir) {
                    if isDir.boolValue { dirs.append(s) }
                    found += FolderScanner.scan([URL(fileURLWithPath: s)]).map { t in
                        var t = t
                        t.path = Self.canonical(t.path, roots: rootsSnapshot)
                        return t
                    }
                } else {
                    gone.append(s)
                }
            }
            DispatchQueue.main.async { self.apply(dirs: dirs, gone: gone, found: found) }
        }
    }

    private func apply(dirs: [String], gone: [String], found: [Track]) {
        let foundKeys = Set(found.map(\.key))
        func covered(_ path: String) -> Bool {
            dirs.contains { path.hasPrefix($0 + "/") } || gone.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        // 1. Removed on disk.
        let tracks = controller.tracks
        let removed = IndexSet(tracks.indices.filter { i in
            let p = tracks[i].path
            return root(of: p) != nil && covered(p) && !foundKeys.contains(tracks[i].key)
        })
        for r in roots { seen[r] = seen[r]?.filter { !(covered($0) && !foundKeys.contains($0)) } }
        if !removed.isEmpty { controller.remove(trackIndices: removed) }

        // 2. Changed on disk → re-read tags.
        var index: [String: Int] = [:]
        for (i, t) in controller.tracks.enumerated() { index[t.key] = i }
        var updates: [(index: Int, size: Int64, mtime: Double)] = []
        for f in found {
            if let i = index[f.key], controller.tracks[i].size != f.size || controller.tracks[i].mtime != f.mtime {
                updates.append((i, f.size, f.mtime))
            }
        }
        controller.store.refresh(updates)

        // 3. New files (never seen before, not already in the playlist) → next to their folder-mates.
        var fresh: [Track] = []
        for f in found {
            guard let r = root(of: f.path) else { continue }
            let isNew = !(seen[r]?.contains(f.key) ?? false)
            seen[r, default: []].insert(f.key)
            if isNew && index[f.key] == nil { fresh.append(f) }
        }
        var byDir: [(String, [Track])] = []
        for f in fresh {
            let d = (f.path as NSString).deletingLastPathComponent
            if let k = byDir.firstIndex(where: { $0.0 == d }) { byDir[k].1.append(f) } else { byDir.append((d, [f])) }
        }
        for (dir, group) in byDir {
            let all = controller.tracks
            let at = all.lastIndex { ($0.path as NSString).deletingLastPathComponent == dir }.map { $0 + 1 } ?? all.count
            controller.insertScanned(group, at: at)
        }

        saveSeen()
        if !removed.isEmpty || !updates.isEmpty || !fresh.isEmpty {
            NSLog("OmniAmp: folder sync +%d −%d ~%d", fresh.count, removed.count, updates.count)
            onSynced?(fresh.count, removed.count, updates.count)
        }
    }

    private func saveSeen() {
        let snapshot = seen.mapValues { Array($0) }
        DispatchQueue.global(qos: .background).async {
            let enc = PropertyListEncoder()
            enc.outputFormat = .binary
            if let d = try? enc.encode(snapshot) { try? d.write(to: Self.stateURL, options: .atomic) }
        }
    }
}
