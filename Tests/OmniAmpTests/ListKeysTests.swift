import AppKit
import XCTest
@testable import OmniAmp

/// The fast movement keys, shared by the playlist and the radio and podcast lists.
@MainActor
final class ListKeysTests: XCTestCase {
    final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 500 }
    }

    private func key(_ t: NSTableView, _ code: UInt16, _ ch: Int, _ f: NSEvent.ModifierFlags = []) {
        let c = String(UnicodeScalar(ch)!)
        t.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: 0, context: nil,
                                         characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code)!)
    }

    func testJumpsInEveryKindOfList() {
        for table in [KeyTableView(), PlaylistTableView()] as [NSTableView] {
            let rows = Rows()
            table.addTableColumn(NSTableColumn(identifier: .init("c")))
            table.dataSource = rows
            table.rowHeight = 20
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 210))   // ~10 rows on screen
            scroll.documentView = table
            table.reloadData()
            table.selectRowIndexes([0], byExtendingSelection: false)

            key(table, 125, NSDownArrowFunctionKey, .command)
            XCTAssertEqual(table.selectedRow, 10, "⌘↓ in \(type(of: table))")
            key(table, 125, NSDownArrowFunctionKey, [.command, .shift])
            XCTAssertEqual(table.selectedRow, 110, "⌘⇧↓")
            key(table, 126, NSUpArrowFunctionKey, .command)
            XCTAssertEqual(table.selectedRow, 100, "⌘↑")
            key(table, 119, NSEndFunctionKey)
            XCTAssertEqual(table.selectedRow, 499, "End")
            key(table, 125, NSDownArrowFunctionKey, [.command, .shift])
            XCTAssertEqual(table.selectedRow, 499, "stops at the last row")
            key(table, 116, NSPageUpFunctionKey)
            XCTAssertLessThan(table.selectedRow, 499, "Page Up")
            key(table, 115, NSHomeFunctionKey)
            XCTAssertEqual(table.selectedRow, 0, "Home")
            _ = rows
        }
    }
}
