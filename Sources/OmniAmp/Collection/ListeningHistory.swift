import Foundation

/// The user's last.fm history in the library database, and where the artists come from.
///
/// Import: new plays since the last sync first, then older pages until the whole history is in. It picks up
/// where it stopped (an interrupted first import continues from the oldest play stored). Last.fm asks for
/// restraint: at most five requests a second.
///
/// Countries: MusicBrainz, one request a second (shared with the rest of the app), most played and owned
/// artists first, cached for good. Can be turned off (Pref.libraryOnlineLookups).
@MainActor
final class ListeningHistory {
    static let shared = ListeningHistory()
    static let changed = Notification.Name("OmniAmpListeningChanged")

    enum Phase: Equatable {
        case idle
        case importing(done: Int, total: Int)
        case failed(String)
    }
    private(set) var phase: Phase = .idle
    private(set) var lookupsRunning = false
    private(set) var lookedUp = 0
    private(set) var lastSync: Date?
    private var failures = 0
    /// Failed lookups per artist in this session.
    private var attempts: [String: Int] = [:]

    private let queue = DispatchQueue(label: "omniamp.listening", qos: .utility)
    nonisolated(unsafe) private var connection: CollectionDB?
    private let lastfmGate = Gate(interval: 0.22)

    private init() {
        UserDefaults.standard.register(defaults: [Pref.libraryOnlineLookups: true])
    }

    var user: String? {
        let u = UserDefaults.standard.string(forKey: Pref.lastfmHistoryUser) ?? LastFM.shared.username
        return (u?.isEmpty ?? true) ? nil : u
    }
    var canImport: Bool { LastFM.shared.apiKey != nil }
    var lookupsEnabled: Bool { UserDefaults.standard.bool(forKey: Pref.libraryOnlineLookups) }

    /// Another account: its plays replace the old ones.
    func setUser(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.lowercased() != user?.lowercased() else { return }
        UserDefaults.standard.set(n, forKey: Pref.lastfmHistoryUser)
        // An import still running pages the old account: stop it before the plays go, or it writes them back.
        let running = importTask
        running?.cancel()
        switching = true
        Task {
            _ = await running?.value
            try? await onDB { try $0.forgetPlays() }
            lastSync = nil
            switching = false
            sync()
        }
    }

    func setLookupsEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Pref.libraryOnlineLookups)
        if on { startLookups() }
    }

    /// The Listening page opened: bring things up to date if it's been a while.
    func refreshIfStale() {
        if lastSync.map({ Date().timeIntervalSince($0) > 1800 }) ?? true { sync() }
        startLookups()
    }

    // MARK: Database (own connection, on its own queue)

    nonisolated private func onDB<T: Sendable>(_ f: @escaping @Sendable (CollectionDB) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    if self.connection == nil { self.connection = try CollectionDB() }
                    cont.resume(returning: try f(self.connection!))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Import

    private var importing = false
    private var importTask: Task<Void, Never>?
    /// Between choosing another account and its old plays being gone: no import.
    private var switching = false
    /// Plays reach last.fm late with their own time (scrobbled offline; it takes them up to 14 days back).
    static let lateScrobbles = 14 * 86_400
    private var lastPost = Date.distantPast

    private func post(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPost) > 3 else { return }
        lastPost = Date()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func fetch(_ user: String, from: Int? = nil, to: Int? = nil, page: Int = 1) async throws
        -> (tracks: [LastFM.Play], pages: Int, total: Int) {
        var attempt = 0
        while true {
            await lastfmGate.wait()
            do {
                return try await LastFM.shared.recentTracks(user: user, from: from, to: to, page: page)
            } catch {
                attempt += 1
                if attempt >= 4 { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 5_000_000_000)   // rate limit or a hiccup: back off
            }
        }
    }

    func sync() {
        guard !importing, !switching, let user, canImport else { return }
        importing = true
        importTask = Task {
            defer { importing = false; importTask = nil; post(force: true) }
            do {
                let range = try await onDB { try $0.playRange() }
                var stored = range.count
                // 1. What's new since the last sync that got through, and late plays from before it (plays already
                // stored are skipped). Pages come newest first: one that fails part-way leaves older new plays
                // behind, so the mark only moves once all of them are in.
                if let newest = range.newest {
                    let through = (try await onDB { $0.meta("lastfmSyncedThrough") }) ?? newest
                    var page = 1, pages = 1
                    while page <= pages {
                        let r = try await fetch(user, from: max(0, min(through, newest) - Self.lateScrobbles) + 1, page: page)
                        pages = r.pages
                        let tracks = r.tracks
                        try Task.checkCancellation()
                        stored += try await onDB { try $0.addPlays(tracks) }
                        phase = .importing(done: stored, total: stored + max(0, r.total - page * 200))
                        post()
                        page += 1
                    }
                    try await onDB { db in
                        if let n = try db.playRange().newest { try db.setMeta("lastfmSyncedThrough", n) }
                    }
                }
                // 2. Older pages, until the start of the history (resumable).
                while (try await onDB { $0.meta("lastfmComplete") }) != 1 {
                    let oldest = try await onDB { try $0.playRange().oldest }
                    let r = try await fetch(user, to: oldest.map { $0 - 1 })
                    let tracks = r.tracks
                    try Task.checkCancellation()
                    if tracks.isEmpty {
                        try await onDB { try $0.setMeta("lastfmComplete", 1) }
                        break
                    }
                    stored += try await onDB { try $0.addPlays(tracks) }
                    phase = .importing(done: stored, total: stored + max(0, r.total - tracks.count))
                    post()
                }
                phase = .idle
                lastSync = Date()
                startLookups()
            } catch is CancellationError {
                phase = .idle
            } catch {
                guard !Task.isCancelled else { phase = .idle; return }
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
                NSLog("OmniAmp: last.fm history: %@", "\(error)")
            }
        }
    }

    // MARK: Countries

    func startLookups() {
        guard !lookupsRunning, lookupsEnabled else { return }
        lookupsRunning = true
        Task {
            defer { lookupsRunning = false; post(force: true) }
            outer: while lookupsEnabled {
                let batch = (try? await onDB { try $0.pendingArtists(limit: 25) }) ?? []
                if batch.isEmpty { break }
                for a in batch {
                    guard lookupsEnabled else { break outer }
                    let found = await MetadataLookup.shared.artistPlace(name: a.name, mbid: a.mbid, album: a.album, trusted: a.trusted)
                    if found.failed {
                        // One artist that keeps failing (MusicBrainz errors on some searches) must not block the rest:
                        // after two tries it counts as not found (tried again in a later round).
                        attempts[a.key, default: 0] += 1
                        NSLog("OmniAmp: artist country lookup failed for %@ (try %d)", a.name, attempts[a.key]!)
                        if attempts[a.key]! >= 2 {
                            try? await onDB { try $0.savePlace(a, mbid: nil, country: nil, found: false, retryInDays: 1) }
                            continue
                        }
                        // Several in a row: MusicBrainz is busy or away. Wait, longer each time.
                        failures += 1
                        let wait = min(600, 30 * failures)
                        NSLog("OmniAmp: artist countries paused for %d s", wait)
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(wait)) { [weak self] in self?.startLookups() }
                        break outer
                    }
                    failures = 0
                    var country = found.country, retry: Double = 90
                    if country == nil, let area = found.area {
                        // Couldn't walk up to the country this time: try again tomorrow, not in 90 days.
                        if let c = await self.country(ofArea: area) { country = c } else { retry = 1 }
                    }
                    let c = country, r = retry
                    try? await onDB { try $0.savePlace(a, mbid: found.mbid, country: c, found: found.found, retryInDays: r) }
                    lookedUp += 1
                    post()
                }
            }
        }
    }

    /// Walk up from a city or region to its country (a few steps at most), remembering every area on the way.
    /// nil: a lookup failed; .some(nil): the area has no country.
    private func country(ofArea start: String) async -> String?? {
        var id = start, visited: [String] = []
        for _ in 0..<6 {
            let current = id
            let cached: String?? = (try? await onDB { $0.areaCountry(current) }) ?? nil
            if case .some(let known) = cached {   // already worked out (maybe to "no country")
                let v = visited
                try? await onDB { db in v.forEach { db.saveArea($0, country: known) } }
                return known
            }
            let step = await MetadataLookup.shared.areaStep(current)
            if step.failed { return .none }
            visited.append(id)
            if let c = step.country {
                let v = visited
                try? await onDB { db in v.forEach { db.saveArea($0, country: c) } }
                return c
            }
            guard let parent = step.parent else { break }
            id = parent
        }
        let v = visited
        try? await onDB { db in v.forEach { db.saveArea($0, country: nil) } }
        return .some(nil)
    }
}
