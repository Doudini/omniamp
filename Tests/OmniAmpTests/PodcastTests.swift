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

    func testEpisodeImageNumbersAndLinks() {
        let xml = """
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
          <title>Show</title><itunes:image href="https://example.com/show.jpg"/>
          <item>
            <title>Deep dive</title>
            <itunes:image href="https://example.com/ep.jpg"/>
            <itunes:season>2</itunes:season><itunes:episode>14</itunes:episode>
            <description><![CDATA[<p>Read <a href="https://example.com/post?a=1&amp;b=2">the post</a> or
              <a href='mailto:hi@example.com'>mail us</a>. <a href="javascript:x()">nope</a></p>
              <p>Also https://example.org/bare</p>]]></description>
            <enclosure url="https://example.com/e.mp3" type="audio/mpeg"/>
          </item>
          <item><title>Plain</title><enclosure url="https://example.com/p.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """
        let p = PodcastFeedParser.parse(Data(xml.utf8))
        let show = PodcastShow(feedURL: "f", title: "Show", author: "", artwork: "https://example.com/show.jpg")
        let e = p.episodes[0]
        XCTAssertEqual(p.artwork, "https://example.com/show.jpg", "an episode image doesn't replace the show's")
        XCTAssertEqual(e.image, "https://example.com/ep.jpg")
        XCTAssertEqual(e.artwork(show: show), "https://example.com/ep.jpg")
        XCTAssertEqual(p.episodes[1].artwork(show: show), "https://example.com/show.jpg", "falls back to the show cover")
        XCTAssertEqual(e.season, 2)
        XCTAssertEqual(e.number, 14)
        XCTAssertEqual(e.links, [["the post", "https://example.com/post?a=1&b=2"], ["mail us", "mailto:hi@example.com"]],
                       "web and mail links only")
        XCTAssertNil(p.episodes[1].links)

        // In the notes pane the link texts become links again, and bare addresses are found too.
        let notes = EpisodeNotesView.notes(e, font: .systemFont(ofSize: 11), color: .white)
        var found: [String: String] = [:]
        notes.enumerateAttribute(.link, in: NSRange(location: 0, length: notes.length)) { v, r, _ in
            if let u = v as? URL { found[(notes.string as NSString).substring(with: r)] = u.absoluteString }
        }
        XCTAssertEqual(found["the post"], "https://example.com/post?a=1&b=2")
        XCTAssertEqual(found["mail us"], "mailto:hi@example.com")
        XCTAssertEqual(found["https://example.org/bare"], "https://example.org/bare")
        XCTAssertNil(found["nope"])
    }

    func testOlderCachedEpisodesStillDecode() throws {
        // Feed caches written before episodes had images, numbers and links.
        let old = #"[{"title":"Old","url":"https://example.com/o.mp3","published":1,"duration":60,"summary":"s"}]"#
        let eps = try JSONDecoder().decode([PodcastEpisode].self, from: Data(old.utf8))
        XCTAssertEqual(eps.first?.title, "Old")
        XCTAssertNil(eps.first?.image)
        XCTAssertNil(eps.first?.links)
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
        PodcastLibrary.writes.sync {}
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

final class PlayedPruningTests: XCTestCase {
    func testOldestMarksGoFirstAndNewOnesStay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-played-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // An older build's list (no dates), already long.
        let old = (0..<20_500).map { "https://old.example.com/\($0).mp3" }
        try JSONEncoder().encode(old).write(to: dir.appendingPathComponent("played.json"))
        let lib = PodcastLibrary(directory: dir)
        XCTAssertTrue(lib.isPlayed(old[0]), "the old format still loads")

        let fresh = (0..<50).map { "https://new.example.com/\($0).mp3" }
        lib.markPlayed(fresh)
        lib.markPlayed("https://new.example.com/single.mp3")
        XCTAssertTrue(fresh.allSatisfy { lib.isPlayed($0) }, "what was just marked is never the part that's dropped")
        XCTAssertTrue(lib.isPlayed("https://new.example.com/single.mp3"))
        XCTAssertLessThan(old.filter { lib.isPlayed($0) }.count, old.count, "the list was trimmed, from the old end")

        let again = PodcastLibrary(directory: dir)
        XCTAssertTrue(again.isPlayed("https://new.example.com/single.mp3"), "saved with dates")
    }
}

final class ContinueListeningMemoryTests: XCTestCase {
    func testStartedEpisodeOfAnUnsubscribedShowIsFoundAfterRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = PodcastLibrary(directory: dir)
        let url = "https://example.com/unsubscribed/ep1.mp3"
        let t = Track.episode(url, title: "Ep 1", show: "Browsed Show", artwork: "https://example.com/c.jpg", duration: 3600,
                              published: 1, summary: "notes")
        lib.noteListened(url, track: t)
        let again = PodcastLibrary(directory: dir)   // relaunch: no feeds in memory, not subscribed
        let found = try XCTUnwrap(again.lookup(url))
        XCTAssertEqual(found.episode.title, "Ep 1")
        XCTAssertEqual(found.show.title, "Browsed Show")
        XCTAssertEqual(found.episode.artwork(show: found.show), "https://example.com/c.jpg")

        let web = Track.webFile("https://example.com/talk.mp3", title: "A Talk")
        lib.noteListened(web.path, track: web)
        XCTAssertEqual(PodcastLibrary(directory: dir).lookup(web.path)?.show.title, "Web audio", "no empty show name")
    }
}
