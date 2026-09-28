import Foundation

/// Brings the database in line with folders on disk: new and changed files (by size and mtime) get their
/// tags read and classified, files gone from disk are removed. Everything runs off the main thread and
/// writes go through one serial queue, in batches, so the browser stays usable during a first scan of a big
/// share.
///
/// Missing is not deleted: a folder that can't be listed, or a root that's gone or suddenly empty (an
/// unmounted NAS), keeps its files in the library.
final class CollectionScanner: @unchecked Sendable {
    struct Progress: Sendable {
        var found = 0       // files listed so far
        var toRead = 0      // new or changed, tags to read
        var read = 0        // tags read and written
        var removed = 0
        var running = false
    }

    private let db: CollectionDB
    private let writes = DispatchQueue(label: "omniamp.collection.writes", qos: .utility)
    private let lock = NSLock()
    private var progress = Progress()
    private var pending: [LibraryFile] = []   // on `writes` only
    private var activeScans = 0              // under the lock
    /// Batches of new or changed files between writes (one transaction each).
    static let batchSize = 500

    /// On the main queue, at most every half second while scanning, and once when a scan ends.
    var onProgress: ((Progress) -> Void)?
    /// Written to the database: the browser can refresh (main queue, throttled like onProgress).
    var onChange: (() -> Void)?

    init(db: CollectionDB) {
        self.db = db
    }

    var current: Progress { lock.lock(); defer { lock.unlock() }; return progress }

    /// Rescan `scopes` (folders, each inside one of `roots`). `done` runs on the main queue.
    func scan(_ scopes: [String], roots: [String], done: (@Sendable () -> Void)? = nil) {
        lock.lock()
        activeScans += 1
        if activeScans == 1 { progress = Progress(running: true) }
        lock.unlock()
        report()
        DispatchQueue.global(qos: .utility).async {
            for scope in Self.topmost(scopes) {
                guard let root = roots.first(where: { scope == $0 || scope.hasPrefix($0 + "/") }) else { continue }
                self.scan(scope: scope, root: root)
            }
            self.writes.async {
                self.flush()
                self.lock.lock()
                self.activeScans -= 1
                if self.activeScans == 0 { self.progress.running = false }
                self.lock.unlock()
                self.report(force: true)
                if let done { DispatchQueue.main.async(execute: done) }
            }
        }
    }

    /// Scopes without the ones inside others.
    static func topmost(_ scopes: [String]) -> [String] {
        var out: [String] = []
        for s in Set(scopes).sorted() where !out.contains(where: { s.hasPrefix($0 + "/") }) { out.append(s) }
        return out
    }

    /// One folder, synchronously on the calling (background) thread; tag reads and writes run alongside.
    private func scan(scope: String, root: String) {
        guard let isDir = ExactPath.kind(scope) else {
            // Gone: really deleted only while its root is still there (not an unmounted share).
            if scope != root, ExactPath.exists(root) { removeAll(under: scope) }
            return
        }
        guard isDir else { return }
        let known: [String: (size: Int64, mtime: Double)]
        do { known = try writes.sync { try db.known(under: scope) } } catch { NSLog("OmniAmp: library: %@", "\(error)"); return }

        var seen = Set<String>(), unreadable: [String] = []
        let group = DispatchGroup()
        let spell = Self.spelling(of: root)
        FolderScanner.scan([URL(exactPath: scope, isDirectory: true)], includeUnplayable: true, batch: { batch in
            let files = Self.withoutConverted(batch.filter { !$0.isRemote }.map { t in var t = t; t.path = spell(t.path); return t })
            for t in files { seen.insert(t.key) }
            let changed = files.filter { t in known[t.key].map { $0.size != t.size || $0.mtime != t.mtime } ?? true }
            self.bump { $0.found += files.count; $0.toRead += changed.count }
            guard !changed.isEmpty else { return }
            group.enter()
            let byKey = Dictionary(changed.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            TagQueue.read(changed.map { (id: $0.key, path: $0.path, size: $0.size) }, chunk: { results in
                let rows = results.compactMap { r in byKey[r.id].map { Self.file($0, info: r.info, root: root) } }
                self.writes.async { self.add(rows) }
            }, doneQueue: .global(qos: .utility), done: { group.leave() })
        }, unreadable: { unreadable.append(spell($0)) })
        group.wait()

        // Removed on disk: known here, not listed now, and not under a folder that couldn't be read.
        let rootEmpty = scope == root && seen.isEmpty && !known.isEmpty
        if rootEmpty { NSLog("OmniAmp: library folder %@ lists no files: treating it as unavailable", root) }
        guard !rootEmpty else { return }
        let gone = known.keys.filter { k in
            !seen.contains(k) && !unreadable.contains { k.hasPrefix($0 + "/") }
        }
        if !gone.isEmpty {
            writes.async {
                self.flush()
                do { try self.db.remove(keys: gone) } catch { NSLog("OmniAmp: library: %@", "\(error)") }
                self.bump { $0.removed += gone.count }
                self.changed()
            }
        }
    }

    /// The user took a folder out of the library: its files go (after anything still being written).
    func forget(root: String) {
        writes.async {
            self.flush()
            do { try self.db.removeRoot(root) } catch { NSLog("OmniAmp: library: %@", "\(error)") }
            self.changed()
            self.report(force: true)
        }
    }

    private func removeAll(under folder: String) {
        writes.async {
            do {
                let keys = Array(try self.db.known(under: folder).keys)
                try self.db.remove(keys: keys)
                self.bump { $0.removed += keys.count }
                self.changed()
            } catch { NSLog("OmniAmp: library: %@", "\(error)") }
        }
    }

    /// A folder's files without the unplayable ones that have a playable copy next to them ("plea.wma" once
    /// "plea.flac" exists): converted music shows once, and the originals can stay where they are.
    static func withoutConverted(_ files: [Track]) -> [Track] {
        func stem(_ t: Track) -> String { (t.path as NSString).deletingPathExtension.lowercased() }
        func playable(_ t: Track) -> Bool { !FolderScanner.unplayableExtensions.contains((t.path as NSString).pathExtension.lowercased()) }
        guard files.contains(where: { !playable($0) }) else { return files }
        let converted = Set(files.filter(playable).map(stem))
        return files.filter { playable($0) || !converted.contains(stem($0)) }
    }

    /// Paths rewritten into the root's stored spelling: the file system hands out several for one folder
    /// (/var/… and /private/var/…, a link and its target). Worked out once per scan, not per file.
    static func spelling(of root: String) -> @Sendable (String) -> String {
        let other = root.hasPrefix("/private/") ? String(root.dropFirst(8)) : "/private" + root
        let resolved = ExactPath.resolved(root)
        let forms = resolved != root && resolved != other ? [other, resolved] : [other]
        return { path in
            if path == root || path.hasPrefix(root + "/") { return path }
            for f in forms where path == f || path.hasPrefix(f + "/") { return root + path.dropFirst(f.count) }
            return path
        }
    }

    static func file(_ t: Track, info: TagInfo, root: String) -> LibraryFile {
        // A CUE track: the sheet's title, artist and album win; the file's tags fill the gaps.
        var tags = info
        if t.cueStart != nil {
            tags.title = t.title ?? info.title
            tags.artist = t.artist ?? info.artist
            tags.album = t.album ?? info.album
            if let s = t.cueStart { tags.duration = (t.cueEnd ?? info.duration).map { $0 - s } }
        }
        let result = ReleaseClassifier.classify(path: t.path, root: root, tags: .init(
            title: tags.title, artist: tags.artist, albumArtist: tags.albumArtist, album: tags.album, date: tags.date,
            originalDate: tags.originalDate, releaseType: tags.releaseType, releaseStatus: tags.releaseStatus))
        let name = ((t.path as NSString).lastPathComponent as NSString).deletingPathExtension
        var title = tags.title
        if title == nil || tags.trackNumber == nil {
            let guess = ReleaseClassifier.fromFileName(name, artist: result.artist)
            title = title ?? guess.title
            tags.trackNumber = tags.trackNumber ?? guess.track
            tags.discNumber = tags.discNumber ?? guess.disc
        }
        return LibraryFile(key: t.key, path: t.path, root: root, size: t.size, mtime: t.mtime, cueStart: t.cueStart, cueEnd: t.cueEnd,
                           cueNumber: t.cueNumber, info: tags, result: result, title: title ?? name,
                           playable: !FolderScanner.unplayableExtensions.contains((t.path as NSString).pathExtension.lowercased()))
    }

    // MARK: Writing (on `writes`)

    private func add(_ rows: [LibraryFile]) {
        pending += rows
        bump { $0.read += rows.count }
        if pending.count >= Self.batchSize { flush() }
        report()
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let rows = pending
        pending.removeAll(keepingCapacity: true)
        do { try db.upsert(rows) } catch { NSLog("OmniAmp: library write failed: %@", "\(error)") }
        changed()
    }

    // MARK: Reporting

    private var lastReport = Date.distantPast
    private var dirty = false

    private func bump(_ f: (inout Progress) -> Void) {
        lock.lock(); f(&progress); lock.unlock()
    }

    private func changed() {
        lock.lock(); dirty = true; lock.unlock()
        report()
    }

    private func report(force: Bool = false) {
        lock.lock()
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.5 else { lock.unlock(); return }
        lastReport = now
        let p = progress, wasDirty = dirty
        dirty = false
        lock.unlock()
        DispatchQueue.main.async {
            self.onProgress?(p)
            if wasDirty || force { self.onChange?() }
        }
    }
}
