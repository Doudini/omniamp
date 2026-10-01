import AppKit

extension NSTableView {
    /// A row view of this kind, one the table has spare when it can (by identifier, as cells are reused). A new one
    /// every time isn't recycled: AppKit parks the old ones until the window is next drawn, and a window left in the
    /// background with its lists refreshing (a night of playing) piled up thousands, with their layers.
    func reusableRowView<T: NSTableRowView>(_ id: String, _ make: () -> T) -> T {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let v = makeView(withIdentifier: identifier, owner: nil) as? T { return v }
        let v = make()
        v.identifier = identifier
        return v
    }
}

/// What the Radio and Podcasts windows share: the look of their lists, their columns, typing to search.
@MainActor
enum ListLook {
    static func column(_ id: String, _ width: CGFloat, flexible: Bool = false) -> NSTableColumn {
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        c.width = width
        c.resizingMask = flexible ? .autoresizingMask : []
        return c
    }

    /// The LCD-style list: no header or grid, in a rounded, black-edged scroll view.
    static func apply(_ table: NSTableView, in scroll: NSScrollView, rowHeight: CGFloat) {
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.style = .plain
        table.gridStyleMask = []
        table.backgroundColor = Theme.lcd
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false   // the transparent title bar mustn't push rows under the top edge
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.lcd
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 4
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.black.cgColor
    }

    /// A single letter or digit typed in a list (it starts a search or a filter), else nil.
    static func typedText(_ e: NSEvent) -> String? {
        guard let c = e.characters, c.count == 1, c.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return c
    }
}

/// A table that first offers every key to its owner (which checks modifiers itself); what it doesn't
/// take works as usual (arrows, page keys, ⇧-selection…).
final class KeyTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        // ⌃Return: the row's right-click menu, from the keyboard.
        if event.modifierFlags.intersection([.command, .control, .option]) == .control, event.keyCode == 36 || event.keyCode == 76 {
            showRowMenu()
            return
        }
        if onKey?(event) == true || handleJumpKey(event) { return }   // same fast jumps as the playlist
        super.keyDown(with: event)
    }

    func showRowMenu() {
        guard let menu, selectedRow >= 0 else { NSSound.beep(); return }
        let r = rect(ofRow: selectedRow)
        menu.popUp(positioning: nil, at: NSPoint(x: r.minX + 40, y: r.maxY), in: self)
    }
}

