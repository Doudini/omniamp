import XCTest
@testable import OmniAmp

final class OutputTests: XCTestCase {
    func testBestRatePrefersExactMatch() {
        XCTAssertEqual(AudioDevices.bestRate(for: 96000, supported: [44100, 48000, 88200, 96000]), 96000)
    }

    func testBestRateUsesSameFamilyMultiple() {
        // 44.1 kHz on a 48k-family+88.2 device → 88.2 kHz (clean 2× instead of fractional resampling).
        XCTAssertEqual(AudioDevices.bestRate(for: 44100, supported: [48000, 88200, 96000]), 88200)
        XCTAssertEqual(AudioDevices.bestRate(for: 48000, supported: [44100, 96000, 192_000]), 96000)
    }

    func testBestRateFallsBackToNextHigherThenHighest() {
        XCTAssertEqual(AudioDevices.bestRate(for: 22050, supported: [48000, 96000]), 48000)
        XCTAssertEqual(AudioDevices.bestRate(for: 384_000, supported: [44100, 48000, 96000, 192_000]), 192_000)
        XCTAssertNil(AudioDevices.bestRate(for: 44100, supported: []))
    }

    func testDefaultOutputExists() {
        // Every Mac running the tests has some output; the list must contain the default device.
        let def = AudioDevices.defaultOutputID()
        XCTAssertNotEqual(def, 0)
        XCTAssertTrue(AudioDevices.outputDevices().contains { $0.id == def })
        XCTAssertGreaterThan(AudioDevices.nominalRate(def), 0)
        // Rendering to the speakers: a few ms at least (one IO buffer), well under a second.
        let latency = AudioDevices.outputLatency(def)
        XCTAssertGreaterThan(latency, 0.001)
        XCTAssertLessThan(latency, 0.5)
    }
}
