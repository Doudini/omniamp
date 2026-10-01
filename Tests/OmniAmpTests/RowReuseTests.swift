import AppKit
import XCTest
@testable import OmniAmp

/// Lists in a window that isn't being drawn (behind others all night, playing) scroll on their own: the playlist to
/// each new track, the library's lists when they refresh. A new row view each time piled up in AppKit's parked set
/// (thousands overnight, ~500 MB); reused ones (NSTableView.reusableRowView) stay a screenful.
@MainActor
final class RowReuseTests: XCTestCase {
    private final class Source: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let reuse: Bool
        var made = 0
        var alive: [Weak] = []
        struct Weak { weak var view: NSView? }
        init(reuse: Bool) { self.reuse = reuse }

        func numberOfRows(in tableView: NSTableView) -> Int { 500 }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let make = { () -> CardRowView in
                self.made += 1
                let v = CardRowView()
                self.alive.append(Weak(view: v))
                return v
            }
            return reuse ? tableView.reusableRowView("cardRow", make) : make()
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { libraryCell(tableView, "cell") }
    }

    /// 300 jumps through a 500-row list in a layer-backed window that's never shown (so never drawn).
    private func scrollAround(reuse: Bool) -> (made: Int, alive: Int) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        let source = Source(reuse: reuse)
        table.dataSource = source
        table.delegate = source
        table.rowHeight = 24
        scroll.documentView = table
        window.contentView?.addSubview(scroll)
        var row = 0
        for _ in 0..<300 {
            autoreleasepool {
                row = (row + 97) % 500
                table.scrollRowToVisible(row)
                window.contentView?.layoutSubtreeIfNeeded()
            }
        }
        let alive = source.alive.filter { $0.view != nil }.count
        withExtendedLifetime((window, table)) {}
        return (source.made, alive)
    }

    func testScrollingAnUndrawnListDoesntPileUpRowViews() {
        let reused = scrollAround(reuse: true)
        XCTAssertLessThan(reused.made, 40, "row views made: \(reused.made)")
        XCTAssertLessThan(reused.alive, 40, "row views alive: \(reused.alive)")
        // For comparison (not asserted: it's AppKit's behaviour): a new row view each time.
        let fresh = scrollAround(reuse: false)
        print("row views after 300 jumps: reused \(reused.made) made / \(reused.alive) alive; new each time \(fresh.made) / \(fresh.alive)")
    }
}
