import Accelerate
// AVFAudio's types (buffers, files) aren't marked Sendable yet; they're handed between threads by design here.
@preconcurrency import AVFAudio
import AVFoundation
import CoreAudio
import os

/// AVAudioEngine-based player: gapless queueing, 10-band EQ, seek, volume, output device selection and a
/// bit-perfect mode, plus a tap for the spectrum.
///
/// Graph: player → converter (mixer) → EQ → main mixer → output device.
/// Gapless: near the end of a track the controller calls `queueNext(url:)`. If the next file has the same
/// format, it is scheduled right behind the current one on the same player node, so there is no gap.
/// Bit-perfect: the device is switched to each file's sample rate, the EQ is bypassed and the software
/// volume is pinned to 1.0, so samples reach the device unchanged (float32 carries 16/24-bit PCM exactly).
/// OMNIAMP_DEBUG=1 logs the audio engine's start-up sequence.
private let debugAudio = ProcessInfo.processInfo.environment["OMNIAMP_DEBUG"] != nil
private func dlog(_ s: @autoclosure () -> String) { if debugAudio { NSLog("OmniAmp[audio]: %@", s()) } }

@MainActor
final class AudioPlayer {
    enum State { case stopped, playing, paused }

    /// A track being played: a whole file, or a slice of one (CUE sheet track).
    private struct Item {
        let id: Int
        let file: AVAudioFile
        let url: URL
        /// The caller's name for it (the playlist entry): tells which one a gapless change went to.
        var tag: String?
        /// The track's range in the file (whole file unless it is a CUE track).
        let trackStart: AVAudioFramePosition
        let trackEnd: AVAudioFramePosition
        /// Frame where playback of this item began (≥ trackStart; later after a seek or resume).
        var startFrame: AVAudioFramePosition
        var frames: AVAudioFramePosition { trackEnd - startFrame }
        var sampleRate: Double { file.processingFormat.sampleRate }

        init(id: Int, file: AVAudioFile, url: URL, range: (start: Double, end: Double?)?, offset: Double) {
            self.id = id
            self.file = file
            self.url = url
            let sr = file.processingFormat.sampleRate
            let len = file.length
            // Times come from CUE sheets and playlists: only believable ones become frame positions.
            let ts = min(max(0, AVAudioFramePosition((Sane.offset(range?.start) ?? 0) * sr)), max(0, len - 1))
            let te = Sane.offset(range?.end).map { min(len, max(ts + 1, AVAudioFramePosition($0 * sr))) } ?? len
            trackStart = ts
            trackEnd = te
            startFrame = min(ts + AVAudioFramePosition((Sane.offset(offset) ?? 0) * sr), max(ts, te - 1))
        }
    }
    private var nextItemID = 1

    private let engine = AVAudioEngine()
    /// The player the file (or radio) plays on.
    private var node = AVAudioPlayerNode()
    /// A second player, for a next track in another format: connected in that format and started (empty) ahead
    /// of time, it takes over when the current track ends. A player that's only started then, or connected in a
    /// new format then (which stops it), sounds ~150 ms late: a gap between the tracks.
    private var spare = AVAudioPlayerNode()
    /// The track ended by itself (its last audio went through the mixer): the player is still running, empty.
    private var endedByItself = false
    let eq = AVAudioUnitEQ(numberOfBands: Equalizer.frequencies.count)
    /// Converts any file format to the stereo format the EQ runs in (no-op when rates already match).
    private let converter = AVAudioMixerNode()
    private var current: Item?
    private var upcoming: Item?
    private var generation = 0

    // Output state.
    private var outputUID: String?                         // nil = follow the system default
    private(set) var bitPerfect = false { didSet { if bitPerfect != oldValue { watchDeviceVolume() } } }
    private(set) var exclusive = false
    private var originalRates: [AudioDeviceID: Double] = [:]
    private var lastRateRematch = Date.distantPast
    private var eqSettings = Equalizer.Settings()
    private var graphRate: Double = 0
    /// After we switch the device rate, the engine reports a configuration change a moment later and stops.
    /// Playback waits for that (or a timeout) instead of starting and then stuttering on the restart.
    private var awaitingRateSettle = false
    /// Which wait a settle timeout belongs to (the play generation changes too often to tell).
    private var settleToken = 0
    /// Playback clock kept on the host clock. Never ask the engine (`lastRenderTime`) from the main thread:
    /// during a device reconfiguration that call waits for an IO cycle while holding the engine lock, and the
    /// engine's own reconfiguration handler needs that lock → deadlock (silent, frozen UI, slow quit).
    private var clockBase: Double = 0          // position (s) when the clock last started
    private var clockStart: Double?            // host time it started; nil while not running

    // Test hooks (see README / memory): OMNIAMP_RECORD writes the final mix, OMNIAMP_VOLUME mutes.
    private let recordPath = ProcessInfo.processInfo.environment["OMNIAMP_RECORD"]
    private var recorders: [Double: AVAudioFile] = [:]
    private let testVolume = ProcessInfo.processInfo.environment["OMNIAMP_VOLUME"].flatMap(Float.init)

    let spectrum = SpectrumAnalyzer()
    /// The analyzer tap exists only while an analyzer is visible and playing.
    private var analyzerActive = false
    private var tapFormat: AVAudioFormat?
    private(set) var state: State = .stopped { didSet { if state != oldValue { onStateChange?() } } }
    /// Playing / paused / stopped changed (main thread).
    var onStateChange: (() -> Void)?
    /// Track ended and nothing was queued.
    var onTrackFinished: (() -> Void)?
    /// Playback moved seamlessly into the queued track.
    var onGaplessAdvance: (() -> Void)?
    /// Output device / rate / mode changed (for UI).
    var onOutputChange: (() -> Void)?

    // MARK: Volume

    /// Volume used outside bit-perfect mode (persisted by the controller).
    var softwareVolume: Float = 0.8 {
        didSet {
            if !bitPerfect { engine.mainMixerNode.outputVolume = testVolume ?? Self.loudness(softwareVolume) }
            applyGainStage()
        }
    }

    /// Volume as the UI sees it: software volume, or the device's hardware volume in bit-perfect mode.
    var volume: Float {
        get { bitPerfect ? (AudioDevices.hardwareVolume(deviceID) ?? 1) : softwareVolume }
        set {
            let v = max(0, min(1, newValue))
            if bitPerfect { AudioDevices.setHardwareVolume(deviceID, v) } else { softwareVolume = v }
        }
    }

    /// In bit-perfect mode the volume only works if the device has a hardware volume control.
    var volumeAdjustable: Bool { !bitPerfect || AudioDevices.hasHardwareVolume(deviceID) }

    /// The device's volume changed (bit-perfect mode, where the slider is the device's volume): from the volume
    /// keys, Control Center, another app. Main thread.
    var onVolumeChange: (() -> Void)?
    private var stopVolumeWatch: (() -> Void)?

    /// In bit-perfect mode, follow the device's own volume so the slider moves with the volume keys. Outside it the
    /// slider is the app's own volume, apart from the system's, as it should be.
    private func watchDeviceVolume() {
        stopVolumeWatch?()
        stopVolumeWatch = nil
        guard bitPerfect, AudioDevices.hasHardwareVolume(deviceID) else { return }
        stopVolumeWatch = AudioDevices.observeVolume(deviceID) { [weak self] in self?.onVolumeChange?() }
    }

    // MARK: Position

    var duration: Double {
        if let p = episodePlayer {
            let d = p.currentItem?.duration.seconds ?? .nan
            return d.isFinite && d > 0 ? d : episodeDurationHint
        }
        guard let c = current else { return 0 }
        return Double(c.trackEnd - c.trackStart) / c.sampleRate
    }

    var currentTime: Double {
        if let p = episodePlayer {
            let t = p.currentTime().seconds
            return t.isFinite ? max(0, t) : 0
        }
        let running = clockStart.map { CACurrentMediaTime() - $0 } ?? 0
        if isStreaming { return clockBase + running }   // radio: time since it started playing
        guard current != nil else { return 0 }
        return max(0, min(clockBase + running, duration))
    }

    /// Start the clock at the current item's start frame (called right after node.play()).
    private func startClock() {
        guard let c = current else { return }
        clockBase = Double(c.startFrame - c.trackStart) / c.sampleRate
        clockStart = CACurrentMediaTime()
    }

    private func freezeClock() {
        clockBase = currentTime
        clockStart = nil
    }

    var remaining: Double { max(0, duration - currentTime) }
    var currentURL: URL? { current?.url }
    /// The tag given to `queueNext` for the playing item (nil for one started with `play`).
    var currentTag: String? { current?.tag }
    /// A track is queued behind the current one (or its file is still being opened for that).
    var hasQueuedNext: Bool { upcoming != nil || pendingNext != nil }
    var sampleRate: Double { stream != nil ? mainStreamInfo.sampleRate : current?.file.fileFormat.sampleRate ?? 0 }
    var channelCount: Int { stream != nil ? mainStreamInfo.channels : Int(current?.file.fileFormat.channelCount ?? 0) }

    // MARK: Internet radio

    private var stream: StreamSource?
    private var streamURL: URL?
    private var streamStarted = false
    private var reconnects = 0
    /// When the current connection started playing (nil until it does). Per connection: the retry budget
    /// comes back only after a connection that really played a while, not after each failed attempt.
    private var connectionPlayingSince: CFTimeInterval?
    /// True while waiting for enough audio (start, or after the connection stalled).
    /// A stream ran dry while playing: the player is held until enough is queued again.
    private var stalled = false
    private(set) var isBuffering = false { didSet { if isBuffering != oldValue { onStreamChange?() } } }
    var isStreaming: Bool { stream != nil || systemPlayer != nil }
    var streamInfo: StreamSource.Info? { stream != nil ? mainStreamInfo : systemInfo }
    /// Latest "Artist - Title" from the station.
    private(set) var streamTitle: String?
    /// Why the last station stopped (shown instead of the title), cleared when a stream starts.
    private(set) var streamError: String?
    /// Title, info or buffering changed (main thread).
    var onStreamChange: (() -> Void)?

    /// Start an Icecast/SHOUTcast stream. Buffers ~2 s before sound starts.
    /// HLS and Ogg/Opus stations go to the system player (no EQ/visualizer for those).
    func playStream(url: URL) {
        finishFade()   // radio takes the player now
        stopNode()
        stopStream()
        upcoming = nil
        current = nil
        streamURL = url
        streamTitle = nil
        streamError = nil
        reconnects = 0
        state = .playing
        clockBase = 0
        clockStart = nil
        if StreamSource.isSystemPlayerURL(url) { openSystemStream(url, codec: nil) } else { openStream(url) }
    }

    // MARK: System player (HLS and Ogg/Opus radio, podcast episodes)

    /// An AVPlayer with what every use of it needs: failure, playing/buffering and end-of-item reports
    /// (on the main thread), and one teardown.
    @MainActor
    private final class SystemPlayback {
        let player: AVPlayer
        private var observers: [NSKeyValueObservation] = []
        private var endObserver: NSObjectProtocol?

        init(item: AVPlayerItem, deviceUID: String?, onFailed: @escaping @Sendable @MainActor (Error?) -> Void,
             onStatus: @escaping @Sendable @MainActor (AVPlayer.TimeControlStatus) -> Void, onEnd: (@Sendable @MainActor () -> Void)? = nil) {
            player = AVPlayer(playerItem: item)
            player.audioOutputDeviceUniqueID = deviceUID
            observers = [
                // KVO reports on any thread: read the value there, act on it on the main thread.
                item.observe(\.status, options: [.new]) { @Sendable [weak self] it, _ in
                    guard it.status == .failed else { return }
                    let error = it.error
                    DispatchQueue.main.async { [self] in if self != nil { onFailed(error) } }
                },
                player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] pl, _ in
                    let status = pl.timeControlStatus
                    DispatchQueue.main.async { [self] in if self != nil { onStatus(status) } }
                },
            ]
            if let onEnd {
                endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                     object: item, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if self != nil { onEnd() } }
                }
            }
        }

        /// After this nothing is reported any more.
        func stop() {
            observers.removeAll()
            endObserver.map(NotificationCenter.default.removeObserver)
            endObserver = nil
            player.pause()
        }
    }

    private var deviceUID: String? { AudioDevices.device(id: deviceID)?.uid }

    private var system: SystemPlayback?
    private var systemPlayer: AVPlayer? { system?.player }
    private var systemMetadata: AVPlayerItemMetadataOutput?
    private let systemMetaDelegate = SystemMetadataDelegate()
    private var systemInfo: StreamSource.Info?
    /// True while a station plays through the system player (EQ and visualizer don't apply).
    var usesSystemPlayer: Bool { system != nil }

    private func openSystemStream(_ url: URL, codec: String?) {
        stream?.stop()
        stream = nil
        // The system player can't use a device we hold exclusively.
        _ = AudioDevices.setHog(deviceID, false)
        let item = AVPlayerItem(url: url)
        let out = AVPlayerItemMetadataOutput(identifiers: nil)
        systemMetaDelegate.onTitle = { [weak self] t in
            guard let self, self.systemPlayer?.currentItem === item else { return }
            self.streamTitle = t
            self.onStreamChange?()
        }
        out.setDelegate(systemMetaDelegate, queue: .main)
        item.add(out)
        systemMetadata = out
        var playback: SystemPlayback?
        playback = SystemPlayback(item: item, deviceUID: deviceUID, onFailed: { [weak self] error in
            guard let self, self.system === playback else { return }
            self.stop()
            self.streamError = Self.friendly(error)
            self.onStreamChange?()
        }, onStatus: { [weak self] status in
            guard let self, self.system === playback else { return }
            let playing = status == .playing
            dlog("system player: \(playing ? "playing" : "waiting")")
            if playing, self.clockStart == nil { self.clockStart = CACurrentMediaTime() }
            self.isBuffering = !playing && self.state == .playing
        })
        system = playback
        var info = StreamSource.Info()
        let path = url.path.lowercased()
        info.codec = codec ?? (path.hasSuffix(".m3u8") || (codec ?? "").contains("mpegurl") ? "HLS" : (path.contains("opus") ? "OPUS" : "OGG"))
        systemInfo = info
        applyGainStage()
        isBuffering = true
        playback?.player.play()
        scheduleIdleStop()
        onStreamChange?()
    }

    // MARK: Podcast episodes

    // Episodes are ordinary audio files on the web. The system player streams them with seeking and a known
    // length; like HLS radio they bypass our engine (no EQ or visualizer).
    private var episode: SystemPlayback?
    private var episodePlayer: AVPlayer? { episode?.player }
    private var episodeDurationHint: Double = 0
    /// True while a podcast episode is loaded (playing or paused).
    var isPlayingEpisode: Bool { episode != nil }

    /// Playback speed for episodes and web files (1 = normal; pitch is kept). Music always plays at 1×.
    var rate: Float = 1 {
        didSet {
            guard let p = episodePlayer else { return }
            p.defaultRate = rate
            if state == .playing { p.rate = rate }
        }
    }

    /// Play a podcast episode from `start` seconds. `duration` (from the feed) is shown until the file reports its own.
    func playEpisode(url: URL, from start: Double = 0, duration: Double? = nil) {
        finishFade()
        stopNode()
        stopStream()
        upcoming = nil
        current = nil
        streamError = nil
        _ = AudioDevices.setHog(deviceID, false)
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral   // faster speech without chipmunk voices
        var playback: SystemPlayback?
        playback = SystemPlayback(item: item, deviceUID: deviceUID, onFailed: { [weak self] error in
            guard let self, self.episode === playback else { return }
            let err = Self.friendly(error)
            self.stop()
            self.streamError = err
            self.onStreamChange?()
        }, onStatus: { [weak self] status in
            guard let self, self.episode === playback else { return }
            self.isBuffering = status == .waitingToPlayAtSpecifiedRate
        }, onEnd: { [weak self] in
            guard let self, self.episode === playback else { return }
            self.stopEpisode()
            self.state = .stopped
            self.onTrackFinished?()
        })
        guard let p = playback?.player else { return }
        p.defaultRate = rate                        // play() uses it
        episode = playback
        episodeDurationHint = duration ?? 0
        applyGainStage()
        isBuffering = true
        if start > 0 { p.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
        p.play()
        state = .playing
        scheduleIdleStop()
        onStreamChange?()
    }

    private func stopEpisode() {
        episode?.stop()
        episode = nil
        episodeDurationHint = 0
    }

    private func stopSystemStream() {
        system?.stop()
        system = nil
        systemMetadata = nil
        systemInfo = nil
    }

    /// The format the player is connected with for the current engine stream (nil until the station's format
    /// is known). Buffers are only scheduled when they match it: AVAudioPlayerNode throws on a channel mismatch.
    private var streamFormat: AVAudioFormat?
    /// The stream's details as last handed over on the main thread (the source itself updates its own copy
    /// on the network queue: reading that from here was a data race).
    private var mainStreamInfo = StreamSource.Info()

    /// Bumped whenever the stream is stopped or started anew: a reconnect scheduled before that is stale.
    private var reconnectToken = 0
    /// Which connection `stream` is: callbacks from an earlier one (still queued for the main thread) are dropped.
    private var streamConnection = 0

    private func isCurrentStream(_ connection: Int) -> Bool { stream != nil && streamConnection == connection }

    private func openStream(_ url: URL) {
        stream?.stop()   // never two connections: an old one would keep downloading and decoding unseen
        let src = StreamSource(url: url)
        stream = src
        streamConnection += 1
        let connection = streamConnection
        endedByItself = false
        streamFormat = nil
        mainStreamInfo = StreamSource.Info()
        connectionPlayingSince = nil
        streamStarted = false
        stalled = false
        // Per connection: completions of an earlier connection's buffers must not count against this one.
        let bufferedFrames = OSAllocatedUnfairLock(initialState: AVAudioFramePosition(0))
        isBuffering = true
        // Callbacks arrive on the stream's own queue.
        src.onInfo = { [weak self] info in
            DispatchQueue.main.async { [self] in
                guard let self, self.isCurrentStream(connection) else { return }
                self.mainStreamInfo = info
                if info.sampleRate > 0, let f = AVAudioFormat(standardFormatWithSampleRate: info.sampleRate, channels: AVAudioChannelCount(max(1, info.channels))) {
                    self.connect(format: f)
                    self.streamFormat = f
                    self.startEngineIfNeeded()
                }
                self.onStreamChange?()
            }
        }
        src.onTitle = { [weak self] t in
            DispatchQueue.main.async { [self] in
                guard let self, self.isCurrentStream(connection) else { return }
                self.streamTitle = t
                self.onStreamChange?()
            }
        }
        src.onBuffer = { [weak self] buf in
            // Scheduled on the main thread, after onInfo has connected the player in the station's format
            // (same queue, so in order), and only while this is still the current stream.
            DispatchQueue.main.async { [self] in
                guard let self, self.isCurrentStream(connection), let f = self.streamFormat,
                      f.channelCount == buf.format.channelCount, f.sampleRate == buf.format.sampleRate else { return }
                let frames = AVAudioFramePosition(buf.frameLength)
                let total = bufferedFrames.withLock { $0 += frames; return $0 }
                // Called on the render thread once the buffer has been played.
                self.node.scheduleBuffer(buf) { @Sendable [weak self] in
                    let left = bufferedFrames.withLock { $0 -= frames; return $0 }
                    guard left <= 0 else { return }
                    DispatchQueue.main.async { [self] in
                        // Ran dry (nothing arrived meanwhile): hold the player until 2 s are queued again, instead
                        // of playing each piece the moment it arrives (choppy bursts on a flaky connection).
                        guard let self, self.isCurrentStream(connection), self.state == .playing,
                              bufferedFrames.withLock({ $0 }) <= 0 else { return }
                        self.isBuffering = true
                        self.stalled = true
                        self.node.pause()
                    }
                }
                // Start (or leave the stall) once 2 s are queued.
                guard Double(total) >= f.sampleRate * 2, self.state == .playing else { return }
                if !self.streamStarted {
                    self.streamStarted = true
                    self.startEngineIfNeeded()
                    guard self.playNode() else { return }
                    self.clockStart = CACurrentMediaTime()
                    self.connectionPlayingSince = CACurrentMediaTime()
                }
                if self.stalled {
                    self.stalled = false
                    guard self.playNode() else { return }
                }
                self.isBuffering = false
            }
        }
        src.onUnsupported = { [weak self] type in
            DispatchQueue.main.async { [self] in
                guard let self, self.isCurrentStream(connection), let u = self.streamURL else { return }
                NSLog("OmniAmp: %@ stream, using the system player", type)
                self.openSystemStream(u, codec: type.contains("mpegurl") ? "HLS" : (type.contains("opus") ? "OPUS" : "OGG"))
            }
        }
        src.onEnd = { [weak self] error in
            DispatchQueue.main.async { [self] in
                guard let self, self.isCurrentStream(connection), self.state == .playing else { return }
                // Dropped connection: retry a few times before giving up. A connection that played for a
                // while earns the retries back (a long session can see several unrelated drops).
                if let t = self.connectionPlayingSince, CACurrentMediaTime() - t > 60 { self.reconnects = 0 }
                if self.reconnects < 3, let u = self.streamURL {
                    self.reconnects += 1
                    NSLog("OmniAmp: stream ended (%@), reconnecting (%d/3)", error?.localizedDescription ?? "closed", self.reconnects)
                    self.stopNode()
                    self.stopStream(keepState: true)
                    let token = self.reconnectToken
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        // Stop → Play of the same station in the meantime already connected again.
                        guard self.reconnectToken == token, self.state == .playing, self.streamURL == u else { return }
                        self.openStream(u)
                    }
                } else {
                    // Give up: stop and say why (don't skip to the next playlist entry like a finished file).
                    NSLog("OmniAmp: stream failed: %@", error?.localizedDescription ?? "closed")
                    self.stop()
                    self.streamError = Self.friendly(error)
                    self.onStreamChange?()
                }
            }
        }
        src.start()
    }

    /// Short, human message for a failed station.
    nonisolated static func friendly(_ error: Error?) -> String {
        guard let e = error else { return "station closed the connection" }
        if let u = e as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost: return "no internet connection"
            case .cannotFindHost, .dnsLookupFailed: return "station not found"
            case .timedOut: return "station not responding"
            case .appTransportSecurityRequiresSecureConnection: return "insecure connection blocked"
            default: break
            }
        }
        return e.localizedDescription
    }

    private func stopStream(keepState: Bool = false) {
        if !keepState { reconnectToken += 1 }
        stream?.stop()
        stream = nil
        streamFormat = nil
        stopSystemStream()
        stopEpisode()
        if !keepState { streamURL = nil; isBuffering = false }
    }

    // MARK: Output info

    /// The device we play to. Kept ourselves: after a configuration change the engine's output unit can
    /// report no device, so it is re-pointed at this one before every restart.
    private(set) var deviceID: AudioDeviceID = AudioDevices.defaultOutputID() { didSet { if deviceID != oldValue { watchDeviceVolume() } } }
    var deviceName: String { AudioDevices.device(id: deviceID)?.name ?? "Output" }
    var deviceRate: Double { AudioDevices.nominalRate(deviceID) }
    var selectedOutputUID: String? { outputUID }
    /// True when the current file reaches the device untouched.
    var isBitPerfectNow: Bool { bitPerfect && current != nil && deviceRate == sampleRate }

    // MARK: Setup

    init() {
        engine.attach(node)
        engine.attach(spare)
        engine.attach(converter)
        engine.attach(eq)
        for (i, f) in Equalizer.frequencies.enumerated() {
            let b = eq.bands[i]
            b.filterType = .parametric
            b.frequency = f
            b.bandwidth = 1.0
            b.gain = 0
            b.bypass = false
        }
        engine.connect(node, to: converter, format: nil)
        rebuildGraph()
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
        AudioDevices.observeDeviceChanges { [weak self] in self?.devicesChanged() }
        engine.prepare()
    }

    /// Make sure the engine's output unit talks to `deviceID`.
    private func bindOutputUnit() {
        let au = engine.outputNode.auAudioUnit
        guard deviceID != 0, au.deviceID != deviceID else { return }
        do { try au.setDeviceID(deviceID) } catch {
            NSLog("OmniAmp: cannot use output device %d: %@", deviceID, error.localizedDescription)
        }
    }

    /// (Re)connects converter → EQ → mixer → output at the device's current rate and reinstalls the taps.
    private func rebuildGraph() {
        let hwRate = AudioDevices.nominalRate(deviceID)
        let rate = hwRate > 0 ? hwRate : max(engine.outputNode.outputFormat(forBus: 0).sampleRate, 48000)
        guard let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        eq.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        spare.stop()   // readied again for the next track if needed
        engine.disconnectNodeOutput(converter)
        engine.disconnectNodeOutput(eq)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(converter, to: eq, format: f)
        engine.connect(eq, to: engine.mainMixerNode, format: f)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: f)
        graphRate = rate
        tapFormat = f
        if analyzerActive { installAnalyzerTap() }
        if ProcessInfo.processInfo.environment["OMNIAMP_NO_IOBUF"] == nil { AudioDevices.setIOBufferFrames(deviceID, 2048) }
        if let path = recordPath {
            // Test hook: record exactly what goes to the device, one file per rate.
            let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("\(Int(rate)).caf")
            if recorders[rate] == nil { recorders[rate] = try? AVAudioFile(forWriting: url, settings: f.settings) }
            let rec = recorders[rate]
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: f) { @Sendable buf, _ in try? rec?.write(from: buf) }
        }
        applyMixState()
    }

    /// Called by the display clock: add/remove the analyzer tap so hidden playback does no analysis at all.
    func setAnalyzerActive(_ on: Bool) {
        spectrum.isEnabled = on
        guard on != analyzerActive else { return }
        analyzerActive = on
        if on { installAnalyzerTap() } else { eq.removeTap(onBus: 0); spectrum.reset() }
    }

    private func installAnalyzerTap() {
        guard let f = tapFormat else { return }
        eq.removeTap(onBus: 0)
        // After the EQ, before the volume (like Winamp).
        eq.installTap(onBus: 0, bufferSize: 2048, format: f) { @Sendable [spectrum] buf, _ in spectrum.process(buf) }   // render thread
    }

    /// ReplayGain for the current track (linear). Ignored in bit-perfect mode, which must not alter samples.
    var replayGain: Float = 1 { didSet { applyGainStage() } }
    /// Fade multiplier (sleep timer fade-out).
    var fadeGain: Float = 1 { didSet { applyGainStage() } }

    private func applyGainStage() {
        converter.outputVolume = (bitPerfect ? 1 : replayGain) * fadeGain * transitionGain
        // The system player (HLS/Opus radio) bypasses our mixer: give it the volume directly.
        systemPlayer?.volume = (bitPerfect ? 1 : (testVolume ?? Self.loudness(softwareVolume))) * fadeGain
        episodePlayer?.volume = (bitPerfect ? 1 : (testVolume ?? Self.loudness(softwareVolume))) * fadeGain
    }

    /// The volume slider is a position, not a gain: cubed, it follows loudness (50 % ≈ −18 dB, 80 % ≈ −6 dB)
    /// instead of crowding everything audible into the bottom quarter.
    nonisolated static func loudness(_ position: Float) -> Float {
        let p = max(0, min(1, position))
        return p * p * p
    }

    // MARK: Click-free transitions

    // Cutting audio mid-wave clicks. The mixer spreads a volume change evenly over the next render cycle, so a
    // fade is: set the level, let one cycle render (≈ 85 ms at our IO buffer size), then pause/stop/seek.
    // Starting again fades in over the first cycle. Gapless changes between tracks are not touched.
    private var transitionGain: Float = 1
    private var fading = false
    private var afterFade: [() -> Void] = []
    private var fadeEpoch = 0

    /// How long rendered audio takes to reach the speakers (the output's buffers and the device's own latency).
    private var outputLatency: Double { max(0, min(0.5, AudioDevices.outputLatency(deviceID))) }

    /// One render cycle of the output, a little more for safety.
    private var renderCycle: Double {
        let rate = graphRate > 0 ? graphRate : 48_000
        return min(0.2, max(0.02, Double(AudioDevices.ioBufferFrames(deviceID)) / rate * 1.2))
    }

    /// Fade the file/radio output to silence, then run `action` (right away if nothing is playing).
    private func fadeOut(then action: @escaping () -> Void) {
        if fading { afterFade.append(action); return }
        guard engine.isRunning, node.isPlaying else { action(); return }
        fading = true
        afterFade = [action]
        fadeEpoch += 1
        let epoch = fadeEpoch
        transitionGain = 0
        applyGainStage()
        DispatchQueue.main.asyncAfter(deadline: .now() + renderCycle) { [weak self] in
            guard let self, self.fadeEpoch == epoch else { return }
            self.finishFade()
        }
    }

    /// Run what waits for a fade now (something else needs the player at once: radio, a device change…).
    private func finishFade() {
        guard fading else { return }
        fading = false
        let actions = afterFade
        afterFade = []
        actions.forEach { $0() }
    }

    /// After a fade that is still running, else now.
    private func whenFaded(_ action: @escaping () -> Void) {
        if fading { afterFade.append(action) } else { action() }
    }

    private func fadeIn() {
        guard transitionGain != 1 else { return }
        transitionGain = 1
        applyGainStage()
    }

    /// EQ bypass and mixer volume for the current mode.
    private func applyMixState() {
        applyGainStage()
        eq.bypass = bitPerfect || !eqSettings.enabled
        eq.globalGain = eqSettings.preamp
        for (i, g) in eqSettings.bands.prefix(eq.bands.count).enumerated() { eq.bands[i].gain = g }
        engine.mainMixerNode.outputVolume = bitPerfect ? 1 : (testVolume ?? Self.loudness(softwareVolume))
    }

    // MARK: EQ

    func apply(_ settings: Equalizer.Settings) {
        eqSettings = settings
        applyMixState()
    }

    // MARK: Output device & bit-perfect

    /// nil = follow the system default output.
    func setOutputDevice(uid: String?) {
        outputUID = uid
        pointEngineAtDevice()   // no-op if it resolves to the device already in use (keeps hog and rate)
    }

    func setBitPerfect(_ on: Bool, exclusive excl: Bool) {
        let changedMode = on != bitPerfect
        bitPerfect = on
        exclusive = excl
        if !on { releaseDevice(deviceID) }
        if on { updateHog() }
        if changedMode { reconfigureKeepingPosition(matchRate: on) }
        applyMixState()
        onOutputChange?()
    }

    /// Give back hog mode and the device's original sample rate.
    private func releaseDevice(_ id: AudioDeviceID) {
        _ = AudioDevices.setHog(id, false)
        if let r = originalRates.removeValue(forKey: id) {
                AudioDevices.setNominalRate(id, r)
        }
    }

    /// Call on quit.
    func shutdown() {
        finishFade()
        engine.stop()
        for id in Array(originalRates.keys) { releaseDevice(id) }
        _ = AudioDevices.setHog(deviceID, false)
    }

    private func pointEngineAtDevice() {
        finishFade()   // a device change takes the player now
        let target = outputUID.flatMap { AudioDevices.device(uid: $0)?.id } ?? AudioDevices.defaultOutputID()
        guard target != 0, target != deviceID else { return }
        let t = currentTime, wasState = state
        engine.stop()
        releaseDevice(deviceID)   // exclusive access and a switched rate stay behind otherwise
        deviceID = target
        restart(at: t, wasState: wasState, matchRate: bitPerfect)
        // The system players (HLS/Opus radio, podcast episodes) play outside the engine: move them too.
        let deviceUID = AudioDevices.device(id: deviceID)?.uid
        systemPlayer?.audioOutputDeviceUniqueID = deviceUID
        episodePlayer?.audioOutputDeviceUniqueID = deviceUID
        onOutputChange?()
    }

    /// In bit-perfect mode: switch the device to the file's rate (or the best it supports). Engine must be stopped.
    private func matchDeviceRate(to fileRate: Double) {
        let id = deviceID
        guard let target = AudioDevices.bestRate(for: fileRate, supported: AudioDevices.availableRates(id)) else { return }
        let now = AudioDevices.nominalRate(id)
        guard target != now else { return }
        if originalRates[id] == nil { originalRates[id] = now }
        let ok = AudioDevices.setNominalRate(id, target)
        NSLog("OmniAmp: output rate %.0f → %.0f Hz (file %.0f Hz)%@", now, target, fileRate, ok ? "" : " FAILED")
    }

    private func reconfigureKeepingPosition(matchRate: Bool) {
        let t = currentTime, wasState = state
        engine.stop()
        if !matchRate {
            for id in Array(originalRates.keys) { releaseDevice(id) }
        }
        restart(at: t, wasState: wasState, matchRate: matchRate)
    }

    /// Rebuild the graph (optionally matching the current file's rate) and resume where we were.
    private func restart(at t: Double, wasState: State, matchRate: Bool) {
        finishFade()
        if engine.isRunning { engine.stop() }
        bindOutputUnit()
        if matchRate, current != nil { matchDeviceRate(to: sampleRate) }
        rebuildGraph()
        if let f = current?.file { connect(format: f.processingFormat) }
        // Radio through our engine: the stopped engine dropped its queued audio, so reconnect the station
        // (without this it stayed silent while showing "playing").
        if stream != nil, let u = streamURL {
            stopNode()
            stopStream(keepState: true)
            if wasState == .playing { openStream(u) }
            return
        }
        guard current != nil, wasState != .stopped else { return }
        state = .playing
        seek(to: t)
        if wasState == .paused { pause() }
    }

    /// The engine stops itself whenever the device format changes, including after our own rate switches,
    /// so always rebuild and resume here.
    private func engineConfigurationChanged() {
        finishFade()
        dlog("configChange awaiting=\(awaitingRateSettle) running=\(engine.isRunning) rate=\(deviceRate)")
        if awaitingRateSettle {
            // Expected: the device finished switching rate / taking exclusive access.
            settleComplete()
            return
        }
        if idled, !engine.isRunning {
            // Idle, e.g. the device reconfigured after we gave back exclusive access: just rebuild, stay stopped.
            bindOutputUnit()
            rebuildGraph()
            if let f = current?.file { connect(format: f.processingFormat) }
            onOutputChange?()
            return
        }
        NSLog("OmniAmp: audio configuration changed (device %.0f Hz), restarting", deviceRate)
        // Bit-perfect: back to the track's rate (the DAC reset itself after sleep, say), but not again and again
        // if another app keeps setting its own.
        let rematch = bitPerfect && Date().timeIntervalSince(lastRateRematch) > 10
        if rematch { lastRateRematch = Date() }
        restart(at: currentTime, wasState: state, matchRate: rematch)
        onOutputChange?()
    }

    private func devicesChanged() {
        // Follow the system default, or fall back to it if the chosen device disappeared.
        if let uid = outputUID, AudioDevices.device(uid: uid) == nil { outputUID = nil }
        pointEngineAtDevice()
        onOutputChange?()
    }

    // MARK: Transport

    /// Files are opened off the main thread: over a network share (or for a long MP3, which is scanned) that
    /// takes up to a second, and the app must not stall meanwhile. A new `play` or `stop` makes a pending
    /// open moot.
    private static let opener = DispatchQueue(label: "omniamp.open", qos: .userInitiated)
    private var openToken = 0 { didSet { let t = openToken; wantedOpen.withLock { $0 = t } } }
    /// `openToken` for the opener queue: files queued for opening that were skipped past meanwhile (pressing Next
    /// several times on a slow share) aren't opened at all, one after the other, before the one wanted.
    private let wantedOpen = OSAllocatedUnfairLock(initialState: 0)
    /// A file for `play` is being opened (Play/Pause still work meanwhile).
    private var opening = false
    /// A file opened ahead of time for what will probably play next (Next, the end of the track): starting it
    /// then needs no open, which over a network share is most of the wait.
    private var prepared: (url: URL, file: AVAudioFile)?
    private var preparing: URL?

    /// Open `url` in the background so a following `play(url:)` starts without waiting for it.
    func prepare(_ url: URL?) {
        guard let url, url.isFileURL else { prepared = nil; preparing = nil; return }
        guard prepared?.url != url, preparing != url else { return }
        prepared = nil
        preparing = url
        Self.opener.async { [weak self] in
            let file = try? AVAudioFile(forReading: url)
            DispatchQueue.main.async { [self] in
                guard let self, self.preparing == url else { return }
                self.preparing = nil
                if let file { self.prepared = (url, file) }
            }
        }
    }

    /// Play a file, optionally starting at `start` seconds (resume position). `range`: the track's slice of
    /// the file in seconds (CUE tracks). The old track stops at once; `opened` says (on the main thread)
    /// whether the new one could be played.
    func play(url: URL, from start: Double = 0, range: (start: Double, end: Double?)? = nil,
              opened: @escaping @Sendable @MainActor (Bool) -> Void = { _ in }) {
        // The old track fades out while the new file opens; the new one starts once both are done. After a track
        // that ended by itself there's nothing to fade (its tail is already past the mixer), and its player keeps
        // running, empty: the next track goes onto it (or the spare) and sounds right away.
        if stream == nil, state == .playing { fadeOut { [weak self] in self?.stopNode() } }
        else if stream == nil, endedByItself, node.isPlaying { finishFade(); generation += 1 }
        else { finishFade(); stopNode() }
        endedByItself = false
        stopStream()
        upcoming = nil
        pendingNext = nil
        awaitingRateSettle = false   // a new track: any earlier wait is over (a new one starts below if needed)
        current = nil
        clockBase = 0
        clockStart = nil
        state = .playing
        openToken += 1
        let token = openToken
        if let p = prepared, p.url == url {
            prepared = nil   // opened ahead of time: start right away
            opening = false
            whenFaded { [weak self] in
                guard let self, token == self.openToken else { return }
                opened(self.start(p.file, url: url, from: start, range: range))
            }
            return
        }
        opening = true
        let wanted = wantedOpen
        Self.opener.async { [weak self] in
            guard wanted.withLock({ $0 }) == token else { return }   // another track (or stop) came since
            let file: AVAudioFile?
            do { file = try AVAudioFile(forReading: url) } catch {
                NSLog("OmniAmp: cannot open %@: %@", url.path, error.localizedDescription)
                file = nil
            }
            DispatchQueue.main.async { [self] in
                guard let self, token == self.openToken else { return }   // another track (or stop) came since
                self.opening = false
                guard let file else { self.state = .stopped; opened(false); return }
                self.whenFaded { [weak self] in
                    guard let self, token == self.openToken else { return }
                    opened(self.start(file, url: url, from: start, range: range))
                }
            }
        }
    }

    /// The file is open: set the device up for it and start it.
    private func start(_ file: AVAudioFile, url: URL, from start: Double, range: (start: Double, end: Double?)?) -> Bool {
        let item = Item(id: nextItemID, file: file, url: url, range: range, offset: start)
        // No audio in it (a header-only or cut-off download, a CUE range past the end): nothing would ever finish,
        // so it would show "playing" forever. Unplayable instead, like a file that doesn't open.
        guard item.trackEnd > item.trackStart else {
            NSLog("OmniAmp: no audio in %@", url.path)
            state = .stopped
            return false
        }
        var settle = false
        if bitPerfect, AudioDevices.bestRate(for: file.fileFormat.sampleRate, supported: AudioDevices.availableRates(deviceID)) != graphRate {
            engine.stop()
            bindOutputUnit()
            let before = AudioDevices.nominalRate(deviceID)
            matchDeviceRate(to: file.fileFormat.sampleRate)
            settle = AudioDevices.nominalRate(deviceID) != before
            rebuildGraph()
            onOutputChange?()
        }
        connect(format: file.processingFormat)
        current = item
        nextItemID += 1
        // The start offset, already while a rate switch settles: pausing then must not lose the resume point.
        clockBase = current.map { Double($0.startFrame - $0.trackStart) / $0.sampleRate } ?? 0
        clockStart = nil
        // Paused while it opened: scheduled, ready to go; resume() starts it.
        if state == .playing { if settle { awaitSettle() } else { beginPlayback() } } else { scheduleCurrent() }
        return true
    }

    private func beginPlayback() {
        dlog("beginPlayback engineRunning=\(engine.isRunning) state=\(state)")
        // Taking exclusive access reconfigures the device too: wait for that before any audio goes out.
        if startEngineIfNeeded() { awaitSettle(); return }
        scheduleCurrent()
        if state == .playing, playNode() { startClock() }   // paused while waiting: resume() starts it
    }

    /// Wait for the configuration change that follows a rate switch / hog grab (or give up after 0.8 s).
    private func awaitSettle() {
        dlog("awaitSettle")
        awaitingRateSettle = true
        settleToken += 1
        let token = settleToken
        // OMNIAMP_SETTLE_TIMEOUT (test hook) shortens the wait to force the timeout path.
        let wait = ProcessInfo.processInfo.environment["OMNIAMP_SETTLE_TIMEOUT"].flatMap(Double.init) ?? 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.awaitingRateSettle, self.settleToken == token else { return }
            dlog("settle timeout → start")
            self.settleComplete()
        }
    }

    /// The device finished (or we stopped waiting for) a reconfiguration: rebuild the graph from scratch
    /// either way. Resuming on the old connections can render digital silence after a hog/rate change.
    private func settleComplete() {
        finishFade()
        awaitingRateSettle = false
        if engine.isRunning { engine.stop() }
        // Stopping the engine drops everything scheduled: a queued gapless track has to be queued again.
        if upcoming != nil { upcoming = nil; onPreloadDropped?() }
        bindOutputUnit()
        rebuildGraph()
        if let f = current?.file { connect(format: f.processingFormat) }
        beginPlayback()
        onOutputChange?()
    }

    /// The queued track's file being opened (a token: cancelling or playing something else drops it).
    private var pendingNext: Int?
    private var nextToken = 0

    /// Schedule `url` to start exactly when the current track ends. `queued` says (on the main thread)
    /// whether it could: not if it's unreadable or in another format (the normal end-of-track path plays it
    /// then). `tag`: the caller's name for it (`currentTag` once it plays).
    func queueNext(url: URL, range: (start: Double, end: Double?)? = nil, tag: String? = nil, queued: @escaping @Sendable @MainActor (Bool) -> Void) {
        // Not while the device settles: the restart that follows would drop it, and it could land first.
        guard current != nil, upcoming == nil, pendingNext == nil, state != .stopped, !awaitingRateSettle else { queued(false); return }
        nextToken += 1
        let token = nextToken, playing = openToken
        pendingNext = token
        let wanted = wantedOpen
        Self.opener.async { [weak self] in
            guard wanted.withLock({ $0 }) == playing else { return }   // another track started meanwhile
            let file = try? AVAudioFile(forReading: url)
            DispatchQueue.main.async { [self] in
                guard let self, self.pendingNext == token, self.openToken == playing else { return }   // taken back meanwhile
                self.pendingNext = nil
                guard let file, let c = self.current, self.state != .stopped, !self.awaitingRateSettle else { queued(false); return }
                let a = file.processingFormat, b = c.file.processingFormat
                guard a.sampleRate == b.sampleRate, a.channelCount == b.channelCount, a.commonFormat == b.commonFormat else {
                    // Another format: not behind this track, but the spare player gets ready for it (see `spare`).
                    self.readySpare(for: a)
                    queued(false)
                    return
                }
                var item = Item(id: self.nextItemID, file: file, url: url, range: range, offset: 0)
                item.tag = tag
                self.nextItemID += 1
                self.upcoming = item
                self.schedule(item, gen: self.generation)
                queued(true)
            }
        }
    }

    /// Drop a queued track (e.g. the playlist order changed).
    func cancelQueuedNext() {
        pendingNext = nil   // still opening: it will never be queued
        guard upcoming != nil else { return }
        let t = currentTime
        upcoming = nil
        if state != .stopped { seek(to: t) } // reschedules only the current track
    }

    /// Paused, stopped, or playing outside the engine (podcasts, HLS radio) for a few seconds: stop the engine.
    /// A running output costs battery, and in exclusive mode it keeps the device from every other app.
    private var idleStop: DispatchWorkItem?
    private func scheduleIdleStop() {
        idleStop?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.engine.isRunning, !self.awaitingRateSettle,
                  self.state != .playing || self.episodePlayer != nil || self.systemPlayer != nil else { return }
            dlog("idle: stopping the engine")
            self.idled = true
            self.engine.stop()
            _ = AudioDevices.setHog(self.deviceID, false)
            if self.upcoming != nil { self.upcoming = nil; self.onPreloadDropped?() }
        }
        idleStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    /// The engine was stopped for idling (not by a device change): nothing to restart.
    private var idled = false

    /// The queued gapless track was dropped (the engine idled out while paused): queue it again.
    var onPreloadDropped: (() -> Void)?

    func pause() {
        guard state == .playing else { return }
        defer { scheduleIdleStop() }
        if let p = episodePlayer { p.pause(); state = .paused; return }
        if isStreaming {
            // Radio: pausing stops the stream (a live broadcast can't be paused); play restarts it.
            let u = streamURL
            stopNode()
            stopStream()
            streamURL = u
            freezeClock()
            state = .paused
            return
        }
        state = .paused
        fadeOut { [weak self] in
            guard let self, self.state == .paused else { return }   // resumed meanwhile
            self.node.pause()
            self.freezeClock()
        }
    }

    func resume() {
        guard state == .paused else { return }
        if let p = episodePlayer { p.play(); state = .playing; return }
        if let u = streamURL, !isStreaming { playStream(url: u); return }
        if current == nil {
            if opening { state = .playing }   // resumed while the file opens: it starts when it's ready
            return
        }
        if !engine.isRunning, var c = current {
            // The engine idled out while paused and dropped the schedule: start again where we paused.
            c.startFrame = min(c.trackStart + AVAudioFramePosition((Sane.offset(clockBase) ?? 0) * c.sampleRate), max(c.trackStart, c.trackEnd - 1))
            current = c
            stopNode()
            state = .playing
            // Bit-perfect: while idle another app may have changed the device rate: match the file again.
            let fileRate = c.file.fileFormat.sampleRate
            if bitPerfect, AudioDevices.bestRate(for: fileRate, supported: AudioDevices.availableRates(deviceID)) != graphRate {
                bindOutputUnit()
                let before = AudioDevices.nominalRate(deviceID)
                matchDeviceRate(to: fileRate)
                rebuildGraph()
                connect(format: c.file.processingFormat)
                onOutputChange?()
                if AudioDevices.nominalRate(deviceID) != before { awaitSettle(); return }
            }
            beginPlayback()
            return
        }
        state = .playing
        whenFaded { [weak self] in
            guard let self, self.state == .playing, self.current != nil else { return }
            if self.node.isPlaying { self.fadeIn(); return }   // resumed during the pause's fade: just come back up
            self.startEngineIfNeeded()
            guard self.playNode() else { return }
            if !self.awaitingRateSettle { self.clockStart = CACurrentMediaTime() }
        }
    }

    func stop() {
        openToken += 1   // a file still being opened won't start
        opening = false
        endedByItself = false
        pendingNext = nil
        awaitingRateSettle = false
        if stream == nil { fadeOut { [weak self] in self?.stopNode() } } else { finishFade(); stopNode() }
        stopStream()
        upcoming = nil
        if var c = current { c.startFrame = c.trackStart; current = c }
        clockBase = 0
        clockStart = nil
        state = .stopped
        spectrum.reset()
        scheduleIdleStop()
    }

    func seek(to seconds: Double) {
        if let p = episodePlayer {
            p.seek(to: CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 600))
            return
        }
        guard !isStreaming, let c = current else { return }   // live radio can't seek
        awaitingRateSettle = false
        let frame = min(c.trackStart + AVAudioFramePosition((Sane.offset(min(seconds, duration)) ?? 0) * c.sampleRate),
                        max(c.trackStart, c.trackEnd - 1))
        // The clock shows the new place at once (not the old one for the length of the fade).
        clockBase = Double(frame - c.trackStart) / c.sampleRate
        clockStart = nil
        fadeOut { [weak self] in self?.seekNow(to: frame, itemID: c.id) }
    }

    private func seekNow(to frame: AVAudioFramePosition, itemID: Int) {
        guard var c = current, c.id == itemID else { return }   // another track started meanwhile
        let wasPaused = state == .paused
        stopNode()
        // A queued gapless track went with the schedule: have it queued again (near the end, gapless stays).
        if upcoming != nil || pendingNext != nil { upcoming = nil; pendingNext = nil; onPreloadDropped?() }
        c.startFrame = frame
        current = c
        clockStart = nil
        scheduleCurrent()
        if wasPaused {
            // Stay paused: the clock shows the new place and resume() plays from there. (Playing and pausing
            // again flickered the state, could leak a moment of audio and woke an idle engine.)
            clockBase = Double(c.startFrame - c.trackStart) / c.sampleRate
            return
        }
        startEngineIfNeeded()
        guard playNode() else { return }
        startClock()
        state = .playing
    }

    // MARK: Scheduling

    private func scheduleCurrent() {
        guard let c = current, c.frames > 0 else { return }
        generation += 1
        schedule(c, gen: generation)
    }

    /// Queue an item on the node. A segment's length is 32-bit (4.29e9 frames: 27 h at 44.1 kHz, 6 h at
    /// 192 kHz), so a longer track goes in back-to-back pieces (sample-contiguous, like gapless tracks);
    /// only the last one reports the end.
    private func schedule(_ item: Item, gen: Int) {
        let pieces = Self.segments(from: item.startFrame, count: item.frames)
        let id = item.id
        for (i, p) in pieces.enumerated() {
            let last = i == pieces.count - 1
            // .dataRendered: the end is known once the last audio has gone through the mixer, while it is still on
            // its way to the speakers. A next track that can't be queued behind this one (another format) starts
            // then, right behind it, instead of after the tail has played out (a quarter-second gap before).
            // (Two plain calls: with the handler chosen inline, Swift 6.4's strict concurrency checking crashes.)
            if last {
                node.scheduleSegment(item.file, startingFrame: p.start, frameCount: p.frames, at: nil,
                                     completionCallbackType: .dataRendered, completionHandler: Self.segmentDone(self, gen: gen, id: id))
            } else {
                node.scheduleSegment(item.file, startingFrame: p.start, frameCount: p.frames, at: nil)
            }
        }
    }

    /// The render thread's "segment done" call, handed to the main thread. Made outside the player's (main-thread)
    /// code, so it can't be taken for main-thread code itself.
    nonisolated private static func segmentDone(_ player: AudioPlayer, gen: Int, id: Int)
        -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak player] _ in
            DispatchQueue.main.async { [player] in player?.segmentFinished(gen: gen, id: id) }
        }
    }

    /// `count` frames from `start`, in pieces a segment can hold (at most `limit` frames each).
    nonisolated static func segments(from start: AVAudioFramePosition, count: AVAudioFramePosition,
                         limit: AVAudioFramePosition = AVAudioFramePosition(AVAudioFrameCount.max))
        -> [(start: AVAudioFramePosition, frames: AVAudioFrameCount)] {
        var out: [(start: AVAudioFramePosition, frames: AVAudioFrameCount)] = []
        var at = start, left = max(0, count)
        repeat {
            let n = min(left, limit)
            out.append((at, AVAudioFrameCount(n)))
            at += n
            left -= n
        } while left > 0
        return out
    }

    /// A scheduled segment has been rendered: its last audio is on the way out of the speakers.
    private func segmentFinished(gen: Int, id: Int) {
        guard gen == generation, state == .playing, current?.id == id else { return }
        // The engine stopping (device change, reconfiguration) also completes the schedule: that's not the end
        // of the track unless we really are there.
        guard engine.isRunning || currentTime >= duration - 1 else { return }
        if let next = upcoming {
            current = next
            upcoming = nil
            clockBase = 0
            // The previous track's tail is still playing out: the new one is heard once it has.
            clockStart = CACurrentMediaTime() + outputLatency
            onGaplessAdvance?()
        } else {
            state = .stopped
            endedByItself = true
            onTrackFinished?()
            if state == .stopped { scheduleIdleStop() }
        }
    }

    private func connect(format: AVAudioFormat) {
        // Still running (the last track ended by itself) in this format: nothing to change, it plays on at once.
        if node.isPlaying, node.outputFormat(forBus: 0) == format { return }
        // The spare, running in this format already: it takes over, and the old player becomes the spare.
        if spare.isPlaying, spare.outputFormat(forBus: 0) == format {
            let old = node
            node = spare
            spare = old
            old.stop()
            dlog("spare player takes over (\(Int(format.sampleRate)) Hz)")
            return
        }
        // Player → converter in the file's own format; the converter resamples/upmixes only if needed.
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: converter, format: format)
    }

    /// Connect the spare player in the next track's format and start it, empty, while this track still plays
    /// (connecting it then doesn't disturb the running one). Not in bit-perfect mode: the device changes rate there.
    private func readySpare(for format: AVAudioFormat) {
        guard !bitPerfect, engine.isRunning, !(spare.isPlaying && spare.outputFormat(forBus: 0) == format) else { return }
        spare.stop()
        engine.disconnectNodeOutput(spare)
        engine.connect(spare, to: converter, fromBus: 0, toBus: converter.nextAvailableInputBus, format: format)
        spare.play()
        dlog("spare player ready (\(Int(format.sampleRate)) Hz)")
    }

    /// Start the player, but only on a running engine: AVAudioPlayerNode throws (crashes the app) otherwise.
    /// If the output can't start (another app holds the device exclusively, it was unplugged…), stop and say why.
    @discardableResult
    private func playNode() -> Bool {
        defer { fadeIn() }   // from silence after a fade: up over the first cycle
        guard engine.isRunning else {
            NSLog("OmniAmp: the audio output isn't running, stopping")
            stop()
            streamError = "The audio output couldn't start. Another app may be using the device exclusively."
            onStreamChange?()
            return false
        }
        node.play()
        return true
    }

    private func stopNode() {
        generation += 1 // invalidate pending completions
        node.stop()
    }

    /// Returns true if exclusive access was just taken (the device will reconfigure).
    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        guard !engine.isRunning else { let h = updateHog(); dlog("engine already running, hogTaken=\(h)"); return h }
        bindOutputUnit()
        dlog("engine.start()")
        do {
            try engine.start()
        } catch {
            // Exclusive access can stop the output unit from starting; fall back to shared mode.
            if AudioDevices.hogOwner(deviceID) == getpid() {
                _ = AudioDevices.setHog(deviceID, false)
                NSLog("OmniAmp: engine start failed in exclusive mode, retrying shared")
                do { try engine.start() } catch { NSLog("OmniAmp: engine start failed: %@", error.localizedDescription) }
            } else {
                NSLog("OmniAmp: engine start failed: %@", error.localizedDescription)
            }
            return false
        }
        idled = false
        let h = updateHog()
        dlog("engine started, hogTaken=\(h), running=\(engine.isRunning)")
        return h
    }

    /// Exclusive access is taken only while the engine runs (taking it before the first start makes
    /// the output unit fail to initialize) and released when leaving bit-perfect/exclusive.
    @discardableResult
    private func updateHog() -> Bool {
        let want = bitPerfect && exclusive
        let have = AudioDevices.hogOwner(deviceID) == getpid()
        guard want != have, !want || engine.isRunning else { return false }
        if !AudioDevices.setHog(deviceID, want) {
            if want { NSLog("OmniAmp: exclusive access unavailable (device busy)") }
            return false
        }
        return want
    }
}

/// Picks the song title out of the system player's timed metadata (ICY StreamTitle, ID3 in HLS…).
@MainActor
final class SystemMetadataDelegate: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    var onTitle: ((String) -> Void)?

    // Set up with `queue: .main`: called on the main thread.
    nonisolated func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                                    from track: AVPlayerItemTrack?) {
        let title = Self.title(in: groups)
        MainActor.assumeIsolated { if let title { onTitle?(title) } }
    }

    nonisolated private static func title(in groups: [AVTimedMetadataGroup]) -> String? {
        for item in groups.flatMap(\.items) {
            let key = (item.identifier?.rawValue ?? "").lowercased()
            let isTitle = item.commonKey == .commonKeyTitle || key.contains("streamtitle") || key.hasSuffix("/tit2")
            guard isTitle, let v = item.stringValue?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { continue }
            return v
        }
        return nil
    }
}
