import AppKit

// The library, radio, podcast and settings windows draw their own controls (Pill) in the theme's colors. These
// are the rest of them in the same look: a pop-up menu, a checkbox, and text and search fields. Each one keeps
// its AppKit class's API (items and selection, state, stringValue, delegates), so only the type changes where
// it's used; the menus themselves stay the system's.

/// Rounded like a Pill: the chosen item and a ▾. On (accent) while the choice isn't the first item ("All genres",
/// "Year…"), unless `highlightsChoice` is off.
final class DashPopUp: NSPopUpButton {
    var highlightsChoice = true { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    private var isOn: Bool { highlightsChoice && indexOfSelectedItem > 0 }

    private var label: NSAttributedString {
        let color: NSColor = !isEnabled ? Dash.text3 : isOn ? Dash.accent : (hovering ? Dash.text : Dash.text2)
        let s = NSMutableAttributedString(string: titleOfSelectedItem ?? "",
                                          attributes: [.font: Dash.font(12, .medium), .foregroundColor: color])
        s.append(NSAttributedString(string: "  " + Fonts.Icon.chevronDown, attributes: [.font: Fonts.hack(9), .foregroundColor: color]))
        return s
    }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.size().width) + 26, height: 26) }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }   // no room for the system's bezel

    override func synchronizeTitleAndSelectedItem() {
        super.synchronizeTitleAndSelectedItem()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Dash.drawPillShape(in: bounds, on: isOn, hovering: hovering)
        let s = label, size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A checkbox: a small rounded box (accent with a ✓ when on) and its title. Still an NSButton checkbox, so
/// clicks, `state` and VoiceOver work as before.
final class DashCheck: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private static let box: CGFloat = 14, gap: CGFloat = 7

    private var label: NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: title, attributes: [.font: font ?? Dash.font(12), .paragraphStyle: p,
                                                              .foregroundColor: isEnabled ? (hovering ? Dash.text : Dash.text2) : Dash.text3])
    }

    override var intrinsicContentSize: NSSize {
        let s = label.size()
        return NSSize(width: Self.box + (title.isEmpty ? 0 : Self.gap + ceil(s.width)), height: max(Self.box + 4, ceil(s.height)))
    }

    override var title: String { didSet { invalidateIntrinsicContentSize() } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)   // shortened with "…" where space is short
    }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }   // no room for the system's bezel
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let r = NSRect(x: 0.5, y: (bounds.height - Self.box) / 2 + 0.5, width: Self.box - 1, height: Self.box - 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 3.5, yRadius: 3.5)
        (on ? Dash.accent.withAlphaComponent(isEnabled ? 0.9 : 0.4) : (hovering ? Dash.cardRaised : Dash.card)).setFill()
        path.fill()
        if !on {
            (hovering && isEnabled ? Dash.accent.withAlphaComponent(0.6) : Dash.border).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            let tick = NSAttributedString(string: Fonts.Icon.check, attributes: [.font: Fonts.hack(9), .foregroundColor: Dash.page])
            let t = tick.size()
            tick.draw(at: NSPoint(x: r.midX - t.width / 2, y: r.midY - t.height / 2))
        }
        guard !title.isEmpty else { return }
        // A long title ends in "…" where the space ends (a sheet's edge), instead of being cut off.
        let s = label, size = s.size(), x = Self.box + Self.gap
        s.draw(with: NSRect(x: x, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - x), height: size.height),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

// MARK: Fields

/// Height of the fields, the same as a Pill's: they sit in the same rows.
private let fieldHeight: CGFloat = 26

/// The fields' shared look: a rounded card with a border (accent while typing in it), the text inset and centered.
@MainActor private protocol DashFieldLook: NSTextFieldCell {}

extension DashFieldLook {
    func textRect(_ bounds: NSRect) -> NSRect {
        let line = ceil((font ?? Dash.font(13)).boundingRectForFont.height)
        let h = min(bounds.height, line)
        return NSRect(x: bounds.minX + 10, y: bounds.minY + floor((bounds.height - h) / 2), width: max(0, bounds.width - 20), height: h)
    }

    /// Where the field editor goes: the text rect, less the few points the cell adds when it draws the text itself,
    /// so the text doesn't shift sideways when typing starts.
    func editRect(_ bounds: NSRect) -> NSRect {
        let r = textRect(bounds)
        return NSRect(x: r.minX + 4, y: r.minY, width: max(0, r.width - 4), height: r.height)
    }

    func drawField(_ frame: NSRect, in view: NSView) {
        Dash.drawField(in: frame, editing: Dash.isEditing(view))
    }
}

private final class DashTextCell: NSTextFieldCell, DashFieldLook {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { textRect(rect) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawField(cellFrame, in: controlView)
        drawInterior(withFrame: cellFrame, in: controlView)
    }
    // Typing happens in the same inset, centered place as the text is drawn.
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: editRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: editRect(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

private final class DashSecureCell: NSSecureTextFieldCell, DashFieldLook {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { textRect(rect) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawField(cellFrame, in: controlView)
        drawInterior(withFrame: cellFrame, in: controlView)
    }
    // Typing happens in the same inset, centered place as the text is drawn.
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: editRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: editRect(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

/// A text field in the theme's look.
final class DashField: NSTextField {
    override class var cellClass: AnyClass? { get { DashTextCell.self } set {} }
    override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width, height: fieldHeight) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); Dash.prepareField(self) }
    override func becomeFirstResponder() -> Bool { defer { needsDisplay = true }; return super.becomeFirstResponder() }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); needsDisplay = true }
}

/// A password field in the theme's look.
final class DashSecureField: NSSecureTextField {
    override class var cellClass: AnyClass? { get { DashSecureCell.self } set {} }
    override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width, height: fieldHeight) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); Dash.prepareField(self) }
    override func becomeFirstResponder() -> Bool { defer { needsDisplay = true }; return super.becomeFirstResponder() }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); needsDisplay = true }
}

private final class DashSearchCell: NSSearchFieldCell {
    /// The system lays out the icon, text and ✕ for its own 22 pt field: the same, centered in a taller one.
    private func centered(_ rect: NSRect) -> NSRect {
        let h = min(rect.height, 22)
        return NSRect(x: rect.minX + 4, y: rect.minY + floor((rect.height - h) / 2), width: max(0, rect.width - 8), height: h)
    }
    // The system's text sits a little high for the taller field: 2.5 pt lower (the field is flipped).
    override func searchTextRect(forBounds rect: NSRect) -> NSRect { super.searchTextRect(forBounds: centered(rect)).offsetBy(dx: 0, dy: 2.5) }
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect { super.searchButtonRect(forBounds: centered(rect)) }
    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect { super.cancelButtonRect(forBounds: centered(rect)) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Dash.drawField(in: cellFrame, editing: Dash.isEditing(controlView))
        drawInterior(withFrame: cellFrame, in: controlView)
    }
}

/// A search field in the theme's look (same height and roundness as the pills next to it).
final class DashSearchField: NSSearchField {
    override class var cellClass: AnyClass? { get { DashSearchCell.self } set {} }
    override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width, height: fieldHeight) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); Dash.prepareField(self) }
    override func becomeFirstResponder() -> Bool { defer { needsDisplay = true }; return super.becomeFirstResponder() }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); needsDisplay = true }
}

extension Dash {
    /// A Pill's shape and fill: `on` in the accent's tint, a raised card under the mouse.
    static func drawPillShape(in bounds: NSRect, on: Bool, hovering: Bool) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (on ? accent.withAlphaComponent(0.16) : (hovering ? cardRaised : card)).setFill()
        path.fill()
        (on ? accent.withAlphaComponent(0.5) : border).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// A field's background: a rounded card, its border in the accent while typing.
    static func drawField(in frame: NSRect, editing: Bool) {
        let r = frame.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(8, r.height / 2)
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        card.setFill()
        path.fill()
        (editing ? accent.withAlphaComponent(0.6) : border).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Typing in it: the window's field editor works for this field.
    @MainActor static func isEditing(_ view: NSView) -> Bool {
        (view.window?.firstResponder as? NSTextView)?.delegate === view
    }

    /// The system's bezel and focus ring off (the field draws its own), the theme's text colors on.
    @MainActor static func prepareField(_ f: NSTextField) {
        f.isBezeled = false
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.textColor = text
        // One line that scrolls while typing, as the system's editable fields do (a swapped cell starts out wrapping).
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.usesSingleLineMode = true
        f.lineBreakMode = .byClipping
        if let p = f.placeholderString {
            f.placeholderAttributedString = NSAttributedString(string: p, attributes: [.foregroundColor: text3, .font: f.font ?? font(13)])
        }
    }
}
