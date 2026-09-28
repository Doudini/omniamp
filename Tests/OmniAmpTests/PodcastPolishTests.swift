import XCTest
@testable import OmniAmp

final class ShowNotesEntityTests: XCTestCase {
    func testEntitiesDecodeOnceIncludingNumericOnes() {
        XCTAssertEqual(PodcastFeedParser.decodeEntities("Tom &amp; Jerry"), "Tom & Jerry")
        XCTAssertEqual(PodcastFeedParser.decodeEntities("&amp;lt;b&amp;gt;"), "&lt;b&gt;", "decoded once, not twice")
        XCTAssertEqual(PodcastFeedParser.decodeEntities("it&#8217;s &#x27;ok&#39; &hellip; &eacute;"), "it’s 'ok' … é")
        XCTAssertEqual(PodcastFeedParser.decodeEntities("&bogus; & &#xFFFFFFF;"), "&bogus; & &#xFFFFFFF;", "unknown ones stay as written")
    }
}

@MainActor
final class EpisodeGuidTests: XCTestCase {
    private func feed(_ items: [(guid: String, url: String)]) -> Data {
        let body = items.map { "<item><title>\($0.url)</title><guid>\($0.guid)</guid><enclosure url=\"\($0.url)\" type=\"audio/mpeg\"/></item>" }
        return Data("<rss><channel><title>Show</title>\(body.joined())</channel></rss>".utf8)
    }

    final class Transport: HTTPTransport, @unchecked Sendable {
        var body = Data()
        func send(_ req: URLRequest) async throws -> (Data, Int) { (body, 200) }
    }

    func testStateFollowsAnEpisodeWhoseAddressChanged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-guid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let show = PodcastShow(feedURL: "https://example.com/feed", title: "Show", author: "")
        let lib = PodcastLibrary(directory: dir)
        let t = Transport()
        lib.transport = t
        t.body = feed([("a", "https://cdn1.example.com/a.mp3"), ("b", "https://cdn1.example.com/b.mp3"),
                       ("same", "https://cdn1.example.com/c.mp3"), ("same", "https://cdn1.example.com/d.mp3")])
        _ = try awaitResult { try await lib.episodes(show, maxAge: 0) }
        lib.markPlayed(["https://cdn1.example.com/a.mp3", "https://cdn1.example.com/c.mp3"])

        var moved: [String: String]?
        let obs = NotificationCenter.default.addObserver(forName: PodcastLibrary.episodesMoved, object: nil, queue: nil) {
            moved = $0.userInfo?["moved"] as? [String: String]
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        // A tracking prefix appears in front of every address.
        t.body = feed([("a", "https://track.example.net/cdn1/a.mp3"), ("b", "https://track.example.net/cdn1/b.mp3"),
                       ("same", "https://track.example.net/cdn1/c.mp3"), ("same", "https://track.example.net/cdn1/d.mp3")])
        let eps = try awaitResult { try await lib.episodes(show, maxAge: 0) }
        XCTAssertEqual(eps.first?.guid, "a")
        XCTAssertTrue(lib.isPlayed("https://track.example.net/cdn1/a.mp3"), "played mark moved with the guid")
        XCTAssertFalse(lib.isPlayed("https://track.example.net/cdn1/c.mp3"), "a guid shared by several items identifies nothing")
        XCTAssertEqual(moved?["https://cdn1.example.com/b.mp3"], "https://track.example.net/cdn1/b.mp3")
        XCTAssertNil(moved?["https://cdn1.example.com/c.mp3"])
    }

    private func awaitResult<T>(_ body: @escaping () async throws -> T) throws -> T {
        let done = expectation(description: "async")
        var result: Result<T, Error>!
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try result.get()
    }
}

