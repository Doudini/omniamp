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
