import CoreServices
import Foundation

/// FSEvents stream over a set of folders, delivering changed paths on the main queue.
final class FolderWatcher {
    /// Changed paths, whether FSEvents asked for a full rescan (dropped events, root changed, history
    /// incomplete…), and the newest event ID in the batch.
    var onEvents: (([String], Bool, FSEventStreamEventId) -> Void)?
    private var stream: FSEventStreamRef?

    /// `since`: replay what changed after this event ID (changes made while OmniAmp was closed) first.
    func watch(_ roots: [String], since: FSEventStreamEventId? = nil) {
        stop()
        guard !roots.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, ids in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let all = (Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String]) ?? []
            let rescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                     | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
                                     | kFSEventStreamEventFlagEventIdsWrapped)
            let rescan = (0..<count).contains { flags[$0] & rescanFlags != 0 }
            // "History done" marks the end of the replay: not a change.
            let paths = (0..<min(count, all.count)).filter { flags[$0] & UInt32(kFSEventStreamEventFlagHistoryDone) == 0 }.map { all[$0] }
            let newest = (0..<count).map { ids[$0] }.max() ?? 0
            me.onEvents?(paths, rescan, newest)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, roots as CFArray,
                                          since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
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
@MainActor
final class FolderSync {
    /// Weak: a scan finishing after the controller is gone (tests, quitting) just does nothing.
    private weak var controllerRef: PlayerController?
    private let watcher = FolderWatcher()
    private(set) var roots: [String]
    /// Files already seen per root (persisted).
    private var seen: [String: Set<String>] = [:]
    private var pending = Set<String>()
    private var flushWork: DispatchWorkItem?
    var onSynced: ((_ added: Int, _ removed: Int, _ updated: Int) -> Void)?

    nonisolated private static var stateURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("watched.plist") }

    init(controller: PlayerController) {
        self.controllerRef = controller
        roots = UserDefaults.standard.stringArray(forKey: Pref.watchedFolders) ?? []
        if let d = try? Data(contentsOf: Self.stateURL),
           let s = try? PropertyListDecoder().decode([String: [String]].self, from: d) {
            seen = s.mapValues(Set.init)
        }
        watcher.onEvents = { [weak self] paths, rescan, newest in self?.received(paths, rescan: rescan, through: newest) }
        let resume = Self.resumePoint(for: roots)
        processedThrough = resume ?? 0
        watcher.watch(roots, since: resume)
    }

    // MARK: Catching up at launch

    // How far the playlist is in line with the folders: an FSEvents event ID, saved with the time and the
    // roots it belongs to. At launch the events after it are replayed (only what changed is read again)
    // instead of re-reading every file in every watched folder.
    private static let resumeKey = "watchedResumePoint"
    /// Replays only reach this far back with confidence; older, or roots changed: read everything again.
    private static let resumeMaxAge: TimeInterval = 7 * 86400

    private static func resumePoint(for roots: [String]) -> FSEventStreamEventId? {
        guard let d = UserDefaults.standard.dictionary(forKey: resumeKey), let id = d["id"] as? NSNumber,
              let at = d["at"] as? Double, Date().timeIntervalSince1970 - at < resumeMaxAge,
              (d["roots"] as? [String])?.sorted() == roots.sorted() else { return nil }
        return id.uint64Value
    }

    /// Folders whose changes FSEvents keeps a history of: local internal disks. Network shares report no
    /// events from other computers and external drives may keep no history: those are read again.
    private static func historyKept(_ root: String) -> Bool {
        let v = try? URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey])
        return v?.volumeIsLocal == true && v?.volumeIsInternal == true
    }

    /// At launch: replay events where there's a history (started in init), read the rest again.
    func catchUp() {
        if Self.resumePoint(for: roots) == nil { rescanAll(); return }
        let others = roots.filter { !Self.historyKept($0) }
        if !others.isEmpty { rescan(others) }
    }

    /// Everything up to here is applied to the playlist (only moves forward).
    private var processedThrough: FSEventStreamEventId = 0
    private var scansRunning = 0

    private func saveResumePoint() {
        guard scansRunning == 0, pending.isEmpty, processedThrough > 0 else { return }
        UserDefaults.standard.set(["id": NSNumber(value: processedThrough), "at": Date().timeIntervalSince1970, "roots": roots],
                                  forKey: Self.resumeKey)
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
        rescan([path], through: FSEventsGetCurrentEventId())
    }

    func remove(_ root: String, removeTracks: Bool) {
        roots.removeAll { $0 == root }
        seen.removeValue(forKey: root)
        persistRoots()
        saveSeen()
        saveResumePoint()   // for the remaining roots
        if removeTracks, let controller = controllerRef {
            let idx = IndexSet(controller.tracks.indices.filter { controller.tracks[$0].path.hasPrefix(root + "/") })
            controller.remove(trackIndices: idx)
        }
    }

    func rescanAll() { rescan(roots, through: FSEventsGetCurrentEventId()) }

    private func persistRoots() {
        UserDefaults.standard.set(roots, forKey: Pref.watchedFolders)
        watcher.watch(roots)
    }

    private func root(of path: String) -> String? {
        roots.first { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// A missing path only counts as deleted while its watched root is still there. With the root missing
    /// too, the drive or share is unmounted (or the folder moved away): keep its tracks and seen files
    /// rather than wiping them; they come back on remount.
    nonisolated static func deletionIsReal(_ path: String, roots: [String]) -> Bool {
        guard let r = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
        return FileManager.default.fileExists(atPath: r)
    }

    /// Rewrite a path into its root's stored spelling. The file system hands out several spellings of
    /// the same folder (e.g. /var/… vs /private/var/… from the enumerator and FSEvents).
    nonisolated static func canonical(_ path: String, roots: [String]) -> String {
        for r in roots {
            var forms = [r, r.hasPrefix("/private/") ? String(r.dropFirst(8)) : "/private" + r]
            let resolved = URL(fileURLWithPath: r).resolvingSymlinksInPath().path
            if !forms.contains(resolved) { forms.append(resolved) }
            for f in forms where path == f || path.hasPrefix(f + "/") { return r + path.dropFirst(f.count) }
        }
        return path
    }

    // MARK: Events

    /// The newest event received and not yet applied (applied with the rescan it triggers).
    private var receivedThrough: FSEventStreamEventId = 0

    private func received(_ paths: [String], rescan: Bool, through newest: FSEventStreamEventId) {
        receivedThrough = max(receivedThrough, newest)
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
            self.rescan(Array(scopes), through: self.receivedThrough)
        }
        flushWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    // MARK: Reconcile

    /// Re-read the given folders/files and bring the playlist in line with them. `through`: the event ID
    /// this brings the playlist up to (saved as the resume point once nothing else is pending).
    private func rescan(_ rawScopes: [String], through: FSEventStreamEventId = 0) {
        // Drop scopes already covered by an ancestor scope.
        let sorted = Set(rawScopes).sorted()
        var scopes: [String] = []
        for s in sorted where !scopes.contains(where: { s.hasPrefix($0 + "/") }) { scopes.append(s) }
        guard !scopes.isEmpty else { return }

        let rootsSnapshot = roots
        scansRunning += 1
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var dirs: [String] = [], gone: [String] = [], found: [Track] = [], unreadable: [String] = []
            for s in scopes {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: s, isDirectory: &isDir) {
                    if isDir.boolValue { dirs.append(s) }
                    found += FolderScanner.scan([URL(fileURLWithPath: s)], unreadable: &unreadable).map { t in
                        var t = t
                        t.path = Self.canonical(t.path, roots: rootsSnapshot)
                        return t
                    }
                } else if Self.deletionIsReal(s, roots: rootsSnapshot) {
                    gone.append(s)
                }
            }
            let unknown = unreadable.map { Self.canonical($0, roots: rootsSnapshot) }
            DispatchQueue.main.async {
                self.scansRunning -= 1
                self.apply(dirs: dirs, gone: gone, found: found, unknown: unknown)
                self.processedThrough = max(self.processedThrough, through)
                self.saveResumePoint()
            }
        }
    }

    /// `unknown`: folders that couldn't be listed. What's under them is left alone (no removals, `seen` kept):
    /// a permission problem or a network error must not look like "everything was deleted".
    func apply(dirs: [String], gone: [String], found: [Track], unknown: [String] = []) {
        guard let controller = controllerRef else { return }
        let foundKeys = Set(found.map(\.key))
        var unknown = unknown
        // A watched root that suddenly lists nothing while the playlist still has its tracks is far more likely
        // unavailable (a share mounted over an empty folder, a drive that isn't ready) than emptied.
        let tracksNow = controller.tracks
        for d in dirs where roots.contains(d) && !found.contains(where: { $0.path.hasPrefix(d + "/") })
            && tracksNow.contains(where: { $0.path.hasPrefix(d + "/") }) {
            NSLog("OmniAmp: watched folder %@ lists no files: treating it as unavailable", d)
            unknown.append(d)
        }
        func isUnknown(_ path: String) -> Bool { unknown.contains { path == $0 || path.hasPrefix($0 + "/") } }
        func covered(_ path: String) -> Bool {
            guard !isUnknown(path) else { return false }
            return dirs.contains { path.hasPrefix($0 + "/") } || gone.contains { path == $0 || path.hasPrefix($0 + "/") }
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
        // Grouped by folder, each after the last playlist row from that folder (new folders at the end), all
        // in one pass and one insert: per folder it scanned the whole playlist and reloaded the table.
        if !fresh.isEmpty {
            var order: [String] = [], byDir: [String: [Track]] = [:]
            for f in fresh {
                let d = (f.path as NSString).deletingLastPathComponent
                if byDir[d] == nil { order.append(d) }
                byDir[d, default: []].append(f)
            }
            var lastRow: [String: Int] = [:]
            let all = controller.tracks
            for (i, t) in all.enumerated() where byDir[(t.path as NSString).deletingLastPathComponent] != nil {
                lastRow[(t.path as NSString).deletingLastPathComponent] = i
            }
            controller.insertScanned(order.map { d in (lastRow[d].map { $0 + 1 } ?? all.count, byDir[d]!) })
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
