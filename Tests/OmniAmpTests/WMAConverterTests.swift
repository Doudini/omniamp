import XCTest
@testable import OmniAmp

final class WMAConverterTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-wma-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// An ASF header with one audio stream of this format tag (0x0161 WMA 9 Standard, 0x0163 WMA Lossless).
    private func asf(formatTag: UInt16) throws -> String {
        func le(_ n: Int, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8((n >> (8 * $0)) & 0xFF) } }
        let streamProperties: [UInt8] = [0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65]
        let audio: [UInt8] = [0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B]
        let waveFormat = le(Int(formatTag), 2) + le(2, 2) + le(44100, 4) + le(16000, 4) + le(4, 2) + le(16, 2) + le(0, 2)
        let body = audio + [UInt8](repeating: 0, count: 16) + le(0, 8) + le(waveFormat.count, 4) + le(0, 4) + le(1, 2) + le(0, 4) + waveFormat
        let object = streamProperties + le(24 + body.count, 8) + body
        let filler = [UInt8](repeating: 0xAB, count: 16) + le(40, 8) + [UInt8](repeating: 0, count: 16)   // another object first
        let header = [UInt8](repeating: 0x30, count: 16) + le(30 + filler.count + object.count, 8) + le(2, 4) + [1, 2] + filler + object
        let url = tmp.appendingPathComponent("t\(formatTag).wma")
        try Data(header + [UInt8](repeating: 0, count: 100)).write(to: url)
        return url.path
    }

    func testLosslessWMAIsToldApart() throws {
        XCTAssertTrue(WMAConverter.isLosslessWMA(try asf(formatTag: 0x0163)))
        XCTAssertFalse(WMAConverter.isLosslessWMA(try asf(formatTag: 0x0161)))
        let junk = tmp.appendingPathComponent("junk.wma")
        try Data(repeating: 1, count: 10).write(to: junk)
        XCTAssertFalse(WMAConverter.isLosslessWMA(junk.path))
    }

    /// ffmpeg failing: its last line is the reason, the WMA stays, and no temporary file is left in the folder.
    func testFailedConversionLeavesNothingBehind() throws {
        let fake = tmp.appendingPathComponent("ffmpeg")
        try "#!/bin/sh\necho 'warming up' >&2\necho 'Invalid data found when processing input' >&2\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let wma = try asf(formatTag: 0x0161)
        let r = WMAConverter.convert([wma], ffmpeg: fake.path)
        XCTAssertEqual(r.converted, [])
        XCTAssertEqual(r.failed, ["t353.wma: Invalid data found when processing input"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: wma))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: tmp.path).contains { $0.hasPrefix(".omniamp-") })
        XCTAssertEqual(r.line, "1 failed: t353.wma: Invalid data found when processing input.")
    }
}
