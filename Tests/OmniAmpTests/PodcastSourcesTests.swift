import XCTest
@testable import OmniAmp

@MainActor
final class PodcastSourcesTests: XCTestCase {
    func testReadsOPMLFromOtherApps() {
        let opml = """
        <?xml version="1.0" encoding="utf-8"?>
        <opml version="1.0"><head><title>Pocket Casts Feeds</title></head><body>
          <outline text="feeds">
            <outline type="rss" text="Stay Forever" xmlUrl="https://example.com/sf.xml"/>
            <outline text="Folder"><outline type="rss" title="The Daily" text="ignored" xmlURL="https://example.com/daily"/></outline>
            <outline type="rss" text="Duplicate" xmlUrl="https://example.com/sf.xml"/>
            <outline type="link" text="Not a feed" url="https://example.com"/>
            <outline type="rss" text="Local" xmlUrl="file:///etc/passwd"/>
          </outline>
        </body></opml>
        """
        let shows = PodcastOPML.read(Data(opml.utf8))
        XCTAssertEqual(shows.map(\.title), ["Stay Forever", "The Daily"], "nested folders, any attribute case, no duplicates or non-web feeds")
        XCTAssertEqual(shows.map(\.feedURL), ["https://example.com/sf.xml", "https://example.com/daily"])
    }

    func testExportedOPMLReadsBack() {
        let shows = [PodcastShow(feedURL: "https://example.com/a?x=1&y=2", title: "Rock & \"Roll\" <Hour>", author: "A", artwork: "https://example.com/a.jpg"),
                     PodcastShow(feedURL: "https://example.com/b", title: "B", author: "")]
        let back = PodcastOPML.read(PodcastOPML.write(shows))
        XCTAssertEqual(back.map(\.feedURL), shows.map(\.feedURL))
        XCTAssertEqual(back.map(\.title), shows.map(\.title), "escaped and unescaped")
        XCTAssertEqual(back.first?.artwork, "https://example.com/a.jpg")
    }

    func testMergeAddsOnlyMissingShows() {
        let apple = [PodcastShow(feedURL: "https://feeds.example.com/daily/", title: "The Daily", author: "NYT"),
                     PodcastShow(feedURL: "https://a.example.com/sf", title: "Stay Forever", author: "Stay Forever Team")]
        let fyyd = [PodcastShow(feedURL: "http://www.feeds.example.com/daily", title: "The Daily", author: "The New York Times"),   // same feed
                    PodcastShow(feedURL: "https://b.example.com/sf-mp3", title: "Stay Forever", author: "Stay Forever Team"),     // same show
                    PodcastShow(feedURL: "https://c.example.com/indie", title: "Indie Show", author: "Someone")]
        XCTAssertEqual(PodcastDirectory.merge(apple, fyyd).map(\.title), ["The Daily", "Stay Forever", "Indie Show"])
    }

    func testFyydResultsMustMatchTheSearch() {
        let shows = [PodcastShow(feedURL: "a", title: "Stay Forever - Retrogames & Technik", author: "Stay Forever Team"),
                     PodcastShow(feedURL: "b", title: "Ben & Liam", author: "KIIS 1023"),
                     PodcastShow(feedURL: "c", title: "Retro Talk", author: "Stay Forever Crew")]
        XCTAssertEqual(PodcastDirectory.relevant(shows, to: "Stay forever").map(\.feedURL), ["a", "c"])
    }

    func testDecodesFyyd() {
        let json = #"{"status":1,"msg":"ok","data":[{"title":"Stay Forever - Retrogames & Technik","author":"Stay Forever Team","xmlURL":"https://podcastd45a61.podigee.io/feed/mp3","imgURL":"https://img/full.jpg","layoutImageURL":"https://img/layout.jpg"},{"title":"No feed"}]}"#
        let shows = PodcastDirectory.decodeFyyd(Data(json.utf8))
        XCTAssertEqual(shows.count, 1)
        XCTAssertEqual(shows[0].feedURL, "https://podcastd45a61.podigee.io/feed/mp3")
        XCTAssertEqual(shows[0].artwork, "https://img/layout.jpg")
        XCTAssertEqual(shows[0].author, "Stay Forever Team")
    }

    func testImportedShowGetsItsDetailsFromTheFeed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-opml-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        struct Feed: HTTPTransport {
            func send(_ req: URLRequest) async throws -> (Data, Int) {
                (Data("""
                <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Real Title</title>
                <itunes:author>Real Author</itunes:author><itunes:image href="https://example.com/cover.jpg"/>
                <item><title>E1</title><pubDate>Tue, 03 Mar 2026 10:00:00 +0000</pubDate><enclosure url="https://example.com/1.mp3" type="audio/mpeg"/></item>
                </channel></rss>
                """.utf8), 200)
            }
        }
        let lib = PodcastLibrary(directory: dir)
        lib.transport = Feed()
        let imported = PodcastShow(feedURL: "https://example.com/feed", title: "https://example.com/feed", author: "")
        XCTAssertEqual(lib.subscribe([imported, imported]), 1)
        XCTAssertEqual(lib.subscribe([imported]), 0, "already subscribed")

        let done = expectation(description: "feed")
        Task { @MainActor in _ = try? await lib.episodes(imported); done.fulfill() }
        wait(for: [done], timeout: 5)
        let s = try XCTUnwrap(lib.subscriptions.first)
        XCTAssertEqual(s.title, "Real Title")
        XCTAssertEqual(s.author, "Real Author")
        XCTAssertEqual(s.artwork, "https://example.com/cover.jpg")
        XCTAssertEqual(lib.newCount(s), 0, "what was out at import isn't new")
    }

    func testListCoversAskForSmallAppleImages() {
        XCTAssertEqual(LogoStore.thumbnail("https://is1-ssl.mzstatic.com/image/thumb/P/v4/x.jpg/600x600bb.jpg"),
                       "https://is1-ssl.mzstatic.com/image/thumb/P/v4/x.jpg/120x120bb.jpg")
        XCTAssertEqual(LogoStore.thumbnail("https://example.com/600x600bb.jpg"), "https://example.com/600x600bb.jpg", "only Apple's image server")
        XCTAssertNil(LogoStore.thumbnail(nil))
    }

    /// Counts requests and answers like Apple's chart and lookup services.
    final class CountingDirectory: HTTPTransport, @unchecked Sendable {
        var requests: [String] = []
        func send(_ req: URLRequest) async throws -> (Data, Int) {
            let u = req.url!.absoluteString
            requests.append(u)
            if u.contains("marketingtools") { return (Data(#"{"feed":{"results":[{"id":"1"}]}}"#.utf8), 200) }
            if u.contains("lookup") || u.contains("search") {
                return (Data(#"{"results":[{"collectionId":1,"collectionName":"Chart Show","artistName":"A","feedUrl":"https://example.com/f"}]}"#.utf8), 200)
            }
            return (Data(), 404)
        }
    }

    @MainActor
    func testChartAndSearchAreRemembered() async throws {
        let net = CountingDirectory()
        let dir = PodcastDirectory()
        dir.transport = net
        let cc = "Z" + UUID().uuidString.prefix(8)   // a country no other test (or earlier run's saved chart) uses
        XCTAssertNil(dir.cachedTop(country: cc))
        let first = try await dir.top(country: cc)
        XCTAssertEqual(first.map(\.title), ["Chart Show"])
        XCTAssertEqual(net.requests.count, 2, "chart + lookup")
        _ = try await dir.top(country: cc)
        XCTAssertEqual(net.requests.count, 2, "a recent chart comes from the cache")
        XCTAssertEqual(PodcastDirectory().cachedTop(country: cc)?.shows.first?.title, "Chart Show", "kept on disk for the next launch")

        _ = try await dir.searchApple("Llama", country: cc)
        _ = try await dir.searchApple("llama", country: cc)
        XCTAssertEqual(net.requests.count, 3, "the same search again is instant")
    }
}

@MainActor
final class FeedRobustnessTests: XCTestCase {
    func testRepairMakesSloppyFeedsParse() {
        let xml = """
        <rss><channel><title>Tom &amp; Jerry&nbsp;Show</title>
        <item><title>Part 1 &hellip; the start</title><enclosure url="https://e.com/1.mp3?a=1&b=2" type="audio/mpeg"/>
          <description><![CDATA[<p>Keep &nbsp; literally & fine</p>]]></description></item>
        <item><title>R&D &unknown; stuff</title><enclosure url="https://e.com/2.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """
        let p = PodcastFeedParser.parse(Data(xml.utf8))
        XCTAssertFalse(p.failed)
        XCTAssertEqual(p.title, "Tom & Jerry\u{A0}Show")
        XCTAssertEqual(p.episodes.map(\.title), ["Part 1 … the start", "R&D &unknown; stuff"])
        XCTAssertEqual(p.episodes.first?.url, "https://e.com/1.mp3?a=1&b=2")
        XCTAssertEqual(p.episodes.first?.summary, "Keep literally & fine", "CDATA left alone: the notes cleanup turns &nbsp; into a space itself")
    }

    func testBrokenResponseKeepsTheSavedEpisodes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-feedkeep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        final class Switch: HTTPTransport, @unchecked Sendable {
            var body = ""
            func send(_ req: URLRequest) async throws -> (Data, Int) { (Data(body.utf8), 200) }
        }
        let net = Switch()
        let lib = PodcastLibrary(directory: dir)
        lib.transport = net
        let show = PodcastShow(feedURL: "https://example.com/feed", title: "S", author: "")
        net.body = #"<rss><channel><title>S</title><item><title>E1</title><enclosure url="https://e.com/1.mp3" type="audio/mpeg"/></item></channel></rss>"#

        func fetch() -> Result<[PodcastEpisode], Error> {
            let done = expectation(description: "feed")
            var r: Result<[PodcastEpisode], Error>!
            Task { @MainActor in
                do { r = .success(try await lib.episodes(show, maxAge: 0)) } catch { r = .failure(error) }
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            return r
        }
        XCTAssertEqual(try fetch().get().count, 1)

        net.body = "<html><body><h1>Please log in to the Wi-Fi</h1></body></html>"   // captive portal, HTTP 200
        XCTAssertThrowsError(try fetch().get())
        XCTAssertEqual(lib.cachedEpisodes(show).map(\.title), ["E1"], "the saved episodes survive")
        PodcastLibrary.writes.sync {}
        XCTAssertEqual(PodcastLibrary(directory: dir).cachedEpisodes(show).count, 1, "on disk too")
    }

    func testDamagedOPMLReportsAPartialImport() {
        let opml = #"<opml><body><outline type="rss" text="A" xmlUrl="https://a.com/f"/><outline text="<<broken"#
        let r = PodcastOPML.parse(Data(opml.utf8))
        XCTAssertEqual(r.shows.map(\.title), ["A"])
        XCTAssertFalse(r.complete)
        let amp = #"<opml><body><outline type="rss" text="B & C" xmlUrl="https://b.com/f?x=1&y=2"/></body></opml>"#
        let r2 = PodcastOPML.parse(Data(amp.utf8))
        XCTAssertTrue(r2.complete, "bare & from sloppy exporters is repaired")
        XCTAssertEqual(r2.shows.first?.feedURL, "https://b.com/f?x=1&y=2")
    }
}
