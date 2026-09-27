import AppKit

/// Skinned playlist window (PLEDIT.BMP frame, PLEDIT.TXT colors). Sizes snap to 25×29 steps.
final class ClassicPlaylistView: SkinCanvasView {
    weak var controller: PlayerController?
    var onClose: (() -> Void)?
    var onResize: ((CGSize) -> Void)?
    /// Menus built by the app delegate: right-click, MISC (sort) and LIST buttons.
    var contextMenu: (() -> NSMenu)?
    var miscMenu: (() -> NSMenu)?
    var listMenu: (() -> NSMenu)?

    /// Size in skin pixels.
    var skinSize = CGSize(width: 275, height: 232) { didSet { invalidateIntrinsicContentSize(); clampScroll(); needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: skinSize.width * scale, height: skinSize.height * scale) }
    /// Vector text: render at full screen resolution.
    override var renderScale: CGFloat { scale * (window?.backingScaleFactor ?? 2) }

    private(set) var selection = IndexSet()   // rows
    private var anchor: Int?
    private var scrollRow = 0
    private var draggingThumb = false
    private var closePressed = false
    private let rowHeight: CGFloat = 13

    // Content area in skin pixels.
    private var content: CGRect { CGRect(x: 12, y: 20, width: skinSize.width - 32, height: skinSize.height - 58) }
    private var visibleRows: Int { max(1, Int(content.height / rowHeight)) }
    private var rowCount: Int { controller?.rowCount ?? 0 }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Font

    private var cachedFont: (String, CGFloat, NSFont)?
    private var font: NSFont {
        // Skin font if installed, else Hack. Drawn at skin-pixel size (scaled with the view).
        let name = skin.plFontName ?? ""
        let size: CGFloat = 8.5
        if let c = cachedFont, c.0 == name, c.1 == size { return c.2 }
        let f = NSFont(name: name, size: size) ?? Fonts.hack(size - 0.5)
        cachedFont = (name, size, f)
        return f
    }

    // MARK: Drawing

    override func drawSkin(_ ctx: CGContext) {
        let s = skin
        let W = skinSize.width, H = skinSize.height
        let active = window?.isKeyWindow ?? false
        let ay: CGFloat = active ? 0 : 21

        // Content background first (frame overlaps its edges).
        ctx.setFillColor(s.plNormalBG.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        // Top: corners, tiles, centered title.
        s.draw("pledit", CGRect(x: 0, y: ay, width: 25, height: 20), at: .zero, in: ctx)
        s.tile("pledit", CGRect(x: 127, y: ay, width: 25, height: 20), in: CGRect(x: 25, y: 0, width: W - 50, height: 20), ctx: ctx)
        s.draw("pledit", CGRect(x: 26, y: ay, width: 100, height: 20), at: CGPoint(x: ((W - 100) / 2).rounded(.down), y: 0), in: ctx)
        s.draw("pledit", CGRect(x: 153, y: ay, width: 25, height: 20), at: CGPoint(x: W - 25, y: 0), in: ctx)
        if closePressed { s.draw("pledit", CGRect(x: 52, y: 42, width: 9, height: 9), at: CGPoint(x: W - 11, y: 3), in: ctx) }

        // Sides.
        s.tile("pledit", CGRect(x: 0, y: 42, width: 12, height: 29), in: CGRect(x: 0, y: 20, width: 12, height: H - 58), ctx: ctx)
        s.tile("pledit", CGRect(x: 31, y: 42, width: 20, height: 29), in: CGRect(x: W - 20, y: 20, width: 20, height: H - 58), ctx: ctx)

        // Bottom.
        s.draw("pledit", CGRect(x: 0, y: 72, width: 125, height: 38), at: CGPoint(x: 0, y: H - 38), in: ctx)
        s.tile("pledit", CGRect(x: 179, y: 0, width: 25, height: 38), in: CGRect(x: 125, y: H - 38, width: W - 275, height: 38), ctx: ctx)
        s.draw("pledit", CGRect(x: 126, y: 72, width: 150, height: 38), at: CGPoint(x: W - 150, y: H - 38), in: ctx)

        drawRows(ctx)
        drawScrollThumb(ctx)
        drawTotals(ctx)
    }

    private func drawRows(_ ctx: CGContext) {
        guard let c = controller else { return }
        let area = content
        ctx.saveGState()
        ctx.clip(to: area)
        let f = font
        let first = scrollRow
        let last = min(rowCount, first + visibleRows + 1)
        // Text is drawn with AppKit (vector) so it stays crisp at any scale.
        NSGraphicsContext.saveGraphicsState()
        ctx.setShouldAntialias(true)
        for row in first..<max(first, last) {
            let y = area.minY + CGFloat(row - first) * rowHeight
            let i = c.trackIndex(forRow: row)
            let t = c.tracks[i]
            if selection.contains(row) {
                ctx.setFillColor(skin.plSelectedBG.cgColor)
                ctx.fill(CGRect(x: area.minX, y: y, width: area.width, height: rowHeight))
            }
            let color = i == c.currentIndex ? skin.plCurrent : skin.plNormal
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
            let q = c.queuePosition(of: i).map { "[\($0)] " } ?? ""
            let dur = (q + TimeFormat.mmss(t.duration)) as NSString
            let dw = dur.size(withAttributes: attrs).width
            let textY = y + (rowHeight - f.ascender + f.descender) / 2 - 0.5
            dur.draw(at: CGPoint(x: area.maxX - dw - 3, y: textY), withAttributes: attrs)
            let title = "\(i + 1). \(t.displayTitle)" as NSString
            title.draw(with: CGRect(x: area.minX + 2, y: textY, width: area.width - dw - 10, height: rowHeight),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    private var thumbTrack: (minY: CGFloat, range: CGFloat) {
        (20, max(0, skinSize.height - 58 - 18))
    }

    private func drawScrollThumb(_ ctx: CGContext) {
        let maxScroll = max(0, rowCount - visibleRows)
        let f = maxScroll > 0 ? CGFloat(scrollRow) / CGFloat(maxScroll) : 0
        let y = thumbTrack.minY + (f * thumbTrack.range).rounded()
        skin.draw("pledit", CGRect(x: draggingThumb ? 61 : 52, y: 53, width: 8, height: 18), at: CGPoint(x: skinSize.width - 15, y: y), in: ctx)
    }

    private func drawTotals(_ ctx: CGContext) {
        guard let c = controller else { return }
        let sel = selection.reduce(0.0) { $0 + (c.tracks[c.trackIndex(forRow: $1)].duration ?? 0) }
        let total = c.store.totalDuration
        let text = "\(TimeFormat.mmss(sel).isEmpty ? "0:00" : TimeFormat.mmss(sel))/\(TimeFormat.mmss(total).isEmpty ? "0:00" : TimeFormat.mmss(total))"
        let x = skinSize.width - 143
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x, y: skinSize.height - 28, width: 90, height: 6))
        skin.drawText(text, at: CGPoint(x: x, y: skinSize.height - 28), in: ctx)
        ctx.restoreGState()
    }

    // MARK: Scrolling / selection

    private func clampScroll() {
        scrollRow = max(0, min(scrollRow, rowCount - visibleRows))
    }

    func reload() {
        selection = selection.filteredIndexSet { $0 < rowCount }
        clampScroll()
        needsDisplay = true
    }

    func scrollToVisible(_ row: Int) {
        if row < scrollRow { scrollRow = row }
        else if row >= scrollRow + visibleRows { scrollRow = row - visibleRows + 1 }
        clampScroll()
        needsDisplay = true
    }

    func select(row: Int) {
        guard row >= 0, row < rowCount else { return }
        selection = [row]
        anchor = row
        scrollToVisible(row)
    }

    var selectedRow: Int? { selection.first }

    var selectedTrackIndices: IndexSet {
        guard let c = controller else { return [] }
        return IndexSet(selection.filter { $0 < rowCount }.map { c.trackIndex(forRow: $0) })
    }

    /// Replace the selection (e.g. after a move) and keep it in view.
    func setSelection(_ rows: IndexSet) {
        selection = rows
        anchor = rows.first
        if let f = rows.first { scrollToVisible(f) }
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / (rowHeight * scale) : event.scrollingDeltaY * 3
        accumulatedScroll -= d
        let whole = Int(accumulatedScroll)
        guard whole != 0 else { return }
        accumulatedScroll -= CGFloat(whole)
        scrollRow += whole
        clampScroll()
        needsDisplay = true
    }
    private var accumulatedScroll: CGFloat = 0

    // MARK: Mouse

    private func row(at p: CGPoint) -> Int? {
        guard content.contains(p) else { return nil }
        let r = scrollRow + Int((p.y - content.minY) / rowHeight)
        return r < rowCount ? r : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = skinPoint(event)
        let W = skinSize.width, H = skinSize.height
        guard let c = controller else { return }

        // Close button (top-right).
        if CGRect(x: W - 11, y: 3, width: 9, height: 9).contains(p) {
            closePressed = true; needsDisplay = true
            var inside = true
            track(event) { inside = CGRect(x: W - 11, y: 3, width: 9, height: 9).contains($0); self.closePressed = inside }
            closePressed = false
            if inside { onClose?() }
            return
        }
        // Title bar: drag window.
        if p.y < 20 { window?.performDrag(with: event); return }
        // Resize grip (bottom-right corner).
        if p.x > W - 20, p.y > H - 20 { resize(event); return }
        // Scrollbar.
        if p.x >= W - 15, p.x < W - 7, p.y >= 20, p.y < H - 38 { dragThumb(event); return }
        // Bottom bar buttons.
        if p.y >= H - 38 { bottomButton(p, c); return }

        guard let r = row(at: p) else { selection = []; needsDisplay = true; return }
        if event.clickCount == 2 {
            c.play(index: c.trackIndex(forRow: r))
            return
        }
        if event.modifierFlags.contains(.shift), let a = anchor {
            selection = IndexSet(integersIn: min(a, r)...max(a, r))
        } else if event.modifierFlags.contains(.command) {
            if selection.contains(r) { selection.remove(r) } else { selection.insert(r) }
            anchor = r
        } else {
            let wasSelected = selection.contains(r)
            if !wasSelected { selection = [r]; anchor = r }
            needsDisplay = true
            // Winamp: dragging moves the selected rows along with the mouse.
            if !dragSelection(event, from: r, controller: c), wasSelected {
                selection = [r]; anchor = r   // plain click on a multi-selection collapses it
            }
        }
        needsDisplay = true
    }

    /// Moves the selection while the mouse is dragged. Returns true if anything moved.
    private func dragSelection(_ event: NSEvent, from startRow: Int, controller c: PlayerController) -> Bool {
        guard c.visible == nil else { return false } // no reordering while filtered
        var lastRow = startRow
        var moved = false
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if e.type == .leftMouseUp { break }
            let p = skinPoint(e)
            // Auto-scroll when dragging past the edges.
            if p.y < content.minY, scrollRow > 0 { scrollRow -= 1 }
            if p.y > content.maxY { scrollRow = min(scrollRow + 1, max(0, rowCount - visibleRows)) }
            let r = max(0, min(rowCount - 1, scrollRow + Int(floor((p.y - content.minY) / rowHeight))))
            guard r != lastRow else { needsDisplay = true; displayIfNeeded(); continue }
            let newRows = c.shift(trackIndices: selectedTrackIndices, by: r - lastRow)
            let delta = (newRows.first ?? 0) - (selection.first ?? 0)
            if delta != 0 { moved = true }
            selection = newRows
            anchor = anchor.map { $0 + delta }
            lastRow += delta
            needsDisplay = true
            displayIfNeeded()
        }
        return moved
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = skinPoint(event)
        if let r = row(at: p), !selection.contains(r) { selection = [r]; anchor = r; needsDisplay = true }
        if let m = contextMenu?() { NSMenu.popUpContextMenu(m, with: event, for: self) }
    }

    private func bottomButton(_ p: CGPoint, _ c: PlayerController) {
        let W = skinSize.width, H = skinSize.height
        let y = H - 30
        if CGRect(x: 14, y: y, width: 22, height: 18).contains(p) { c.showOpenPanel(for: window) }            // ADD
        else if CGRect(x: 43, y: y, width: 22, height: 18).contains(p) { removeSelected() }                   // REM
        else if CGRect(x: 72, y: y, width: 22, height: 18).contains(p) {                                    // SEL
            selection = IndexSet(integersIn: 0..<rowCount); needsDisplay = true
        } else if CGRect(x: 101, y: y, width: 22, height: 18).contains(p) {                                 // MISC (sort)
            popMenu(miscMenu?(), at: CGPoint(x: 101, y: y))
        } else if CGRect(x: W - 44, y: y, width: 22, height: 18).contains(p) {                              // LIST
            popMenu(listMenu?(), at: CGPoint(x: W - 44, y: y))
        }
        else {
            // Mini transport in the bottom-right piece.
            let mini: [(CGFloat, CGFloat, () -> Void)] = [
                (W - 144, 7, c.previous), (W - 137, 8, c.playOrResume), (W - 129, 9, c.pause),
                (W - 120, 9, c.stop), (W - 111, 8, c.next), (W - 103, 9, { c.showOpenPanel(for: self.window) }),
            ]
            if p.y >= H - 16, p.y < H - 8, let hit = mini.first(where: { p.x >= $0.0 && p.x < $0.0 + $0.1 }) { hit.2() }
        }
    }

    private func popMenu(_ menu: NSMenu?, at skinPoint: CGPoint) {
        guard let menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: skinPoint.x * scale, y: skinPoint.y * scale), in: self)
    }

    private func dragThumb(_ event: NSEvent) {
        draggingThumb = true
        track(event) { p in
            let maxScroll = max(0, self.rowCount - self.visibleRows)
            let f = (p.y - self.thumbTrack.minY - 9) / max(1, self.thumbTrack.range)
            self.scrollRow = Int((max(0, min(1, f)) * CGFloat(maxScroll)).rounded())
        }
        draggingThumb = false
        needsDisplay = true
    }

    /// Drag the bottom-right grip; the top-left corner stays put (the window controller keeps it).
    private func resize(_ event: NSEvent) {
        guard let w = window else { return }
        let startMouse = NSEvent.mouseLocation
        let startSize = skinSize
        while let e = w.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let m = NSEvent.mouseLocation
            let width = startSize.width + (m.x - startMouse.x) / scale
            let height = startSize.height + (startMouse.y - m.y) / scale
            let wSteps = max(0, Int((width - 275) / 25 + 0.5))
            let hSteps = max(0, Int((height - 116) / 29 + 0.5))
            let newSize = CGSize(width: 275 + CGFloat(wSteps) * 25, height: 116 + CGFloat(hSteps) * 29)
            if newSize != skinSize {
                skinSize = newSize
                onResize?(newSize)
            }
            if e.type == .leftMouseUp { break }
        }
    }

    private func track(_ event: NSEvent, _ update: (CGPoint) -> Void) {
        update(skinPoint(event))
        needsDisplay = true
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            update(skinPoint(e))
            needsDisplay = true
            displayIfNeeded()
            if e.type == .leftMouseUp { break }
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return }
        let n = rowCount
        let cur = anchor ?? selection.first ?? -1
        if event.modifierFlags.contains(.option), event.keyCode == 125 || event.keyCode == 126 {   // ⌥↓ / ⌥↑
            guard c.visible == nil else { NSSound.beep(); return }
            setSelection(c.shift(trackIndices: selectedTrackIndices, by: event.keyCode == 125 ? 1 : -1))
            return
        }
        switch event.keyCode {
        case 125: select(row: min(n - 1, cur + 1))                     // ↓
        case 126: select(row: max(0, cur - 1))                         // ↑
        case 121: select(row: min(n - 1, cur + visibleRows))           // page down
        case 116: select(row: max(0, cur - visibleRows))               // page up
        case 115: select(row: 0)                                       // home
        case 119: select(row: n - 1)                                   // end
        case 36, 76: if let r = selection.first { c.play(index: c.trackIndex(forRow: r)) }
        case 51, 117: removeSelected()
        default: super.keyDown(with: event)
        }
    }

    private func removeSelected() {
        guard let c = controller, let first = selection.first else { return }
        var idx = IndexSet()
        for r in selection { idx.insert(c.trackIndex(forRow: r)) }
        selection = []
        c.remove(trackIndices: idx)
        if rowCount > 0 { select(row: min(first, rowCount - 1)) }
    }
}
