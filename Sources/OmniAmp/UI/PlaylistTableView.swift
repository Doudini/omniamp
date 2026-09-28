import AppKit

/// The same fast movement in every list (playlist, radio, podcasts): ⌘↑/⌘↓ 10 rows, ⌘⇧↑/⌘⇧↓ 100,
/// Page Up/Down (fn↑/fn↓) a screen, Home/End (fn←/fn→) first/last row.
extension NSTableView {
    @discardableResult
    func handleJumpKey(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 126 where f == .command: jump(by: -10)
        case 125 where f == .command: jump(by: 10)
        case 126 where f == [.command, .shift]: jump(by: -100)
        case 125 where f == [.command, .shift]: jump(by: 100)
        // Page keys only on their own: with ⇧ or ⌘ AppKit's own handling (extend, scroll) applies.
        case 116 where f.isEmpty: jump(by: -pageRows)        // Page Up
        case 121 where f.isEmpty: jump(by: pageRows)         // Page Down
        case 115 where f.isEmpty: jump(to: 0)                // Home
        case 119 where f.isEmpty: jump(to: numberOfRows - 1) // End
        default: return false
        }
        return true
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
}

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
        let opt = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 36, 76: onActivate?()          // Return / Enter
        case 51, 117: onDelete?()           // Backspace / Forward delete
        case 126 where opt: onMove?(-1)     // ⌥↑
        case 125 where opt: onMove?(1)      // ⌥↓
        default: if !handleJumpKey(event) { super.keyDown(with: event) }
        }
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
