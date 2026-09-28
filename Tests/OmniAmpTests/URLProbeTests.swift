import XCTest
@testable import OmniAmp

final class URLProbeTests: XCTestCase {
    private func classify(_ url: String, type: String, headers: [String: String] = [:], body: String = "", endless: Bool = false) throws -> URLProbe.Result {
        try URLProbe.classify(url: URL(string: url)!, contentType: type, headers: headers, body: Data(body.utf8), endless: endless)
    }

    func testNormalize() {
        XCTAssertEqual(URLProbe.normalize("  stream.example.com/live  ")?.absoluteString, "https://stream.example.com/live")
        XCTAssertEqual(URLProbe.normalize("feed://example.com/rss")?.absoluteString, "https://example.com/rss")
        XCTAssertEqual(URLProbe.normalize("itpc://example.com/rss")?.absoluteString, "https://example.com/rss")
        XCTAssertEqual(URLProbe.normalize("<http://radio.example:8000/stream>")?.absoluteString, "http://radio.example:8000/stream")
        XCTAssertNil(URLProbe.normalize("hello world"))
        XCTAssertNil(URLProbe.normalize("ftp://example.com/file.mp3"))
        XCTAssertNil(URLProbe.normalize("justaword"))
    }

    func testApplePodcastLinks() {
        XCTAssertEqual(URLProbe.applePodcastID(URL(string: "https://podcasts.apple.com/us/podcast/the-daily/id1200361736?i=100")!), "1200361736")
        XCTAssertNil(URLProbe.applePodcastID(URL(string: "https://example.com/id1234")!))
    }

    func testLiveStations() throws {
        XCTAssertEqual(try classify("http://r.example/live", type: "audio/mpeg", headers: ["icy-name": "Groove Radio", "icy-br": "128"]),
                       .station(url: "http://r.example/live", name: "Groove Radio"))
        XCTAssertEqual(try classify("http://r.example/aac", type: "audio/aacp", endless: true), .station(url: "http://r.example/aac", name: nil))
        XCTAssertEqual(try classify("https://r.example/live.m3u8", type: "application/vnd.apple.mpegurl",
                                    body: "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=128000\nchunk.m3u8\n"),
                       .station(url: "https://r.example/live.m3u8", name: nil))
    }

    func testStationPlaylists() throws {
        let pls = "[playlist]\nFile1=http://s1.example/stream\nTitle1=Jazz One\nFile2=http://s2.example/stream\nNumberOfEntries=2\n"
        XCTAssertEqual(try classify("https://r.example/listen.pls", type: "audio/x-scpls", body: pls),
                       .stations([URLProbe.Station(url: "http://s1.example/stream", name: "Jazz One"),
                                  URLProbe.Station(url: "http://s2.example/stream", name: nil)]))
        let m3u = "#EXTM3U\n#EXTINF:-1,Talk\nhttps://t.example/talk.mp3\n"
        XCTAssertEqual(try classify("https://r.example/listen.m3u", type: "audio/x-mpegurl", body: m3u),
                       .stations([URLProbe.Station(url: "https://t.example/talk.mp3", name: "Talk")]))
        // Relative entries keep their folders and resolve against the playlist's address.
        let rel = "#EXTM3U\n#EXTINF:-1,Hi\nstreams/hi.mp3\n/root/low.aac\n"
        XCTAssertEqual(try classify("https://r.example/radio/listen.m3u", type: "audio/x-mpegurl", body: rel),
                       .stations([URLProbe.Station(url: "https://r.example/radio/streams/hi.mp3", name: "Hi"),
                                  URLProbe.Station(url: "https://r.example/root/low.aac", name: nil)]))
        XCTAssertThrowsError(try classify("https://r.example/empty.pls", type: "audio/x-scpls", body: "[playlist]\nNumberOfEntries=0\n"))
    }

    func testPodcastFeedAndWebFile() throws {
        let rss = """
        <?xml version="1.0"?><rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>My Private Show</title>
        <itunes:author>Me</itunes:author><itunes:image href="https://x.example/c.jpg"/></channel></rss>
        """
        XCTAssertEqual(try classify("https://x.example/feed?token=abc", type: "application/rss+xml", body: rss),
                       .podcast(PodcastShow(feedURL: "https://x.example/feed?token=abc", title: "My Private Show", author: "Me",
                                            artwork: "https://x.example/c.jpg")))
        XCTAssertEqual(try classify("https://x.example/audio/Talk%20One.mp3", type: "audio/mpeg"),
                       .file(url: "https://x.example/audio/Talk%20One.mp3", title: "Talk One"))
    }

    func testWebPagesAreRejectedWithAHelpfulMessage() {
        XCTAssertThrowsError(try classify("https://radio.example/", type: "text/html", body: "<!DOCTYPE html><html>")) { e in
            XCTAssertTrue(e.localizedDescription.contains("web page"))
        }
    }

    func testWebFileTracks() {
        let t = Track.webFile("https://x.example/a.mp3", title: "A")
        XCTAssertTrue(t.isEpisode)
        XCTAssertTrue(t.isWebFile)
        XCTAssertFalse(t.isStream)
        XCTAssertEqual(t.displayTitle, "A")
    }

    /// Real servers. Off by default (needs the network): OMNIAMP_NET_TESTS=1 swift test --filter URLProbeTests
    func testLiveProbes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OMNIAMP_NET_TESTS"] != nil, "network tests are opt-in")
        if case .station(_, let name) = try await URLProbe.probe("https://ice1.somafm.com/groovesalad-128-mp3") {
            XCTAssertNotNil(name)
        } else { XCTFail("SomaFM stream") }
        if case .stations(let list) = try await URLProbe.probe("https://somafm.com/groovesalad.pls") {
            XCTAssertFalse(list.isEmpty)
        } else { XCTFail("SomaFM .pls") }
        if case .podcast(let show) = try await URLProbe.probe("https://podcasts.apple.com/us/podcast/the-daily/id1200361736") {
            XCTAssertEqual(show.title, "The Daily")
        } else { XCTFail("Apple Podcasts link") }
        if case .podcast(let show) = try await URLProbe.probe("feeds.simplecast.com/EmVW7VGp") {
            XCTAssertFalse(show.title.isEmpty)
        } else { XCTFail("RSS feed without scheme") }
    }
}
