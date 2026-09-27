import Foundation

/// One play worth reporting.
struct Scrobble: Codable, Equatable {
    var artist: String
    var title: String
    var album: String?
    var duration: Int?      // seconds
    var timestamp: Int      // UNIX time the track started
}

/// A scrobbling service (Last.fm, ListenBrainz).
protocol ScrobbleService: AnyObject {
    var id: String { get }
    var isConnected: Bool { get }
    func nowPlaying(_ s: Scrobble) async throws
    /// Submit a batch (the service may accept fewer; returns how many were accepted from the front).
    func submit(_ batch: [Scrobble]) async throws -> Int
    var maxBatch: Int { get }
}

/// Sends HTTP requests; swapped out in tests.
protocol HTTPTransport {
    func send(_ req: URLRequest) async throws -> (Data, Int)
}

struct URLSessionTransport: HTTPTransport {
    func send(_ req: URLRequest) async throws -> (Data, Int) {
        let (d, r) = try await URLSession.shared.data(for: req)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum ScrobbleError: Error, LocalizedError {
    case http(Int, String)
    case notConnected
    case auth(String)
    var errorDescription: String? {
        switch self {
        case .http(let c, let m): return "HTTP \(c): \(m)"
        case .notConnected: return "Not connected"
        case .auth(let m): return m
        }
    }
}

/// Decides *when* a play counts and keeps a persistent queue per service.
///
/// Rules (Last.fm and ListenBrainz agree): the track must be longer than 30 s and be listened to for
/// half its length or 4 minutes, whichever comes first. Listening time is accumulated from play/pause
/// events with a single one-shot timer — no polling. Main-thread only (like PlayerController); network
/// results hop back to the main actor.
final class Scrobbler {
    static let shared = Scrobbler()

    private(set) var services: [ScrobbleService] = []
    private var queues: [String: [Scrobble]] = [:]
    private var flushing = Set<String>()
    private var oneByOne = Set<String>()
    var onChange: (() -> Void)?
    private(set) var lastError: [String: String] = [:]

    // The play being timed.
    private var pending: Scrobble?
    private var listened: TimeInterval = 0
    private var playingSince: Date?
    private var threshold: TimeInterval = .infinity
    private var timer: Timer?

    private static var queueURL: URL {
        LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("scrobble-queue.json")
    }

    init(services: [ScrobbleService]? = nil) {
        self.services = services ?? [LastFM.shared, ListenBrainz.shared]
        if let d = try? Data(contentsOf: Self.queueURL),
           let q = try? JSONDecoder().decode([String: [Scrobble]].self, from: d) { queues = q }
    }

    func pendingCount(_ serviceID: String) -> Int { queues[serviceID]?.count ?? 0 }

    // MARK: Rules

    /// Seconds of listening after which a track of `duration` counts, or nil if it never does.
    nonisolated static func threshold(for duration: Double) -> TimeInterval? {
        guard duration > 30 else { return nil }
        return min(duration / 2, 240)
    }

    /// Artist/title from tags, else from a "Artist - Title" file name (leading track numbers dropped).
    nonisolated static func identify(_ t: Track) -> (artist: String, title: String)? {
        if let a = t.artist?.trimmingCharacters(in: .whitespaces), let ti = t.title?.trimmingCharacters(in: .whitespaces),
           !a.isEmpty, !ti.isEmpty { return (a, ti) }
        var stem = t.fileStem
        if let r = stem.range(of: #"^\d{1,3}[\s.\-_]+"#, options: .regularExpression) { stem.removeSubrange(r) }
        let parts = stem.components(separatedBy: " - ")
        guard parts.count >= 2 else { return nil }
        let a = parts[0].trimmingCharacters(in: .whitespaces), ti = parts[1...].joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        return a.isEmpty || ti.isEmpty ? nil : (a, ti)
    }

    // MARK: Playback events

    /// A new track started (or nil when playback moved to nothing).
    func trackStarted(_ t: Track?, duration: Double) {
        commitListening()
        timer?.invalidate()
        pending = nil
        listened = 0
        guard let t, let id = Self.identify(t), let th = Self.threshold(for: duration),
              services.contains(where: { $0.isConnected }) else { return }
        pending = Scrobble(artist: id.artist, title: id.title, album: t.album, duration: Int(duration.rounded()),
                           timestamp: Int(Date().timeIntervalSince1970))
        threshold = th
        playingSince = Date()
        armTimer()
        let s = pending!
        for svc in services where svc.isConnected {
            Task { try? await svc.nowPlaying(s) }
        }
    }

    func playbackPaused() {
        commitListening()
        timer?.invalidate()
    }

    func playbackResumed() {
        guard pending != nil, playingSince == nil else { return }
        playingSince = Date()
        armTimer()
    }

    private func commitListening() {
        if let since = playingSince { listened += Date().timeIntervalSince(since) }
        playingSince = nil
    }

    private func armTimer() {
        timer?.invalidate()
        let left = threshold - listened
        let t = Timer(timeInterval: max(0.5, left), repeats: false) { [weak self] _ in
            self?.thresholdReached()
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func thresholdReached() {
        commitListening()
        guard let s = pending else { return }
        if listened + 0.5 < threshold { playingSince = Date(); armTimer(); return }
        pending = nil
        enqueue(s)
    }

    // MARK: Queue

    func enqueue(_ s: Scrobble) {
        for svc in services where svc.isConnected { queues[svc.id, default: []].append(s) }
        saveQueue()
        flushAll()
    }

    func flushAll() {
        for svc in services where svc.isConnected { flush(svc) }
    }

    private func flush(_ svc: ScrobbleService) {
        guard !flushing.contains(svc.id), let q = queues[svc.id], !q.isEmpty else { return }
        flushing.insert(svc.id)
        // After a rejected batch, go one at a time to find the scrobble the service refuses.
        let batch = Array(q.prefix(oneByOne.contains(svc.id) ? 1 : svc.maxBatch))
        Task { @MainActor in
            do {
                let n = try await svc.submit(batch)
                self.queues[svc.id] = Array((self.queues[svc.id] ?? []).dropFirst(max(1, n)))
                self.lastError[svc.id] = nil
                if (self.queues[svc.id] ?? []).isEmpty { self.oneByOne.remove(svc.id) }
                self.saveQueue()
                self.flushing.remove(svc.id)
                self.onChange?()
                if !(self.queues[svc.id] ?? []).isEmpty { self.flush(svc) }
            } catch ScrobbleError.http(400, let msg) {
                // The service refused the content itself (not auth, not an outage): retrying it as is
                // would block the queue for good. Split the batch; drop a single refused scrobble.
                self.flushing.remove(svc.id)
                if batch.count > 1 {
                    self.oneByOne.insert(svc.id)
                } else {
                    NSLog("OmniAmp: %@ refused a scrobble (%@), dropping it", svc.id, msg)
                    self.queues[svc.id] = Array((self.queues[svc.id] ?? []).dropFirst())
                    self.oneByOne.remove(svc.id)
                    self.saveQueue()
                }
                self.flush(svc)
            } catch {
                // Keep everything queued (offline, server trouble); retried on the next scrobble or launch.
                self.lastError[svc.id] = error.localizedDescription
                self.flushing.remove(svc.id)
                self.onChange?()
            }
        }
    }

    private func saveQueue() {
        // Cap each queue so a long offline period can't grow without bound.
        for (k, v) in queues where v.count > 5000 { queues[k] = Array(v.suffix(5000)) }
        if let d = try? JSONEncoder().encode(queues) { try? d.write(to: Self.queueURL, options: .atomic) }
        onChange?()
    }

    /// Drop the queue of a service that was disconnected.
    func clearQueue(_ serviceID: String) {
        queues[serviceID] = nil
        saveQueue()
    }
}
