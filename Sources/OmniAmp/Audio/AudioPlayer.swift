import Accelerate
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

final class AudioPlayer {
    enum State { case stopped, playing, paused }

    /// A track being played: a whole file, or a slice of one (CUE sheet track).
    private struct Item {
        let id: Int
        let file: AVAudioFile
        let url: URL
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
            let ts = min(max(0, AVAudioFramePosition((range?.start ?? 0) * sr)), max(0, len - 1))
            let te = range?.end.map { min(len, max(ts + 1, AVAudioFramePosition($0 * sr))) } ?? len
            trackStart = ts
            trackEnd = te
            startFrame = min(ts + AVAudioFramePosition(max(0, offset) * sr), max(ts, te - 1))
        }
    }
    private var nextItemID = 1

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: Equalizer.frequencies.count)
    /// Converts any file format to the stereo format the EQ runs in (no-op when rates already match).
    private let converter = AVAudioMixerNode()
    private var current: Item?
    private var upcoming: Item?
    private var generation = 0

    // Output state.
    private var outputUID: String?                         // nil = follow the system default
    private(set) var bitPerfect = false
    private(set) var exclusive = false
    private var originalRates: [AudioDeviceID: Double] = [:]
    private var eqSettings = Equalizer.Settings()
    private var graphRate: Double = 0
    /// After we switch the device rate, the engine reports a configuration change a moment later and stops.
    /// Playback waits for that (or a timeout) instead of starting and then stuttering on the restart.
    private var awaitingRateSettle = false
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
            if !bitPerfect { engine.mainMixerNode.outputVolume = testVolume ?? softwareVolume }
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

    // MARK: Position

    var duration: Double {
        guard let c = current else { return 0 }
        return Double(c.trackEnd - c.trackStart) / c.sampleRate
    }

    var currentTime: Double {
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
    var hasQueuedNext: Bool { upcoming != nil }
    var sampleRate: Double { stream.map { $0.info.sampleRate } ?? current?.file.fileFormat.sampleRate ?? 0 }
    var channelCount: Int { stream.map { $0.info.channels } ?? Int(current?.file.fileFormat.channelCount ?? 0) }

    // MARK: Internet radio

    private var stream: StreamSource?
    private var streamURL: URL?
    private let bufferedFrames = OSAllocatedUnfairLock(initialState: AVAudioFramePosition(0))
    private var streamStarted = false
    private var reconnects = 0
    /// True while waiting for enough audio (start, or after the connection stalled).
    private(set) var isBuffering = false { didSet { if isBuffering != oldValue { onStreamChange?() } } }
    var isStreaming: Bool { stream != nil || systemPlayer != nil }
    var streamInfo: StreamSource.Info? { stream?.info ?? systemInfo }
    /// Latest "Artist - Title" from the station.
    private(set) var streamTitle: String?
    /// Why the last station stopped (shown instead of the title), cleared when a stream starts.
    private(set) var streamError: String?
    /// Title, info or buffering changed (main thread).
    var onStreamChange: (() -> Void)?

    /// Start an Icecast/SHOUTcast stream. Buffers ~2 s before sound starts.
    /// HLS and Ogg/Opus stations go to the system player (no EQ/visualizer for those).
    func playStream(url: URL) {
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

    // MARK: System player (HLS, Ogg/Opus)

    private var systemPlayer: AVPlayer?
    private var systemObservers: [NSKeyValueObservation] = []
    private var systemMetadata: AVPlayerItemMetadataOutput?
    private let systemMetaDelegate = SystemMetadataDelegate()
    private var systemInfo: StreamSource.Info?
    /// True while a station plays through the system player (EQ and visualizer don't apply).
    var usesSystemPlayer: Bool { systemPlayer != nil }

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
        let p = AVPlayer(playerItem: item)
        p.audioOutputDeviceUniqueID = AudioDevices.device(id: deviceID)?.uid
        systemPlayer = p
        var info = StreamSource.Info()
        let path = url.path.lowercased()
        info.codec = codec ?? (path.hasSuffix(".m3u8") || (codec ?? "").contains("mpegurl") ? "HLS" : (path.contains("opus") ? "OPUS" : "OGG"))
        systemInfo = info
        applyGainStage()
        isBuffering = true
        systemObservers = [
            item.observe(\.status, options: [.new]) { [weak self] it, _ in
                DispatchQueue.main.async {
                    guard let self, self.systemPlayer?.currentItem === it, it.status == .failed else { return }
                    self.stop()
                    self.streamError = Self.friendly(it.error)
                    self.onStreamChange?()
                }
            },
            p.observe(\.timeControlStatus, options: [.new]) { [weak self] pl, _ in
                DispatchQueue.main.async {
                    guard let self, self.systemPlayer === pl else { return }
                    let playing = pl.timeControlStatus == .playing
                    if playing, self.clockStart == nil { self.clockStart = CACurrentMediaTime() }
                    self.isBuffering = !playing && self.state == .playing
                }
            },
        ]
        p.play()
        onStreamChange?()
    }

    private func stopSystemStream() {
        systemObservers.removeAll()
        systemPlayer?.pause()
        systemPlayer = nil
        systemMetadata = nil
        systemInfo = nil
    }

    private func openStream(_ url: URL) {
        let src = StreamSource(url: url)
        stream = src
        streamStarted = false
        bufferedFrames.withLock { $0 = 0 }
        isBuffering = true
        src.onInfo = { [weak self, weak src] info in
            DispatchQueue.main.async {
                guard let self, let src, self.stream === src else { return }
                if info.sampleRate > 0, let f = AVAudioFormat(standardFormatWithSampleRate: info.sampleRate, channels: AVAudioChannelCount(max(1, info.channels))) {
                    self.connect(format: f)
                    self.startEngineIfNeeded()
                }
                self.onStreamChange?()
            }
        }
        src.onTitle = { [weak self, weak src] t in
            DispatchQueue.main.async {
                guard let self, self.stream === src else { return }
                self.streamTitle = t
                self.onStreamChange?()
            }
        }
        src.onBuffer = { [weak self, weak src] buf in
            guard let self, self.stream === src else { return }
            let frames = AVAudioFramePosition(buf.frameLength)
            let sr = buf.format.sampleRate
            let total = self.bufferedFrames.withLock { $0 += frames; return $0 }
            self.node.scheduleBuffer(buf) { [weak self] in
                guard let self else { return }
                let left = self.bufferedFrames.withLock { $0 -= frames; return $0 }
                if left <= 0 { DispatchQueue.main.async { if self.stream === src, self.state == .playing { self.isBuffering = true } } }
            }
            // Start (or leave the stall) once 2 s are queued.
            if Double(total) >= sr * 2 {
                DispatchQueue.main.async {
                    guard self.stream === src, self.state == .playing else { return }
                    if !self.streamStarted {
                        self.streamStarted = true
                        self.startEngineIfNeeded()
                        self.node.play()
                        self.clockStart = CACurrentMediaTime()
                    }
                    self.isBuffering = false
                }
            }
        }
        src.onUnsupported = { [weak self, weak src] type in
            DispatchQueue.main.async {
                guard let self, self.stream === src, let u = self.streamURL else { return }
                NSLog("OmniAmp: %@ stream, using the system player", type)
                self.openSystemStream(u, codec: type.contains("mpegurl") ? "HLS" : (type.contains("opus") ? "OPUS" : "OGG"))
            }
        }
        src.onEnd = { [weak self, weak src] error in
            DispatchQueue.main.async {
                guard let self, self.stream === src, self.state == .playing else { return }
                // Dropped connection: retry a few times before giving up.
                if self.reconnects < 3, let u = self.streamURL {
                    self.reconnects += 1
                    NSLog("OmniAmp: stream ended (%@), reconnecting (%d/3)", error?.localizedDescription ?? "closed", self.reconnects)
                    self.stopNode()
                    self.stopStream(keepState: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        guard self.state == .playing, self.streamURL == u else { return }
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
    static func friendly(_ error: Error?) -> String {
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
        stream?.stop()
        stream = nil
        stopSystemStream()
        if !keepState { streamURL = nil; isBuffering = false }
    }

    // MARK: Output info

    /// The device we play to. Kept ourselves: after a configuration change the engine's output unit can
    /// report no device, so it is re-pointed at this one before every restart.
    private(set) var deviceID: AudioDeviceID = AudioDevices.defaultOutputID()
    var deviceName: String { AudioDevices.device(id: deviceID)?.name ?? "Output" }
    var deviceRate: Double { AudioDevices.nominalRate(deviceID) }
    var selectedOutputUID: String? { outputUID }
    /// True when the current file reaches the device untouched.
    var isBitPerfectNow: Bool { bitPerfect && current != nil && deviceRate == sampleRate }

    // MARK: Setup

    init() {
        engine.attach(node)
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
            self?.engineConfigurationChanged()
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
        engine.disconnectNodeOutput(converter)
        engine.disconnectNodeOutput(eq)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(converter, to: eq, format: f)
        engine.connect(eq, to: engine.mainMixerNode, format: f)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: f)
        graphRate = rate
        tapFormat = f
        if analyzerActive { installAnalyzerTap() }
        if ProcessInfo.processInfo.environment["OMNIAMP_NO_IOBUF"] == nil { AudioDevices.setIOBufferFrames(deviceID, 4096) }
        if let path = recordPath {
            // Test hook: record exactly what goes to the device, one file per rate.
            let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("\(Int(rate)).caf")
            if recorders[rate] == nil { recorders[rate] = try? AVAudioFile(forWriting: url, settings: f.settings) }
            let rec = recorders[rate]
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: f) { buf, _ in try? rec?.write(from: buf) }
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
        eq.installTap(onBus: 0, bufferSize: 2048, format: f) { [spectrum] buf, _ in spectrum.process(buf) }
    }

    /// ReplayGain for the current track (linear). Ignored in bit-perfect mode, which must not alter samples.
    var replayGain: Float = 1 { didSet { applyGainStage() } }
    /// Fade multiplier (sleep timer fade-out).
    var fadeGain: Float = 1 { didSet { applyGainStage() } }

    private func applyGainStage() {
        converter.outputVolume = (bitPerfect ? 1 : replayGain) * fadeGain
        // The system player (HLS/Opus radio) bypasses our mixer: give it the volume directly.
        systemPlayer?.volume = (bitPerfect ? 1 : (testVolume ?? softwareVolume)) * fadeGain
    }

    /// EQ bypass and mixer volume for the current mode.
    private func applyMixState() {
        applyGainStage()
        eq.bypass = bitPerfect || !eqSettings.enabled
        eq.globalGain = eqSettings.preamp
        for (i, g) in eqSettings.bands.prefix(eq.bands.count).enumerated() { eq.bands[i].gain = g }
        engine.mainMixerNode.outputVolume = bitPerfect ? 1 : (testVolume ?? softwareVolume)
    }

    // MARK: EQ

    func apply(_ settings: Equalizer.Settings) {
        eqSettings = settings
        applyMixState()
    }

    // MARK: Output device & bit-perfect

    /// nil = follow the system default output.
    func setOutputDevice(uid: String?) {
        guard uid != outputUID || uid == nil else { return }
        releaseDevice(deviceID)
        outputUID = uid
        pointEngineAtDevice()
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
        engine.stop()
        for id in Array(originalRates.keys) { releaseDevice(id) }
        _ = AudioDevices.setHog(deviceID, false)
    }

    private func pointEngineAtDevice() {
        let target = outputUID.flatMap { AudioDevices.device(uid: $0)?.id } ?? AudioDevices.defaultOutputID()
        guard target != 0, target != deviceID else { return }
        let t = currentTime, wasState = state
        engine.stop()
        deviceID = target
        restart(at: t, wasState: wasState, matchRate: bitPerfect)
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
        if engine.isRunning { engine.stop() }
        bindOutputUnit()
        if matchRate, current != nil { matchDeviceRate(to: sampleRate) }
        rebuildGraph()
        if let f = current?.file { connect(format: f.processingFormat) }
        guard current != nil, wasState != .stopped else { return }
        state = .playing
        seek(to: t)
        if wasState == .paused { pause() }
    }

    /// The engine stops itself whenever the device format changes, including after our own rate switches,
    /// so always rebuild and resume here.
    private func engineConfigurationChanged() {
        dlog("configChange awaiting=\(awaitingRateSettle) running=\(engine.isRunning) rate=\(deviceRate)")
        if awaitingRateSettle {
            // Expected: the device finished switching rate / taking exclusive access.
            settleComplete()
            return
        }
        NSLog("OmniAmp: audio configuration changed (device %.0f Hz), restarting", deviceRate)
        restart(at: currentTime, wasState: state, matchRate: false)
        onOutputChange?()
    }

    private func devicesChanged() {
        // Follow the system default, or fall back to it if the chosen device disappeared.
        if let uid = outputUID, AudioDevices.device(uid: uid) == nil { outputUID = nil }
        pointEngineAtDevice()
        onOutputChange?()
    }

    // MARK: Transport

    /// Play a file, optionally starting at `start` seconds (resume position).
    @discardableResult
    /// `range`: the track's slice of the file in seconds (CUE tracks); `start`: offset within the track.
    func play(url: URL, from start: Double = 0, range: (start: Double, end: Double?)? = nil) -> Bool {
        stopNode()
        stopStream()
        upcoming = nil
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            NSLog("OmniAmp: cannot open %@: %@", url.path, error.localizedDescription)
            current = nil
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
        current = Item(id: nextItemID, file: file, url: url, range: range, offset: start)
        nextItemID += 1
        clockBase = 0
        clockStart = nil
        state = .playing
        if settle { awaitSettle() } else { beginPlayback() }
        return true
    }

    private func beginPlayback() {
        dlog("beginPlayback engineRunning=\(engine.isRunning) state=\(state)")
        // Taking exclusive access reconfigures the device too: wait for that before any audio goes out.
        if startEngineIfNeeded() { awaitSettle(); return }
        scheduleCurrent()
        if state == .playing { node.play(); startClock() }   // paused while waiting: resume() starts it
    }

    /// Wait for the configuration change that follows a rate switch / hog grab (or give up after 0.8 s).
    private func awaitSettle() {
        dlog("awaitSettle")
        awaitingRateSettle = true
        let gen = generation
        // OMNIAMP_SETTLE_TIMEOUT (test hook) shortens the wait to force the timeout path.
        let wait = ProcessInfo.processInfo.environment["OMNIAMP_SETTLE_TIMEOUT"].flatMap(Double.init) ?? 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.awaitingRateSettle, self.generation == gen else { return }
            dlog("settle timeout → start")
            self.settleComplete()
        }
    }

    /// The device finished (or we stopped waiting for) a reconfiguration: rebuild the graph from scratch
    /// either way. Resuming on the old connections can render digital silence after a hog/rate change.
    private func settleComplete() {
        awaitingRateSettle = false
        if engine.isRunning { engine.stop() }
        bindOutputUnit()
        rebuildGraph()
        if let f = current?.file { connect(format: f.processingFormat) }
        beginPlayback()
        onOutputChange?()
    }

    /// Schedule `url` to start exactly when the current track ends. Returns false if it can't be gapless
    /// (different sample rate / channel count, unreadable), in which case the normal end-of-track path is used.
    @discardableResult
    func queueNext(url: URL, range: (start: Double, end: Double?)? = nil) -> Bool {
        guard let c = current, upcoming == nil, state != .stopped else { return false }
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let a = file.processingFormat, b = c.file.processingFormat
        guard a.sampleRate == b.sampleRate, a.channelCount == b.channelCount, a.commonFormat == b.commonFormat else { return false }
        let item = Item(id: nextItemID, file: file, url: url, range: range, offset: 0)
        nextItemID += 1
        upcoming = item
        let gen = generation, id = item.id
        node.scheduleSegment(file, startingFrame: item.startFrame, frameCount: AVAudioFrameCount(max(0, item.frames)), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.segmentFinished(gen: gen, id: id) }
        }
        return true
    }

    /// Drop a queued track (e.g. the playlist order changed).
    func cancelQueuedNext() {
        guard upcoming != nil else { return }
        let t = currentTime
        upcoming = nil
        if state != .stopped { seek(to: t) } // reschedules only the current track
    }

    func pause() {
        guard state == .playing else { return }
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
        node.pause()
        freezeClock()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        if let u = streamURL, !isStreaming { playStream(url: u); return }
        startEngineIfNeeded()
        node.play()
        if !awaitingRateSettle { clockStart = CACurrentMediaTime() }
        state = .playing
    }

    func stop() {
        awaitingRateSettle = false
        stopNode()
        stopStream()
        upcoming = nil
        if var c = current { c.startFrame = c.trackStart; current = c }
        clockBase = 0
        clockStart = nil
        state = .stopped
        spectrum.reset()
    }

    func seek(to seconds: Double) {
        guard !isStreaming, var c = current else { return }   // live radio can't seek
        awaitingRateSettle = false
        let wasPaused = state == .paused
        let frame = c.trackStart + AVAudioFramePosition(max(0, min(seconds, duration)) * c.sampleRate)
        stopNode()
        upcoming = nil
        c.startFrame = min(frame, max(c.trackStart, c.trackEnd - 1))
        current = c
        clockStart = nil
        scheduleCurrent()
        startEngineIfNeeded()
        node.play()
        startClock()
        state = .playing
        if wasPaused { node.pause(); freezeClock(); state = .paused }
    }

    // MARK: Scheduling

    private func scheduleCurrent() {
        guard let c = current, c.frames > 0 else { return }
        generation += 1
        let gen = generation
        let id = c.id
        node.scheduleSegment(c.file, startingFrame: c.startFrame, frameCount: AVAudioFrameCount(c.frames), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.segmentFinished(gen: gen, id: id) }
        }
    }

    /// A scheduled segment finished playing out of the speakers.
    private func segmentFinished(gen: Int, id: Int) {
        guard gen == generation, state == .playing, current?.id == id else { return }
        if let next = upcoming {
            current = next
            upcoming = nil
            clockBase = 0
            clockStart = CACurrentMediaTime()   // the previous track just finished playing out
            onGaplessAdvance?()
        } else {
            state = .stopped
            onTrackFinished?()
        }
    }

    private func connect(format: AVAudioFormat) {
        // Player → converter in the file's own format; the converter resamples/upmixes only if needed.
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: converter, format: format)
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
final class SystemMetadataDelegate: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    var onTitle: ((String) -> Void)?

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        for item in groups.flatMap(\.items) {
            let key = (item.identifier?.rawValue ?? "").lowercased()
            let isTitle = item.commonKey == .commonKeyTitle || key.contains("streamtitle") || key.hasSuffix("/tit2")
            guard isTitle, let v = item.stringValue?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { continue }
            onTitle?(v)
            return
        }
    }
}
