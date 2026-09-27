import XCTest
@testable import OmniAmp

final class UpdaterTests: XCTestCase {
    func testVersionOrder() {
        XCTAssertTrue(Updater.isNewer("0.3", than: "0.2"))
        XCTAssertTrue(Updater.isNewer("v0.10", than: "0.9"))
        XCTAssertTrue(Updater.isNewer("1.0", than: "0.99.1"))
        XCTAssertFalse(Updater.isNewer("0.2", than: "0.2.0"))
        XCTAssertFalse(Updater.isNewer("0.2", than: "0.3"))
    }

    /// The fields GitHub's releases API returns (as for v0.2).
    func testReadsGitHubRelease() throws {
        let json = """
        {"tag_name":"v0.3","html_url":"https://github.com/Doudini/omniamp/releases/tag/v0.3","draft":false,"prerelease":false,
         "body":"Notes","assets":[
           {"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"},
           {"name":"OmniAmp-0.3.dmg","browser_download_url":"https://github.com/Doudini/omniamp/releases/download/v0.3/OmniAmp-0.3.dmg",
            "digest":"sha256:ABCDEF"}]}
        """
        let r = try XCTUnwrap(Updater.parseRelease(Data(json.utf8)))
        XCTAssertEqual(r.version, "0.3")
        XCTAssertEqual(r.dmg.lastPathComponent, "OmniAmp-0.3.dmg")
        XCTAssertEqual(r.sha256, "ABCDEF")
        XCTAssertEqual(r.notes, "Notes")
        let draft = json.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")
        XCTAssertNil(Updater.parseRelease(Data(draft.utf8)), "drafts are never offered")
    }
}
