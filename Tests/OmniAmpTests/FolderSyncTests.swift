import XCTest
@testable import OmniAmp

final class FolderSyncTests: XCTestCase {
    func testCanonicalMapsPrivateVarSpellings() {
        let roots = ["/var/folders/x/T/music"]
        XCTAssertEqual(FolderSync.canonical("/private/var/folders/x/T/music/A/1.flac", roots: roots), "/var/folders/x/T/music/A/1.flac")
        XCTAssertEqual(FolderSync.canonical("/var/folders/x/T/music/A/1.flac", roots: roots), "/var/folders/x/T/music/A/1.flac")
        let privateRoot = ["/private/tmp/m"]
        XCTAssertEqual(FolderSync.canonical("/tmp/m/song.mp3", roots: privateRoot), "/private/tmp/m/song.mp3")
    }

    func testCanonicalLeavesOtherPathsAlone() {
        let roots = ["/Users/me/Music"]
        XCTAssertEqual(FolderSync.canonical("/Users/me/Musical/x.mp3", roots: roots), "/Users/me/Musical/x.mp3")
        XCTAssertEqual(FolderSync.canonical("/Volumes/Ext/x.mp3", roots: roots), "/Volumes/Ext/x.mp3")
    }

    func testMissingRootIsNotADeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-sync-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertTrue(FolderSync.deletionIsReal(root + "/Album", roots: [root]), "root present: subfolder really went away")
        XCTAssertFalse(FolderSync.deletionIsReal("/Volumes/NotMounted-\(UUID().uuidString)/Album", roots: ["/Volumes/NotMounted"]),
                       "outside every root")
        let unmounted = "/Volumes/OmniAmpTest-\(UUID().uuidString)"
        XCTAssertFalse(FolderSync.deletionIsReal(unmounted + "/Album", roots: [unmounted]), "unmounted share")
        XCTAssertFalse(FolderSync.deletionIsReal(unmounted, roots: [unmounted]))
    }

    func testUnreadableOrSuddenlyEmptyFoldersKeepTheirTracks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-watch-\(UUID().uuidString)")
        setenv("OMNIAMP_CACHE_DIR", dir.path, 1)
        let before = UserDefaults.standard.stringArray(forKey: "watchedFolders")
        defer {
            unsetenv("OMNIAMP_CACHE_DIR")
            UserDefaults.standard.set(before, forKey: "watchedFolders")
            try? FileManager.default.removeItem(at: dir)
        }
        let root = "/music"
        UserDefaults.standard.set([root], forKey: "watchedFolders")
        let c = PlayerController()
        func track(_ p: String) -> Track { var t = Track(path: p, size: 1, mtime: 0); t.tagsLoaded = true; return t }
        c.store.restore([track("/music/A/1.mp3"), track("/music/B/2.mp3")])

        // B couldn't be listed (permission / network error): its track stays.
        c.folders.apply(dirs: [root], gone: [], found: [track("/music/A/1.mp3")], unknown: ["/music/B"])
        XCTAssertEqual(c.tracks.map(\.path), ["/music/A/1.mp3", "/music/B/2.mp3"])

        // The whole root lists nothing while it still has tracks: unavailable, not emptied.
        c.folders.apply(dirs: [root], gone: [], found: [])
        XCTAssertEqual(c.tracks.count, 2)

        // A real deletion still removes the track.
        c.folders.apply(dirs: [root], gone: [], found: [track("/music/A/1.mp3")])
        XCTAssertEqual(c.tracks.map(\.path), ["/music/A/1.mp3"])
    }

    func testScannerReportsFoldersItCannotList() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("omniamp-locked-\(UUID().uuidString)")
        let locked = root.appendingPathComponent("Locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        fm.createFile(atPath: root.appendingPathComponent("a.mp3").path, contents: Data([0]))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }
        var unreadable: [String] = []
        let found = FolderScanner.scan([root], unreadable: &unreadable)
        XCTAssertEqual(found.map { ($0.path as NSString).lastPathComponent }, ["a.mp3"])
        XCTAssertEqual(unreadable.map { ($0 as NSString).lastPathComponent }, ["Locked"])
    }
}
