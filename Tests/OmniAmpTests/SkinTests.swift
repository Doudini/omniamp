import XCTest
@testable import OmniAmp

final class SkinTests: XCTestCase {
    private var syrogenesis: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Syrogenesis_v5.wsz")
    }

    func testLoadsSyrogenesis() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: syrogenesis.path), "test skin not present")
        let skin = try Skin(url: syrogenesis)
        for f in ["main", "titlebar", "cbuttons", "nums_ex", "text", "pledit", "posbar", "volume", "shufrep", "monoster", "playpaus"] {
            XCTAssertTrue(skin.has(f), "missing \(f)")
        }
        XCTAssertEqual(skin.size(of: "main"), CGSize(width: 275, height: 116))
        XCTAssertEqual(skin.plFontName, "Arial")
        XCTAssertEqual(skin.plNormalBG.redComponent, 0, accuracy: 0.01)
        XCTAssertEqual(skin.plNormalBG.blueComponent, 42.0 / 255, accuracy: 0.01)
        XCTAssertEqual(skin.visColors.count, 24)
        XCTAssertEqual(skin.visColors[2].blueComponent, 252.0 / 255, accuracy: 0.01)
        XCTAssertNotNil(skin.sprite("cbuttons", CGRect(x: 23, y: 18, width: 23, height: 18)))
        XCTAssertNil(skin.sprite("cbuttons", CGRect(x: 500, y: 0, width: 5, height: 5)))
    }

    func testRejectsNonZip() {
        XCTAssertThrowsError(try ZipArchive(data: Data("not a zip".utf8)))
    }

    func testPleditHexParsing() {
        let c = Skin.hex("#FF8000")!
        XCTAssertEqual(c.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(c.greenComponent, 128.0 / 255, accuracy: 0.01)
        XCTAssertNil(Skin.hex("nope"))
    }
}
