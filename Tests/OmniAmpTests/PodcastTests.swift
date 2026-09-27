import XCTest
@testable import OmniAmp

final class PodcastTests: XCTestCase {
    private let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/">
    <channel>
      <title>Llama Radio Hour</title>
      <itunes:author>Nullsoft Fans</itunes:author>
      <itunes:image href="https://example.com/cover.jpg"/>
      <image><url>https://example.com/other.jpg</url><title>ignored</title></image>
      <item>
        <title>Episode 2: Skins</title>
        <pubDate>Tue, 03 Mar 2026 10:00:00 +0000</pubDate>
        <itunes:duration>1:02:03</itunes:duration>
        <description><![CDATA[<p>All about <b>skins</b> &amp; more.</p><p>Second paragraph.</p>]]></description>
        <enclosure url="https://example.com/ep2.mp3" length="123" type="audio/mpeg"/>
      </item>
      <item>
        <title>Episode 1: Intro</title>
        <pubDate>Mon, 2 Feb 2026 09:30:00 GMT</pubDate>
        <itunes:duration>754</itunes:duration>
        <itunes:image href="https://example.com/ep1.jpg"/>
        <enclosure url="https://example.com/ep1.m4a" type=""/>
      </item>
      <item>
        <title>Trailer (video)</title>
        <enclosure url="https://example.com/trailer.mp4" type="video/mp4"/>
      </item>
      <item><title>No audio at all</title></item>
    </channel>
    </rss>
    """

    func testFeedParsing() {
        let p = PodcastFeedParser.parse(Data(feed.utf8))
        XCTAssertEqual(p.title, "Llama Radio Hour")
        XCTAssertEqual(p.author, "Nullsoft Fans")
        XCTAssertEqual(p.artwork, "https://example.com/cover.jpg", "the channel's itunes:image, not an episode's")
        XCTAssertEqual(p.episodes.map(\.title), ["Episode 2: Skins", "Episode 1: Intro"], "video and enclosure-less items are skipped")
        let e2 = p.episodes[0]
        XCTAssertEqual(e2.url, "https://example.com/ep2.mp3")
        XCTAssertEqual(e2.duration, 3723)
        XCTAssertEqual(e2.published, 1_772_532_000)
        XCTAssertEqual(e2.summary, "All about skins & more.\nSecond paragraph.")
        XCTAssertEqual(p.episodes[1].duration, 754)
        XCTAssertNotNil(p.episodes[1].published, "single-digit day and GMT zone")
    }

    func testDurationAndDates() {
        XCTAssertEqual(PodcastFeedParser.duration("62:03"), 3723)
        XCTAssertEqual(PodcastFeedParser.duration("45"), 45)
        XCTAssertNil(PodcastFeedParser.duration("about an hour"))
        XCTAssertNil(PodcastFeedParser.date("yesterday"))
    }

    func testDirectoryDecoding() {
        let lookup = """
        {"resultCount":2,"results":[
          {"collectionId":42,"collectionName":"The Show","artistName":"Host","feedUrl":"https://f.example/rss",
           "artworkUrl600":"https://a.example/600.jpg","primaryGenreName":"History"},
          {"collectionId":43,"collectionName":"No Feed"}]}
        """
        let shows = PodcastDirectory.decodeLookup(Data(lookup.utf8))
        XCTAssertEqual(shows, [PodcastShow(feedURL: "https://f.example/rss", title: "The Show", author: "Host",
                                           artwork: "https://a.example/600.jpg", genre: "History")])
        let chart = #"{"feed":{"results":[{"id":"43"},{"id":"42"}]}}"#
        XCTAssertEqual(PodcastDirectory.decodeChartIDs(Data(chart.utf8)), ["43", "42"])
    }

    func testEpisodeTracksAreNotRadio() {
        let show = PodcastShow(feedURL: "https://f.example/rss", title: "The Show", author: "Host", artwork: "https://a.example/a.jpg")
        let t = PodcastEpisode(title: "Pilot", url: "https://f.example/1.mp3", published: 1000, duration: 1800, summary: "Notes").track(show: show)
        XCTAssertTrue(t.isEpisode)
        XCTAssertFalse(t.isStream)
        XCTAssertTrue(t.isRemote)
        XCTAssertEqual(t.displayTitle, "The Show - Pilot")
        XCTAssertTrue(Track.stream("https://radio.example/live", name: "Live").isStream)
        XCTAssertFalse(Track.stream("https://radio.example/live", name: "Live").isEpisode)
    }

    func testEpisodesSurviveM3U() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-pod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let show = PodcastShow(feedURL: "https://f.example/rss", title: "The \"Best\" Show", author: "Host", artwork: "https://a.example/a.jpg")
        let ep = PodcastEpisode(title: "Pilot", url: "https://f.example/1.mp3", published: nil, duration: 1800, summary: nil).track(show: show)
        let m3u = dir.appendingPathComponent("pods.m3u")
        try PlaylistFile.writeM3U([ep, .stream("https://radio.example/live", name: "Live")], to: m3u)
        let entries = PlaylistFile.entries(m3u)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].podcast, "The 'Best' Show")
        XCTAssertEqual(entries[0].seconds, 1800)
        XCTAssertEqual(entries[0].logo, "https://a.example/a.jpg")
        XCTAssertNil(entries[1].podcast, "radio stays radio")
    }

    func testLibrarySubscriptionsPlayedAndNewCounts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-podlib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let show = PodcastShow(feedURL: "https://example.com/feed", title: "Llama Radio Hour", author: "Nullsoft Fans")

        struct FeedTransport: HTTPTransport {
            let body: Data
            func send(_ req: URLRequest) async throws -> (Data, Int) { (body, 200) }
        }

        let lib = PodcastLibrary(directory: dir)
        lib.transport = FeedTransport(body: Data(feed.utf8))
        let eps = try awaitResult { try await lib.episodes(show) }
        XCTAssertEqual(eps.first?.title, "Episode 2: Skins", "newest first")

        XCTAssertFalse(lib.isSubscribed(show))
        lib.toggleSubscription(show)
        XCTAssertTrue(lib.isSubscribed(show))
        XCTAssertEqual(lib.newCount(show), 0, "episodes out before subscribing aren't new")

        lib.markPlayed(eps[0].url)
        XCTAssertTrue(lib.isPlayed(eps[0].url))

        // Everything is saved: a fresh library sees the same state (and the cached feed, offline).
        let again = PodcastLibrary(directory: dir)
        XCTAssertTrue(again.isSubscribed(show))
        XCTAssertTrue(again.isPlayed(eps[0].url))
        XCTAssertEqual(again.cachedEpisodes(show).count, 2)

        lib.toggleSubscription(show)
        XCTAssertFalse(lib.isSubscribed(show))
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
