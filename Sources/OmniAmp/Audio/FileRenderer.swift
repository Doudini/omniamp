import Accelerate
import AVFoundation
import CAtomics
import Darwin

/// Plays local files sample-exactly: a reader thread decodes ahead into a ring buffer, and the audio render
/// callback copies from it, counting every frame.
///
/// That count is the playback position (no clock estimates), and the boundary between a track and the one
/// queued behind it is a known frame: the next track's level (ReplayGain) applies from its first sample,
/// the switch is reported when it is heard, and a queued track can be taken back without touching the one
/// playing. Pausing, a stopped engine (idle, device change) or a slow disk only stop the count: playback
/// always continues from the exact frame it left off.
///
/// One renderer per audio format (rate, channels): gapless joins only happen within one format anyway.
/// Threads: the render callback never locks or allocates; the reader and the main thread share `lock`.
final class FileRenderer {
    /// A slice of a file to play: whole file, a CUE track, or from a resume/seek point.
    struct Item {
        let id: Int
        let url: URL
        let start: AVAudioFramePosition
        let end: AVAudioFramePosition
        /// ReplayGain: applied from the item's first frame.
        let gain: Float
        /// Already open (the player opened it to learn its format): read from here on, not opened again.
        var file: AVAudioFile? = nil
    }

    let format: AVAudioFormat
    private(set) var node: AVAudioSourceNode!
    /// The node's render callback (tests call it directly, without an audio device).
    private(set) var renderBlock: AVAudioSourceNodeRenderBlock!
    /// Output delay (device + safety offset), in seconds: the position is what is heard, not what was rendered.
    var latency: Double = 0

    /// Called on the main thread when a queued item starts to be heard / when everything played out.
    /// `session` is the `start()` it belongs to: ignore it if another start came since.
    var onAdvance: ((_ id: Int, _ session: Int64) -> Void)?
    var onEnd: ((_ session: Int64) -> Void)?
    /// The latest `start()`/`stop()` (main thread).
    private(set) var session: Int64 = 0

    // Shared counters, one Int64 each (see K). Only atomic access from the render thread.
    private enum K: Int {
        case write, read, requested, published, acked, jumpPos, jumpGain, jumpSerial
        case mark, markGain, markSerial, markCancel, paused, fade, gainGen, gainItem, gainValue
        case callbacks, lastFrames, lastTime
        static let count = 20
    }
    private let c: UnsafeMutablePointer<Int64>
    private func load(_ k: K) -> Int64 { oa_load(c + k.rawValue) }
    private func store(_ k: K, _ v: Int64) { oa_store(c + k.rawValue, v) }

    private let channels: Int
    private let capacity: Int64          // frames, a power of two
    private let ring: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let renderState: UnsafeMutablePointer<RenderState>
    private let wake: semaphore_t
    /// Owns the memory above. The render callback keeps it alive too, so a callback still running while
    /// the renderer is replaced (format change) never touches freed memory.
    private let storage: Storage

    private final class Storage {
        let c: UnsafeMutablePointer<Int64>
        let ring: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
        let renderState: UnsafeMutablePointer<RenderState>
        let channels: Int
        var wake = semaphore_t()
        init(channels: Int, capacity: Int) {
            self.channels = channels
            ring = .allocate(capacity: channels)
            for ch in 0..<channels { ring[ch] = .allocate(capacity: capacity); ring[ch].initialize(repeating: 0, count: capacity) }
            c = .allocate(capacity: K.count)
            c.initialize(repeating: 0, count: K.count)
            renderState = .allocate(capacity: 1)
            renderState.initialize(to: RenderState())
            semaphore_create(mach_task_self_, &wake, SYNC_POLICY_FIFO, 0)
        }
        deinit {
            for ch in 0..<channels { ring[ch].deallocate() }
            ring.deallocate()
            c.deallocate()
            renderState.deallocate()
            semaphore_destroy(mach_task_self_, wake)
        }
    }
    private static let chunk: AVAudioFrameCount = 8192
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    /// Render-thread-only state.
    private struct RenderState {
        var gain: Float = 1          // applied now (ramps toward target)
        var itemGain: Float = 1      // the playing item's own level
        var serial: Int64 = -1       // the playing item
        var seenJump: Int64 = 0
        var seenMark: Int64 = -1
        var seenGain: Int64 = 0
    }

    init?(format: AVAudioFormat) {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved, format.channelCount > 0 else { return nil }
        self.format = format
        channels = Int(format.channelCount)
        var cap: Int64 = 16384
        while Double(cap) < format.sampleRate { cap <<= 1 }   // about a second ahead
        capacity = cap
        storage = Storage(channels: channels, capacity: Int(cap))
        ring = storage.ring
        c = storage.c
        renderState = storage.renderState
        wake = storage.wake
        store(.mark, .max)
        store(.fade, Int64(Float(1).bitPattern))
        renderBlock = makeRenderBlock()
        node = AVAudioSourceNode(format: format, renderBlock: renderBlock)
        let t = Thread { [weak self] in self?.run() }
        t.name = "OmniAmp file reader"
        t.qualityOfService = .userInitiated
        t.start()
    }

    // MARK: Commands (main thread)

    private let lock = NSLock()
    private var alive = true
    private var pendingStart: Item?
    private var queue: [Item] = []
    private var cancelRequested = false

    /// Play `item` from its start, dropping everything before (a new track, a seek). nil = silence.
    func start(_ item: Item?) {
        lock.lock()
        pendingStart = item
        queue.removeAll()
        cancelRequested = false
        lock.unlock()
        session = oa_add(c + K.requested.rawValue, 1)
        semaphore_signal(wake)
    }

    func stop() { start(nil) }

    /// Play `item` right after the current one, with no gap.
    func enqueue(_ item: Item) {
        lock.lock(); queue.append(item); lock.unlock()
        semaphore_signal(wake)
    }

    /// Take back what `enqueue` queued. If it has started already, it simply plays (onAdvance follows).
    func cancelQueued() {
        lock.lock()
        if !queue.isEmpty { queue.removeAll() } else { cancelRequested = true }
        lock.unlock()
        semaphore_signal(wake)
    }

    func setPaused(_ on: Bool) { store(.paused, on ? 1 : 0) }
    var isPaused: Bool { load(.paused) != 0 }

    /// Volume fades (sleep timer): ramped, so no zipper noise.
    func setFade(_ g: Float) { store(.fade, Int64(g.bitPattern)) }

    /// A new level for item `id` while it plays (ReplayGain mode changed, tags arrived late): ramped.
    func setGain(_ g: Float, for id: Int) {
        store(.gainItem, Int64(id))
        store(.gainValue, Int64(g.bitPattern))
        oa_add(c + K.gainGen.rawValue, 1)
    }

    func shutdown() {
        lock.lock(); alive = false; lock.unlock()
        semaphore_signal(wake)
    }

    // MARK: Position (main thread)

    /// Where playback is, as heard: the item and the frame in its file. nil when nothing is placed.
    func position() -> (id: Int, frame: AVAudioFramePosition)? {
        lock.lock(); defer { lock.unlock() }
        // A start (seek) the reader hasn't taken up yet: that is where playback goes next.
        if load(.requested) != handled { return pendingStart.map { ($0.id, $0.start) } }
        guard let first = placed.first else { return nil }
        // A start not taken up by the render thread yet: it will begin at the new item's start.
        guard load(.acked) == load(.published), load(.published) == load(.requested) else { return (first.id, first.start) }
        var heard = load(.read)
        if load(.paused) == 0 {
            // Frames rendered in the last callback reach the speakers over the following buffer period,
            // then after the output delay. (A stopped engine: they were all rendered, the last ones not heard.)
            let frames = load(.lastFrames)
            let elapsed = Double(mach_absolute_time() &- UInt64(bitPattern: load(.lastTime))) * Self.secondsPerTick
            let played = min(Double(frames), max(0, elapsed * format.sampleRate))
            heard = heard - frames + Int64(played) - Int64(latency * format.sampleRate)
        }
        let p = placed.last { $0.ring <= heard } ?? first
        return (p.id, p.start + max(0, heard - p.ring))
    }

    // MARK: Reader thread

    /// Where each item begins in the ring (reader + main, under `lock`).
    private var placed: [(ring: Int64, id: Int, start: AVAudioFramePosition)] = []
    private var reading: (item: Item, file: AVAudioFile, pos: AVAudioFramePosition)?
    /// The queued item's first frame in the ring, until it is heard (one at a time).
    private var markPos: Int64?
    private var markID = 0
    private var endPos: Int64?
    private var endAnnounced = false
    private var handled: Int64 = 0
    private var scratch: AVAudioPCMBuffer?

    private func run() {
        scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunk)
        while true {
            lock.lock()
            if !alive { lock.unlock(); break }
            let requested = load(.requested)
            if requested != handled {
                var file = pendingStart?.file
                if let item = pendingStart, file == nil {
                    // A seek: open the file again, without the lock (a network share can take a while, and the
                    // main thread asks for the position many times a second).
                    lock.unlock()
                    file = open(item)
                    lock.lock()
                    if load(.requested) != requested { lock.unlock(); continue }   // a newer start came meanwhile
                }
                beginSession(requested, file: file)
            }
            if cancelRequested { cancelRequested = false; lock.unlock(); takeBackMark(); lock.lock() }
            // Something queued at the last moment goes in before "the end" is announced.
            if reading == nil { startNextIfAny() }
            announce()
            let wrote = fill()
            lock.unlock()
            if !wrote { semaphore_wait(wake) }   // woken by the render callback, or a command
        }
    }

    /// A start/seek/stop: new data goes after what's in the ring; the render thread jumps there.
    private func beginSession(_ requested: Int64, file: AVAudioFile?) {
        handled = requested
        reading = nil
        markPos = nil
        endAnnounced = false
        store(.mark, .max)
        store(.markCancel, 0)
        let w = load(.write)
        let item = pendingStart
        pendingStart = nil
        placed.removeAll()
        if let item, let f = file, matches(f) {
            reading = (item, f, item.start)
            placed = [(w, item.id, item.start)]
            endPos = nil
            store(.jumpGain, Int64(item.gain.bitPattern))
            store(.jumpSerial, Int64(item.id))
        } else {
            endPos = nil
            endAnnounced = true   // nothing to announce for silence
            store(.jumpSerial, -1)
        }
        store(.jumpPos, w)
        // With something to play, the render thread is told only once its first audio is in the ring: then
        // the very next callback plays it (instead of one of silence while it's read).
        if reading != nil { unpublished = requested } else { store(.published, requested) }
    }

    /// A start whose first audio is still being read (the render thread plays silence meanwhile).
    private var unpublished: Int64?
    private func publishIfWaiting() {
        guard let u = unpublished else { return }
        unpublished = nil
        if load(.requested) == u { store(.published, u) }
    }

    private func open(_ item: Item) -> AVAudioFile? {
        guard let f = try? AVAudioFile(forReading: item.url), matches(f) else { return nil }
        return f
    }

    private func matches(_ f: AVAudioFile) -> Bool {
        f.processingFormat.sampleRate == format.sampleRate && f.processingFormat.channelCount == format.channelCount
    }

    /// Report a queued item once it is heard, and the end once everything played out.
    private func announce() {
        guard load(.acked) == handled else { return }   // the render thread hasn't taken up this session yet
        let r = load(.read), session = handled, delay = max(0, latency)
        if let m = markPos, r > m {
            markPos = nil
            let id = markID
            placed.removeFirst(max(0, placed.count - 2))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.onAdvance?(id, session) }
        }
        if let e = endPos, r >= e, !endAnnounced {
            endAnnounced = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.onEnd?(session) }
        }
    }

    /// Decode into free ring space. Returns false when there's nothing to do until the render thread moves on.
    private func fill() -> Bool {
        if reading == nil { startNextIfAny() }
        guard var rd = reading, let buf = scratch else { return false }
        let w = load(.write), r = load(.read)
        // One chunk of the ring is kept free while playing: a new start's first chunk goes there, safely
        // after everything the render thread may still be reading, and can play at the next callback.
        let reserve = unpublished == nil ? Int64(Self.chunk) : 0
        let free = capacity - (w - r) - reserve
        let n = min(Int64(Self.chunk), free, rd.item.end - rd.pos)
        guard n > 0 || rd.pos >= rd.item.end else { publishIfWaiting(); return false }   // no room: never leave a start waiting
        var got: Int64 = 0
        if n > 0 {
            if rd.file.framePosition != rd.pos { rd.file.framePosition = rd.pos }
            // Decoding without the lock: main only needs it briefly (position, commands).
            lock.unlock()
            let ok = (try? rd.file.read(into: buf, frameCount: AVAudioFrameCount(n))) != nil
            lock.lock()
            // A command may have arrived meanwhile (start, cancel): let the loop see it first.
            guard load(.requested) == handled, !cancelRequested else { return true }
            got = ok ? Int64(buf.frameLength) : 0
            if got > 0, let src = buf.floatChannelData {
                let at = Int(w & (capacity - 1)), first = min(Int(got), Int(capacity) - at)
                for ch in 0..<channels {
                    (ring[ch] + at).update(from: src[ch], count: first)
                    if first < Int(got) { ring[ch].update(from: src[ch] + first, count: Int(got) - first) }
                }
                store(.write, w + got)
                rd.pos += got
            }
        }
        publishIfWaiting()
        if got == 0 || rd.pos >= rd.item.end {
            reading = nil   // done with this item (or the file ended early / became unreadable)
            startNextIfAny()
        } else {
            reading = rd
        }
        return true
    }

    /// Continue with the queued item right after the one just read (only one boundary pending at a time).
    private func startNextIfAny() {
        guard reading == nil, !placed.isEmpty else { return }
        if markPos == nil, !queue.isEmpty {
            let next = queue.removeFirst()
            var file = next.file
            if file == nil {
                // Not opened by the player: open it here, without the lock.
                let session = handled
                lock.unlock()
                file = open(next)
                lock.lock()
                guard load(.requested) == session, reading == nil, markPos == nil else { return }   // things moved on
            }
            guard let f = file, matches(f) else { return startNextIfAny() }
            let w = load(.write)
            reading = (next, f, next.start)
            placed.append((w, next.id, next.start))
            markPos = w
            markID = next.id
            endPos = nil
            endAnnounced = false
            store(.markGain, Int64(next.gain.bitPattern))
            store(.markSerial, Int64(next.id))
            store(.markCancel, 0)
            store(.mark, w)
        } else if markPos == nil, queue.isEmpty, endPos == nil {
            endPos = load(.write)   // nothing follows: the end is where the data ends (unless something is queued in time)
        }
    }

    /// Cancel the queued item that is already in the ring: cut the ring at its first frame, unless it
    /// started playing already.
    private func takeBackMark() {
        lock.lock()
        guard let m = markPos else { lock.unlock(); return }
        lock.unlock()
        store(.markCancel, 1)
        // A render callback that began before the flag may still cross; after two more callbacks none can.
        let seen = load(.callbacks)
        var waited = 0
        while load(.callbacks) < seen + 2, waited < 50 {
            _ = semaphore_timedwait(wake, mach_timespec_t(tv_sec: 0, tv_nsec: 10_000_000))
            waited += 1
        }
        lock.lock(); defer { lock.unlock() }
        guard markPos == m else { return }
        if load(.read) <= m {
            store(.write, m)       // the render thread stops at m while cancelling: nothing past it is read
            if placed.last?.ring == m { placed.removeLast() }
            reading = nil
            markPos = nil
            store(.mark, .max)
            endPos = nil
            endAnnounced = false
        }
        store(.markCancel, 0)
    }

    // MARK: Render callback

    private func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        let c = self.c, ring = self.ring, st = self.renderState, channels = self.channels
        let mask = capacity - 1, wake = self.wake, storage = self.storage
        func ld(_ k: K) -> Int64 { oa_load(c + k.rawValue) }
        func sv(_ k: K, _ v: Int64) { oa_store(c + k.rawValue, v) }
        func bits(_ v: Int64) -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: v)) }
        let rampFrames: Float = 256

        return { isSilence, _, frameCount, abl in
            let out = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int64(frameCount)
            var filled: Int64 = 0
            let published = ld(.published)
            if ld(.requested) == published {
                if published != st.pointee.seenJump {
                    // A new start: skip whatever was left of the old one.
                    sv(.read, ld(.jumpPos))
                    st.pointee.serial = ld(.jumpSerial)
                    st.pointee.itemGain = bits(ld(.jumpGain))
                    st.pointee.gain = st.pointee.itemGain * bits(ld(.fade))
                    st.pointee.seenJump = published
                    sv(.acked, published)
                }
                let gainGen = ld(.gainGen)
                if gainGen != st.pointee.seenGain {
                    st.pointee.seenGain = gainGen
                    if ld(.gainItem) == st.pointee.serial { st.pointee.itemGain = bits(ld(.gainValue)) }
                }
                if ld(.paused) == 0 {
                    var r = ld(.read)
                    let w = ld(.write)
                    let fade = bits(ld(.fade))
                    while filled < n {
                        let mark = ld(.mark)
                        if mark == r, ld(.markSerial) != st.pointee.seenMark {
                            if ld(.markCancel) != 0 { break }   // being taken back: wait here
                            // The queued track begins exactly here, at its own level.
                            st.pointee.seenMark = ld(.markSerial)
                            st.pointee.serial = st.pointee.seenMark
                            st.pointee.itemGain = bits(ld(.markGain))
                            st.pointee.gain = st.pointee.itemGain * fade
                        }
                        let limit = mark > r && mark < w ? mark : w
                        let take = min(n - filled, limit - r)
                        if take <= 0 { break }
                        let at = Int(r & mask), first = min(Int(take), Int(mask + 1) - at)
                        let target = st.pointee.itemGain * fade
                        let g0 = st.pointee.gain
                        // A level change is spread over 256 frames (no clicks, no zipper noise); otherwise
                        // a plain copy (bit-exact at 1.0) or one multiply.
                        let rampN = g0 == target ? 0 : min(Int(take), Int(rampFrames))
                        let step = rampN > 0 ? (target - g0) / rampFrames : 0
                        for ch in 0..<min(channels, out.count) {
                            guard let d = out[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                            let dst = d + Int(filled)
                            dst.update(from: ring[ch] + at, count: first)
                            if first < Int(take) { (dst + first).update(from: ring[ch], count: Int(take) - first) }
                            var g = g0
                            for i in 0..<rampN { g += step; dst[i] *= g }
                            if Int(take) > rampN, target != 1 {
                                var t = target
                                vDSP_vsmul(dst + rampN, 1, &t, dst + rampN, 1, vDSP_Length(Int(take) - rampN))
                            }
                        }
                        // Frames after a finished ramp were scaled by `target`; a ramp cut short by the chunk
                        // continues from where it got to.
                        let reached = rampN == Int(rampFrames) ? target : g0 + step * Float(rampN)
                        st.pointee.gain = abs(reached - target) < 1e-6 ? target : reached
                        r += take
                        filled += take
                    }
                    sv(.read, r)
                }
            }
            for ch in 0..<out.count where filled < n {
                guard let d = out[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                (d + Int(filled)).update(repeating: 0, count: Int(n - filled))
            }
            isSilence.pointee = ObjCBool(filled == 0)
            sv(.lastFrames, filled)
            sv(.lastTime, Int64(bitPattern: mach_absolute_time()))
            _ = oa_add(c + K.callbacks.rawValue, 1)
            semaphore_signal(wake)
            withExtendedLifetime(storage) {}
            return noErr
        }
    }
}
