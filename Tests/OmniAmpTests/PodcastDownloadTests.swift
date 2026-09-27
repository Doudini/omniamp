import XCTest
@testable import OmniAmp

final class PodcastDownloadTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let show = PodcastShow(feedURL: "https://example.com/feed", title: "Llama Radio Hour", author: "Nullsoft Fans")

    func testFileNamesAreReadableAndSafe() {
        let e = PodcastEpisode(title: "Ep. 12: AC/DC? Yes!", url: "u", published: nil, duration: nil, summary: nil)
        XCTAssertEqual(PodcastDownloads.fileName(for: e, show: show, ext: "mp3"), "Llama Radio Hour - Ep. 12- AC-DC- Yes!.mp3")
        let long = PodcastEpisode(title: String(repeating: "x", count: 300), url: "u", published: nil, duration: nil, summary: nil)
        XCTAssertLessThanOrEqual(PodcastDownloads.fileName(for: long, show: show, ext: "m4a").count, 124)

        XCTAssertEqual(PodcastDownloads.fileExtension(for: "https://cdn.example.com/ep/42.m4a?token=abc", response: nil), "m4a")
        // Tracking redirect without an extension: the MIME type decides.
        let r = URLResponse(url: URL(string: "https://track.example.com/x")!, mimeType: "audio/mpeg", expectedContentLength: 1, textEncodingName: nil)
        XCTAssertEqual(PodcastDownloads.fileExtension(for: "https://track.example.com/x", response: r), "mp3")
    }

    func testChangingTheFolderMovesDownloads() throws {
        let source = dir.appendingPathComponent("src.mp3")
        try Data(repeating: 3, count: 2000).write(to: source)
        let ep = PodcastEpisode(title: "Episode 9", url: source.absoluteString, published: nil, duration: nil, summary: nil)
        let d = PodcastDownloads(directory: dir.appendingPathComponent("a"))
        let done = expectation(forNotification: PodcastDownloads.changed, object: ep.url) { _ in d.state(ep.url) == .done }
        d.download(ep, show: show)
        wait(for: [done], timeout: 10)
        XCTAssertEqual(d.localFile(ep.url)?.lastPathComponent, "Llama Radio Hour - Episode 9.mp3")

        let b = dir.appendingPathComponent("b")
        let key = PodcastDownloads.folderKey
        let before = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        XCTAssertNil(d.setFolder(b))
        XCTAssertEqual(d.localFile(ep.url)?.deletingLastPathComponent().standardizedFileURL.path, b.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a/Llama Radio Hour - Episode 9.mp3").path))
    }

    func testDownloadPlaysLocallyAndIsRemembered() throws {
        let source = dir.appendingPathComponent("source.mp3")
        try Data(repeating: 7, count: 50_000).write(to: source)
        let ep = PodcastEpisode(title: "Episode 1", url: source.absoluteString, published: 1, duration: 60, summary: nil)
        let store = dir.appendingPathComponent("store")
        let d = PodcastDownloads(directory: store)
        XCTAssertEqual(d.state(ep.url), .none)

        let done = expectation(forNotification: PodcastDownloads.changed, object: ep.url) { _ in d.state(ep.url) == .done }
        d.download(ep, show: show)
        XCTAssertNotEqual(d.state(ep.url), .none, "queued or running at once")
        wait(for: [done], timeout: 10)

        let file = try XCTUnwrap(d.localFile(ep.url))
        XCTAssertEqual(try Data(contentsOf: file).count, 50_000)
        XCTAssertEqual(d.totalBytes, 50_000)
        XCTAssertEqual(d.all.first?.show.title, "Llama Radio Hour")

        // A fresh instance (next launch) still knows it.
        let again = PodcastDownloads(directory: store)
        XCTAssertEqual(again.state(ep.url), .done)
        XCTAssertEqual(again.localFile(ep.url), file)

        again.remove(ep.url)
        XCTAssertEqual(again.state(ep.url), .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(PodcastDownloads(directory: store).state(ep.url), .none, "removal is saved")
    }

    func testMissingFileIsForgotten() throws {
        let source = dir.appendingPathComponent("s.mp3")
        try Data(repeating: 1, count: 1000).write(to: source)
        let ep = PodcastEpisode(title: "E", url: source.absoluteString, published: nil, duration: nil, summary: nil)
        let store = dir.appendingPathComponent("store2")
        let d = PodcastDownloads(directory: store)
        let done = expectation(forNotification: PodcastDownloads.changed, object: ep.url) { _ in d.state(ep.url) == .done }
        d.download(ep, show: show)
        wait(for: [done], timeout: 10)
        try FileManager.default.removeItem(at: XCTUnwrap(d.localFile(ep.url)))   // deleted behind our back
        XCTAssertEqual(PodcastDownloads(directory: store).state(ep.url), .none)
    }

    func testRelativeDates() {
        let now = Date().timeIntervalSince1970
        XCTAssertEqual(PodcastWindowController.relative(now), "today")
        XCTAssertFalse(PodcastWindowController.relative(now - 3 * 86_400).isEmpty)
    }
}
