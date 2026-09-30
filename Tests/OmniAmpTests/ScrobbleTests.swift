import XCTest
@testable import OmniAmp

/// Records requests and answers with canned responses.
final class MockTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var status = 200
    var body: [String: Any] = [:]
    func send(_ req: URLRequest) async throws -> (Data, Int) {
        requests.append(req)
        return (try JSONSerialization.data(withJSONObject: body), status)
    }
    func form(_ i: Int) -> [String: String] {
        let s = String(data: requests[i].httpBody ?? Data(), encoding: .utf8) ?? ""
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }
}

/// A connected in-memory service for queue tests.
final class FakeService: ScrobbleService {
    let id = "fake"
    let maxBatch = 2
    var isConnected = true
    var needsReconnect = false
    var fail = false
    var refuse: Set<String> = []   // titles the service answers 400 for
    var received: [[Scrobble]] = []
    func nowPlaying(_ s: Scrobble) async throws {}
    func submit(_ batch: [Scrobble]) async throws -> Int {
        if fail { throw ScrobbleError.http(503, "down") }
        if batch.contains(where: { refuse.contains($0.title) }) { throw ScrobbleError.rejected("invalid parameters") }
        received.append(batch)
        return batch.count
    }
}

@MainActor
final class ScrobbleTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-scrobble-\(UUID().uuidString)")
        setenv("OMNIAMP_CACHE_DIR", dir.path, 1)
        setenv("OMNIAMP_KEYCHAIN_SERVICE", "OmniAmp.tests", 1)   // never touch the real login
    }

    override func tearDown() {
        unsetenv("OMNIAMP_CACHE_DIR")
        unsetenv("OMNIAMP_KEYCHAIN_SERVICE")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Rules

    func testThreshold() {
        XCTAssertNil(Scrobbler.threshold(for: 30))           // too short
        XCTAssertEqual(Scrobbler.threshold(for: 100), 50)     // half
        XCTAssertEqual(Scrobbler.threshold(for: 1200), 240)   // capped at 4 minutes
    }

    func testIdentifyFromTagsOrFileName() {
        var t = Track(path: "/m/01 - Nick Drake - Pink Moon.flac", size: 1, mtime: 0)
        XCTAssertEqual(Scrobbler.identify(t)?.artist, "Nick Drake")
        XCTAssertEqual(Scrobbler.identify(t)?.title, "Pink Moon")
        t.artist = "Tagged"; t.title = "Title"
        XCTAssertEqual(Scrobbler.identify(t)?.artist, "Tagged")
        XCTAssertNil(Scrobbler.identify(Track(path: "/m/untitled.flac", size: 1, mtime: 0)))
    }

    // MARK: Last.fm

    func testLastFMSignatureMatchesReference() {
        // Reference computed independently with Python's hashlib.
        let p = ["api_key": "KEY", "method": "track.scrobble", "sk": "SESSION",
                 "artist[0]": "Björk", "track[0]": "Jóga", "timestamp[0]": "1700000000"]
        XCTAssertEqual(LastFM.signature(p, secret: "SECRET"), "662eb01b89a6180b9f1ac6309b01d0a6")
    }

    func testLastFMScrobbleRequest() async throws {
        let lfm = LastFM(apiKey: "KEY", secret: "SECRET")
        let mock = MockTransport()
        mock.body = ["scrobbles": [:]]
        lfm.transport = mock
        Keychain.set("lastfm.session", "SESSION")
        defer { Keychain.set("lastfm.session", nil) }
        let n = try await lfm.submit([Scrobble(artist: "Björk", title: "Jóga", album: nil, duration: nil, timestamp: 1_700_000_000)])
        XCTAssertEqual(n, 1)
        let f = mock.form(0)
        XCTAssertEqual(mock.requests[0].httpMethod, "POST")
        XCTAssertEqual(f["method"], "track.scrobble")
        XCTAssertEqual(f["artist[0]"], "Björk")
        XCTAssertEqual(f["format"], "json")
        XCTAssertEqual(f["api_sig"], "662eb01b89a6180b9f1ac6309b01d0a6")
    }

    func testLastFMErrorIsReported() async {
        let lfm = LastFM(apiKey: "KEY", secret: "SECRET")
        let mock = MockTransport()
        mock.body = ["error": 11, "message": "Service Offline"]
        lfm.transport = mock
        Keychain.set("lastfm.session", "SESSION")
        defer { Keychain.set("lastfm.session", nil) }
        do {
            _ = try await lfm.submit([Scrobble(artist: "a", title: "b", album: nil, duration: nil, timestamp: 1)])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Service Offline"))
        }
    }

    func testExpiredLoginKeepsQueueingUntilReconnected() async throws {
        // Last.fm answers "invalid session": the login is gone, but it wasn't a disconnect.
        let lfm = LastFM(apiKey: "KEY", secret: "SECRET")
        let mock = MockTransport()
        mock.body = ["error": 9, "message": "Invalid session key"]
        lfm.transport = mock
        Keychain.set("lastfm.session", "SESSION")
        defer { Keychain.set("lastfm.session", nil); ReconnectMark.set(lfm.id, false) }
        _ = try? await lfm.submit([Scrobble(artist: "a", title: "b", album: nil, duration: nil, timestamp: 1)])
        XCTAssertFalse(lfm.isConnected)
        XCTAssertTrue(lfm.needsReconnect)
        lfm.disconnect()
        XCTAssertFalse(lfm.needsReconnect, "disconnecting in Settings ends it")

        // Meanwhile plays are queued, not dropped, and go out after reconnecting.
        let svc = FakeService()
        svc.isConnected = false
        svc.needsReconnect = true
        let s = Scrobbler(services: [svc])
        s.enqueue(Scrobble(artist: "A", title: "while expired", album: nil, duration: 60, timestamp: 1))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(s.pendingCount("fake"), 1)
        XCTAssertTrue(svc.received.isEmpty, "nothing sent without a login")
        svc.isConnected = true
        svc.needsReconnect = false
        s.flushAll()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(svc.received.flatMap { $0 }.map(\.title), ["while expired"])
    }

    // MARK: ListenBrainz

    func testListenBrainzSubmit() async throws {
        let lb = ListenBrainz()
        let mock = MockTransport()
        mock.body = ["status": "ok"]
        lb.transport = mock
        Keychain.set("listenbrainz.token", "TOKEN")
        defer { Keychain.set("listenbrainz.token", nil) }
        let s = Scrobble(artist: "Air", title: "La Femme d'Argent", album: "Moon Safari", duration: 431, timestamp: 42)
        _ = try await lb.submit([s, s])
        let req = mock.requests[0]
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Token TOKEN")
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(json["listen_type"] as? String, "import")
        let first = (json["payload"] as! [[String: Any]])[0]
        XCTAssertEqual(first["listened_at"] as? Int, 42)
        let meta = first["track_metadata"] as! [String: Any]
        XCTAssertEqual(meta["artist_name"] as? String, "Air")
        XCTAssertEqual(meta["release_name"] as? String, "Moon Safari")
    }

    // MARK: Queue

    func testQueueKeepsScrobblesUntilSentThenBatches() async throws {
        let svc = FakeService()
        let s = Scrobbler(services: [svc])
        svc.fail = true
        for i in 0..<3 { s.enqueue(Scrobble(artist: "A", title: "T\(i)", album: nil, duration: 60, timestamp: i)) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(s.pendingCount("fake"), 3, "offline: nothing lost")
        XCTAssertNotNil(s.lastError["fake"])

        svc.fail = false
        s.flushAll()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(s.pendingCount("fake"), 0)
        XCTAssertEqual(svc.received.map(\.count), [2, 1], "sent in batches of maxBatch, oldest first")
        XCTAssertEqual(svc.received.flatMap { $0 }.map(\.title), ["T0", "T1", "T2"])

        // The queue survives a restart.
        svc.fail = true
        s.enqueue(Scrobble(artist: "A", title: "later", album: nil, duration: 60, timestamp: 9))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(Scrobbler(services: [svc]).pendingCount("fake"), 1)
    }

    func testRefusedScrobbleIsDroppedWithoutBlockingTheQueue() async throws {
        let svc = FakeService()
        svc.refuse = ["bad"]
        svc.fail = true
        let s = Scrobbler(services: [svc])
        for t in ["T0", "bad", "T2", "T3"] { s.enqueue(Scrobble(artist: "A", title: t, album: nil, duration: 60, timestamp: 1)) }
        svc.fail = false
        s.flushAll()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(s.pendingCount("fake"), 0, "only the refused one is dropped; the rest go out")
        XCTAssertEqual(svc.received.flatMap { $0 }.map(\.title), ["T0", "T2", "T3"])
    }
}

@MainActor   // the Last.fm client is main-thread only
final class LastFMKeyTests: XCTestCase {
    override func setUp() { setenv("OMNIAMP_KEYCHAIN_SERVICE", "OmniAmp.tests", 1) }   // never the real Keychain
    override func tearDown() {
        LastFM().setCustomKey(nil, secret: nil)
        unsetenv("OMNIAMP_KEYCHAIN_SERVICE")
    }

    /// The user's own key replaces the built-in one (and signs out); clearing it goes back.
    func testOwnKeyOverridesBuiltInKey() {
        setenv("OMNIAMP_LASTFM_KEY", "builtin-key", 1)
        setenv("OMNIAMP_LASTFM_SECRET", "builtin-secret", 1)
        defer { unsetenv("OMNIAMP_LASTFM_KEY"); unsetenv("OMNIAMP_LASTFM_SECRET") }
        let lfm = LastFM()
        XCTAssertEqual(lfm.apiKey, "builtin-key")
        XCTAssertFalse(lfm.usesCustomKey)

        lfm.setCustomKey(" mine ", secret: "my-secret")
        XCTAssertTrue(lfm.usesCustomKey)
        XCTAssertEqual(lfm.apiKey, "mine")
        XCTAssertEqual(lfm.secret, "my-secret")
        XCTAssertEqual(LastFM().apiKey, "mine", "kept for the next launch")

        lfm.setCustomKey("only-a-key", secret: "")   // incomplete: back to the built-in key
        XCTAssertFalse(lfm.usesCustomKey)
        XCTAssertEqual(lfm.apiKey, "builtin-key")
    }
}
