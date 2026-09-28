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
        cc.playCommand.addTarget { [weak self] _ in
            guard let c = self?.controller else { return .success }
            if c.player.state != .playing { c.playOrResume() }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let c = self?.controller, c.player.state == .playing else { return .success }
            c.pause()   // like every other pause: the position is remembered
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.controller?.togglePlayPause(); return .success }
        cc.stopCommand.addTarget { [weak self] _ in self?.controller?.stop(); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.controller?.next(); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.controller?.previous(); return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let c = self?.controller, let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            c.seek(to: e.positionTime)
            return .success
        }
        // Podcasts: 15 s back / 30 s forward instead of previous / next (switched per track in update()).
        cc.skipBackwardCommand.preferredIntervals = [15]
        cc.skipForwardCommand.preferredIntervals = [30]
        cc.skipBackwardCommand.addTarget { [weak self] _ in
            guard let c = self?.controller else { return .commandFailed }
            c.seek(to: max(0, c.player.currentTime - 15))
            return .success
        }
        cc.skipForwardCommand.addTarget { [weak self] _ in
            guard let c = self?.controller else { return .commandFailed }
            c.seek(to: min(c.player.duration, c.player.currentTime + 30))
            return .success
        }
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
        let deliver: (CGImage?) -> Void = { [weak self] img in
            guard let self, let img, self.controller?.currentTrack?.key == key else { return }
            let image = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            self.art = (key, MPMediaItemArtwork(boundsSize: image.size) { _ in image })
            self.update()
        }
        if t.isRemote { LogoStore.shared.load(t.logo, completion: deliver) } else { ArtworkStore.shared.load(t.path) { deliver($0.thumb) } }
        return nil
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
