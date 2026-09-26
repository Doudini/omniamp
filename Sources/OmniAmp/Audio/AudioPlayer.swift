import AVFoundation

/// AVAudioEngine-based player: gapless queueing, 10-band EQ, seek, volume and an output tap for the spectrum.
///
/// Gapless: near the end of a track the controller calls `queueNext(url:)`. If the next file has the same
/// format, it is scheduled right behind the current one on the same player node, so there is no gap.
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
    /// Converts any file format to the fixed stereo format the EQ runs in.
    private let converter = AVAudioMixerNode()
    private var current: Item?
    private var upcoming: Item?
    private var generation = 0
    private var testVolume: Float?

    let spectrum = SpectrumAnalyzer()
    private(set) var state: State = .stopped
    /// Track ended and nothing was queued.
    var onTrackFinished: (() -> Void)?
    /// Playback moved seamlessly into the queued track.
    var onGaplessAdvance: (() -> Void)?

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = testVolume ?? max(0, min(1, newValue)) }
    }

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

    init() {
        engine.attach(node)
        engine.attach(converter)
        engine.attach(eq)
        let hwRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let eqFormat = AVAudioFormat(standardFormatWithSampleRate: hwRate > 0 ? hwRate : 48000, channels: 2)
        engine.connect(node, to: converter, format: nil)
        engine.connect(converter, to: eq, format: eqFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: eqFormat)
        for (i, f) in Equalizer.frequencies.enumerated() {
            let b = eq.bands[i]
            b.filterType = .parametric
            b.frequency = f
            b.bandwidth = 1.0
            b.gain = 0
            b.bypass = false
        }
        // Tap after the EQ but before the volume, so the analyzer doesn't shrink with volume (like Winamp).
        // OMNIAMP_RECORD=<file.caf> also writes that signal to disk (used to test gapless playback).
        let env = ProcessInfo.processInfo.environment
        let recorder = env["OMNIAMP_RECORD"].flatMap { try? AVAudioFile(forWriting: URL(fileURLWithPath: $0), settings: eqFormat!.settings) }
        eq.installTap(onBus: 0, bufferSize: 2048, format: eqFormat) { [spectrum] buf, _ in
            spectrum.process(buf)
            try? recorder?.write(from: buf)
        }
        if let v = env["OMNIAMP_VOLUME"].flatMap(Float.init) { testVolume = v }
        engine.prepare()
    }

    // MARK: EQ

    func apply(_ settings: Equalizer.Settings) {
        eq.bypass = !settings.enabled
        eq.globalGain = settings.preamp
        for (i, g) in settings.bands.prefix(eq.bands.count).enumerated() { eq.bands[i].gain = g }
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
        connect(format: file.processingFormat)
        current = Item(file: file, url: url, startFrame: 0, nodeStart: 0)
        scheduleCurrent()
        startEngineIfNeeded()
        node.play()
        state = .playing
        return true
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
        stopNode()
        upcoming = nil
        if var c = current { c.startFrame = 0; c.nodeStart = 0; current = c }
        state = .stopped
        spectrum.reset()
    }

    func seek(to seconds: Double) {
        guard var c = current else { return }
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
        // Reconnect with the file's format so sample-rate changes are handled.
        // Player → converter in the file's own format; the converter resamples/upmixes for the EQ.
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: converter, format: format)
    }

    private func stopNode() {
        generation += 1 // invalidate pending completions
        node.stop()
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do { try engine.start() } catch { NSLog("OmniAmp: engine start failed: %@", error.localizedDescription) }
    }
}
