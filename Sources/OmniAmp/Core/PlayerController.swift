import AppKit
import MediaPlayer

/// What a look (modern or classic skin) must implement to follow the player.
protocol PlayerUI: AnyObject {
    func playlistDidReload()
    func playlistRowsDidUpdate(_ trackIndices: IndexSet)
    func currentTrackDidChange(old: Int?, new: Int?)
    func optionsDidChange()
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
        player.apply(eqSettings)
        player.onStreamChange = { [weak self] in
            guard let self, let c = self.currentIndex else { return }
            self.ui?.playlistRowsDidUpdate([c])
            self.updateNowPlaying()
        }
        player.onOutputChange = { [weak self] in self?.ui?.optionsDidChange() }
        restore()
        let d = UserDefaults.standard
        player.setOutputDevice(uid: d.string(forKey: "outputDeviceUID"))
        player.setBitPerfect(d.bool(forKey: "bitPerfect"), exclusive: d.bool(forKey: "exclusiveAccess"))
        folders.rescanAll()   // pick up changes made while the app was closed
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

    func setFilter(_ query: String) {
        invalidatePreload()
        filterQuery = query
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            visible = nil
        } else {
            let words = q.split(separator: " ")
            visible = store.tracks.indices.filter { i in
                let t = store.tracks[i]
                let hay = "\(t.displayTitle) \(t.album ?? "") \(t.path)".lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
        }
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

    func saveNow() {
        LibraryCache.save(payload())
    }

    func scheduleSave() {
        saveWorkItem?.cancel()
        let p = payload()
        let item = DispatchWorkItem { LibraryCache.save(p) }
        saveWorkItem = item
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func payload() -> LibraryCache.Payload {
        .init(tracks: store.tracks, currentIndex: currentIndex, volume: player.softwareVolume, shuffle: shuffle, repeatAll: repeatAll)
    }

    // MARK: Adding / removing

    /// Add files/folders/playlists; `at` inserts at a track index (nil = append).
    func add(_ urls: [URL], at position: Int? = nil) {
        let t0 = Date()
        if position != nil { invalidatePreload() }
        let currentID = currentIndex.map { store.id(at: $0) }
        store.add(urls: urls, at: position, onBatch: { [weak self] start, n in
            guard let self else { return }
            self.remapCurrent(currentID)
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
        if let i = store.tracks.firstIndex(where: { $0.path == episode.path }) { return i }
        insertScanned([episode], at: store.tracks.count)
        return store.tracks.count - 1
    }

    /// Insert tracks that were already scanned (watched folders), keeping the current track.
    func insertScanned(_ tracks: [Track], at position: Int) {
        invalidatePreload()
        let currentID = currentIndex.map { store.id(at: $0) }
        store.insert(tracks, at: position)
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
        preloadAttempted = false
        applyReplayGain()
        if store.tracks[index].isStream {
            player.playStream(url: store.tracks[index].url)
            Scrobbler.shared.trackStarted(nil, duration: 0)   // radio isn't scrobbled
            ui?.currentTrackDidChange(old: old, new: index)
            updateNowPlaying()
            return
        }
        if store.tracks[index].isEpisode {
            let t = store.tracks[index]
            player.playEpisode(url: t.url, from: resumePosition(for: t), duration: t.duration)
            Scrobbler.shared.trackStarted(nil, duration: 0)   // podcasts aren't scrobbled
            ui?.currentTrackDidChange(old: old, new: index)
            updateNowPlaying()
            return
        }
        let ok = player.play(url: store.tracks[index].url, from: resumePosition(for: store.tracks[index]), range: store.tracks[index].cueRange)
        if ok { Scrobbler.shared.trackStarted(store.tracks[index], duration: store.tracks[index].duration ?? player.duration) }
        schedulePreloadCheck()
        ui?.currentTrackDidChange(old: old, new: index)
        updateNowPlaying()
        if !ok {
            // Skip unplayable files.
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
        if player.currentTime > 3, let c = currentIndex { play(index: c, recordHistory: false); return }
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
        if player.queueNext(url: track.url, range: track.cueRange) { preloaded = (t, track.key) }
    }

    private func gaplessAdvanced() {
        let old = currentIndex
        var new: Int?
        if let q = preloaded {
            if q.index < store.tracks.count, store.tracks[q.index].key == q.path { new = q.index }
            else { new = store.tracks.firstIndex { $0.key == q.path } }
        }
        preloaded = nil
        preloadAttempted = false
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
        if player.hasQueuedNext { player.cancelQueuedNext() }
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
        ui?.optionsDidChange()
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
        ui?.optionsDidChange()
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

    /// Short output status for the UI, e.g. "BIT-PERFECT 96 kHz" or "RESAMPLED 96→48 kHz".
    var outputBadge: (text: String, ok: Bool)? {
        guard player.bitPerfect else { return nil }
        guard currentTrack != nil, player.sampleRate > 0 else { return ("BIT-PERFECT", true) }
        func k(_ r: Double) -> String { r.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(r / 1000))" : String(format: "%.1f", r / 1000) }
        if player.isBitPerfectNow { return ("BIT-PERFECT \(k(player.sampleRate)) kHz", true) }
        return ("RESAMPLED \(k(player.sampleRate))→\(k(player.deviceRate)) kHz", false)
    }

    func shutdown() {
        rememberPosition()
        saveNow()
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
        if let t = currentTrack, t.isEpisode { PodcastLibrary.shared.markPlayed(t.path) }
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

    private var resumePositions: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "resumePositions") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "resumePositions") }
    }

    private func resumePosition(for t: Track) -> Double {
        // Only long tracks are ever stored, so a stored position is enough (the duration may not be known yet).
        guard resumeLongTracks, let p = resumePositions[t.key] else { return 0 }
        return max(0, p - 3)   // a few seconds back, for context
    }

    /// Save the current position of a long track (not at the very start or end).
    private func rememberPosition() {
        guard resumeLongTracks, let t = currentTrack, isLong(t), player.state != .stopped else { return }
        let pos = player.currentTime
        var all = resumePositions
        if pos > 30, pos < player.duration - 30 { all[t.key] = pos } else { all.removeValue(forKey: t.key) }
        // Keep the list small.
        if all.count > 300 { for k in all.keys.prefix(all.count - 300) { all.removeValue(forKey: k) } }
        resumePositions = all
    }

    private func forgetPosition(_ path: String?) {
        guard let p = path, resumePositions[p] != nil else { return }
        var all = resumePositions
        all.removeValue(forKey: p)
        resumePositions = all
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
        if let d = t.duration, d > 0 { return Int(Double(t.size) * 8 / d / 1000) }
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
            return ([t.isWebFile ? "WEB" : "PODCAST", codec].filter { !$0.isEmpty }.joined(separator: " "), date)
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
        let kbps = t.bitrate ?? t.duration.flatMap { $0 > 0 ? Int(Double(t.size) * 8 / $0 / 1000) : nil }
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

    var statusText: String {
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
        cc.playCommand.addTarget { [weak self] _ in self?.playOrResume(); return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); self?.updateNowPlaying(); return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        cc.stopCommand.addTarget { [weak self] _ in self?.stop(); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let self, let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: e.positionTime)
            return .success
        }
    }

    func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = currentTrack, player.state != .stopped else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        if t.isStream {
            center.nowPlayingInfo = [
                MPMediaItemPropertyTitle: player.streamTitle ?? t.title ?? "Internet radio",
                MPMediaItemPropertyArtist: t.title ?? player.streamInfo?.name ?? "",
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: player.state == .playing ? 1.0 : 0.0,
            ]
            center.playbackState = player.state == .playing ? .playing : .paused
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: t.title ?? t.fileStem,
            MPMediaItemPropertyArtist: t.artist ?? "",
            MPMediaItemPropertyAlbumTitle: t.album ?? "",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.state == .playing ? 1.0 : 0.0,
        ]
        center.playbackState = player.state == .playing ? .playing : .paused
    }

}

extension PlayerController: PlaylistStoreDelegate {
    func playlistDidReload() {
        if visible != nil { setFilter(filterQuery) } else { ui?.playlistDidReload(); ui?.optionsDidChange() }
    }

    func playlistDidUpdate(indices: IndexSet) {
        // Tags can arrive after playback started (autoplay right after a scan): pick up ReplayGain then.
        if let c = currentIndex, indices.contains(c) { applyReplayGain() }
        ui?.playlistRowsDidUpdate(indices)
    }
}
