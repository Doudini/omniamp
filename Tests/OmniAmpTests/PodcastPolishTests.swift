import AppKit
import AVFoundation
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


final class LongFileSegmentTests: XCTestCase {
    func testLongTracksAreScheduledInPiecesThatFitASegment() {
        // 30 h at 44.1 kHz: more frames than one segment (UInt32) can hold; converting trapped.
        let frames = AVAudioFramePosition(30 * 3600 * 44_100)
        let parts = AudioPlayer.segments(from: 1000, count: frames)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].start, 1000)
        XCTAssertEqual(parts[1].start, 1000 + AVAudioFramePosition(parts[0].frames), "back to back, no gap or overlap")
        XCTAssertEqual(parts.reduce(0) { $0 + AVAudioFramePosition($1.frames) }, frames)
        XCTAssertEqual(AudioPlayer.segments(from: 0, count: 500).map(\.frames), [500], "normal tracks: one segment")
        XCTAssertEqual(AudioPlayer.segments(from: 0, count: 10, limit: 4).map(\.frames), [4, 4, 2])
    }
}

final class NotesLayoutTests: XCTestCase {
    func testFeedHTMLKeepsParagraphsAndLineBreaksApart() {
        let html = "<p>First  paragraph,<br/>same one. </p><p>Werbung: </p><ul><li>One</li><li>Two</li></ul>\r\n\r\n\r\n<p>End</p>"
        XCTAssertEqual(PodcastFeedParser.plainText(html), "First paragraph,\nsame one.\n\nWerbung:\n\nOne\nTwo\n\nEnd")
    }

    func testParagraphsAreSpacedAndLineBreaksStayInside() {
        XCTAssertEqual(NotesText.paragraphs("A\nB\n\nC"), "A\u{2028}B\nC", "blank line: new paragraph; single break: same paragraph")
        XCTAssertEqual(NotesText.paragraphs("Intro.\nWerbung: \nOffer.\nhttps://x.example"), "Intro.\nWerbung:\nOffer.\nhttps://x.example",
                       "older notes (no blank lines): every line is its own paragraph; no trailing spaces")
    }

    func testLinksAreClickableInTheTextsOwnFont() {
        let font = NSFont.systemFont(ofSize: 10)
        let s = NotesText.attributed("See the show page.\nhttps://linktr.ee/x", links: [["show page", "https://example.com/show"]],
                                     font: font, color: .green)
        let str = s.string as NSString
        XCTAssertEqual(s.attribute(.link, at: str.range(of: "show page").location, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com/show"))
        XCTAssertNotNil(s.attribute(.link, at: str.range(of: "linktr.ee").location, effectiveRange: nil), "bare addresses too")
        XCTAssertEqual(s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font)
        XCTAssertEqual((s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.hyphenationFactor, 0,
                       "a paragraph with a link isn't hyphenated (the link would break)")
        let t = NotesText.attributed("Just words here.", font: font, color: .green)
        XCTAssertGreaterThan((t.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.hyphenationFactor ?? 0, 0)
    }
}
