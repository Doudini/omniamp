import AppKit

/// The library's design tokens: slate surfaces, a text hierarchy, and the theme's accent used sparingly.
///
/// Text is white (names, figures), grey (details) or muted (captions, axes). The theme's phosphor color marks
/// section titles, selections and data; a second accent, complementary to the theme, is for comparisons (a
/// line over bars). Names and body text are in the system font, numbers and labels in Hack.
enum Dash {
    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    // Surfaces.
    static let page = rgb(0x0D1519)
    static let card = rgb(0x152127)
    static let cardRaised = rgb(0x1B2A31)
    static let border = rgb(0x24353D)
    static let grid = NSColor.white.withAlphaComponent(0.06)

    // Text.
    static let text = rgb(0xE6ECEE)
    static let text2 = rgb(0x93A3AA)
    static let text3 = rgb(0x5E6F76)

    // Accents.
    static var accent: NSColor { Theme.phosphor }
    /// Complementary to the theme: for a second series.
    static var accent2: NSColor {
        switch Theme.palette.id {
        case "amber": rgb(0x4FC3C7)
        case "blue", "cyan": rgb(0xF2B84B)
        default: rgb(0x6FA8DC)
        }
    }
    static var selection: NSColor { accent.withAlphaComponent(0.16) }
    /// Up and down, for changes ("▲ +12%").
    static let up = rgb(0x5FD38A)
    static let down = rgb(0xE8736B)

    // Fonts.
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func mono(_ size: CGFloat, bold: Bool = false) -> NSFont { Fonts.hack(size, bold: bold) }
    /// Section titles: small Hack capitals in the accent.
    static func title(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s.uppercased(), attributes: [.font: mono(10, bold: true), .foregroundColor: accent, .kern: 0.6])
    }

    /// Everything in a page gives way sideways (labels truncate, rows clip) instead of setting the window's
    /// minimum width: text and stack views resist being narrowed more strongly than the window keeps its size.
    static func relaxWidth(_ view: NSView) {
        if let stack = view as? NSStackView { stack.setClippingResistancePriority(.defaultLow, for: .horizontal) }
        if view is NSControl { view.setContentCompressionResistancePriority(.init(240), for: .horizontal) }
        view.subviews.forEach(relaxWidth)
    }

    static func label(_ s: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = font
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    /// A list in a card: no header or grid, rows with a soft accent selection.
    static func applyList(_ table: NSTableView, in scroll: NSScrollView, rowHeight: CGFloat) {
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: table.numberOfColumns > 1 ? 8 : 0, height: 0)
        table.style = .plain
        table.gridStyleMask = []
        table.backgroundColor = card
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scroll.drawsBackground = true
        scroll.backgroundColor = card
        styleCard(scroll)
    }

    static func styleCard(_ v: NSView, color: NSColor = card) {
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 1
        v.layer?.borderColor = border.cgColor
        if !(v is NSScrollView) { v.layer?.backgroundColor = color.cgColor }
    }
}

/// A row in a card list: a rounded accent tint when selected, a faint one under the mouse.
final class CardRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Dash.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// A rounded pill button: a filter, a mode, an action. On: accent tint and text.
final class Pill: NSControl {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var glyph: String?
    var isOn = false { didSet { needsDisplay = true } }
    /// Filled with the accent (the main action on a page).
    var prominent = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(_ title: String, glyph: String? = nil, target: AnyObject?, action: Selector) {
        self.title = title
        self.glyph = glyph
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var attributed: NSAttributedString {
        let color: NSColor = prominent ? Dash.page : (isOn ? Dash.accent : (hovering ? Dash.text : Dash.text2))
        let s = NSMutableAttributedString()
        if let g = glyph { s.append(NSAttributedString(string: g + "  ", attributes: [.font: Fonts.hack(11), .foregroundColor: color])) }
        s.append(NSAttributedString(string: title, attributes: [.font: Dash.font(12, .medium), .foregroundColor: color]))
        return s
    }

    override var intrinsicContentSize: NSSize { NSSize(width: attributed.size().width + 24, height: 26) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        let fill: NSColor = prominent ? Dash.accent.withAlphaComponent(pressed ? 0.75 : (hovering ? 1 : 0.9))
            : isOn ? Dash.accent.withAlphaComponent(0.16) : (hovering || pressed ? Dash.cardRaised : Dash.card)
        fill.setFill()
        path.fill()
        if !prominent {
            (isOn ? Dash.accent.withAlphaComponent(0.5) : Dash.border).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let s = attributed, size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if e.type == .leftMouseUp {
                pressed = false
                if bounds.contains(convert(e.locationInWindow, from: nil)) { sendAction(action, to: target) }
                return
            }
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
