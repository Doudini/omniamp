import XCTest
@testable import OmniAmp

/// Tags written with the file's date kept still reach the library: the files are marked, the folder scanned again.
final class RereadTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-reread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("music/Album"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// An MP3 with an ID3v2.3 tag (title, artist, album) and room to spare, so a new tag fits in place (same size).
    private func mp3(_ url: URL) throws {
        func frame(_ id: String, _ text: String) -> [UInt8] {
            let body: [UInt8] = [3] + Array(text.utf8)
            return Array(id.utf8) + [0, 0, UInt8(body.count >> 8), UInt8(body.count & 0xFF), 0, 0] + body
        }
        let frames = frame("TIT2", "Blew") + frame("TPE1", "Nirvana") + frame("TALB", "Bleach")
        let size = frames.count + 2048
        let tag = Array("ID3".utf8) + [3, 0, 0] + [UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)]
            + frames + [UInt8](repeating: 0, count: 2048)
        var audio: [UInt8] = []
        for i in 0..<50 { audio += [0xFF, 0xFB, 0x90, 0x00] + (0..<413).map { UInt8(($0 + i) & 0xFF) } }
        try Data(tag + audio).write(to: url)
    }

    private func scan(_ scanner: CollectionScanner, _ folder: String, root: String) {
        let done = expectation(description: "scanned")
        scanner.scan([folder], roots: [root]) { done.fulfill() }
        wait(for: [done], timeout: 20)
    }

    func testTagsWrittenWithTheDateKeptAreReadAgain() throws {
        let root = tmp.appendingPathComponent("music").path, folder = root + "/Album", file = folder + "/01 Blew.mp3"
        try mp3(URL(fileURLWithPath: file))
        let old = Date(timeIntervalSince1970: 1_262_304_000)   // 2010-01-01
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file)
        let db = try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite"))
        let scanner = CollectionScanner(db: db)
        scan(scanner, folder, root: root)
        XCTAssertEqual(try db.albumsWhere("1", [], order: "a.title").map(\.title), ["Bleach"])

        // Find Missing Info: a new album name, same size and date: a plain rescan wouldn't notice.
        let size = try FileManager.default.attributesOfItem(atPath: file)[.size] as? Int
        XCTAssertEqual(TagWriter.write(BasicTags(album: "Bleach (Deluxe)"), to: file, backupDir: nil), .written)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file)[.size] as? Int, size)
        scan(scanner, folder, root: root)
        XCTAssertEqual(try db.albumsWhere("1", [], order: "a.title").map(\.title), ["Bleach"], "unchanged to a scan by size and date")

        scanner.markChanged(paths: [file])
        scan(scanner, folder, root: root)
        let albums = try db.albumsWhere("1", [], order: "a.title")
        XCTAssertEqual(albums.map(\.title), ["Bleach (Deluxe)"])
        XCTAssertEqual(albums.first?.added, old.timeIntervalSince1970, "still added in 2010")
    }
}
