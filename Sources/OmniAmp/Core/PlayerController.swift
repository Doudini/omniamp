import AppKit
import MediaPlayer

/// What a look (modern or classic skin) must implement to follow the player.
protocol PlayerUI: AnyObject {
    func playlistDidReload()
    func playlistRowsDidUpdate(_ trackIndices: IndexSet)
    func currentTrackDidChange(old: Int?, new: Int?)
    func optionsDidChange()
    /// Track index under the UI's selection, used by Play when nothing is loaded.
    var selectedTrackIndex: Int? { get }
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
    private var history: [Int] = []
    private var saveWorkItem: DispatchWorkItem?
    private(set) var eqSettings = Equalizer.load()

    // Gapless: the track queued behind the current one, and whether we already tried for this track.
    private var queued: (index: Int, path: String)?
    private var queueAttempted = false
    private var gaplessTimer: Timer?

    /// Indices into store.tracks currently shown (nil = no filter).
    private(set) var visible: [Int]?
    private(set) var filterQuery = ""

    init() {
        store.delegate = self
        store.onTagLoadingFinished = { [weak self] in
            self?.ui?.optionsDidChange()
            self?.scheduleSave()
        }
        player.onTrackFinished = { [weak self] in self?.advance() }
        player.onGaplessAdvance = { [weak self] in self?.gaplessAdvanced() }
        player.apply(eqSettings)
        restore()
        setupRemoteCommands()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.maybeQueueNext() }
        RunLoop.main.add(t, forMode: .common)
        gaplessTimer = t
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
        invalidateQueued()
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
        guard let cache = LibraryCache.load() else { player.volume = 0.8; return }
        NSLog("OmniAmp: restored %d tracks from cache in %.3fs", cache.tracks.count, Date().timeIntervalSince(t0))
        shuffle = cache.shuffle ?? false
        repeatAll = cache.repeatAll ?? true
        player.volume = cache.volume ?? 0.8
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
        .init(tracks: store.tracks, currentIndex: currentIndex, volume: player.volume, shuffle: shuffle, repeatAll: repeatAll)
    }

    // MARK: Adding / removing

    func add(_ urls: [URL]) {
        let t0 = Date()
        store.add(urls: urls) { [weak self] n in
            guard let self else { return }
            NSLog("OmniAmp: %d rows visible after %.3fs", n, Date().timeIntervalSince(t0))
            // Start playing if nothing is loaded yet.
            let autoplay = ProcessInfo.processInfo.environment["OMNIAMP_NO_AUTOPLAY"] == nil
            if autoplay, n > 0, self.player.state == .stopped, self.currentIndex == nil {
                self.play(index: self.store.tracks.count - n)
            }
            self.scheduleSave()
        }
    }

    func showOpenPanel(for window: NSWindow?) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.mp3, .init(filenameExtension: "flac")!, .folder, .m3uPlaylist, .init(filenameExtension: "pls") ?? .m3uPlaylist,
                                 .init(filenameExtension: "m3u8") ?? .m3uPlaylist]
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            if r == .OK { self?.add(p.urls) }
        }
        if let w = window { p.beginSheetModal(for: w, completionHandler: done) } else { done(p.runModal()) }
    }

    func clear() {
        invalidateQueued()
        player.stop()
        let old = currentIndex
        currentIndex = nil
        history.removeAll()
        filterQuery = ""
        visible = nil
        store.clear()
        ui?.currentTrackDidChange(old: old, new: nil)
        updateNowPlaying()
        scheduleSave()
    }

    func remove(trackIndices idx: IndexSet) {
        guard !idx.isEmpty else { return }
        invalidateQueued()
        if let c = currentIndex {
            if idx.contains(c) { currentIndex = nil }
            else { currentIndex = c - idx.count(in: 0..<c) }
        }
        history.removeAll()
        store.remove(at: idx)
        scheduleSave()
    }

    // MARK: Playback

    func play(index: Int, recordHistory: Bool = true) {
        guard index >= 0, index < store.tracks.count else { return }
        let old = currentIndex
        if recordHistory, let o = old, o != index {
            history.append(o)
            if history.count > 500 { history.removeFirst() }
        }
        currentIndex = index
        queued = nil
        queueAttempted = false
        let ok = player.play(url: store.tracks[index].url)
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
        case .playing: player.pause()
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
        if player.state == .playing { player.pause() } else if player.state == .paused { player.resume() }
        updateNowPlaying()
    }

    func stop() {
        player.stop()
        updateNowPlaying()
    }

    func next() { advance() }

    func previous() {
        guard !store.tracks.isEmpty else { return }
        if player.currentTime > 3, let c = currentIndex { play(index: c, recordHistory: false); return }
        if shuffle, let h = history.popLast() { play(index: h, recordHistory: false); return }
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
    private func maybeQueueNext() {
        guard player.state == .playing, !queueAttempted, !player.hasQueuedNext,
              player.duration > 0, player.remaining < 8 else { return }
        queueAttempted = true
        guard let t = nextTarget(), t != currentIndex else { return }
        let track = store.tracks[t]
        if player.queueNext(url: track.url) { queued = (t, track.path) }
    }

    private func gaplessAdvanced() {
        let old = currentIndex
        var new: Int?
        if let q = queued {
            if q.index < store.tracks.count, store.tracks[q.index].path == q.path { new = q.index }
            else { new = store.tracks.firstIndex { $0.path == q.path } }
        }
        queued = nil
        queueAttempted = false
        if let o = old, o != new { history.append(o); if history.count > 500 { history.removeFirst() } }
        currentIndex = new
        NSLog("OmniAmp: gapless advance to #%d", (new ?? -2) + 1)
        ui?.currentTrackDidChange(old: old, new: new)
        updateNowPlaying()
    }

    /// The queued track may no longer be the right one (order/filter/shuffle changed).
    private func invalidateQueued() {
        if player.hasQueuedNext { player.cancelQueuedNext() }
        queued = nil
        queueAttempted = false
    }

    // MARK: Equalizer

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
        updateNowPlaying()
    }

    func seek(fraction: Double) { seek(to: fraction * player.duration) }
    func seek(by delta: Double) { seek(to: player.currentTime + delta) }

    func setVolume(_ v: Float) {
        player.volume = v
        ui?.optionsDidChange()
    }

    func changeVolume(by delta: Float) { setVolume(player.volume + delta) }

    func toggleShuffle() {
        invalidateQueued()
        shuffle.toggle()
        history.removeAll()
        ui?.optionsDidChange()
    }

    func toggleRepeat() {
        invalidateQueued()
        repeatAll.toggle()
        ui?.optionsDidChange()
    }

    // MARK: Display text

    func title(for index: Int) -> String {
        let t = store.tracks[index]
        let d = t.duration.map { " (\(TimeFormat.mmss($0)))" } ?? ""
        return "\(index + 1). \(t.displayTitle)\(d)"
    }

    /// Bitrate in kbps for display (FLAC: computed from size/duration).
    var currentKbps: Int? {
        guard let t = currentTrack else { return nil }
        if let b = t.bitrate { return b }
        if let d = t.duration, d > 0 { return Int(Double(t.size) * 8 / d / 1000) }
        return nil
    }

    var currentKHz: Int? {
        let sr = currentTrack?.sampleRate ?? Int(player.sampleRate)
        return sr > 0 ? Int((Double(sr) / 1000).rounded()) : nil
    }

    var statusText: String {
        let total = store.tracks.count
        var s = visible == nil ? "\(total) tracks" : "\(rowCount)/\(total) tracks"
        let dur = store.totalDuration
        if dur > 0 { s += "  \(TimeFormat.mmss(dur))" }
        if store.isLoadingTags { s += "  …" }
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

    /// Called ~1/s by the active UI while playing.
    func refreshNowPlayingElapsed() {
        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        center.nowPlayingInfo = info
    }
}

extension PlayerController: PlaylistStoreDelegate {
    func playlistDidReload() {
        if visible != nil { setFilter(filterQuery) } else { ui?.playlistDidReload(); ui?.optionsDidChange() }
    }

    func playlistDidUpdate(indices: IndexSet) {
        ui?.playlistRowsDidUpdate(indices)
    }
}
