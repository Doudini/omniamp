import XCTest
@testable import OmniAmp

/// Dragging a release out of the library: a loose release sharing its folder carries only its own files.
@MainActor
final class LibraryDragTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func file(_ path: String, artist: String, album: String, title: String, folder: String) -> LibraryFile {
        var info = TagInfo()
        info.duration = 200
        return LibraryFile(key: path, path: path, root: "/m", size: 1, mtime: 1, cueStart: nil, cueEnd: nil, cueNumber: nil, info: info,
                           result: .init(kind: .album, artist: artist, album: album, year: 2021, showDate: nil, venue: nil, albumFolder: folder),
                           title: title)
    }

    func testSharedFolderReleaseDragsItsOwnFiles() throws {
        let d = try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite"))
        try d.upsert([
            // One download folder, three releases told apart by their tags; and an album with a folder of its own.
            file("/m/Downloads/01 Muye.mp3", artist: "Adam Port", album: "Muyè", title: "Muyè", folder: "/m/Downloads"),
            file("/m/Downloads/02 Rapture.flac", artist: "&ME", album: "The Rapture III", title: "The Rapture III", folder: "/m/Downloads"),
            file("/m/Downloads/03 Rapture Edit.flac", artist: "&ME", album: "The Rapture III", title: "The Rapture III (Edit)", folder: "/m/Downloads"),
            file("/m/Downloads/04 Finally.mp3", artist: "Kings of Tomorrow", album: "Finally", title: "Finally", folder: "/m/Downloads"),
            file("/m/Bleach/01 Blew.flac", artist: "Nirvana", album: "Bleach", title: "Blew", folder: "/m/Bleach"),
        ])
        let albums = try d.albumsWhere("1", [], order: "a.title")
        let rapture = try XCTUnwrap(albums.first { $0.title == "The Rapture III" })
        let bleach = try XCTUnwrap(albums.first { $0.title == "Bleach" })
        XCTAssertTrue(rapture.sharedFolder)
        XCTAssertFalse(bleach.sharedFolder)

        let pb = NSPasteboard(name: NSPasteboard.Name("omniamp-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([LibraryDrag.writer(for: rapture, db: d)])
        XCTAssertEqual(LibraryDrag.urls(from: pb).map(\.path), ["/m/Downloads/02 Rapture.flac", "/m/Downloads/03 Rapture Edit.flac"])
        // Finder and other apps see a file of the release, not the folder.
        XCTAssertEqual(pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.count, 1)

        // An album with its folder drags the folder, as before; dragged together, each gives what it should.
        pb.clearContents()
        pb.writeObjects([LibraryDrag.writer(for: bleach, db: d), LibraryDrag.writer(for: rapture, db: d)])
        XCTAssertEqual(LibraryDrag.urls(from: pb).map(\.path), ["/m/Bleach", "/m/Downloads/02 Rapture.flac", "/m/Downloads/03 Rapture Edit.flac"])
        pb.clearContents()
        pb.writeObjects([LibraryDrag.writer(for: bleach, db: d)])
        XCTAssertEqual(LibraryDrag.urls(from: pb).map(\.path), ["/m/Bleach"])
    }

    func testRewrittenFilesAreReadAgain() throws {
        // Tags written with the date kept: the next scan of the folder must read the file again anyway.
        let d = try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite"))
        try d.upsert([file("/m/Bleach/01 Blew.flac", artist: "Nirvana", album: "Bleach", title: "Blew", folder: "/m/Bleach"),
                      file("/m/Bleach/02 Floyd.flac", artist: "Nirvana", album: "Bleach", title: "Floyd", folder: "/m/Bleach")])
        try d.markChanged(paths: ["/m/Bleach/01 Blew.flac"])
        let known = try d.known(under: "/m/Bleach")
        XCTAssertEqual(known["/m/Bleach/01 Blew.flac"]?.mtime, -1, "looks changed to the scanner")
        XCTAssertEqual(known["/m/Bleach/02 Floyd.flac"]?.mtime, 1)
    }
}
