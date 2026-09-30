import AppKit
import XCTest
@testable import OmniAmp

@MainActor
final class AccessibilityTests: XCTestCase {
    private final class Target: NSObject {
        var pressed = 0
        @objc func press(_ sender: Any?) { pressed += 1 }
    }

    func testPillIsAButtonVoiceOverCanPress() {
        _ = NSApplication.shared   // actions go through the app
        let t = Target()
        let pill = Pill("Play All", target: t, action: #selector(Target.press(_:)))
        XCTAssertTrue(pill.isAccessibilityElement())
        XCTAssertEqual(pill.accessibilityRole(), .button)
        XCTAssertEqual(pill.accessibilityLabel(), "Play All")
        pill.isOn = true
        XCTAssertTrue(pill.isAccessibilitySelected())
        XCTAssertTrue(pill.accessibilityPerformPress())
        XCTAssertEqual(t.pressed, 1)
        pill.isEnabled = false
        XCTAssertFalse(pill.accessibilityPerformPress())
        XCTAssertEqual(t.pressed, 1)
    }
}
