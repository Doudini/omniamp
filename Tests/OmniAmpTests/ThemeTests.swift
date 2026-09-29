import XCTest
@testable import OmniAmp

@MainActor
final class ThemeTests: XCTestCase {
    private var savedColor: String!
    private var savedFinish: Finish!
    private var savedDefaults: (Any?, Any?)

    override func setUp() {
        savedColor = Theme.palette.id
        savedFinish = Theme.finish
        savedDefaults = (UserDefaults.standard.object(forKey: Pref.modernTheme), UserDefaults.standard.object(forKey: Pref.modernFinish))
    }

    override func tearDown() {
        Theme.select(savedColor)
        Theme.selectFinish(savedFinish)
        for (key, value) in [(Pref.modernTheme, savedDefaults.0), (Pref.modernFinish, savedDefaults.1)] {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB)!
        return String(format: "%02X%02X%02X", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()),
                      Int((s.blueComponent * 255).rounded()))
    }

    /// Each color has its own tint; Hardware and Studio are the same whatever the color.
    func testFinishesPerColor() {
        let tinted = ThemePalette.all.map { hex(Finish.tinted.surfaces(for: $0).page) }
        XCTAssertEqual(Set(tinted).count, ThemePalette.all.count)
        for finish in [Finish.hardware, .studio] {
            XCTAssertEqual(Set(ThemePalette.all.map { hex(finish.surfaces(for: $0).card) }).count, 1)
        }
        XCTAssertEqual(hex(Finish.studio.surfaces(for: ThemePalette.all[0]).page), "0D1519")
    }

    /// Hardware keeps the player exactly as it looked before finishes.
    func testHardwareIsTheOriginalPlayer() {
        let s = Finish.hardware.surfaces(for: ThemePalette.all[0])
        XCTAssertEqual(s.background, NSColor(calibratedRed: 0.07, green: 0.075, blue: 0.09, alpha: 1))
        XCTAssertEqual(s.buttonTop, NSColor(calibratedRed: 0.30, green: 0.31, blue: 0.36, alpha: 1))
        XCTAssertEqual(s.playlist, .black)
    }

    /// Library colors given once follow a later theme change (labels and tables keep them without being set again).
    func testDashColorsFollowTheTheme() {
        Theme.select("amber")
        Theme.selectFinish(.studio)
        let page = Dash.page, accent = Dash.accent
        XCTAssertEqual(hex(page), "0D1519")
        Theme.selectFinish(.tinted)
        XCTAssertEqual(hex(page), "14110D")
        Theme.select("blue")
        XCTAssertEqual(hex(page), "0C1117")
        XCTAssertEqual(hex(accent), hex(ThemePalette.all.first { $0.id == "blue" }!.phosphor))
        XCTAssertEqual(UserDefaults.standard.string(forKey: Pref.modernFinish), "tinted")
    }
}
