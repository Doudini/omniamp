import AppKit

/// Beveled hardware-style button showing a Nerd Font glyph and/or a label.
final class ModernButton: NSControl {
    var glyph: String
    var label: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
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
    var isOn = false { didSet { needsDisplay = true } }
    var glyphSize: CGFloat = 12
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
        let w = label == nil ? 34 : (label! as NSString).size(withAttributes: [.font: Theme.mono(9, .bold)]).width + (glyph.isEmpty ? 16 : 30)
        return NSSize(width: w, height: 24)
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

        let color = isOn ? Theme.green : Theme.buttonText
        let shadow = NSShadow()
        if isOn {
            shadow.shadowColor = Theme.green.withAlphaComponent(0.8)
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
}

/// Thin LCD-style slider: dark groove, green fill, small metal knob.
final class ModernSlider: NSControl {
    /// Redraws only when the knob moves at least half a point (the seek bar updates every frame).
    var value: Double = 0 {
        didSet { if abs(value - oldValue) * Double(max(1, bounds.width - knobWidth)) >= 0.5 { needsDisplay = true } }
    }
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
        let midY = bounds.midY
        let groove = NSRect(x: track.minX, y: midY - 2.5, width: track.width, height: 5)
        let gp = NSBezierPath(roundedRect: groove, xRadius: 2.5, yRadius: 2.5)
        Theme.lcd.setFill(); gp.fill()
        NSColor.black.setStroke(); gp.lineWidth = 1; gp.stroke()

        let fx = track.minX + CGFloat(value) * track.width
        if fx > groove.minX + 1 {
            let fill = NSRect(x: groove.minX + 1, y: groove.minY + 1, width: fx - groove.minX - 1, height: groove.height - 2)
            NSGradient(starting: Theme.dimGreen, ending: Theme.green)?.draw(in: NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5), angle: 0)
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
