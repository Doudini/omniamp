import AVFoundation
import CoreAudio

/// AVAudioEngine-based player: gapless queueing, 10-band EQ, seek, volume, output device selection and a
/// bit-perfect mode, plus a tap for the spectrum.
///
/// Graph: player → converter (mixer) → EQ → main mixer → output device.
/// Gapless: near the end of a track the controller calls `queueNext(url:)`. If the next file has the same
/// format, it is scheduled right behind the current one on the same player node, so there is no gap.
/// Bit-perfect: the device is switched to each file's sample rate, the EQ is bypassed and the software
/// volume is pinned to 1.0, so samples reach the device unchanged (float32 carries 16/24-bit PCM exactly).
final class AudioPlayer {
    enum State { case stopped, playing, paused }

    private struct Item {
        let file: AVAudioFile
        let url: URL
        /// Frame in the file where playback of this item began (non-zero after a seek).
        var startFrame: AVAudioFramePosition
        /// Node sample time at which this item starts playing.
        var nodeStart: AVAudioFramePosition
        var frames: AVAudioFramePosition { file.length - startFrame }
    }

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

    // Test hooks (see README / memory): OMNIAMP_RECORD writes the final mix, OMNIAMP_VOLUME mutes.
    private let recordPath = ProcessInfo.processInfo.environment["OMNIAMP_RECORD"]
    private var recorders: [Double: AVAudioFile] = [:]
    private let testVolume = ProcessInfo.processInfo.environment["OMNIAMP_VOLUME"].flatMap(Float.init)

    let spectrum = SpectrumAnalyzer()
    private(set) var state: State = .stopped
    /// Track ended and nothing was queued.
    var onTrackFinished: (() -> Void)?
    /// Playback moved seamlessly into the queued track.
    var onGaplessAdvance: (() -> Void)?
    /// Output device / rate / mode changed (for UI).
    var onOutputChange: (() -> Void)?

    // MARK: Volume

    /// Volume used outside bit-perfect mode (persisted by the controller).
    var softwareVolume: Float = 0.8 {
        didSet { if !bitPerfect { engine.mainMixerNode.outputVolume = testVolume ?? softwareVolume } }
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
        return Double(c.file.length) / c.file.processingFormat.sampleRate
    }

    var currentTime: Double {
        guard let c = current else { return 0 }
        var frame = c.startFrame
        if state != .stopped, let nt = node.lastRenderTime, nt.isSampleTimeValid,
           let pt = node.playerTime(forNodeTime: nt) {
            frame += max(0, pt.sampleTime - c.nodeStart)
        }
        return min(Double(max(frame, 0)) / c.file.processingFormat.sampleRate, duration)
    }

    var remaining: Double { max(0, duration - currentTime) }
    var hasQueuedNext: Bool { upcoming != nil }
    var sampleRate: Double { current?.file.fileFormat.sampleRate ?? 0 }
    var channelCount: Int { Int(current?.file.fileFormat.channelCount ?? 0) }

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
        // Analyzer taps after the EQ, before the volume (like Winamp).
        eq.installTap(onBus: 0, bufferSize: 2048, format: f) { [spectrum] buf, _ in spectrum.process(buf) }
        if let path = recordPath {
            // Test hook: record exactly what goes to the device, one file per rate.
            let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("\(Int(rate)).caf")
            if recorders[rate] == nil { recorders[rate] = try? AVAudioFile(forWriting: url, settings: f.settings) }
            let rec = recorders[rate]
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: f) { buf, _ in try? rec?.write(from: buf) }
        }
        applyMixState()
    }

    /// EQ bypass and mixer volume for the current mode.
    private func applyMixState() {
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
        if awaitingRateSettle {
            // Expected: the device finished switching rate. Start the track fresh from the top.
            awaitingRateSettle = false
            bindOutputUnit()
            rebuildGraph()
            if let f = current?.file { connect(format: f.processingFormat) }
            beginPlayback()
            onOutputChange?()
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

    @discardableResult
    func play(url: URL) -> Bool {
        stopNode()
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
        current = Item(file: file, url: url, startFrame: 0, nodeStart: 0)
        state = .playing
        if settle { awaitSettle() } else { beginPlayback() }
        return true
    }

    private func beginPlayback() {
        // Taking exclusive access reconfigures the device too: wait for that before any audio goes out.
        if startEngineIfNeeded() { awaitSettle(); return }
        scheduleCurrent()
        if state == .playing { node.play() }   // paused while waiting: stay paused, resume() starts it
    }

    /// Wait for the configuration change that follows a rate switch / hog grab (or give up after 0.8 s).
    private func awaitSettle() {
        awaitingRateSettle = true
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.awaitingRateSettle, self.generation == gen else { return }
            self.awaitingRateSettle = false
            self.beginPlayback()
        }
    }

    /// Schedule `url` to start exactly when the current track ends. Returns false if it can't be gapless
    /// (different sample rate / channel count, unreadable), in which case the normal end-of-track path is used.
    @discardableResult
    func queueNext(url: URL) -> Bool {
        guard let c = current, upcoming == nil, state != .stopped else { return false }
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let a = file.processingFormat, b = c.file.processingFormat
        guard a.sampleRate == b.sampleRate, a.channelCount == b.channelCount, a.commonFormat == b.commonFormat else { return false }
        let item = Item(file: file, url: url, startFrame: 0, nodeStart: c.nodeStart + c.frames)
        upcoming = item
        let gen = generation
        node.scheduleSegment(file, startingFrame: 0, frameCount: AVAudioFrameCount(max(0, file.length)), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.segmentFinished(gen: gen, url: url) }
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
        node.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        startEngineIfNeeded()
        node.play()
        state = .playing
    }

    func stop() {
        awaitingRateSettle = false
        stopNode()
        upcoming = nil
        if var c = current { c.startFrame = 0; c.nodeStart = 0; current = c }
        state = .stopped
        spectrum.reset()
    }

    func seek(to seconds: Double) {
        guard var c = current else { return }
        awaitingRateSettle = false
        let wasPaused = state == .paused
        let frame = AVAudioFramePosition(max(0, min(seconds, duration)) * c.file.processingFormat.sampleRate)
        stopNode()
        upcoming = nil
        c.startFrame = min(frame, c.file.length)
        c.nodeStart = 0
        current = c
        scheduleCurrent()
        startEngineIfNeeded()
        node.play()
        state = .playing
        if wasPaused { node.pause(); state = .paused }
    }

    // MARK: Scheduling

    private func scheduleCurrent() {
        guard let c = current, c.frames > 0 else { return }
        generation += 1
        let gen = generation
        let url = c.url
        node.scheduleSegment(c.file, startingFrame: c.startFrame, frameCount: AVAudioFrameCount(c.frames), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.segmentFinished(gen: gen, url: url) }
        }
    }

    /// A scheduled segment finished playing out of the speakers.
    private func segmentFinished(gen: Int, url: URL) {
        guard gen == generation, state == .playing, current?.url == url else { return }
        if let next = upcoming {
            current = next
            upcoming = nil
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
        guard !engine.isRunning else { return updateHog() }
        bindOutputUnit()
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
        return updateHog()
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
