import AppKit
import MediaPlayer

/// What a look (modern or classic skin) must implement to follow the player.
protocol PlayerUI: AnyObject {
    func playlistDidReload()
    func playlistRowsDidUpdate(_ trackIndices: IndexSet)
    func currentTrackDidChange(old: Int?, new: Int?)
    func optionsDidChange()
    /// Volume or EQ changed (many times a second while dragging): refresh only what shows them.
    func mixDidChange()
    /// Playing / paused / stopped changed.
    func playbackStateDidChange()
    /// Track index under the UI's selection, used by Play when nothing is loaded.
    var selectedTrackIndex: Int? { get }
    /// All selected tracks (for queue/remove actions from menus and keys).
    var selectedTrackIndices: IndexSet { get }
    func focusFilter()
}

/// Playback + playlist logic shared by every look. Main-thread only.
final class PlayerController {
    let store = PlaylistStore()
    let player = AudioPlayer()
    weak var ui: PlayerUI?

    private(set) var currentIndex: Int?
    private(set) var shuffle = false
    private(set) var repeatAll = true
    /// Previously played tracks (stable track IDs), for Previous in shuffle mode.
    private var history: [Int] = []
    /// Tracks the user queued with Q (stable track IDs), played before the normal order.
    private(set) var playQueue: [Int] = []
    private var saveWorkItem: DispatchWorkItem?
    private(set) var eqSettings = Equalizer.load()
    /// Watched folders feeding the playlist.
    private(set) lazy var folders = FolderSync(controller: self)

    // Gapless: the track preloaded behind the current one, and whether we already tried for this track.
    private var preloaded: (index: Int, path: String)?   // path = Track.key
    /// A preload taken back after it may already have started: if it did, it's what plays now.
    private var droppedPreload: (index: Int, path: String)?
    private var preloadAttempted = false
    /// One-shot timer that fires ~8 s before the end of the track to preload the next one.
    private var preloadTimer: Timer?

    /// Indices into store.tracks currently shown (nil = no filter).
    private(set) var visible: [Int]?
    private(set) var filterQuery = ""

    init() {
        store.delegate = self
        store.onScanProgress = { [weak self] in self?.ui?.optionsDidChange() }
        store.onTagLoadingFinished = { [weak self] in
            self?.ui?.optionsDidChange()
            self?.scheduleSave()
        }
        player.onTrackFinished = { [weak self] in self?.trackFinished() }
        player.onGaplessAdvance = { [weak self] in self?.gaplessAdvanced() }
        player.onPreloadDropped = { [weak self] in
            self?.preloaded = nil
            self?.preloadAttempted = false
            self?.schedulePreloadCheck()
        }
        player.apply(eqSettings)
        player.onStreamChange = { [weak self] in
            guard let self, let c = self.currentIndex else { return }
            self.ui?.playlistRowsDidUpdate([c])
            self.updateNowPlaying()
        }
        player.onOutputChange = { [weak self] in self?.ui?.optionsDidChange() }
        NotificationCenter.default.addObserver(forName: PodcastLibrary.episodesMoved, object: nil, queue: .main) { [weak self] n in
            guard let moved = n.userInfo?["moved"] as? [String: String] else { return }
            MainActor.assumeIsolated { self?.episodesMoved(moved) }
        }
        restore()
        let d = UserDefaults.standard
        player.setOutputDevice(uid: d.string(forKey: "outputDeviceUID"))
        player.setBitPerfect(d.bool(forKey: "bitPerfect"), exclusive: d.bool(forKey: "exclusiveAccess"))
        folders.catchUp()   // pick up changes made while the app was closed
        setupRemoteCommands()
        Scrobbler.shared.flushAll()   // send anything queued while offline / closed
        player.onStateChange = { [weak self] in
            guard let self else { return }
            switch self.player.state {
            case .playing: Scrobbler.shared.playbackResumed()
            case .paused: Scrobbler.shared.playbackPaused()
            case .stopped: Scrobbler.shared.trackStarted(nil, duration: 0)
            }
            self.schedulePreloadCheck()
            self.updateNowPlaying()
            self.ui?.playbackStateDidChange()
        }
    }

    /// No polling: arm a single timer for the moment the next track should be preloaded.
    private func schedulePreloadCheck() {
        preloadTimer?.invalidate()
        preloadTimer = nil
        guard player.state == .playing, !preloadAttempted, player.duration > 0 else { return }
        let t = Timer(timeInterval: max(0.05, player.remaining - 7.5), repeats: false) { [weak self] _ in self?.maybePreloadNext() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        preloadTimer = t
    }

    var tracks: [Track] { store.tracks }
    var currentTrack: Track? { currentIndex.flatMap { $0 < store.tracks.count ? store.tracks[$0] : nil } }

    // MARK: Rows (filtered view)

    var rowCount: Int { visible?.count ?? store.tracks.count }
    func trackIndex(forRow row: Int) -> Int { visible?[row] ?? row }
    func row(forTrackIndex i: Int) -> Int? {
        guard let v = visible else { return i < store.tracks.count ? i : nil }
        return v.firstIndex(of: i)
    }

    /// What the filter searches, lowercased, per track: built once when filtering starts (not per keystroke),
    /// kept current as tags arrive, dropped when the filter is cleared.
    private var searchText: [String]?
    /// The last query and its rows: typing on (a longer query) only needs to look at those.
    private var lastFilter: (query: String, rows: [Int])?

    /// Lowercased and precomposed (file names often spell "é" as e + accent, tags and typing as one
    /// character), so a plain byte search finds it: String.contains is several times slower per row.
    private static func searchable(_ t: Track) -> String { fold("\(t.displayTitle) \(t.album ?? "") \(t.path)") }
    private static func fold(_ s: String) -> String { s.lowercased().precomposedStringWithCanonicalMapping }

    private static func contains(_ hay: String, _ needle: [UInt8]) -> Bool {
        var hay = hay
        return hay.withUTF8 { h in
            needle.withUnsafeBytes { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil }
        }
    }

    func setFilter(_ query: String) {
        filterQuery = query
        let q = Self.fold(query.trimmingCharacters(in: .whitespaces))
        if q.isEmpty {
            visible = nil
            searchText = nil
            lastFilter = nil
        } else {
            if searchText?.count != store.tracks.count { searchText = store.tracks.map(Self.searchable); lastFilter = nil }
            let hay = searchText!
            let words = q.split(separator: " ").map { Array($0.utf8) }
            // Every match of "abc" also matches "ab": narrow the previous result instead of the whole list.
            let pool = lastFilter.flatMap { q.hasPrefix($0.query) ? $0.rows : nil }
            let rows = (pool ?? Array(store.tracks.indices)).filter { i in words.allSatisfy { Self.contains(hay[i], $0) } }
            visible = rows
            lastFilter = (q, rows)
        }
        // Typing a filter near the end of a track mustn't break gapless when the next track stays the same.
        let keep = preloaded.map { p in shuffle && playQueue.isEmpty ? playOrder().contains(p.index) : nextTarget() == p.index } ?? false
        if !keep { invalidatePreload() }
        ui?.playlistDidReload()
        ui?.optionsDidChange()
    }

    // MARK: Persistence

    private func restore() {
        let t0 = Date()
        guard let cache = LibraryCache.load() else { player.softwareVolume = 0.8; return }
        NSLog("OmniAmp: restored %d tracks from cache in %.3fs", cache.tracks.count, Date().timeIntervalSince(t0))
        shuffle = cache.shuffle ?? false
        repeatAll = cache.repeatAll ?? true
        player.softwareVolume = cache.volume ?? 0.8
        store.restore(cache.tracks)
        if let i = cache.currentIndex, i < store.tracks.count { currentIndex = i }
    }

    /// Saves run one at a time, in order (an older snapshot can never land after a newer one).
    private static let saveQueue = DispatchQueue(label: "omniamp.library-save", qos: .utility)

    func saveNow() {
        saveWorkItem?.cancel()
        let p = payload()
        Self.saveQueue.sync { LibraryCache.save(p) }
    }

    /// Edits come in bursts (a drag, tags arriving, a folder sync): write once they settle. A save re-encodes
    /// the whole playlist (a fifth of a second and several MB at 50,000 tracks).
    func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let p = self.payload()   // a snapshot now (copy-on-write, no copying)
            Self.saveQueue.async { LibraryCache.save(p) }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func payload() -> LibraryCache.Payload {
        .init(tracks: store.tracks, currentIndex: currentIndex, volume: player.softwareVolume, shuffle: shuffle, repeatAll: repeatAll)
    }

    // MARK: Adding / removing

    /// Add files/folders/playlists; `at` inserts at a track index (nil = append).
    func add(_ urls: [URL], at position: Int? = nil) {
        let t0 = Date()
        if position != nil { invalidatePreload() }
        store.add(urls: urls, at: position, onBatch: { [weak self] start, n in
            guard let self else { return }
            // Each batch is n rows inserted at `start`: shift whatever is current *now* (it may have
            // changed since the scan began, e.g. autoplay from the first batch).
            if let c = self.currentIndex, c >= start {
                self.currentIndex = c + n
                self.ui?.currentTrackDidChange(old: nil, new: self.currentIndex)
            }
            // Start playing the first track as soon as it shows up, if nothing is loaded yet.
            let autoplay = ProcessInfo.processInfo.environment["OMNIAMP_NO_AUTOPLAY"] == nil
            if autoplay, n > 0, self.player.state == .stopped, self.currentIndex == nil {
                self.play(index: start)
            }
        }, done: { [weak self] n in
            NSLog("OmniAmp: %d rows visible after %.3fs", n, Date().timeIntervalSince(t0))
            self?.scheduleSave()
        })
    }

    enum OpenKind { case filesOrFolders, files, folder }

    func showOpenPanel(for window: NSWindow?, kind: OpenKind = .filesOrFolders) {
        let p = NSOpenPanel()
        p.canChooseDirectories = kind != .files
        p.canChooseFiles = kind != .folder
        p.prompt = kind == .folder ? "Add Folder" : "Add"
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.audio, .folder, .m3uPlaylist, .init(filenameExtension: "pls") ?? .m3uPlaylist,
                                 .init(filenameExtension: "m3u8") ?? .m3uPlaylist, .init(filenameExtension: "flac") ?? .audio]
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            if r == .OK { self?.add(p.urls) }
        }
        if let w = window { p.beginSheetModal(for: w, completionHandler: done) } else { done(p.runModal()) }
    }

    func clear() {
        invalidatePreload()
        player.stop()
        let old = currentIndex
        currentIndex = nil
        history.removeAll()
        playQueue.removeAll()
        filterQuery = ""
        visible = nil
        store.clear()
        ui?.currentTrackDidChange(old: old, new: nil)
        updateNowPlaying()
        scheduleSave()
    }

    func remove(trackIndices idx: IndexSet) {
        guard !idx.isEmpty else { return }
        invalidatePreload()
        let currentID = currentIndex.flatMap { idx.contains($0) ? nil : store.id(at: $0) }
        store.remove(at: idx)
        remapCurrent(currentID)
        scheduleSave()
    }

    /// Add a radio station to the end of the playlist (or find it if it's already there); returns its index.
    @discardableResult
    func addStation(url: String, name: String, logo: String? = nil, tags: String? = nil) -> Int {
        if let i = store.tracks.firstIndex(where: { $0.path == url }) { return i }
        var t = Track.stream(url, name: name, logo: logo)
        t.stationTags = tags
        insertScanned([t], at: store.tracks.count)
        return store.tracks.count - 1
    }

        /// Add a podcast episode (or find it if it's already in the playlist). Returns its index.
    @discardableResult
    func addEpisode(_ episode: Track) -> Int {
        if let i = store.tracks.firstIndex(where: { $0.path == episode.path }) {
            store.updateEpisode(at: i, from: episode)   // e.g. added before episodes had their own covers
            scheduleSave()
            return i
        }
        insertScanned([episode], at: store.tracks.count)
        return store.tracks.count - 1
    }

    /// Insert tracks that were already scanned (watched folders), keeping the current track.
    func insertScanned(_ tracks: [Track], at position: Int) { insertScanned([(position, tracks)]) }

    /// Many groups at once (a folder sync): one insert, one reload, one save.
    func insertScanned(_ groups: [(at: Int, tracks: [Track])]) {
        guard groups.contains(where: { !$0.tracks.isEmpty }) else { return }
        invalidatePreload()
        let currentID = currentIndex.map { store.id(at: $0) }
        store.insert(groups: groups)
        remapCurrent(currentID)
        scheduleSave()
    }

    /// After the list changed, find the current track again by its stable ID.
    private func remapCurrent(_ id: Int?) {
        let old = currentIndex
        currentIndex = id.flatMap { store.index(ofID: $0) }
        if old != currentIndex { ui?.currentTrackDidChange(old: nil, new: currentIndex) }
    }

    // MARK: Reordering

    /// Move tracks so they start at `destination` (a track index before the move). Returns their new indexes.
    @discardableResult
    func move(trackIndices idx: IndexSet, to destination: Int) -> IndexSet {
        guard visible == nil else { return idx } // no reordering while filtered
        invalidatePreload()
        let currentID = currentIndex.map { store.id(at: $0) }
        let moved = store.move(idx, to: destination)
        remapCurrent(currentID)
        scheduleSave()
        return moved
    }

    /// Move a block of tracks up/down by `delta` rows (⌥↑/⌥↓, and dragging in the classic playlist).
    @discardableResult
    func shift(trackIndices idx: IndexSet, by delta: Int) -> IndexSet {
        guard let first = idx.first, let last = idx.last, delta != 0 else { return idx }
        let d = delta < 0 ? max(delta, -first) : min(delta, store.tracks.count - 1 - last)
        guard d != 0 else { return idx }
        return move(trackIndices: idx, to: d < 0 ? first + d : last + 1 + d)
    }

    enum SortKey: String, CaseIterable {
        case title = "Title", artist = "Artist", album = "Album", fileName = "File Name", path = "Path and File Name", duration = "Duration"
    }

    func sort(by key: SortKey) {
        let t = store.tracks
        let order: [Int]
        if key == .duration {
            order = t.indices.sorted { (t[$0].duration ?? .infinity, $0) < (t[$1].duration ?? .infinity, $1) }
        } else {
            // Tracks missing the field sort last.
            let keys: [String] = t.map { tr in
                switch key {
                case .title: return tr.title ?? tr.fileStem
                case .artist: return "\(tr.artist ?? "\u{10FFFF}") \(tr.album ?? "") \(tr.path)"
                case .album: return "\(tr.album ?? "\u{10FFFF}") \(tr.path)"
                case .fileName: return (tr.path as NSString).lastPathComponent
                default: return tr.path
                }
            }
            order = t.indices.sorted {
                let r = keys[$0].localizedStandardCompare(keys[$1])
                return r == .orderedSame ? $0 < $1 : r == .orderedAscending
            }
        }
        apply(order: order)
    }

    func reverse() { apply(order: Array(store.tracks.indices.reversed())) }
    func randomize() { apply(order: Array(store.tracks.indices).shuffled()) }

    private func apply(order: [Int]) {
        invalidatePreload()
        let currentID = currentIndex.map { store.id(at: $0) }
        store.reorder(order)
        remapCurrent(currentID)
        scheduleSave()
    }

    /// Remove tracks whose files no longer exist. Calls back with the number removed.
    func removeDeadFiles(completion: ((Int) -> Void)? = nil) {
        let paths = store.tracks.map(\.path)
        let streams = store.tracks.map(\.isRemote)
        let ids = store.tracks.indices.map { store.id(at: $0) }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let dead = paths.indices.filter { !streams[$0] && !fm.fileExists(atPath: paths[$0]) }.map { ids[$0] }
            DispatchQueue.main.async {
                let idx = IndexSet(dead.compactMap { self.store.index(ofID: $0) })
                if !idx.isEmpty { self.remove(trackIndices: idx) }
                completion?(idx.count)
            }
        }
    }

    // MARK: Play queue

    /// 1-based position in the play queue, or nil.
    func queuePosition(of trackIndex: Int) -> Int? {
        guard !playQueue.isEmpty, trackIndex < store.tracks.count else { return nil }
        return playQueue.firstIndex(of: store.id(at: trackIndex)).map { $0 + 1 }
    }

    /// Q: queue the tracks, or unqueue them if they are all queued already.
    func toggleQueue(trackIndices idx: IndexSet) {
        let ids = idx.filter { $0 < store.tracks.count }.map { store.id(at: $0) }
        guard !ids.isEmpty else { return }
        if ids.allSatisfy(playQueue.contains) {
            playQueue.removeAll { ids.contains($0) }
        } else {
            playQueue += ids.filter { !playQueue.contains($0) }
        }
        invalidatePreload()
        ui?.playlistDidReload()
    }

    func clearQueue() {
        playQueue.removeAll()
        invalidatePreload()
        ui?.playlistDidReload()
    }

    /// A track started: take it out of the play queue.
    private func dequeue(_ index: Int) {
        guard !playQueue.isEmpty, index < store.tracks.count,
              let i = playQueue.firstIndex(of: store.id(at: index)) else { return }
        playQueue.remove(at: i)
        ui?.playlistDidReload()
    }

    private func pushHistory(_ index: Int) {
        guard index < store.tracks.count else { return }
        history.append(store.id(at: index))
        if history.count > 500 { history.removeFirst() }
    }

    // MARK: Playback

    func play(index: Int, recordHistory: Bool = true) {
        guard index >= 0, index < store.tracks.count else { return }
        let old = currentIndex
        rememberPosition()
        if recordHistory, let o = old, o != index { pushHistory(o) }
        currentIndex = index
        dequeue(index)
        preloaded = nil
        droppedPreload = nil
        preloadAttempted = false
        applyReplayGain()
        if !store.tracks[index].isEpisode { player.rate = 1 }
        if store.tracks[index].isStream {
            player.playStream(url: store.tracks[index].url)
            Scrobbler.shared.trackStarted(nil, duration: 0)   // radio isn't scrobbled
            ui?.currentTrackDidChange(old: old, new: index)
            updateNowPlaying()
            return
        }
        if store.tracks[index].isEpisode {
            // Pick up what the podcast library knows now (the episode's own cover for older entries).
            if let e = PodcastLibrary.shared.knownEpisode(store.tracks[index].path), let show = store.tracks[index].podcast {
                store.updateEpisode(at: index, from: .episode(e.url, title: e.title, show: show, artwork: e.image, duration: e.duration,
                                                              published: e.published, summary: e.summary))
                scheduleSave()
            }
            let t = store.tracks[index]
            player.rate = speed(for: t)
            // Downloaded: play from disk (offline too). The track keeps its web address as its identity.
            player.playEpisode(url: PodcastDownloads.shared.localFile(t.path) ?? t.url, from: resumePosition(for: t), duration: t.duration)
            PodcastLibrary.shared.noteListened(t.path, track: t)
            Scrobbler.shared.trackStarted(nil, duration: 0)   // podcasts aren't scrobbled
            ui?.currentTrackDidChange(old: old, new: index)
            updateNowPlaying()
            return
        }
        let ok = player.play(url: store.tracks[index].url, from: resumePosition(for: store.tracks[index]), range: store.tracks[index].cueRange)
        if ok {
            Scrobbler.shared.trackStarted(store.tracks[index], duration: store.tracks[index].duration ?? player.duration)
            failedInARow = 0
            if playbackProblem != nil { playbackProblem = nil; ui?.optionsDidChange() }
        } else {
            failedInARow += 1
        }
        schedulePreloadCheck()
        ui?.currentTrackDidChange(old: old, new: index)
        updateNowPlaying()
        if !ok {
            // Skip unplayable files, but not forever: when every track has failed in a row (a drive that's gone,
            // with repeat on), stop and say so instead of trying five files a second.
            if failedInARow >= min(max(1, store.tracks.count), 50) {
                failedInARow = 0
                player.stop()
                playbackProblem = "Stopped: the files couldn't be opened (is the drive connected?)"
                NSLog("OmniAmp: %d files in a row couldn't be opened, stopping", store.tracks.count)
                ui?.optionsDidChange()
                updateNowPlaying()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.currentIndex == index else { return }
                self.advance()
            }
        }
    }

    func togglePlayPause() {
        switch player.state {
        case .playing: player.pause(); rememberPosition()
        case .paused: player.resume()
        case .stopped: playOrResume()
        }
        updateNowPlaying()
    }

    /// Winamp "Play": resume if paused, restart if playing, else play selection/current.
    func playOrResume() {
        switch player.state {
        case .paused:
            player.resume()
            updateNowPlaying()
        case .playing:
            if let c = currentIndex { play(index: c, recordHistory: false) }
        case .stopped:
            if let s = ui?.selectedTrackIndex, s != currentIndex {
                play(index: s)
            } else if let c = currentIndex {
                play(index: c, recordHistory: false)
            } else if rowCount > 0 {
                play(index: trackIndex(forRow: 0))
            }
        }
    }

    func pause() {
        if player.state == .playing { player.pause(); rememberPosition() } else if player.state == .paused { player.resume() }
        updateNowPlaying()
    }

    func stop() {
        rememberPosition()
        player.stop()
        updateNowPlaying()
    }

    func next() { advance() }

    func previous() {
        guard !store.tracks.isEmpty else { return }
        // Past 3 s, Previous restarts the track, but not a live station (that would just reconnect it).
        if player.currentTime > 3, let c = currentIndex, !store.tracks[c].isStream { play(index: c, recordHistory: false); return }
        while shuffle, let h = history.popLast() {
            if let i = store.index(ofID: h) { play(index: i, recordHistory: false); return }
        }
        guard let c = currentIndex else { play(index: 0); return }
        let order = playOrder()
        if let pos = order.firstIndex(of: c) {
            let prev = pos > 0 ? order[pos - 1] : (repeatAll ? order[order.count - 1] : order[0])
            play(index: prev, recordHistory: false)
        } else {
            play(index: max(0, c - 1), recordHistory: false)
        }
    }

    /// Order to walk: the filtered view if a filter is active, otherwise everything.
    private func playOrder() -> [Int] { visible ?? Array(store.tracks.indices) }

    /// The track that should follow the current one (nil = stop). Shuffle picks randomly.
    private func nextTarget() -> Int? {
        // The play queue wins over shuffle/order; drop queued tracks that were removed.
        while let id = playQueue.first {
            if let i = store.index(ofID: id) { return i }
            playQueue.removeFirst()
        }
        let order = playOrder()
        guard !order.isEmpty else { return nil }
        if shuffle, order.count > 1 {
            var r: Int
            repeat { r = order.randomElement()! } while r == currentIndex
            return r
        } else if let c = currentIndex, let pos = order.firstIndex(of: c) {
            return pos + 1 < order.count ? order[pos + 1] : (repeatAll ? order[0] : nil)
        } else if let c = currentIndex {
            return order.first(where: { $0 > c }) ?? (repeatAll ? order[0] : nil)
        }
        return order[0]
    }

    private func advance() {
        if let t = nextTarget() { play(index: t) } else { player.stop(); updateNowPlaying() }
    }

    // MARK: Gapless

    /// Near the end of a track, schedule the next one behind it on the audio engine.
    private func maybePreloadNext() {
        guard player.state == .playing, !preloadAttempted, !player.hasQueuedNext, !stopAfterCurrent, !player.isPlayingEpisode,
              player.duration > 0, player.remaining < 8 else { return }
        preloadAttempted = true
        guard let t = nextTarget(), t != currentIndex, !store.tracks[t].isRemote else { return }
        let track = store.tracks[t]
        // Its own level from its first sample (tags are usually loaded by now; if not, it plays at 1.0 until they are).
        if player.queueNext(url: track.url, range: track.cueRange, gain: replayGainFactor(for: track), tag: track.key) {
            preloaded = (t, track.key)
        }
    }

    private func gaplessAdvanced() {
        let old = currentIndex
        let key = player.currentTag
        func find(_ q: (index: Int, path: String)) -> Int? {
            q.index < store.tracks.count && store.tracks[q.index].key == q.path ? q.index : store.tracks.firstIndex { $0.key == q.path }
        }
        var new: Int?
        if let q = droppedPreload, q.path == key, preloaded?.path != key {
            // The one taken back had started already; what was queued since stays queued behind it.
            new = find(q)
            droppedPreload = nil
        } else {
            if let q = preloaded { new = find(q) } else if let k = key { new = store.tracks.firstIndex { $0.key == k } }
            preloaded = nil
            droppedPreload = nil
            preloadAttempted = false
        }
        if let o = old, o != new { pushHistory(o) }
        currentIndex = new
        if let n = new { dequeue(n) }
        if let o = old { forgetPosition(store.tracks.indices.contains(o) ? store.tracks[o].key : nil) }
        applyReplayGain()
        Scrobbler.shared.trackStarted(currentTrack, duration: currentTrack?.duration ?? player.duration)
        schedulePreloadCheck()
        NSLog("OmniAmp: gapless advance to #%d", (new ?? -2) + 1)
        ui?.currentTrackDidChange(old: old, new: new)
        updateNowPlaying()
    }

    /// The preloaded track may no longer be the right one (order/filter/shuffle changed).
    private func invalidatePreload() {
        if player.hasQueuedNext { droppedPreload = preloaded; player.cancelQueuedNext() }
        preloaded = nil
        preloadAttempted = false
        schedulePreloadCheck()
    }

    // MARK: Equalizer

    /// The EQ is on and actually in the signal path (bit-perfect mode bypasses it).
    var eqActive: Bool { eqSettings.enabled && !player.bitPerfect }

    func setEQ(_ s: Equalizer.Settings) {
        eqSettings = s
        player.apply(s)
        Equalizer.save(s)
        ui?.mixDidChange()
    }

    func applyPreset(_ p: Equalizer.Preset) {
        var s = eqSettings
        s.preamp = p.preamp
        s.bands = p.bands
        s.enabled = true
        setEQ(s)
    }

    // MARK: Playlist files

    /// Replace the playlist with the contents of a .m3u/.pls file.
    func loadPlaylist(_ url: URL) {
        clear()
        add([url])
    }

    func savePlaylist(to url: URL) throws {
        try PlaylistFile.writeM3U(store.tracks, to: url)
    }

    func seek(to seconds: Double) {
        guard player.state != .stopped else { return }
        player.seek(to: seconds)
        schedulePreloadCheck()
        updateNowPlaying()
    }

    func seek(fraction: Double) { seek(to: fraction * player.duration) }
    func seek(by delta: Double) { seek(to: player.currentTime + delta) }

    func setVolume(_ v: Float) {
        player.volume = v
        ui?.mixDidChange()
    }

    func changeVolume(by delta: Float) { setVolume(player.volume + delta) }

    // MARK: Output

    /// nil = system default.
    func setOutputDevice(uid: String?) {
        UserDefaults.standard.set(uid, forKey: "outputDeviceUID")
        player.setOutputDevice(uid: uid)
        ui?.optionsDidChange()
    }

    func setBitPerfect(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "bitPerfect")
        invalidatePreload()
        player.setBitPerfect(on, exclusive: player.exclusive)
        ui?.optionsDidChange()
    }

    func setExclusive(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "exclusiveAccess")
        player.setBitPerfect(player.bitPerfect, exclusive: on)
        ui?.optionsDidChange()
    }

    /// Short output status for the UI, e.g. "BIT-PERFECT 96 kHz", or what changes the samples on the way:
    /// "RESAMPLED 96→48 kHz", "MONO → STEREO", "24→16-BIT".
    var outputBadge: (text: String, ok: Bool)? {
        guard player.bitPerfect else { return nil }
        guard let t = currentTrack, player.sampleRate > 0 else { return ("BIT-PERFECT", true) }
        func k(_ r: Double) -> String { r.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(r / 1000))" : String(format: "%.1f", r / 1000) }
        guard player.isBitPerfectNow else { return ("RESAMPLED \(k(player.sampleRate))→\(k(player.deviceRate)) kHz", false) }
        // Playback runs in stereo 32-bit float: other channel counts are mixed, and float holds up to 24 bits.
        let ch = player.channelCount
        if ch != 2 { return ("\(ch == 1 ? "MONO" : "\(ch) CH") → STEREO", false) }
        if let bits = t.bitDepth {
            let device = AudioDevices.outputBitDepth(player.deviceID) ?? 24
            let limit = min(device, 24)
            if bits > limit { return ("\(bits)→\(limit)-BIT", false) }
        }
        return ("BIT-PERFECT \(k(player.sampleRate)) kHz", true)
    }

    func shutdown() {
        rememberPosition()
        saveNow()
        PodcastLibrary.writes.sync {}   // podcast state saved in the background: let it land before quitting
        player.shutdown()
    }

    // MARK: Stop after current / sleep timer

    /// One-shot: stop when the current track ends (Winamp's Ctrl+V; here Shift+V).
    var stopAfterCurrent = false {
        didSet {
            if stopAfterCurrent { invalidatePreload() } else { schedulePreloadCheck() }
            ui?.optionsDidChange()
        }
    }

    /// A track reached its end on its own (not Next).
    private func trackFinished() {
        forgetPosition(currentTrack?.key)
        if let t = currentTrack, t.isEpisode {
            PodcastLibrary.shared.markPlayed(t.path)
            PodcastDownloads.shared.remove(t.path)   // heard to the end: the download has done its job
        }
        if stopAfterCurrent {
            stopAfterCurrent = false
            player.stop()
            updateNowPlaying()
            return
        }
        advance()
    }

    private(set) var sleepAt: Date?
    private var sleepTimer: Timer?

    /// Pause after `minutes` (fading out over the last seconds); nil cancels.
    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        player.fadeGain = 1
        sleepAt = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        if let at = sleepAt {
            let t = Timer(fire: at.addingTimeInterval(-8), interval: 0.1, repeats: true) { [weak self] _ in self?.sleepTick() }
            RunLoop.main.add(t, forMode: .common)
            sleepTimer = t
        }
        ui?.optionsDidChange()
    }

    /// Last 8 seconds: fade out, then pause and restore the level for next time.
    private func sleepTick() {
        guard let at = sleepAt else { return }
        let left = at.timeIntervalSinceNow
        if left > 0 {
            player.fadeGain = Float(max(0, min(1, left / 8)))
            return
        }
        if player.state == .playing { player.pause(); rememberPosition() }
        updateNowPlaying()
        setSleepTimer(minutes: nil)
    }

    // MARK: Playback speed (podcasts and web files)

    static let speeds: [Float] = [1, 1.25, 1.5, 1.75, 2]

    /// Speed per show (web files share one), remembered between launches.
    private var showSpeeds: [String: Float] {
        get { (UserDefaults.standard.dictionary(forKey: "podcastSpeeds") as? [String: Double])?.mapValues { Float($0) } ?? [:] }
        set { UserDefaults.standard.set(newValue.mapValues { Double($0) }, forKey: "podcastSpeeds") }
    }

    private func speedKey(_ t: Track) -> String { t.isWebFile ? "\u{0}web" : (t.podcast ?? "") }

    func speed(for t: Track) -> Float { t.isEpisode ? (showSpeeds[speedKey(t)] ?? 1) : 1 }

    /// The playing episode's speed (1 for anything else).
    var currentSpeed: Float { currentTrack.map(speed(for:)) ?? 1 }

    /// Change the speed of the playing episode's show.
    func setSpeed(_ s: Float) {
        guard let t = currentTrack, t.isEpisode else { return }
        var all = showSpeeds
        all[speedKey(t)] = s == 1 ? nil : s
        showSpeeds = all
        player.rate = s
        updateNowPlaying()
        if let i = currentIndex { ui?.playlistRowsDidUpdate([i]) }
        ui?.optionsDidChange()
    }

    // MARK: Resume position (audiobooks, podcasts, long mixes)

    /// Long files resume where they were left (≥ 10 minutes, or any .m4b audiobook).
    var resumeLongTracks: Bool {
        get { UserDefaults.standard.object(forKey: "resumeLongTracks") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "resumeLongTracks") }
    }

    /// Uses the player's duration when the tags aren't read yet.
    private func isLong(_ t: Track) -> Bool {
        if t.isEpisode { return true }   // podcasts always continue where you left off
        let d = t.duration ?? (t.path == player.currentURL?.path ? player.duration : 0)
        return d >= 600 || (t.path as NSString).pathExtension.lowercased() == "m4b"
    }

    /// Kept in memory too: the podcast window asks for every episode row it draws.
    private lazy var resumeCache = UserDefaults.standard.dictionary(forKey: "resumePositions") as? [String: Double] ?? [:]
    private var resumePositions: [String: Double] {
        get { resumeCache }
        set { resumeCache = newValue; UserDefaults.standard.set(newValue, forKey: "resumePositions") }
    }
    /// When each position was saved: the list is trimmed oldest first (never the one just saved).
    private lazy var resumeDates = UserDefaults.standard.dictionary(forKey: "resumeDates") as? [String: Double] ?? [:]
    private static let maxResumePositions = 1000

    private func resumePosition(for t: Track) -> Double {
        // Only long tracks are ever stored, so a stored position is enough (the duration may not be known yet).
        // Podcasts always continue where you left off; the setting is about long music files.
        guard resumeLongTracks || t.isEpisode, let p = resumePositions[t.key] else { return 0 }
        return max(0, p - 3)   // a few seconds back, for context
    }

    /// Save the current position of a long track (not at the very start or end).
    private func rememberPosition() {
        guard let t = currentTrack, resumeLongTracks || t.isEpisode, isLong(t), player.state != .stopped else { return }
        let pos = player.currentTime, length = player.duration
        var all = resumePositions
        if pos > 30, length <= 0 || pos < length - 30 {
            all[t.key] = pos
            resumeDates[t.key] = Date().timeIntervalSince1970
        } else if length > 60, pos >= length - 30 {
            all.removeValue(forKey: t.key)          // heard to the end
            resumeDates.removeValue(forKey: t.key)
        }
        // Otherwise (the first 30 s, or still loading: an episode reads 0 until it plays) the saved place stays:
        // leaving before playback really started must not erase it.
        if all.count > Self.maxResumePositions {
            let oldest = all.keys.sorted { (resumeDates[$0] ?? 0) < (resumeDates[$1] ?? 0) }.prefix(all.count - Self.maxResumePositions)
            for k in oldest { all.removeValue(forKey: k); resumeDates.removeValue(forKey: k) }
        }
        UserDefaults.standard.set(resumeDates, forKey: "resumeDates")
        resumePositions = all
        if t.isEpisode {
            PodcastLibrary.shared.noteListened(t.path, track: t)
            NotificationCenter.default.post(name: PodcastLibrary.progressChanged, object: nil)
        }
    }

    /// A feed changed some episodes' audio addresses (same guid): positions and playlist entries follow.
    private func episodesMoved(_ moved: [String: String]) {
        var all = resumePositions
        for (was, now) in moved {
            if let p = all.removeValue(forKey: was) { all[now] = p }
            if let d = resumeDates.removeValue(forKey: was) { resumeDates[now] = d }
        }
        UserDefaults.standard.set(resumeDates, forKey: "resumeDates")
        resumePositions = all
        store.moveEpisodes(moved)
        scheduleSave()
    }

    private func forgetPosition(_ path: String?) {
        guard let p = path, resumePositions[p] != nil else { return }
        var all = resumePositions
        all.removeValue(forKey: p)
        resumeDates.removeValue(forKey: p)
        UserDefaults.standard.set(resumeDates, forKey: "resumeDates")
        resumePositions = all
        NotificationCenter.default.post(name: PodcastLibrary.progressChanged, object: nil)
    }

    /// Web addresses of the episodes you've heard more than 30 s of and not finished: those with a saved
    /// position (saved on pause, stop, track change and quit), plus the one playing now once it's past 30 s.
    /// (The live position is read, not saved: no extra writes while playing.)
    var startedEpisodeURLs: [String] {
        var urls = resumePositions.keys.filter { $0.hasPrefix("http") }
        if let t = currentTrack, t.isEpisode, player.isPlayingEpisode, player.currentTime > 30, !urls.contains(t.path) { urls.append(t.path) }
        return urls
    }

    /// How far into an episode the user got: the live position for the one playing, else the saved one.
    /// nil = not started (or finished). `duration` is nil when only the feed could say.
    func episodeProgress(_ url: String) -> (position: Double, duration: Double?)? {
        if let t = currentTrack, t.isEpisode, t.path == url, player.isPlayingEpisode, player.currentTime > 0 {
            return (player.currentTime, player.duration > 0 ? player.duration : nil)
        }
        return resumePositions[url].map { ($0, nil) }
    }

    // MARK: ReplayGain

    enum ReplayGainMode: String, CaseIterable {
        case off, track, album
        var title: String { self == .off ? "Off" : (self == .track ? "Track" : "Album") }
    }

    var replayGainMode: ReplayGainMode {
        get { ReplayGainMode(rawValue: UserDefaults.standard.string(forKey: "replayGain") ?? "") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "replayGain"); applyReplayGain(); ui?.optionsDidChange() }
    }

    /// Gain for the playing track: album gain (falls back to track), clipped so peaks stay ≤ 1.0.
    func replayGainFactor(for t: Track) -> Float {
        let mode = replayGainMode
        guard mode != .off else { return 1 }
        let db = mode == .album ? (t.rgAlbumGain ?? t.rgTrackGain) : (t.rgTrackGain ?? t.rgAlbumGain)
        guard let gain = db else { return 1 }
        var linear = powf(10, gain / 20)
        let peak = mode == .album ? (t.rgAlbumPeak ?? t.rgTrackPeak) : (t.rgTrackPeak ?? t.rgAlbumPeak)
        if let pk = peak, pk > 0 { linear = min(linear, 1 / pk) }   // prevent clipping
        return linear
    }

    private func applyReplayGain() {
        guard var t = currentTrack else { player.replayGain = 1; return }
        if replayGainMode != .off, !t.tagsLoaded {
            // Tags not read yet (e.g. autoplay right after adding a folder): read this one file now (~ms),
            // so the first second isn't played at the wrong level.
            let i = TagReader.read(path: t.path, fileSize: t.size)
            t.rgTrackGain = i.rgTrackGain; t.rgAlbumGain = i.rgAlbumGain
            t.rgTrackPeak = i.rgTrackPeak; t.rgAlbumPeak = i.rgAlbumPeak
        }
        player.replayGain = replayGainFactor(for: t)
    }

    // MARK: Duplicates

    /// Remove repeated entries of the same file (keeps the first). Returns how many were removed.
    @discardableResult
    func removeDuplicates() -> Int {
        var seen = Set<String>()
        var dupes = IndexSet()
        for (i, t) in store.tracks.enumerated() where !seen.insert(t.key).inserted { dupes.insert(i) }
        if !dupes.isEmpty { remove(trackIndices: dupes) }
        return dupes.count
    }

    func toggleShuffle() {
        invalidatePreload()
        shuffle.toggle()
        history.removeAll()
        ui?.optionsDidChange()
    }

    func toggleRepeat() {
        invalidatePreload()
        repeatAll.toggle()
        ui?.optionsDidChange()
    }

    // MARK: Display text

    func title(for index: Int) -> String {
        let t = store.tracks[index]
        if t.isStream {
            // "3. Groove Salad — Artist - Title", plus BUFFERING while it fills up.
            var s = "\(index + 1). \(t.title ?? player.streamInfo?.name ?? t.path)"
            if index == currentIndex, player.isStreaming {
                if player.isBuffering { s += " · BUFFERING…" } else if let st = player.streamTitle { s += " — \(st)" }
            } else if index == currentIndex, let err = player.streamError {
                s += " · couldn't connect: \(err)"
            }
            return s
        }
        let d = t.duration.map { " (\(TimeFormat.mmss($0)))" } ?? ""
        if t.isEpisode, index == currentIndex {
            if player.isPlayingEpisode, player.isBuffering { return "\(index + 1). \(t.displayTitle) · BUFFERING…" }
            if let err = player.streamError { return "\(index + 1). \(t.displayTitle) · couldn't load: \(err)" }
        }
        return "\(index + 1). \(t.displayTitle)\(d)"
    }

    /// Bitrate in kbps for display (FLAC: computed from size/duration).
    var currentKbps: Int? {
        guard let t = currentTrack else { return nil }
        if t.isStream { return player.streamInfo?.bitrate }
        if t.isEpisode { return t.bitrate }
        if let b = t.bitrate { return b }
        if let k = Sane.kbps(bytes: t.size, seconds: t.duration) { return k }
        return nil
    }

    var currentKHz: Int? {
        let sr = currentTrack?.sampleRate ?? Int(player.sampleRate)
        return sr > 0 ? Int((Double(sr) / 1000).rounded()) : nil
    }

    /// Human readable format, e.g. "FLAC 24-bit / 96 kHz" or "MP3 320 kbps · 44.1 kHz".
    var formatDescription: String { currentIndex.map { formatDescription(for: $0) } ?? "" }

    /// Format line for any track; the playing one also gets live info (actual rate, channels).
    func formatDescription(for index: Int) -> String {
        let l = formatLines(for: index)
        return [l.0, l.1].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The format split in two, for narrow layouts: ("FLAC 16-bit / 44.1 kHz", "801 kbps · stereo").
    func formatLines(for index: Int) -> (String, String) {
        guard index < store.tracks.count else { return ("", "") }
        let t = store.tracks[index]
        if t.isStream {
            guard index == currentIndex, let i = player.streamInfo else { return ("Internet radio", "") }
            let khz = i.sampleRate > 0 ? String(format: i.sampleRate.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0f kHz" : "%.1f kHz", i.sampleRate / 1000) : ""
            let ch = i.channels == 1 ? "mono" : (i.channels == 2 ? "stereo" : "")
            return (["RADIO", i.codec, i.bitrate.map { "\($0) kbps" }].compactMap { $0 }.joined(separator: " "),
                    [khz, ch].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        if t.isEpisode {
            // "PODCAST MP3" · "12 Mar 2026"
            let ext = (t.url.path as NSString).pathExtension.uppercased()
            let codec = ["MP3", "M4A", "AAC", "MP4", "OGG", "OPUS", "WAV"].contains(ext) ? (ext == "M4A" || ext == "MP4" ? "AAC" : ext) : ""
            let date = t.published.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? ""
            let sp = speed(for: t)
            let speedTag = sp == 1 ? "" : String(format: "%g×", sp)
            return ([t.isWebFile ? "WEB" : "PODCAST", codec, speedTag].filter { !$0.isEmpty }.joined(separator: " "), date)
        }
        let playing = index == currentIndex && player.state != .stopped
        let ext = (t.path as NSString).pathExtension.lowercased()
        let lossless = t.bitDepth != nil
        let codec: String
        switch ext {
        case "flac": codec = "FLAC"
        case "mp3": codec = "MP3"
        case "wav", "wave": codec = "WAV"
        case "aif", "aiff", "aifc": codec = "AIFF"
        case "m4a", "m4b", "mp4", "alac": codec = lossless ? "ALAC" : "AAC"
        case "aac": codec = "AAC"
        default: codec = ext.uppercased()
        }
        let sr = t.sampleRate ?? (playing ? Int(player.sampleRate) : 0)
        let khz = sr > 0 ? (sr % 1000 == 0 ? "\(sr / 1000) kHz" : String(format: "%.1f kHz", Double(sr) / 1000)) : ""
        let channels = playing ? player.channelCount : 0
        let ch = channels == 1 ? "mono" : (channels == 2 ? "stereo" : (channels > 2 ? "\(channels) ch" : ""))
        let kbps = t.bitrate ?? Sane.kbps(bytes: t.size, seconds: t.duration)
        func join(_ p: [String]) -> String {
            p.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if lossless, let bits = t.bitDepth {
            return (join(["\(codec) \(bits)-bit / \(khz)"]), join([kbps.map { "\($0) kbps" } ?? "", ch]))
        }
        return (join(["\(codec) \(kbps.map { "\($0) kbps" } ?? "")"]), join([khz, ch]))
    }

    /// Tracks of the same album in the playlist (same album tag, and same folder or artist).
    func albumSummary(for index: Int) -> (count: Int, duration: Double)? {
        guard index < store.tracks.count, let album = store.tracks[index].album, !album.isEmpty else { return nil }
        let t = store.tracks[index]
        let dir = (t.path as NSString).deletingLastPathComponent
        var n = 0, d = 0.0
        for o in store.tracks where o.album == album && ((o.path as NSString).deletingLastPathComponent == dir || o.artist == t.artist) {
            n += 1
            d += o.duration ?? 0
        }
        return (n, d)
    }

    /// Files that couldn't be opened one after another (reset by the first that plays).
    private var failedInARow = 0
    /// Why playback stopped by itself, shown in the status line until something plays.
    private(set) var playbackProblem: String?

    var statusText: String {
        if let p = playbackProblem { return p }
        let total = store.tracks.count
        // While a folder is being added: how far along it is.
        if store.scansInProgress > 0 {
            return "Adding… \(store.scannedSoFar.formatted()) files"
        }
        var s = visible == nil ? "\(total) tracks" : "\(rowCount)/\(total) tracks"
        let dur = store.totalDuration
        if dur > 0 { s += "  \(TimeFormat.mmss(dur))" }
        if store.isLoadingTags { s += "  …" }
        if stopAfterCurrent { s = "⏹ after this · " + s }
        if let at = sleepAt { s = "☾ \(max(1, Int(ceil(at.timeIntervalSinceNow / 60))))m · " + s }
        return s
    }

    // MARK: Media keys / Now Playing

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        // Headsets often send "play" when they reconnect: while playing that must not restart the track.
        cc.playCommand.addTarget { [weak self] _ in
            guard let self else { return .success }
            if self.player.state != .playing { self.playOrResume() }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.player.state == .playing else { return .success }
            self.player.pause()
            self.rememberPosition()   // like every other pause
            self.updateNowPlaying()
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        cc.stopCommand.addTarget { [weak self] _ in self?.stop(); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let self, let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: e.positionTime)
            return .success
        }
        // Podcasts: 15 s back / 30 s forward instead of previous / next (switched per track in updateNowPlaying).
        cc.skipBackwardCommand.preferredIntervals = [15]
        cc.skipForwardCommand.preferredIntervals = [30]
        cc.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.seek(to: max(0, self.player.currentTime - 15))
            return .success
        }
        cc.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.seek(to: min(self.player.duration, self.player.currentTime + 30))
            return .success
        }
        cc.skipBackwardCommand.isEnabled = false
        cc.skipForwardCommand.isEnabled = false
    }

    /// Cover for Now Playing: album art, station logo or show artwork, loaded once per track in the background.
    private var nowPlayingArt: (key: String, art: MPMediaItemArtwork)?
    private var nowPlayingArtRequest: String?

    private func nowPlayingArtwork(for t: Track) -> MPMediaItemArtwork? {
        if let a = nowPlayingArt, a.key == t.key { return a.art }
        guard nowPlayingArtRequest != t.key else { return nil }
        nowPlayingArtRequest = t.key
        let key = t.key
        let deliver: (CGImage?) -> Void = { [weak self] img in
            guard let self, let img, self.currentTrack?.key == key else { return }
            let image = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            self.nowPlayingArt = (key, MPMediaItemArtwork(boundsSize: image.size) { _ in image })
            self.updateNowPlaying()
        }
        if t.isRemote { LogoStore.shared.load(t.logo, completion: deliver) } else { ArtworkStore.shared.load(t.path) { deliver($0.thumb) } }
        return nil
    }

    func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = currentTrack, player.state != .stopped else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        // Podcasts get skip buttons; music and radio get previous / next.
        let cc = MPRemoteCommandCenter.shared()
        let skips = t.isEpisode
        cc.skipBackwardCommand.isEnabled = skips
        cc.skipForwardCommand.isEnabled = skips
        cc.previousTrackCommand.isEnabled = !skips
        cc.nextTrackCommand.isEnabled = !skips
        let art = nowPlayingArtwork(for: t)
        var info: [String: Any]
        if t.isStream {
            info = [
                MPMediaItemPropertyTitle: player.streamTitle ?? t.title ?? "Internet radio",
                MPMediaItemPropertyArtist: t.title ?? player.streamInfo?.name ?? "",
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: player.state == .playing ? 1.0 : 0.0,
            ]
        } else {
            info = [
                MPMediaItemPropertyTitle: t.title ?? t.fileStem,
                MPMediaItemPropertyArtist: t.artist ?? "",
                MPMediaItemPropertyAlbumTitle: t.album ?? "",
                MPMediaItemPropertyPlaybackDuration: player.duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
                MPNowPlayingInfoPropertyPlaybackRate: player.state == .playing ? Double(player.rate) : 0.0,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            ]
            if t.isEpisode, let show = t.podcast, !show.isEmpty { info[MPMediaItemPropertyPodcastTitle] = show }
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        if let art { info[MPMediaItemPropertyArtwork] = art }
        center.nowPlayingInfo = info
        center.playbackState = player.state == .playing ? .playing : .paused
    }

}

extension PlayerController: PlaylistStoreDelegate {
    func playlistDidReload() {
        searchText = nil   // rows added, removed or moved: rebuilt by the next filter
        lastFilter = nil
        if visible != nil { setFilter(filterQuery) } else { ui?.playlistDidReload(); ui?.optionsDidChange() }
    }

    func playlistDidUpdate(indices: IndexSet) {
        if searchText != nil {
            for i in indices where i < store.tracks.count && i < searchText!.count { searchText![i] = Self.searchable(store.tracks[i]) }
            lastFilter = nil   // a row's text changed: the next keystroke looks at everything again
        }
        // Tags can arrive after playback started (autoplay right after a scan): pick up ReplayGain then.
        if let c = currentIndex, indices.contains(c) { applyReplayGain() }
        ui?.playlistRowsDidUpdate(indices)
    }
}
