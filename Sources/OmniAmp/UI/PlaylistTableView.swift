import AppKit

/// Table with Winamp-ish key handling and drop support.
final class PlaylistTableView: NSTableView {
    override func viewWillDraw() {
        super.viewWillDraw()
        keepDrawingOnCPU()
    }

    var onActivate: (() -> Void)?
    var onDelete: (() -> Void)?
    /// ⌥↑ / ⌥↓: move the selection up/down.
    var onMove: ((Int) -> Void)?
    var contextMenu: (() -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        let f = event.modifierFlags
        let opt = f.contains(.option), cmd = f.contains(.command), shift = f.contains(.shift)
        switch event.keyCode {
        case 36, 76: onActivate?()          // Return / Enter
        case 51, 117: onDelete?()           // Backspace / Forward delete
        case 126 where opt: onMove?(-1)     // ⌥↑
        case 125 where opt: onMove?(1)      // ⌥↓
        case 126 where cmd: jump(by: shift ? -100 : -10)   // ⌘↑ / ⌘⇧↑
        case 125 where cmd: jump(by: shift ? 100 : 10)     // ⌘↓ / ⌘⇧↓
        case 116: jump(by: -pageRows)       // Page Up (fn↑)
        case 121: jump(by: pageRows)        // Page Down (fn↓)
        case 115: jump(to: 0)               // Home (fn←)
        case 119: jump(to: numberOfRows - 1) // End (fn→)
        default: super.keyDown(with: event)
        }
    }

    /// Rows that fit on screen, less one so a page keeps a row of context.
    private var pageRows: Int { max(1, Int((enclosingScrollView?.contentView.bounds.height ?? 0) / max(1, rowHeight)) - 1) }

    /// Move the selection (a single row) by `n`, stopping at the ends.
    func jump(by n: Int) { jump(to: (selectedRowIndexes.last ?? (n > 0 ? -1 : numberOfRows)) + n) }

    func jump(to row: Int) {
        guard numberOfRows > 0 else { return }
        let r = min(max(0, row), numberOfRows - 1)
        selectRowIndexes([r], byExtendingSelection: false)
        scrollRowToVisible(r)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-click selects the row under the mouse first (unless it is already part of the selection).
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return contextMenu?()
    }

    override func drawGrid(inClipRect clipRect: NSRect) {}
}

/// Row view with the classic blue selection.
final class PlaylistRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.selection.setFill()
        bounds.fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Plain container that accepts file drops and forwards them.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
