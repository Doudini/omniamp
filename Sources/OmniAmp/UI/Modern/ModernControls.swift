import AppKit

/// Beveled hardware-style button showing a Nerd Font glyph and/or a label.
final class ModernButton: NSControl {
    var glyph: String
    var label: String? { didSet { if label != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    private var fullLabel: String?
    /// Icon-only when true (narrow windows); the label moves into the tooltip.
    var compact = false {
        didSet {
            guard compact != oldValue, !glyph.isEmpty else { return }
            if compact { fullLabel = label; label = nil; if toolTip == nil { toolTip = fullLabel?.capitalized } }
            else { label = fullLabel }
        }
    }
    var isToggle = false
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    var glyphSize: CGFloat = 12
    /// Drawn as a physical hi-fi key in a recessed housing (like the transport keys); the label glows when on.
    var keyStyle = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// Key style: false when the key shares a housing with its neighbours (see `KeyHousing`).
    var housing = true { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// Key style: the surface color the key sits on (darker for the bottom bar than for the top panel).
    var keyBase: NSColor = Theme.panelTop
    /// Width of an icon-only button (narrower in tight windows).
    var iconWidth: CGFloat = 34 { didSet { if iconWidth != oldValue { invalidateIntrinsicContentSize() } } }
    private var pressed = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(glyph: String, label: String? = nil, target: AnyObject?, action: Selector) {
        self.glyph = glyph
        self.label = label
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let w = label == nil ? iconWidth : (label! as NSString).size(withAttributes: [.font: Theme.mono(9, .bold)]).width + (glyph.isEmpty ? 16 : 30)
        let own = keyStyle && housing
        return NSSize(width: own ? w + 4 : w, height: keyStyle ? (housing ? 26 : 22) : 24)
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
            let inside = bounds.contains(convert(e.locationInWindow, from: nil))
            if e.type == .leftMouseUp {
                pressed = false
                if inside {
                    if isToggle { isOn.toggle() }
                    sendAction(action, to: target)
                }
                return
            }
            pressed = inside
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if keyStyle { drawKey(); return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        let top = pressed ? Theme.buttonBottom : Theme.buttonTop
        let bottom = pressed ? Theme.buttonTop.blended(withFraction: 0.3, of: .black)! : Theme.buttonBottom
        NSGradient(starting: hovering && !pressed ? top.highlight(withLevel: 0.08)! : top, ending: bottom)?.draw(in: path, angle: -90)
        NSColor.black.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1
        path.stroke()
        // Top highlight line.
        if !pressed {
            NSColor.white.withAlphaComponent(0.12).setStroke()
            let hl = NSBezierPath()
            hl.move(to: NSPoint(x: r.minX + 3, y: r.maxY - 1.5))
            hl.line(to: NSPoint(x: r.maxX - 3, y: r.maxY - 1.5))
            hl.stroke()
        }

        let color = isOn ? Theme.phosphor : Theme.buttonText
        let shadow = NSShadow()
        if isOn {
            shadow.shadowColor = Theme.phosphor.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = 5
        }
        let glyphAttrs: [NSAttributedString.Key: Any] = [.font: Theme.icon(glyphSize), .foregroundColor: color, .shadow: shadow]
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(9, .bold), .foregroundColor: color, .shadow: shadow]
        let g = glyph as NSString
        let gs = g.size(withAttributes: glyphAttrs)
        let dy: CGFloat = pressed ? -1 : 0
        if let label {
            let l = label as NSString
            let ls = l.size(withAttributes: labelAttrs)
            let total = (glyph.isEmpty ? 0 : gs.width + 5) + ls.width
            var x = (bounds.width - total) / 2
            if !glyph.isEmpty {
                g.draw(at: NSPoint(x: x, y: (bounds.height - gs.height) / 2 + dy), withAttributes: glyphAttrs)
                x += gs.width + 5
            }
            l.draw(at: NSPoint(x: x, y: (bounds.height - ls.height) / 2 + dy), withAttributes: labelAttrs)
        } else {
            g.draw(at: NSPoint(x: (bounds.width - gs.width) / 2, y: (bounds.height - gs.height) / 2 + dy), withAttributes: glyphAttrs)
        }
    }

    /// Key style: housing, key face, and a printed label (or glyph) that lights up in the theme color when on.
    private func drawKey() {
        if housing { KeyFace.drawHousing(bounds.insetBy(dx: 0.5, dy: 0.5)) }
        // Latching key: while on it stays pushed in, like a hi-fi switch.
        let face = KeyFace.draw(housing ? bounds.insetBy(dx: 2, dy: 2) : bounds, pressed: pressed || isOn, hovering: hovering, base: keyBase)
        let shadow = NSShadow()
        if isOn {
            shadow.shadowColor = Theme.phosphor.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 5
        } else {
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 1
        }
        let color = isOn ? Theme.phosphor : NSColor(calibratedWhite: 0.85, alpha: 1)
        let glyphAttrs: [NSAttributedString.Key: Any] = [.font: Theme.icon(glyphSize), .foregroundColor: color, .shadow: shadow]
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(9, .bold), .foregroundColor: color, .shadow: shadow]
        // Icon and/or label, centered together on the key face.
        let g = glyph as NSString, l = (label ?? "") as NSString
        let gs = glyph.isEmpty ? .zero : g.size(withAttributes: glyphAttrs)
        let ls = label == nil ? .zero : l.size(withAttributes: labelAttrs)
        let gap: CGFloat = glyph.isEmpty || label == nil ? 0 : 5
        var x = (face.midX - (gs.width + gap + ls.width) / 2).rounded()
        if !glyph.isEmpty {
            g.draw(at: NSPoint(x: x, y: (face.midY - gs.height / 2).rounded()), withAttributes: glyphAttrs)
            x += gs.width + gap
        }
        if label != nil { l.draw(at: NSPoint(x: x, y: (face.midY - ls.height / 2).rounded()), withAttributes: labelAttrs) }
    }
}

/// Drawing for physical hi-fi keys: a key sits in a dark recess, has a lit top bevel, a satin face and a
/// darker front lip that gives it depth. Pressed, it sinks: the lip disappears and the face darkens.
enum KeyFace {
    static let lip: CGFloat = 4

    /// Draws one key in `r` (the key's full slot, lip included). Returns the rect of the visible face.
    @discardableResult
    /// `base` is the color of the surface the keys sit on; the face is a little lighter than it.
    static func draw(_ r: NSRect, pressed: Bool, hovering: Bool, corners: CGFloat = 2.5, base: NSColor = Theme.panelTop) -> NSRect {
        // Pressed, the key sinks into its housing: the face moves down and the front lip all but disappears.
        let lipH: CGFloat = pressed ? 1 : lip
        let face = NSRect(x: r.minX, y: r.minY + lipH, width: r.width, height: r.height - lip)
        // Front lip: the key's front edge, dark, with a faint highlight where it catches light.
        if lipH > 0 {
            let lipRect = NSRect(x: r.minX, y: r.minY, width: r.width, height: face.minY - r.minY + corners)
            NSGradient(starting: Theme.panelBottom.blended(withFraction: 0.3, of: .black)!, ending: NSColor(calibratedWhite: 0.04, alpha: 1))?
                .draw(in: NSBezierPath(roundedRect: lipRect, xRadius: corners, yRadius: corners), angle: -90)
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSRect(x: r.minX + corners, y: r.minY + 0.5, width: r.width - 2 * corners, height: 0.5).fill()
        }
        // Face: slightly convex satin plastic in the panel's own blue-grey, just a little lighter than it.
        let facePath = NSBezierPath(roundedRect: face, xRadius: corners, yRadius: corners)
        let dark = base.blended(withFraction: 0.4, of: .black)!
        var top = pressed ? dark.blended(withFraction: 0.35, of: base)! : base.blended(withFraction: 0.14, of: .white)!
        var bottom = pressed ? dark : base.blended(withFraction: 0.25, of: dark)!
        if hovering && !pressed { top = top.highlight(withLevel: 0.08)!; bottom = bottom.highlight(withLevel: 0.05)! }
        NSGradient(colors: [top, top.blended(withFraction: 0.35, of: bottom)!, bottom], atLocations: [0, 0.45, 1],
                   colorSpace: .genericRGB)?.draw(in: facePath, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        facePath.addClip()
        // Specular band across the top third.
        NSGradient(starting: NSColor.white.withAlphaComponent(pressed ? 0.02 : 0.07), ending: .clear)?
            .draw(in: NSRect(x: face.minX, y: face.maxY - face.height * 0.38, width: face.width, height: face.height * 0.38), angle: -90)
        // Pressed: a shadow falls across the top of the sunken face.
        if pressed {
            NSGradient(starting: NSColor.black.withAlphaComponent(0.45), ending: .clear)?
                .draw(in: NSRect(x: face.minX, y: face.maxY - 4, width: face.width, height: 4), angle: -90)
        }
        NSGraphicsContext.restoreGraphicsState()
        // Crisp top bevel.
        if !pressed {
            let edge = NSBezierPath()
            edge.move(to: NSPoint(x: face.minX + corners, y: face.maxY - 0.5))
            edge.line(to: NSPoint(x: face.maxX - corners, y: face.maxY - 0.5))
            NSColor.white.withAlphaComponent(0.18).setStroke()
            edge.lineWidth = 1
            edge.stroke()
        }
        return face
    }

    /// Housing the keys sit in: a dark recess, shaded at the top like a cut-out, with a highlight along its bottom rim.
    static func drawHousing(_ r: NSRect) {
        let p = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        NSColor(calibratedWhite: 0.03, alpha: 1).setFill()
        p.fill()
        NSColor.white.withAlphaComponent(0.1).setStroke()
        let rim = NSBezierPath()
        rim.move(to: NSPoint(x: r.minX + 4, y: r.minY + 0.5))
        rim.line(to: NSPoint(x: r.maxX - 4, y: r.minY + 0.5))
        rim.stroke()
    }

    /// Printed key legend: light icon with a soft dark shadow.
    static func drawIcon(_ glyph: String, in face: NSRect, size: CGFloat, color: NSColor = NSColor(calibratedWhite: 0.88, alpha: 1)) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 1
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.icon(size), .foregroundColor: color, .shadow: shadow]
        let g = glyph as NSString
        let gs = g.size(withAttributes: attrs)
        g.draw(at: NSPoint(x: (face.midX - gs.width / 2).rounded(), y: (face.midY - gs.height / 2).rounded()), withAttributes: attrs)
    }
}

/// A row of joined hi-fi keys in one housing (transport: back, play, pause, stop, next), or a single key.
final class KeyStrip: NSControl, NSViewToolTipOwner {
    struct Key {
        var glyph: String
        var tip: String
        var action: () -> Void
    }
    private let keys: [Key]
    /// Width of each key (slimmer in tight windows).
    var keyWidth: CGFloat = 32 { didSet { if keyWidth != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var glyphSize: CGFloat = 11
    private var pressedIndex: Int? { didSet { if pressedIndex != oldValue { needsDisplay = true } } }
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    private static let inset: CGFloat = 2, seam: CGFloat = 1

    init(_ keys: [Key]) {
        self.keys = keys
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(keys.count) * keyWidth + CGFloat(keys.count - 1) * Self.seam + 2 * Self.inset, height: 26)
    }

    private func keyRect(_ i: Int) -> NSRect {
        let x = Self.inset + CGFloat(i) * (keyWidth + Self.seam)
        return NSRect(x: x, y: Self.inset, width: keyWidth, height: bounds.height - 2 * Self.inset)
    }

    private func index(at p: NSPoint) -> Int? { keys.indices.first { keyRect($0).insetBy(dx: 0, dy: -Self.inset).contains(p) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        // One tooltip area per key, answered by this view. (AppKit doesn't retain a tooltip's owner, so the
        // owner must live as long as the view: passing a temporary string crashed when the tooltip appeared.)
        removeAllToolTips()
        for i in keys.indices { addToolTip(keyRect(i), owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        index(at: point).map { keys[$0].tip } ?? ""
    }

    override func mouseMoved(with event: NSEvent) { hoverIndex = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        pressedIndex = i
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = keyRect(i).insetBy(dx: 0, dy: -Self.inset).contains(convert(e.locationInWindow, from: nil))
            if e.type == .leftMouseUp {
                pressedIndex = nil
                if inside { keys[i].action() }
                return
            }
            pressedIndex = inside ? i : nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        KeyFace.drawHousing(bounds.insetBy(dx: 0.5, dy: 0.5))
        for (i, k) in keys.enumerated() {
            let face = KeyFace.draw(keyRect(i), pressed: pressedIndex == i, hovering: hoverIndex == i)
            KeyFace.drawIcon(k.glyph, in: face, size: glyphSize)
        }
    }
}

/// One recess shared by a group of keys placed side by side with a 1 pt seam (ADD / RADIO / PODCASTS,
/// shuffle / repeat, INFO / EQ). Sits behind the keys.
final class KeyHousing: NSView {
    static let pad: CGFloat = 2, seam: CGFloat = 1

    override func draw(_ dirtyRect: NSRect) { KeyFace.drawHousing(bounds.insetBy(dx: 0.5, dy: 0.5)) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Adds a housing behind `keys` (already in `superview`, laid out left to right) and returns its constraints.
    @discardableResult
    static func wrap(_ keys: [NSView], in superview: NSView) -> [NSLayoutConstraint] {
        guard let first = keys.first, let last = keys.last else { return [] }
        let h = KeyHousing()
        h.translatesAutoresizingMaskIntoConstraints = false
        // Behind every key of the group, whatever order they were added in.
        let lowest = keys.min { (superview.subviews.firstIndex(of: $0) ?? 0) < (superview.subviews.firstIndex(of: $1) ?? 0) } ?? first
        superview.addSubview(h, positioned: .below, relativeTo: lowest)
        let c = [h.leadingAnchor.constraint(equalTo: first.leadingAnchor, constant: -pad),
                 h.trailingAnchor.constraint(equalTo: last.trailingAnchor, constant: pad),
                 h.topAnchor.constraint(equalTo: first.topAnchor, constant: -pad),
                 h.bottomAnchor.constraint(equalTo: first.bottomAnchor, constant: pad)]
        NSLayoutConstraint.activate(c)
        return c
    }
}

/// Small square hi-fi push key with an indicator LED above its icon (shuffle / repeat). The LED glows in the
/// theme color when on; the key dips slightly while pressed. The name lives in the tooltip.
final class LEDKey: NSControl {
    private let glyph: String
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    static let size: CGFloat = 22
    /// False when it shares a housing with a neighbour (see `KeyHousing`).
    var housing = false

    init(glyph: String, tip: String, target: AnyObject?, action: Selector) {
        self.glyph = glyph
        super.init(frame: .zero)
        self.target = target
        self.action = action
        toolTip = tip
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

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
            let inside = bounds.contains(convert(e.locationInWindow, from: nil))
            if e.type == .leftMouseUp {
                pressed = false
                if inside { sendAction(action, to: target) }
                return
            }
            pressed = inside
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if housing { KeyFace.drawHousing(bounds.insetBy(dx: 0.5, dy: 0.5)) }
        // Latching key: while on it stays pushed in.
        let face = KeyFace.draw(housing ? bounds.insetBy(dx: 2, dy: 2) : bounds, pressed: pressed || isOn, hovering: hovering)

        // Indicator LED near the top of the key face.
        let d: CGFloat = 4
        let led = NSRect(x: face.midX - d / 2, y: face.maxY - 3 - d, width: d, height: d)
        NSGraphicsContext.saveGraphicsState()
        if isOn {
            let glow = NSShadow()
            glow.shadowColor = Theme.phosphor
            glow.shadowBlurRadius = 4
            glow.set()
            Theme.phosphor.setFill()
        } else {
            NSColor.black.withAlphaComponent(0.6).setFill()
        }
        NSBezierPath(ovalIn: led).fill()
        NSGraphicsContext.restoreGraphicsState()
        if !isOn {
            NSColor.white.withAlphaComponent(0.12).setStroke()
            NSBezierPath(ovalIn: led.insetBy(dx: -0.25, dy: -0.25)).stroke()
        }
        // Legend below the LED.
        let below = NSRect(x: face.minX, y: face.minY, width: face.width, height: face.height - d - 3)
        KeyFace.drawIcon(glyph, in: below, size: 10, color: NSColor(calibratedWhite: isOn ? 0.9 : 0.72, alpha: 1))
    }
}

/// Thin LCD-style slider: dark groove, green fill, small metal knob.
final class ModernSlider: NSControl {
    /// Redraws only when the knob moves at least half a point (the seek bar updates every frame).
    var value: Double = 0 {
        // Measured against where the knob was last drawn: comparing with the previous value (a tiny step per
        // tick) never added up to half a point, so the seek bar never moved during playback.
        didSet { if abs(value - drawnValue) * Double(max(1, bounds.width - knobWidth)) >= 0.5 { needsDisplay = true } }
    }
    private var drawnValue: Double = -1
    private(set) var isDragging = false
    /// Called continuously while dragging; `action` fires on mouse-up.
    var onChange: ((Double) -> Void)?
    var knobWidth: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    private var track: NSRect { bounds.insetBy(dx: knobWidth / 2, dy: 0) }

    private func valueAt(_ p: NSPoint) -> Double {
        max(0, min(1, Double((p.x - track.minX) / track.width)))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isDragging = true
        value = valueAt(convert(event.locationInWindow, from: nil))
        onChange?(value)
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            value = valueAt(convert(e.locationInWindow, from: nil))
            onChange?(value)
            if e.type == .leftMouseUp { break }
        }
        isDragging = false
        sendAction(action, to: target)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else { return }
        let d = Double(event.scrollingDeltaY + event.scrollingDeltaX) * (event.hasPreciseScrollingDeltas ? 0.002 : 0.03)
        guard d != 0 else { return }
        value = max(0, min(1, value + d))
        onChange?(value)
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawnValue = value
        let midY = bounds.midY
        let groove = NSRect(x: track.minX, y: midY - 2.5, width: track.width, height: 5)
        let gp = NSBezierPath(roundedRect: groove, xRadius: 2.5, yRadius: 2.5)
        Theme.lcd.setFill(); gp.fill()
        NSColor.black.setStroke(); gp.lineWidth = 1; gp.stroke()

        let fx = track.minX + CGFloat(value) * track.width
        if fx > groove.minX + 1 {
            let fill = NSRect(x: groove.minX + 1, y: groove.minY + 1, width: fx - groove.minX - 1, height: groove.height - 2)
            NSGradient(starting: Theme.phosphorDim, ending: Theme.phosphor)?.draw(in: NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5), angle: 0)
        }

        let knob = NSRect(x: fx - knobWidth / 2, y: midY - 6, width: knobWidth, height: 12)
        let kp = NSBezierPath(roundedRect: knob, xRadius: 2, yRadius: 2)
        NSGradient(starting: NSColor(calibratedWhite: 0.85, alpha: 1), ending: NSColor(calibratedWhite: 0.45, alpha: 1))?.draw(in: kp, angle: -90)
        NSColor.black.withAlphaComponent(0.8).setStroke(); kp.stroke()
        // Grip lines.
        NSColor.black.withAlphaComponent(0.35).setStroke()
        for dx in [-2.0, 0.0, 2.0] {
            let l = NSBezierPath()
            l.move(to: NSPoint(x: knob.midX + dx, y: knob.minY + 3))
            l.line(to: NSPoint(x: knob.midX + dx, y: knob.maxY - 3))
            l.lineWidth = 1
            l.stroke()
        }
    }
}

extension NSTextField {
    /// Set the text only if it differs: every stringValue set redraws the field (and can re-run layout),
    /// which adds up for labels refreshed many times a second.
    func setIfChanged(_ s: String) { if stringValue != s { stringValue = s } }
}
