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

    /// A color that follows the theme: it's looked up each time it's drawn, so a label or table given it once
    /// changes with the theme without being set again.
    private static func live(_ color: @escaping () -> NSColor) -> NSColor {
        NSColor(name: nil) { _ in color() }
    }

    // Surfaces (the theme's finish).
    static let page = live { Theme.surfaces.page }
    static let card = live { Theme.surfaces.card }
    static let cardRaised = live { Theme.surfaces.cardRaised }
    static let border = live { Theme.surfaces.border }
    static let grid = NSColor.white.withAlphaComponent(0.06)

    // Text.
    static let text = live { Theme.surfaces.text }
    static let text2 = live { Theme.surfaces.text2 }
    static let text3 = live { Theme.surfaces.text3 }

    // Accents.
    static let accent = live { Theme.phosphor }
    /// Complementary to the theme: for a second series.
    static let accent2 = live {
        switch Theme.palette.id {
        case "amber": rgb(0x4FC3C7)
        case "blue", "cyan": rgb(0xF2B84B)
        default: rgb(0x6FA8DC)
        }
    }
    static let selection = live { Theme.phosphor.withAlphaComponent(0.16) }

    /// Categorical colors for artists (the dataviz reference palette, dark steps), checked on our cards: neighbours
    /// stay apart for color-blind eyes too. Fixed order; a ninth artist folds into "other" (gray).
    static let series: [NSColor] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500, 0xD55181, 0x008300, 0x9085E9, 0xE66767].map { rgb(UInt32($0)) }
    static let other = rgb(0x4A5A61)

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
        // Pills keep their size (squeezed, their labels ran into each other); text gives way.
        // Only ever lowered: a view meant to give way first (a card's note) keeps its lower priority.
        if view is NSControl, !(view is Pill), view.contentCompressionResistancePriority(for: .horizontal).rawValue > 240 {
            view.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        }
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
        ScrollFades.add(to: scroll, color: card)
    }

    static func styleCard(_ v: NSView, color: NSColor = card) {
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 1
        // Layers keep a fixed copy of a color: the card remembers its fill so a theme change can paint it again.
        v.layer?.setValue(color, forKey: cardFill)
        paintCard(v)
    }

    private static let cardFill = "dashCardFill"

    private static func paintCard(_ v: NSView) {
        guard let layer = v.layer, let fill = layer.value(forKey: cardFill) as? NSColor else { return }
        layer.borderColor = border.cgColor
        if !(v is NSScrollView) { layer.backgroundColor = fill.cgColor }
    }

    /// After a theme change: cards and list fades painted again, everything redrawn (the rest of the colors
    /// follow the theme by themselves). Pages keep their state; nothing is rebuilt.
    static func restyle(_ root: NSView) {
        paintCard(root)
        (root as? ScrollFades)?.recolor()
        root.needsDisplay = true
        root.subviews.forEach(restyle)
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
    /// The title under the name the hardware-style buttons use.
    var label: String { get { title } set { title = newValue } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
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
        let color: NSColor = !isEnabled ? Dash.text3 : prominent ? Dash.page : (isOn ? Dash.accent : (hovering ? Dash.text : Dash.text2))
        let s = NSMutableAttributedString()
        if let g = glyph { s.append(NSAttributedString(string: g + "  ", attributes: [.font: Fonts.hack(11), .foregroundColor: color])) }
        s.append(NSAttributedString(string: title, attributes: [.font: Dash.font(12, .medium), .foregroundColor: color]))
        return s
    }

    override var intrinsicContentSize: NSSize { NSSize(width: attributed.size().width + 24, height: 26) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        let fill: NSColor = prominent && !isEnabled ? Dash.cardRaised
            : prominent ? Dash.accent.withAlphaComponent(pressed ? 0.75 : (hovering ? 1 : 0.9))
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
        guard isEnabled else { return }
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

/// Soft edges on a list in a card: rows fade into the card at the top and bottom instead of being cut off,
/// each edge only while there's more to scroll to that way. Clicks go through.
final class ScrollFades: NSView {
    private weak var scroll: NSScrollView?
    private let color: NSColor
    private let top = CAGradientLayer(), bottom = CAGradientLayer()
    static let height: CGFloat = 18

    static func add(to scroll: NSScrollView, color: NSColor) {
        scroll.subviews.filter { $0 is ScrollFades }.forEach { $0.removeFromSuperview() }
        let f = ScrollFades(scroll: scroll, color: color)
        scroll.addSubview(f, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), f.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            f.topAnchor.constraint(equalTo: scroll.topAnchor), f.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        ])
    }

    private init(scroll: NSScrollView, color: NSColor) {
        self.scroll = scroll
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        recolor()
        for (g, down) in [(top, true), (bottom, false)] {
            // Layer y runs up: the top fade is solid at its top, the bottom one at its bottom.
            g.startPoint = CGPoint(x: 0.5, y: down ? 1 : 0)
            g.endPoint = CGPoint(x: 0.5, y: down ? 0 : 1)
            g.opacity = 0
            layer?.addSublayer(g)
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: scroll.documentView)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Gradients hold fixed colors: painted again after a theme change.
    func recolor() {
        let c = color.usingColorSpace(.sRGB) ?? color
        for g in [top, bottom] { g.colors = [c.cgColor, c.withAlphaComponent(0).cgColor] }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        top.frame = CGRect(x: 0, y: bounds.height - Self.height, width: bounds.width, height: Self.height)
        bottom.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.height)
        CATransaction.commit()
        update()
    }

    /// Each edge as strong as there's content beyond it (full after a fade's height).
    @objc private func update() {
        guard let s = scroll, let doc = s.documentView else { return }
        let clip = s.contentView.bounds, inset = s.contentInsets
        let above = clip.minY + inset.top
        let below = doc.frame.height - clip.maxY + inset.bottom
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        top.opacity = Float(max(0, min(1, above / Self.height)))
        bottom.opacity = Float(max(0, min(1, below / Self.height)))
        CATransaction.commit()
    }
}
