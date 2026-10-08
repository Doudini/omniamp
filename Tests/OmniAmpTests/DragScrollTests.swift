import XCTest
@testable import OmniAmp

/// Middle-button drag scrolling, fed made-up events for a real (off-screen) window.
@MainActor
final class DragScrollTests: XCTestCase {
    private var window: NSWindow!
    private var scroll: NSScrollView!
    private var drag: DragScroll!

    /// A flipped document, like a table's.
    private final class Doc: NSView { override var isFlipped: Bool { true } }

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        scroll.documentView = Doc(frame: NSRect(x: 0, y: 0, width: 300, height: 3000))
        window.contentView?.addSubview(scroll)
        drag = DragScroll()
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        drag = nil
    }

    private func event(_ type: NSEvent.EventType, y: CGFloat, at t: TimeInterval, button: Int = 2) -> NSEvent {
        let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: 150, y: y), modifierFlags: [], timestamp: t,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        // mouseEvent makes left-button events; the button number comes from a CGEvent copy.
        let cg = e.cgEvent!
        cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        return NSEvent(cgEvent: cg)!
    }

    private var top: CGFloat { scroll.contentView.bounds.origin.y }

    func testContentFollowsThePointer() {
        XCTAssertTrue(drag.handle(event(.otherMouseDown, y: 100, at: 1)), "swallowed: the list doesn't see it")
        XCTAssertTrue(drag.handle(event(.otherMouseDragged, y: 180, at: 1.1)))
        XCTAssertEqual(top, 80, accuracy: 0.5, "pointer up 80 pt: the content moved up with it")
        drag.handle(event(.otherMouseDragged, y: 150, at: 1.2))
        XCTAssertEqual(top, 50, accuracy: 0.5, "and back down")
        drag.handle(event(.otherMouseDragged, y: -900, at: 1.3))
        XCTAssertEqual(top, 0, accuracy: 0.5, "stops at the top")
        // Released well after the last move: no flick.
        XCTAssertTrue(drag.handle(event(.otherMouseUp, y: -900, at: 2)))
        XCTAssertFalse(drag.handle(event(.otherMouseDragged, y: 0, at: 2.1)), "over: drags are the app's again")
    }

    func testOtherButtonsAndPlacesWithNothingToScrollAreLeftAlone() {
        XCTAssertFalse(drag.handle(event(.otherMouseDown, y: 100, at: 1, button: 3)), "only the middle button")
        scroll.documentView?.frame.size.height = 200
        XCTAssertFalse(drag.handle(event(.otherMouseDown, y: 100, at: 1)), "everything fits: a middle click stays a click")
    }

    func testAFlickGlidesOnAndAClickStopsIt() async throws {
        drag.handle(event(.otherMouseDown, y: 100, at: 1))
        drag.handle(event(.otherMouseDragged, y: 120, at: 1.02))
        drag.handle(event(.otherMouseDragged, y: 160, at: 1.04))
        drag.handle(event(.otherMouseUp, y: 160, at: 1.05))
        let released = top
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(top, released + 20, "it kept going after letting go")
        XCTAssertFalse(drag.handle(event(.leftMouseDown, y: 100, at: 2, button: 0)), "the click itself goes on")
        let stopped = top
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(top, stopped, "and the glide stopped")
    }
}
