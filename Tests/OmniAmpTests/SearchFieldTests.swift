import XCTest
@testable import OmniAmp

/// The themed search field: typing happens where its text is drawn (after the magnifier, centered), not over the
/// whole field.
@MainActor
final class SearchFieldTests: XCTestCase {
    func testTypingSitsWhereTheTextIsDrawn() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        let field = DashSearchField(frame: NSRect(x: 10, y: 17, width: 400, height: 26))
        field.stringValue = "julien"
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor())
        let text = try XCTUnwrap(field.cell as? NSSearchFieldCell).searchTextRect(forBounds: field.bounds)
        let at = editor.convert(editor.bounds, to: field)
        XCTAssertEqual(at.minX, text.minX, accuracy: 1)
        XCTAssertEqual(at.midY, text.midY, accuracy: 1)
        XCTAssertLessThan(at.width, field.bounds.width - 20)   // not over the magnifier and ✕
        window.makeFirstResponder(nil)
    }
}
