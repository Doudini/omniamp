import AppKit
import MediaPlayer

/// macOS Now Playing (menu bar, Control Center, lock screen) and the media keys, for the controller.
@MainActor
final class NowPlaying {
    private weak var controller: PlayerController?

    init(controller: PlayerController) { self.controller = controller }

    /// Media keys, headset buttons and Now Playing's controls (once, at launch).
    func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        // Headsets often send "play" when they reconnect: while playing that must not restart the track.
        cc.playCommand.addTarget(handler: Self.command { [weak self] in
            guard let c = self?.controller, c.player.state != .playing else { return }
            c.playOrResume()
        })
        cc.pauseCommand.addTarget(handler: Self.command { [weak self] in
            guard let c = self?.controller, c.player.state == .playing else { return }
            c.pause()   // like every other pause: the position is remembered
        })
        cc.togglePlayPauseCommand.addTarget(handler: Self.command { [weak self] in self?.controller?.togglePlayPause() })
        cc.stopCommand.addTarget(handler: Self.command { [weak self] in self?.controller?.stop() })
        cc.nextTrackCommand.addTarget(handler: Self.command { [weak self] in self?.controller?.next() })
        cc.previousTrackCommand.addTarget(handler: Self.command { [weak self] in self?.controller?.previous() })
        cc.changePlaybackPositionCommand.addTarget(handler: Self.seekCommand { [weak self] t in self?.controller?.seek(to: t) })
        // Podcasts: 15 s back / 30 s forward instead of previous / next (switched per track in update()).
        cc.skipBackwardCommand.preferredIntervals = [15]
        cc.skipForwardCommand.preferredIntervals = [30]
        cc.skipBackwardCommand.addTarget(handler: Self.command { [weak self] in
            guard let c = self?.controller else { return }
            c.seek(to: max(0, c.player.currentTime - 15))
        })
        cc.skipForwardCommand.addTarget(handler: Self.command { [weak self] in
            guard let c = self?.controller else { return }
            c.seek(to: min(c.player.duration, c.player.currentTime + 30))
        })
        cc.skipBackwardCommand.isEnabled = false
        cc.skipForwardCommand.isEnabled = false
    }

    /// Cover for Now Playing: album art, station logo or show artwork, loaded once per track in the background.
    private var art: (key: String, art: MPMediaItemArtwork)?
    private var artRequest: String?

    private func artwork(for t: Track) -> MPMediaItemArtwork? {
        if let a = art, a.key == t.key { return a.art }
        guard artRequest != t.key else { return nil }
        artRequest = t.key
        let key = t.key
        let deliver: @MainActor (CGImage?) -> Void = { [weak self] img in
            guard let self, let img, self.controller?.currentTrack?.key == key else { return }
            self.art = (key, Self.artwork(img))
            self.update()
        }
        if t.isRemote { LogoStore.shared.load(t.logo, completion: deliver) } else { ArtworkStore.shared.load(t.path) { deliver($0.thumb) } }
        return nil
    }

    /// A remote command's handler, running `action` on the main thread. MediaPlayer may call handlers on a queue of
    /// its own: made here, outside main-actor code, the handler isn't checked (and trapped) for that; it hops over.
    nonisolated private static func command(_ action: @escaping @Sendable @MainActor () -> Void)
        -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            if Thread.isMainThread { MainActor.assumeIsolated { action() } } else { DispatchQueue.main.async { action() } }
            return .success
        }
    }

    /// The same for "go to this position" (the scrubber in Now Playing).
    nonisolated private static func seekCommand(_ action: @escaping @Sendable @MainActor (Double) -> Void)
        -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { e in
            guard let t = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            if Thread.isMainThread { MainActor.assumeIsolated { action(t) } } else { DispatchQueue.main.async { action(t) } }
            return .success
        }
    }

    /// MediaPlayer asks for the image on a thread of its own: the handler is made outside main-actor code, or Swift 6
    /// would check (and trap) that it runs on the main thread.
    nonisolated private static func artwork(_ img: CGImage) -> MPMediaItemArtwork {
        let size = NSSize(width: img.width, height: img.height)
        return MPMediaItemArtwork(boundsSize: size) { _ in NSImage(cgImage: img, size: size) }
    }

    func update() {
        guard let c = controller else { return }
        let center = MPNowPlayingInfoCenter.default()
        let player = c.player
        guard let t = c.currentTrack, player.state != .stopped else {
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
        let art = artwork(for: t)
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
