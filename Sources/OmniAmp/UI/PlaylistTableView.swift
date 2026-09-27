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
        let opt = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 36, 76: onActivate?()          // Return / Enter
        case 51, 117: onDelete?()           // Backspace / Forward delete
        case 126 where opt: onMove?(-1)     // ⌥↑
        case 125 where opt: onMove?(1)      // ⌥↓
        default: super.keyDown(with: event)
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
