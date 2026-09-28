import XCTest
@testable import OmniAmp

final class ResumeStoreTests: XCTestCase {
    func testPositionsPersistPruneOldestAndFollowRenames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-resume-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = ResumeStore(url: url, limit: 3)
        for (i, k) in ["a", "b", "c"].enumerated() { s.set(k, Double(100 + i)); usleep(2000) }
        s.set("d", 400)
        XCTAssertNil(s["a"], "over the limit: the oldest goes")
        XCTAssertEqual(s["d"], 400, "never the one just saved")
        s.rename(["b": "b2"])
        s.remove("c")
        let again = ResumeStore(url: url, limit: 3)   // relaunch
        XCTAssertEqual(again["b2"], 101)
        XCTAssertNil(again["b"])
        XCTAssertNil(again["c"])
        XCTAssertEqual(again["d"], 400)
    }
}
