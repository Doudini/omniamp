import CoreServices
import Foundation

/// The music library: folders the user points at (a NAS share, typically), kept in a database that the
/// Library window browses. Separate from the playlist and its watched folders.
///
/// Stays in step with the folders: FSEvents while OmniAmp runs, a replay of what changed while it was closed
/// (local disks), and a listing of network folders at launch and every hour, since a share doesn't report
/// changes made from other computers. Only new and changed files are read again.
@MainActor
final class MusicCollection {
    static let shared = MusicCollection()
    static let changed = Notification.Name("OmniAmpLibraryChanged")
    static let progressChanged = Notification.Name("OmniAmpLibraryProgress")

    private(set) var roots: [String]
    /// The main thread's connection (browsing). nil when the database couldn't be opened.
    let reader: CollectionDB?
    private let scanner: CollectionScanner?
    private(set) var openError: String?
    private(set) var progress = CollectionScanner.Progress()
    private let watcher = FolderWatcher()
    private var pending = Set<String>()
    private var flushWork: DispatchWorkItem?
    private var networkTimer: Timer?
    private var started = false
    /// How often network folders are listed again.
    static let networkRecheck: TimeInterval = 3600

    /// Whether there's a library at all (without opening its database).
    nonisolated static var hasFolders: Bool { !(UserDefaults.standard.stringArray(forKey: Pref.libraryFolders) ?? []).isEmpty }

    private var needsFullScan = false

    private init() {
        roots = UserDefaults.standard.stringArray(forKey: Pref.libraryFolders) ?? []
        do {
            let writer = try CollectionDB()
            needsFullScan = writer.needsFullScan
            reader = try CollectionDB()
            scanner = CollectionScanner(db: writer)
        } catch {
            reader = nil
            scanner = nil
            openError = "\(error)"
            NSLog("OmniAmp: library database unavailable: %@", "\(error)")
        }
        scanner?.onProgress = { [weak self] p in
            MainActor.assumeIsolated {
                self?.progress = p
                NotificationCenter.default.post(name: Self.progressChanged, object: nil)
            }
        }
        scanner?.onChange = { MainActor.assumeIsolated { NotificationCenter.default.post(name: Self.changed, object: nil) } }
        watcher.onEvents = { [weak self] paths, rescan, newest in self?.received(paths, rescan: rescan, through: newest) }
    }

    /// At launch, when there are library folders: watch them and catch up with what changed meanwhile.
    func start() {
        guard !started, scanner != nil else { return }
        started = true
        let resume = Self.resumePoint(for: roots)
        processedThrough = resume ?? 0
        watcher.watch(roots, since: resume)
        if resume == nil || needsFullScan { rescan(roots) } else {
            WatchedRoots.withoutHistory(roots) { [weak self] others in
                if !others.isEmpty { self?.rescan(others) }
            }
        }
        scheduleNetworkRecheck()
        rereadNewlyPlayable()
    }

    /// Files kept as "can't play" in a format this Mac plays now (OmniAmp learned it, or macOS did: Opus): read
    /// again, only those, so they show up as playable without a full rescan.
    private func rereadNewlyPlayable() {
        let playable = FolderScanner.audioExtensions
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let db = try? CollectionDB(), let paths = try? db.unplayablePaths() else { return }
            let now = paths.filter { playable.contains(($0 as NSString).pathExtension.lowercased()) }
            guard !now.isEmpty else { return }
            let folders = Set(now.map { ($0 as NSString).deletingLastPathComponent })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let scanner = self.scanner else { return }
                    NSLog("OmniAmp: library: %d files in formats that play now, reading them again", now.count)
                    scanner.markChanged(paths: now)
                    self.rescan(Array(folders))
                }
            }
        }
    }

    // MARK: Folders

    func add(_ url: URL) {
        let path = ExactPath.resolved(url.path)
        if roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { rescan([path]); return }
        // A parent replaces the folders inside it (their files stay: same paths, same root from now on).
        roots.removeAll { $0.hasPrefix(path + "/") }
        roots.append(path)
        saveRoots()
        rescan([path])
    }

    func remove(_ root: String) {
        roots.removeAll { $0 == root }
        saveRoots()
        scanner?.forget(root: root)
    }

    func rescanAll() { rescan(roots) }

    /// Read one folder again now (after OmniAmp changed files in it; a share wouldn't tell).
    func rescan(folder: String) { rescan([folder]) }

    /// Tags OmniAmp wrote into these files (their dates kept, so a scan wouldn't notice): read them again, now.
    func reread(_ paths: [String], in folder: String) {
        scanner?.markChanged(paths: paths)
        rescan([folder])
    }

    private func saveRoots() {
        UserDefaults.standard.set(roots, forKey: Pref.libraryFolders)
        started = true
        watcher.watch(roots)
        scheduleNetworkRecheck()
    }

    private func scheduleNetworkRecheck() {
        networkTimer?.invalidate()
        networkTimer = nil
        WatchedRoots.withoutHistory(roots) { [weak self] others in
            guard let self else { return }
            self.networkTimer?.invalidate()   // a second call's answer replaces the first's
            self.networkTimer = nil
            guard !others.isEmpty else { return }
            let t = Timer(timeInterval: Self.networkRecheck, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.progress.running else { return }
                    WatchedRoots.withoutHistory(self.roots) { [weak self] others in
                        if !others.isEmpty { self?.rescan(others) }
                    }
                }
            }
            t.tolerance = 300
            RunLoop.main.add(t, forMode: .common)
            self.networkTimer = t
        }
    }

    // MARK: Scanning

    private var scansRunning = 0
    private var processedThrough: FSEventStreamEventId = 0

    private func rescan(_ scopes: [String], through: FSEventStreamEventId = FSEventsGetCurrentEventId()) {
        guard let scanner, !scopes.isEmpty else { return }
        scansRunning += 1
        let rootsNow = roots
        // Each root's spellings are resolved on the share: off the main thread.
        WatchedRoots.queue.async { [weak self] in
            let canonical = scopes.map(FolderSync.canonicalizer(roots: rootsNow))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    scanner.scan(canonical, roots: rootsNow) {
                        MainActor.assumeIsolated {
                            self.scansRunning -= 1
                            self.processedThrough = max(self.processedThrough, through)
                            self.saveResumePoint()
                        }
                    }
                }
            }
        }
    }

    // MARK: Events

    private var receivedThrough: FSEventStreamEventId = 0

    private func received(_ paths: [String], rescan: Bool, through newest: FSEventStreamEventId) {
        let roots = self.roots
        WatchedRoots.queue.async { [weak self] in
            let scopes = WatchedRoots.scopes(for: paths, rescan: rescan, roots: roots)
            DispatchQueue.main.async {
                // The event ID moves on only with its paths: a resume point saved meanwhile mustn't skip them.
                MainActor.assumeIsolated { self?.queue(scopes, through: newest) }
            }
        }
    }

    private func queue(_ scopes: [String], through newest: FSEventStreamEventId) {
        receivedThrough = max(receivedThrough, newest)
        pending.formUnion(scopes)
        // Copying an album fires an event per file: wait until it settles.
        flushWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let scopes = Array(self.pending)
            self.pending.removeAll()
            self.rescan(scopes, through: self.receivedThrough)
        }
        flushWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    // MARK: Catching up at launch (same scheme as the playlist's watched folders)

    private static let resumeKey = "libraryResumePoint"
    private static let resumeMaxAge: TimeInterval = 7 * 86400

    private static func resumePoint(for roots: [String]) -> FSEventStreamEventId? {
        guard let d = UserDefaults.standard.dictionary(forKey: resumeKey), let id = d["id"] as? NSNumber,
              let at = d["at"] as? Double, Date().timeIntervalSince1970 - at < resumeMaxAge,
              (d["roots"] as? [String])?.sorted() == roots.sorted() else { return nil }
        return id.uint64Value
    }

    private func saveResumePoint() {
        guard scansRunning == 0, pending.isEmpty, processedThrough > 0 else { return }
        UserDefaults.standard.set(["id": NSNumber(value: processedThrough), "at": Date().timeIntervalSince1970, "roots": roots],
                                  forKey: Self.resumeKey)
    }

}
