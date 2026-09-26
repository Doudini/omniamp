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
}
