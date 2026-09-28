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
    /// Tracks whose tags are being read right now (so bursts of inserts don't read them twice).
    private var inFlight = Set<Int>()
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

    /// Folders being added right now (for the "Adding…" status).
    private(set) var scansInProgress = 0
    /// Files found so far by the scans in progress.
    private(set) var scannedSoFar = 0
    private var loadAllStart: Date?
    /// Scanning started or finished, or found more files.
    var onScanProgress: (() -> Void)?

    /// Stage 1 on a background thread, handed over as it goes: rows are inserted (appended if `at` is nil)
    /// a batch at a time, at most every 150 ms, and each batch starts stage 2 right away.
    /// `onBatch` gets each batch's insertion index and size; `done` the total.
    func add(urls: [URL], at position: Int? = nil, onBatch: ((Int, Int) -> Void)? = nil, done: ((Int) -> Void)? = nil) {
        let t0 = Date()
        let cached = Dictionary(tracks.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        scansInProgress += 1
        if loadAllStart == nil { loadAllStart = t0 }
        onScanProgress?()
        var next = position   // where the next batch goes when inserting in the middle
        var total = 0
        var first = true

        func deliver(_ found: [Track]) {
            DispatchQueue.main.async {
                let at = min(max(0, next ?? self.tracks.count), self.tracks.count)
                self.tracks.insert(contentsOf: found, at: at)
                self.ids.insert(contentsOf: found.map { _ in self.allocID() }, at: at)
                self.indexByID = nil
                if next != nil { next = at + found.count }
                total += found.count
                self.scannedSoFar += found.count
                if first { NSLog("OmniAmp: first rows after %.3fs", Date().timeIntervalSince(t0)); first = false }
                self.delegate?.playlistDidReload()
                onBatch?(at, found.count)
                self.onScanProgress?()
                self.loadMissingTags()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var buffer: [Track] = []
            var lastSend = Date.distantPast
            FolderScanner.scan(urls) { batch in
                // Reuse metadata we already know for identical files.
                buffer += batch.map { t in
                    if let c = cached[t.key], c.size == t.size, c.mtime == t.mtime, c.tagsLoaded { return c }
                    return t
                }
                // First rows at once, then at most every 150 ms (keeps the table from reloading per folder).
                if Date().timeIntervalSince(lastSend) >= 0.15 {
                    deliver(buffer)
                    buffer.removeAll()
                    lastSend = Date()
                }
            }
            if !buffer.isEmpty { deliver(buffer) }
            let scanTime = Date().timeIntervalSince(t0)
            DispatchQueue.main.async {
                NSLog("OmniAmp: scanned %d files in %.3fs", total, scanTime)
                self.scansInProgress -= 1
                if self.scansInProgress == 0 { self.scannedSoFar = 0 }
                self.onScanProgress?()
                done?(total)
                self.logIfAllLoaded()
            }
        }
    }

    /// When every scan and tag read has finished: one line for measuring whole loads.
    private func logIfAllLoaded() {
        guard scansInProgress == 0, activeLoads == 0, let s = loadAllStart else { return }
        NSLog("OmniAmp: all loaded (rows and tags) after %.3fs", Date().timeIntervalSince(s))
        loadAllStart = nil
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

    /// Insert already-scanned tracks (from the folder watcher) and read their tags.
    func insert(_ new: [Track], at position: Int) {
        guard !new.isEmpty else { return }
        let at = min(max(0, position), tracks.count)
        tracks.insert(contentsOf: new, at: at)
        ids.insert(contentsOf: new.map { _ in allocID() }, at: at)
        indexByID = nil
        delegate?.playlistDidReload()
        loadMissingTags()
    }

    /// Several insertions at once (positions in the current list): one pass, one reload. A new watched folder
    /// of thousands of albums used to insert, reload and rescan once per album folder.
    func insert(groups: [(at: Int, tracks: [Track])]) {
        let groups = groups.filter { !$0.tracks.isEmpty }
            .map { (at: min(max(0, $0.at), tracks.count), tracks: $0.tracks) }
            .enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        guard !groups.isEmpty else { return }
        let added = groups.reduce(0) { $0 + $1.tracks.count }
        var newTracks: [Track] = [], newIDs: [Int] = []
        newTracks.reserveCapacity(tracks.count + added)
        newIDs.reserveCapacity(tracks.count + added)
        var from = 0
        for g in groups {
            newTracks += tracks[from..<g.at]; newIDs += ids[from..<g.at]
            newTracks += g.tracks; newIDs += g.tracks.map { _ in allocID() }
            from = g.at
        }
        newTracks += tracks[from...]; newIDs += ids[from...]
        tracks = newTracks
        ids = newIDs
        indexByID = nil
        delegate?.playlistDidReload()
        loadMissingTags()
    }

    /// A podcast episode already in the list got newer details from its feed (its own cover, notes…).
    func updateEpisode(at i: Int, from new: Track) {
        guard i < tracks.count, tracks[i].isEpisode else { return }
        var t = tracks[i]
        t.logo = new.logo ?? t.logo
        t.title = new.title ?? t.title
        t.summary = new.summary ?? t.summary
        t.published = new.published ?? t.published
        t.duration = t.duration ?? new.duration
        guard t.logo != tracks[i].logo || t.title != tracks[i].title || t.summary != tracks[i].summary
                || t.published != tracks[i].published || t.duration != tracks[i].duration else { return }
        tracks[i] = t
        delegate?.playlistDidUpdate(indices: [i])
    }

    /// Episodes whose audio address changed in their feed: the playlist entries follow (their identity is the address).
    func moveEpisodes(_ moved: [String: String]) {
        var changed: [Int] = []
        for i in tracks.indices where tracks[i].isEpisode {
            if let now = moved[tracks[i].path] { tracks[i].path = now; changed.append(i) }
        }
        guard !changed.isEmpty else { return }
        indexByID = nil
        delegate?.playlistDidUpdate(indices: IndexSet(changed))
    }

    /// Files changed on disk: take the new size/mtime and read their tags again.
    func refresh(_ updates: [(index: Int, size: Int64, mtime: Double)]) {
        guard !updates.isEmpty else { return }
        for u in updates where u.index < tracks.count {
            tracks[u.index].size = u.size
            tracks[u.index].mtime = u.mtime
            tracks[u.index].tagsLoaded = false
            inFlight.remove(ids[u.index])   // a read already under way may have seen the old file
        }
        loadMissingTags()
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
        for (i, t) in tracks.enumerated() where !t.tagsLoaded && !inFlight.contains(ids[i]) {
            if t.isRemote { tracks[i].tagsLoaded = true; continue }   // nothing to read; keep its title
            work.append((ids[i], t.path, t.size))
            inFlight.insert(ids[i])
        }
        guard !work.isEmpty else { return }
        activeLoads += 1
        if activeLoads == 1 { loadStart = Date() }
        startFlushTimer()

        DispatchQueue.global(qos: .utility).async {   // the volume check can stall on a slow share
            // Network shares: reads mostly wait on the server, so keep many in flight; local disks: one per core.
            // Shared queues bound the total width however many loads overlap, and nothing blocks a thread waiting.
            let remote = Self.isNetworkVolume(work[0].path)
            let chunk = remote ? 8 : 64
            let queue = remote ? Self.remoteTagQueue : Self.localTagQueue
            let group = DispatchGroup()
            for start in stride(from: 0, to: work.count, by: chunk) {
                let slice = work[start..<min(start + chunk, work.count)]
                group.enter()
                queue.addOperation {
                    var local: [(id: Int, info: TagInfo)] = []
                    local.reserveCapacity(slice.count)
                    let buffer = TagReadBuffer()
                    for w in slice { local.append((w.id, TagReader.read(path: w.path, fileSize: w.size, buffer: buffer))) }
                    self.pendingLock.lock()
                    self.pending.append(contentsOf: local)
                    self.pendingLock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                self.activeLoads -= 1
                self.flush()
                if self.activeLoads == 0 {
                    self.flushTimer?.invalidate()
                    self.flushTimer = nil
                    NSLog("OmniAmp: tags for %d files in %.3fs", work.count, Date().timeIntervalSince(self.loadStart))
                    self.onTagLoadingFinished?()
                    self.logIfAllLoaded()
                    MemoryTrim.soon()
                }
            }
        }
    }

    private static func tagQueue(_ name: String, width: Int) -> OperationQueue {
        let q = OperationQueue()
        q.name = name
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = width
        return q
    }
    private static let localTagQueue = tagQueue("omniamp.tags.local", width: ProcessInfo.processInfo.activeProcessorCount)
    private static let remoteTagQueue = tagQueue("omniamp.tags.remote", width: 24)

    static func isNetworkVolume(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
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
        pending.removeAll(keepingCapacity: activeLoads > 0)   // don't hold a big buffer once loading is done
        pendingLock.unlock()
        guard !batch.isEmpty else { return }

        if indexByID == nil { rebuildIndex() }
        var changed = IndexSet()
        for (id, info) in batch {
            inFlight.remove(id)
            guard let i = indexByID?[id] else { continue } // removed meanwhile
            if let start = tracks[i].cueStart {
                // CUE track: the sheet's title/artist win; the file only fills gaps and gives the format.
                tracks[i].title = tracks[i].title ?? info.title
                tracks[i].artist = tracks[i].artist ?? info.artist
                tracks[i].album = tracks[i].album ?? info.album
                let end = tracks[i].cueEnd ?? info.duration
                tracks[i].duration = Sane.duration(end.map { $0 - start })
                // The bitrate belongs to the whole file, not to this slice of it.
                if Sane.duration(info.duration) != nil {
                    tracks[i].bitrate = info.bitrate ?? Sane.kbps(bytes: tracks[i].size, seconds: info.duration)
                }
            } else {
                tracks[i].title = info.title
                tracks[i].artist = info.artist
                tracks[i].album = info.album
                tracks[i].duration = info.duration
            }
            if tracks[i].cueStart == nil { tracks[i].bitrate = info.bitrate }
            tracks[i].sampleRate = info.sampleRate
            tracks[i].bitDepth = info.bitDepth
            tracks[i].rgTrackGain = info.rgTrackGain
            tracks[i].rgAlbumGain = info.rgAlbumGain
            tracks[i].rgTrackPeak = info.rgTrackPeak
            tracks[i].rgAlbumPeak = info.rgAlbumPeak
            tracks[i].tagsLoaded = true
            changed.insert(i)
        }
        delegate?.playlistDidUpdate(indices: IndexSet(changed))
    }
}
