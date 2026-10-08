import AppKit

/// A scroll bar in the theme's colors: a rounded knob on the list's own background, instead of the system's grey
/// one. It still follows System Settings → Show scroll bars (with a mouse attached macOS keeps it visible; the slot
/// is then the list's color, so it reads as part of the list rather than a grey band beside it).
final class ThemedScroller: NSScroller {
    enum Style {
        /// The player's playlist and the LCD-style lists: a dim phosphor knob.
        case lcd
        /// The library's and podcasts' cards and pages: a muted text-colored knob.
        case dash
    }

    var style: Style = .lcd { didSet { needsDisplay = true } }
    private var tracking = false
    private let observers = Observers()

    /// Without this AppKit treats a subclass as legacy-only and keeps it visible even where it could fade.
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    /// Gives `scroll` a themed vertical scroll bar (and a horizontal one when asked).
    static func install(in scroll: NSScrollView, _ style: Style, horizontal: Bool = false) {
        let v = ThemedScroller()
        v.style = style
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = v
        if horizontal {
            let h = ThemedScroller()
            h.style = style
            scroll.hasHorizontalScroller = true
            scroll.horizontalScroller = h
        }
        scroll.scrollerStyle = .overlay   // the system's preference still wins when it changes (a mouse attached)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        observers.add(NotificationCenter.default.addObserver(forName: Theme.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        })
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The scroll bar runs over the list's top and bottom insets too: left beside them, macOS paints that strip
    /// grey when the scroll bar is always shown. Checked here because pages set their insets after installing it.
    override func viewWillDraw() {
        if let scroll = superview as? NSScrollView, scroll.verticalScroller === self {
            let ci = scroll.contentInsets, si = scroll.scrollerInsets
            if si.top != -ci.top || si.bottom != -ci.bottom {
                scroll.scrollerInsets = NSEdgeInsets(top: -ci.top, left: si.left, bottom: -ci.bottom, right: si.right)
            }
        }
        super.viewWillDraw()
    }

    override func draw(_ dirtyRect: NSRect) {
        if scrollerStyle == .legacy { drawKnobSlot(in: bounds, highlight: false) }
        drawKnob()
    }

    /// The list's own background (nothing where the list draws none), so no grey band shows beside it.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard let scroll = superview as? NSScrollView, scroll.drawsBackground else { return }
        scroll.backgroundColor.setFill()
        slotRect.fill()
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.width > 0, knob.height > 0 else { return }
        let across: CGFloat = scrollerStyle == .legacy ? 4 : 3
        let r = bounds.width < bounds.height ? knob.insetBy(dx: across, dy: 2) : knob.insetBy(dx: 2, dy: across)
        let radius = min(r.width, r.height) / 2
        knobColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    private var knobColor: NSColor {
        switch style {
        case .lcd: tracking ? Theme.phosphor.withAlphaComponent(0.7) : Theme.phosphorDim
        case .dash: Theme.surfaces.text3.withAlphaComponent(tracking ? 0.9 : 0.55)
        }
    }

    override func trackKnob(with event: NSEvent) {
        tracking = true
        needsDisplay = true
        super.trackKnob(with: event)   // returns when the mouse goes up
        tracking = false
        needsDisplay = true
    }
}
