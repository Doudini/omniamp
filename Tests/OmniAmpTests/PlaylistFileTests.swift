import XCTest
@testable import OmniAmp

final class PlaylistFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-pl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("music"), withIntermediateDirectories: true)
        for n in ["a.mp3", "b.flac", "c.mp3"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("music/\(n)").path, contents: Data([0]))
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Long playlists are looked up in slices, several files at once, and handed over slice by slice: the order
    /// stays the playlist's, across slices too.
    func testLongM3UKeepsOrderAcrossSlices() throws {
        var lines = ["#EXTM3U"], expected: [String] = []
        for i in 0..<700 {
            let name = String(format: "%04d.mp3", 699 - i)   // reverse of name order
            if i % 97 == 0 { lines.append("music/gone-\(i).mp3"); continue }
            if i == 300 { lines.append("http://radio.example/stream"); expected.append("stream") }
            FileManager.default.createFile(atPath: dir.appendingPathComponent("music/\(name)").path, contents: Data([0]))
            lines.append("music/\(name)")
            expected.append(name)
        }
        let m3u = dir.appendingPathComponent("long.m3u8")
        try lines.joined(separator: "\n").write(to: m3u, atomically: true, encoding: .utf8)
        var batches = 0, names: [String] = []
        FolderScanner.scan([m3u], batch: { b in batches += 1; names += b.map { ($0.path as NSString).lastPathComponent } })
        XCTAssertEqual(names, expected)
        XCTAssertGreaterThan(batches, 1, "handed over in slices")
    }

    func testM3URoundTripKeepsOrderAndDropsMissing() throws {
        let m3u = dir.appendingPathComponent("list.m3u8")
        let text = "#EXTM3U\n#EXTINF:12,Someone - C\nmusic/c.mp3\n\(dir.path)/music/a.mp3\nmusic/missing.mp3\nhttp://radio.example/stream\n"
        try text.write(to: m3u, atomically: true, encoding: .utf8)
        let names = FolderScanner.scan([m3u]).map { ($0.path as NSString).lastPathComponent }
        // Missing files are dropped; the http entry is an internet radio station and is kept.
        XCTAssertEqual(names, ["c.mp3", "a.mp3", "stream"])

        // Write it back out and read again.
        let tracks = FolderScanner.scan([m3u])
        let out = dir.appendingPathComponent("out.m3u8")
        try PlaylistFile.writeM3U(tracks, to: out)
        XCTAssertTrue(try String(contentsOf: out, encoding: .utf8).hasPrefix("#EXTM3U\n#EXTINF:"))
        XCTAssertEqual(FolderScanner.scan([out]).map(\.path), tracks.map(\.path))
    }

    func testPLS() throws {
        let pls = dir.appendingPathComponent("list.pls")
        try "[playlist]\nFile1=music/b.flac\nTitle1=B\nFile2=music/a.mp3\nNumberOfEntries=2\nVersion=2\n"
            .write(to: pls, atomically: true, encoding: .utf8)
        XCTAssertEqual(FolderScanner.scan([pls]).map { ($0.path as NSString).lastPathComponent }, ["b.flac", "a.mp3"])
    }
}

final class PlaylistSanitizingTests: XCTestCase {
    func testTitlesCannotInjectEntriesAndWebFilesStayFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-m3u-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var evil = Track.stream("https://radio.example.com/live", name: "Evil\r/tmp/other.mp3\u{2028}more", logo: "https://x.com/\"logo\".png")
        evil.tagsLoaded = true
        let web = Track.webFile("https://example.com/talk.mp3", title: "A Talk")
        let m3u = dir.appendingPathComponent("x.m3u")
        try PlaylistFile.writeM3U([evil, web], to: m3u)
        let back = PlaylistFile.entries(m3u)
        XCTAssertEqual(back.count, 2, "no injected entry")
        XCTAssertEqual(back[0].logo, "https://x.com/'logo'.png")
        XCTAssertTrue(back[1].web)
        let tracks = FolderScanner.scan([m3u])
        XCTAssertTrue(tracks[1].isWebFile, "a web file comes back as a web file, not a station")
        XCTAssertFalse(tracks[1].isStream)
    }

    func testOPMLExportDropsControlCharacters() {
        let shows = [PodcastShow(feedURL: "https://a.com/f", title: "A", author: ""),
                     PodcastShow(feedURL: "https://b.com/f", title: "B\u{1}ad", author: ""),
                     PodcastShow(feedURL: "https://c.com/f", title: "C", author: "")]
        XCTAssertEqual(PodcastOPML.read(PodcastOPML.write(shows)).count, 3)
    }
}
