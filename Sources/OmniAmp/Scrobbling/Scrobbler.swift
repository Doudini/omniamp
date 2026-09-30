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
@MainActor
protocol ScrobbleService: AnyObject {
    var id: String { get }
    var isConnected: Bool { get }
    /// The login expired or was revoked by the service (not a disconnect in Settings): plays keep being
    /// queued, and go out once you reconnect.
    var needsReconnect: Bool { get }
    func nowPlaying(_ s: Scrobble) async throws
    /// Submit a batch (the service may accept fewer; returns how many were accepted from the front).
    func submit(_ batch: [Scrobble]) async throws -> Int
    var maxBatch: Int { get }
}

/// Sends HTTP requests; swapped out in tests.
extension ScrobbleService {
    /// Plays are timed and queued for this service (sent only while connected).
    var collectsScrobbles: Bool { isConnected || needsReconnect }
}

/// The "needs reconnect" mark of the real services, kept across launches.
enum ReconnectMark {
    static func get(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: id + "NeedsReconnect") }
    static func set(_ id: String, _ on: Bool) { UserDefaults.standard.set(on ? true : nil, forKey: id + "NeedsReconnect") }
}

/// Sendable: requests go out from the main-thread clients and are awaited elsewhere.
protocol HTTPTransport: Sendable {
    func send(_ req: URLRequest) async throws -> (Data, Int)
}

struct URLSessionTransport: HTTPTransport {
    func send(_ req: URLRequest) async throws -> (Data, Int) {
        // Podcast feeds come from addresses anyone can edit: 64 MB is several times the biggest real feed.
        let (d, r) = try await BoundedFetch.data(for: req, limit: 64 << 20, deadline: max(120, req.timeoutInterval * 4))
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum ScrobbleError: Error, LocalizedError {
    case http(Int, String)
    /// The service refused the scrobble itself (bad data): retrying the same one can never work.
    case rejected(String)
    case notConnected
    case auth(String)
    var errorDescription: String? {
        switch self {
        case .http(let c, let m): return "HTTP \(c): \(m)"
        case .rejected(let m): return "Refused: \(m)"
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
/// results hop back to the main actor. A counted play also goes into the play history on this Mac (with no
/// service connected too), unless that's turned off.
@MainActor
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
    /// The file that's playing (nil for a stream), for the play history.
    private var pendingPath: String?
    private var listened: TimeInterval = 0
    private var playingSince: Date?
    private var threshold: TimeInterval = .infinity
    private var timer: Timer?

    private static var queueURL: URL {
        LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("scrobble-queue.json")
    }

    /// Where counted plays go besides the services (the play history), and whether it's kept; tests hand in their own.
    private let history: (Scrobble, String?) -> Void
    private let keepsHistory: () -> Bool
    /// The clock listening time is measured by (tests move it on instead of waiting).
    var now: () -> Date = Date.init

    init(services: [ScrobbleService]? = nil, history: ((Scrobble, String?) -> Void)? = nil, keepsHistory: (() -> Bool)? = nil) {
        self.services = services ?? [LastFM.shared, ListenBrainz.shared]
        self.history = history ?? { ListeningHistory.shared.record($0, path: $1) }
        self.keepsHistory = keepsHistory ?? { ListeningHistory.keepsHistory }
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
        pendingPath = nil
        listened = 0
        guard let t, let id = Self.identify(t), let th = Self.threshold(for: duration),
              services.contains(where: { $0.collectsScrobbles }) || keepsHistory() else { return }
        pending = Scrobble(artist: id.artist, title: id.title, album: t.album, duration: Sane.int(duration.rounded()),
                           timestamp: Int(now().timeIntervalSince1970))
        pendingPath = t.path.hasPrefix("/") ? t.path : nil   // a file, not a stream's URL
        threshold = th
        playingSince = now()
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
        playingSince = now()
        armTimer()
    }

    private func commitListening() {
        if let since = playingSince { listened += now().timeIntervalSince(since) }
        playingSince = nil
    }

    private func armTimer() {
        timer?.invalidate()
        let left = threshold - listened
        let t = Timer(timeInterval: max(0.5, left), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.thresholdReached() }   // a main run loop timer
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The timer's end (internal for tests).
    func thresholdReached() {
        commitListening()
        guard let s = pending else { return }
        if listened + 0.5 < threshold { playingSince = now(); armTimer(); return }
        pending = nil
        if services.contains(where: { $0.collectsScrobbles }) { enqueue(s) }
        if keepsHistory() { history(s, pendingPath) }
    }

    // MARK: Queue

    func enqueue(_ s: Scrobble) {
        for svc in services where svc.collectsScrobbles { queues[svc.id, default: []].append(s) }
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
        Task {
            do {
                let n = try await svc.submit(batch)
                // Remove exactly what was sent (the queue may have been trimmed at the front meanwhile).
                var q = self.queues[svc.id] ?? []
                for sent in batch.prefix(max(1, n)) { if let i = q.firstIndex(of: sent) { q.remove(at: i) } }
                self.queues[svc.id] = q
                self.lastError[svc.id] = nil
                if (self.queues[svc.id] ?? []).isEmpty { self.oneByOne.remove(svc.id) }
                self.saveQueue()
                self.flushing.remove(svc.id)
                self.onChange?()
                if !(self.queues[svc.id] ?? []).isEmpty { self.flush(svc) }
            } catch ScrobbleError.rejected(let msg) {
                // The service refused the content itself (not auth, not an outage): retrying it as is
                // would block the queue for good. Split the batch; drop a single refused scrobble.
                self.flushing.remove(svc.id)
                if batch.count > 1 {
                    self.oneByOne.insert(svc.id)
                } else {
                    NSLog("OmniAmp: %@ refused a scrobble (%@), dropping it", svc.id, msg)
                    // That one, not whatever is first now (the queue may have been trimmed at the front meanwhile).
                    var q = self.queues[svc.id] ?? []
                    if let i = q.firstIndex(of: batch[0]) { q.remove(at: i) }
                    self.queues[svc.id] = q
                    self.oneByOne.remove(svc.id)
                    self.saveQueue()
                }
                if svc.isConnected { self.flush(svc) }
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
