import XCTest
@testable import OmniAmp

final class BoundedFetchTests: XCTestCase {
    private func file(_ bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-fetch-\(UUID().uuidString)")
        try Data((0..<bytes).map { UInt8($0 & 0xFF) }).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testWholeBodyUnderTheLimit() async throws {
        let src = try file(3 << 20)
        let started = Date()
        let (data, _) = try await BoundedFetch.data(for: URLRequest(url: src), limit: 4 << 20)
        XCTAssertEqual(data, try Data(contentsOf: src))
        let (tmp, _) = try await BoundedFetch.download(for: URLRequest(url: src), limit: 4 << 20)
        XCTAssertEqual(try Data(contentsOf: tmp), data)
        try? FileManager.default.removeItem(at: tmp)
        print("BoundedFetch: 2 × 3 MB in \(Date().timeIntervalSince(started)) s")
    }

    func testRefusedOverTheLimit() async throws {
        let src = try file(3 << 20)
        do {
            _ = try await BoundedFetch.data(for: URLRequest(url: src), limit: 1 << 20)
            XCTFail("should stop at the limit")
        } catch is BoundedFetch.TooLarge {}
    }
}
