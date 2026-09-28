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

    func testBundledBaseSkin() throws {
        let url = try XCTUnwrap(SkinLibrary.bundled, "Resources/base-2.91.wsz missing")
        XCTAssertTrue(SkinLibrary.isBundled(url))
        XCTAssertEqual(SkinLibrary.install(url), url, "the built-in skin is not copied into the library")
        let skin = try Skin(url: url)
        for f in ["main", "titlebar", "cbuttons", "numbers", "text", "pledit", "posbar", "volume", "shufrep", "monoster", "playpaus", "eqmain"] {
            XCTAssertTrue(skin.has(f), "missing \(f)")
        }
        XCTAssertEqual(skin.size(of: "main"), CGSize(width: 275, height: 116))
        XCTAssertEqual(skin.plFontName, "Arial")
        XCTAssertEqual(skin.plNormal.greenComponent, 1, accuracy: 0.01)
        XCTAssertEqual(skin.visColors.count, 24)
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

import Compression

final class ZipBombTests: XCTestCase {
    /// A zip whose local entries are `blobs` (deflated) and whose central directory lists `names`, each
    /// pointing at blob `index` (several names may share one blob: the "zip bomb" trick).
    private func zip(blobs: [Data], names: [(String, Int)]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }
        var out = [UInt8](), offsets = [Int](), comp = [[UInt8]]()
        for (i, b) in blobs.enumerated() {
            var dst = [UInt8](repeating: 0, count: b.count + 1024)
            let n = b.withUnsafeBytes { compression_encode_buffer(&dst, dst.count, $0.bindMemory(to: UInt8.self).baseAddress!, b.count, nil, COMPRESSION_ZLIB) }
            let c = Array(dst.prefix(n))
            comp.append(c)
            offsets.append(out.count)
            let name = Array("blob\(i).bmp".utf8)
            out += le32(0x0403_4B50) + le16(20) + le16(0) + le16(8) + le32(0) + le32(0) + le32(c.count) + le32(b.count) + le16(name.count) + le16(0) + name + c
        }
        let cdStart = out.count
        for (name, i) in names {
            let n = Array(name.utf8)
            out += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(8) + le32(0) + le32(0) + le32(comp[i].count) + le32(blobs[i].count)
                + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offsets[i]) + n
        }
        let cdSize = out.count - cdStart
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(names.count) + le16(names.count) + le32(cdSize) + le32(cdStart) + le16(0)
        return Data(out)
    }

    func testEntriesSharingDataAreUnpackedOnce() throws {
        let mb = Data(count: 1 << 20)
        let bomb = zip(blobs: [mb], names: (0..<200).map { ("f\($0).bmp", 0) })
        XCTAssertLessThan(bomb.count, 20_000, "a small file…")
        let z = try ZipArchive(data: bomb)
        XCTAssertEqual(z.entries.count, 1, "…that no longer unpacks 200 MB")
    }

    func testTotalSizeIsCapped() {
        let mb = Data(count: 1 << 20)
        let big = zip(blobs: Array(repeating: mb, count: 100), names: (0..<100).map { ("f\($0).bmp", $0) })
        XCTAssertThrowsError(try ZipArchive(data: big), "100 MB unpacked is more than any skin")
    }

    func testOnlyWantedTypesAreUnpacked() throws {
        let small = Data(count: 1000)
        let z = try ZipArchive(data: zip(blobs: [small, small], names: [("main.bmp", 0), ("readme.exe", 1)]), only: ["bmp"])
        XCTAssertEqual(Array(z.entries.keys), ["main.bmp"])
    }
}
