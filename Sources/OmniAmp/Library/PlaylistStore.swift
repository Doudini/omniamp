import Foundation

protocol PlaylistStoreDelegate: AnyObject {
    /// Whole list changed (add/remove/clear).
    func playlistDidReload()
    /// Tags arrived for these track indices.
    func playlistDidUpdate(indices: IndexSet)
}

/// Owns the track list. All public API is main-thread only.
final class PlaylistStore {
    weak var delegate: PlaylistStoreDelegate?

    private(set) var tracks: [Track] = []
    private var ids: [Int] = []                 // parallel to tracks
    private var nextID = 1
    private var indexByID: [Int: Int]?          // lazily rebuilt after removals

    private let pendingLock = NSLock()
    private var pending: [(id: Int, info: TagInfo)] = []
    private var flushTimer: Timer?
    private var activeLoads = 0
    private var loadStart = Date()

    var onTagLoadingFinished: (() -> Void)?

    var totalDuration: Double { tracks.reduce(0) { $0 + ($1.duration ?? 0) } }
    var isLoadingTags: Bool { activeLoads > 0 }

    // MARK: Mutation

    /// Replace the whole list (used when restoring from cache).
    func restore(_ restored: [Track]) {
        tracks = restored
        ids = restored.map { _ in allocID() }
        indexByID = nil
        delegate?.playlistDidReload()
        loadMissingTags()
    }

    /// Stage 1 on a background thread, then insert (append if `at` is nil) and start stage 2.
    /// Completion gets the insertion index and the number of tracks added.
    func add(urls: [URL], at position: Int? = nil, completion: ((Int, Int) -> Void)? = nil) {
        let t0 = Date()
        let cached = Dictionary(tracks.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        DispatchQueue.global(qos: .userInitiated).async {
            var found = FolderScanner.scan(urls)
            // Reuse metadata we already know for identical files.
            for i in found.indices {
                if let c = cached[found[i].path], c.size == found[i].size, c.mtime == found[i].mtime, c.tagsLoaded {
                    found[i] = c
                }
            }
            let scanTime = Date().timeIntervalSince(t0)
            DispatchQueue.main.async {
                let at = min(max(0, position ?? self.tracks.count), self.tracks.count)
                self.tracks.insert(contentsOf: found, at: at)
                self.ids.insert(contentsOf: found.map { _ in self.allocID() }, at: at)
                self.indexByID = nil
                NSLog("OmniAmp: scanned %d files in %.3fs", found.count, scanTime)
                self.delegate?.playlistDidReload()
                completion?(at, found.count)
                self.loadMissingTags()
            }
        }
    }

    func remove(at indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        // One pass, so removing thousands of rows stays fast.
        var keptTracks: [Track] = [], keptIDs: [Int] = []
        keptTracks.reserveCapacity(tracks.count); keptIDs.reserveCapacity(ids.count)
        for i in tracks.indices where !indexes.contains(i) {
            keptTracks.append(tracks[i])
            keptIDs.append(ids[i])
        }
        tracks = keptTracks
        ids = keptIDs
        indexByID = nil
        delegate?.playlistDidReload()
    }

    /// Move the tracks at `indexes` so they start at `destination` (an index in the list *before* the move).
    /// Returns the new indexes of the moved tracks.
    @discardableResult
    func move(_ indexes: IndexSet, to destination: Int) -> IndexSet {
        let valid = indexes.filteredIndexSet { $0 < tracks.count }
        guard !valid.isEmpty else { return [] }
        let movedTracks = valid.map { tracks[$0] }, movedIDs = valid.map { ids[$0] }
        let dest = destination - valid.count(in: 0..<min(destination, tracks.count))
        var t = tracks, d = ids
        for i in valid.reversed() { t.remove(at: i); d.remove(at: i) }
        let at = max(0, min(dest, t.count))
        t.insert(contentsOf: movedTracks, at: at)
        d.insert(contentsOf: movedIDs, at: at)
        tracks = t
        ids = d
        indexByID = nil
        delegate?.playlistDidReload()
        return IndexSet(integersIn: at..<(at + valid.count))
    }

    /// Reorder the whole list by a permutation of the current indexes.
    func reorder(_ order: [Int]) {
        guard order.count == tracks.count else { return }
        tracks = order.map { tracks[$0] }
        ids = order.map { ids[$0] }
        indexByID = nil
        delegate?.playlistDidReload()
    }

    /// Stable identity of the track at `i` (survives moves and removals).
    func id(at i: Int) -> Int { ids[i] }

    func index(ofID id: Int) -> Int? {
        if indexByID == nil { rebuildIndex() }
        return indexByID?[id]
    }

    private func rebuildIndex() {
        var m: [Int: Int] = [:]
        m.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() { m[id] = i }
        indexByID = m
    }

    func clear() {
        tracks.removeAll()
        ids.removeAll()
        indexByID = nil
        delegate?.playlistDidReload()
    }

    private func allocID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    // MARK: Stage 2: parallel tag reading

    private func loadMissingTags() {
        var work: [(id: Int, path: String, size: Int64)] = []
        for (i, t) in tracks.enumerated() where !t.tagsLoaded {
            work.append((ids[i], t.path, t.size))
        }
        guard !work.isEmpty else { return }
        activeLoads += 1
        if activeLoads == 1 { loadStart = Date() }
        startFlushTimer()

        DispatchQueue.global(qos: .utility).async {
            let chunk = 64
            let chunks = (work.count + chunk - 1) / chunk
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                var local: [(Int, TagInfo)] = []
                local.reserveCapacity(chunk)
                for w in work[(c * chunk)..<min((c + 1) * chunk, work.count)] {
                    local.append((w.id, TagReader.read(path: w.path, fileSize: w.size)))
                }
                self.pendingLock.lock()
                self.pending.append(contentsOf: local.map { (id: $0.0, info: $0.1) })
                self.pendingLock.unlock()
            }
            DispatchQueue.main.async {
                self.activeLoads -= 1
                self.flush()
                if self.activeLoads == 0 {
                    self.flushTimer?.invalidate()
                    self.flushTimer = nil
                    NSLog("OmniAmp: tags for %d files in %.3fs", work.count, Date().timeIntervalSince(self.loadStart))
                    self.onTagLoadingFinished?()
                }
            }
        }
    }

    private func startFlushTimer() {
        guard flushTimer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.flush() }
        RunLoop.main.add(t, forMode: .common)
        flushTimer = t
    }

    // MARK: Stage 3: batched UI updates

    private func flush() {
        pendingLock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        pendingLock.unlock()
        guard !batch.isEmpty else { return }

        if indexByID == nil { rebuildIndex() }
        var changed = IndexSet()
        for (id, info) in batch {
            guard let i = indexByID?[id] else { continue } // removed meanwhile
            tracks[i].title = info.title
            tracks[i].artist = info.artist
            tracks[i].album = info.album
            tracks[i].duration = info.duration
            tracks[i].bitrate = info.bitrate
            tracks[i].sampleRate = info.sampleRate
            tracks[i].bitDepth = info.bitDepth
            tracks[i].tagsLoaded = true
            changed.insert(i)
        }
        delegate?.playlistDidUpdate(indices: changed)
    }
}
