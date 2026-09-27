import AppKit

/// Vertical fader: groove, green fill from the 0 dB center, metal cap.
final class ModernVSlider: NSControl {
    /// -1...1 (0 = center).
    var value: Double = 0 { didSet { needsDisplay = true } }
    var onChange: ((Double) -> Void)?
    private let capH: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    private var track: NSRect { bounds.insetBy(dx: 0, dy: capH / 2 + 1) }

    private func valueAt(_ p: NSPoint) -> Double {
        max(-1, min(1, Double((p.y - track.midY) / (track.height / 2))))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { value = 0; onChange?(0); return } // double-click resets
        value = valueAt(convert(event.locationInWindow, from: nil))
        onChange?(value)
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            value = valueAt(convert(e.locationInWindow, from: nil))
            onChange?(value)
            if e.type == .leftMouseUp { break }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let d = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.004 : 0.06)
        guard d != 0 else { return }
        value = max(-1, min(1, value + d))
        onChange?(value)
    }

    override func draw(_ dirtyRect: NSRect) {
        let groove = NSRect(x: bounds.midX - 2.5, y: track.minY, width: 5, height: track.height)
        let gp = NSBezierPath(roundedRect: groove, xRadius: 2.5, yRadius: 2.5)
        Theme.lcd.setFill(); gp.fill()
        NSColor.black.setStroke(); gp.stroke()
        // Center (0 dB) tick.
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSRect(x: bounds.minX + 2, y: track.midY - 0.5, width: bounds.width - 4, height: 1).fill()

        let y = track.midY + CGFloat(value) * track.height / 2
        let fill = NSRect(x: groove.minX + 1, y: min(y, track.midY), width: groove.width - 2, height: abs(y - track.midY))
        if fill.height > 0.5 {
            (value >= 0 ? Theme.phosphor : Theme.phosphorDim.blended(withFraction: 0.3, of: Theme.phosphor)!).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
        }
        let cap = NSRect(x: bounds.midX - 7, y: y - capH / 2, width: 14, height: capH)
        let cp = NSBezierPath(roundedRect: cap, xRadius: 2, yRadius: 2)
        NSGradient(starting: NSColor(calibratedWhite: 0.85, alpha: 1), ending: NSColor(calibratedWhite: 0.45, alpha: 1))?.draw(in: cp, angle: -90)
        NSColor.black.withAlphaComponent(0.8).setStroke(); cp.stroke()
        NSColor.black.withAlphaComponent(0.4).setFill()
        NSRect(x: cap.minX + 3, y: cap.midY - 0.5, width: cap.width - 6, height: 1).fill()
    }
}

/// Modern EQ drawer: ON, presets, preamp + 10 bands, live response curve.
final class ModernEQView: NSView {
    weak var controller: PlayerController?
    private var onButton: ModernButton!
    private var presetButton: ModernButton!
    private let preamp = ModernVSlider()
    private var bands: [ModernVSlider] = []
    private let curve = EQCurveView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSGradient(starting: Theme.panelTop.blended(withFraction: 0.3, of: .black)!, ending: Theme.panelBottom)?.draw(in: p, angle: -90)
        NSColor.black.setStroke(); p.stroke()
    }

    private func label(_ s: String, _ size: CGFloat = 8.5) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Fonts.hack(size, bold: true)
        l.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        l.alignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func build() {
        onButton = ModernButton(glyph: "", label: "EQ ON", target: self, action: #selector(toggleOn))
        onButton.isToggle = true
        presetButton = ModernButton(glyph: "", label: "PRESETS ▾", target: self, action: #selector(showPresets))
        addSubview(onButton)
        addSubview(presetButton)
        curve.translatesAutoresizingMaskIntoConstraints = false
        addSubview(curve)

        preamp.onChange = { [weak self] v in self?.changed { $0.preamp = Float(v) * Equalizer.range } }
        let preLabel = label("PRE")
        addSubview(preamp)
        addSubview(preLabel)
        let scale = [label("+12", 8), label(" 0 ", 8), label("-12", 8)]
        scale.forEach { $0.textColor = Theme.phosphorDim; addSubview($0) }

        var cons: [NSLayoutConstraint] = [
            onButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            onButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            onButton.heightAnchor.constraint(equalToConstant: 20),
            presetButton.leadingAnchor.constraint(equalTo: onButton.trailingAnchor, constant: 4),
            presetButton.centerYAnchor.constraint(equalTo: onButton.centerYAnchor),
            presetButton.heightAnchor.constraint(equalToConstant: 20),
            curve.leadingAnchor.constraint(equalTo: presetButton.trailingAnchor, constant: 10),
            curve.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            curve.centerYAnchor.constraint(equalTo: onButton.centerYAnchor),
            curve.heightAnchor.constraint(equalToConstant: 20),

            preamp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            preamp.topAnchor.constraint(equalTo: onButton.bottomAnchor, constant: 8),
            preamp.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            preamp.widthAnchor.constraint(equalToConstant: 20),
            preLabel.centerXAnchor.constraint(equalTo: preamp.centerXAnchor),
            preLabel.topAnchor.constraint(equalTo: preamp.bottomAnchor, constant: 3),

            scale[0].leadingAnchor.constraint(equalTo: preamp.trailingAnchor, constant: 6),
            scale[0].topAnchor.constraint(equalTo: preamp.topAnchor, constant: -2),
            scale[1].leadingAnchor.constraint(equalTo: scale[0].leadingAnchor),
            scale[1].centerYAnchor.constraint(equalTo: preamp.centerYAnchor),
            scale[2].leadingAnchor.constraint(equalTo: scale[0].leadingAnchor),
            scale[2].bottomAnchor.constraint(equalTo: preamp.bottomAnchor, constant: 2),
        ]

        var prev: NSView = scale[0]
        for i in 0..<Equalizer.frequencies.count {
            let s = ModernVSlider()
            s.onChange = { [weak self] v in self?.changed { $0.bands[i] = Float(v) * Equalizer.range } }
            let l = label(Equalizer.labels[i])
            addSubview(s)
            addSubview(l)
            bands.append(s)
            cons += [
                s.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: i == 0 ? 8 : 2),
                s.topAnchor.constraint(equalTo: preamp.topAnchor),
                s.bottomAnchor.constraint(equalTo: preamp.bottomAnchor),
                l.centerXAnchor.constraint(equalTo: s.centerXAnchor),
                l.topAnchor.constraint(equalTo: preLabel.topAnchor),
            ]
            if i > 0 { cons.append(s.widthAnchor.constraint(equalTo: bands[0].widthAnchor)) }
            prev = s
        }
        // Preamp is fixed; the bands share the remaining width equally.
        cons.append(bands.last!.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10))
        NSLayoutConstraint.activate(cons)
    }

    private func changed(_ edit: (inout Equalizer.Settings) -> Void) {
        guard let c = controller else { return }
        var s = c.eqSettings
        edit(&s)
        c.setEQ(s)
    }

    func refresh() {
        guard let c = controller else { return }
        let s = c.eqSettings
        let bypassed = c.player.bitPerfect
        onButton.isOn = s.enabled && !bypassed
        onButton.label = bypassed ? "BYPASSED" : "EQ ON"   // both only redraw when they change
        let tip = bypassed ? "The EQ is bypassed in bit-perfect mode (Output menu)." : nil
        if onButton.toolTip != tip { onButton.toolTip = tip }
        preamp.value = Double(s.preamp / Equalizer.range)
        for (i, b) in bands.enumerated() { b.value = Double(s.bands[i] / Equalizer.range) }
        curve.bands = s.bands
        curve.enabled = s.enabled && !bypassed
    }

    @objc private func toggleOn() { changed { $0.enabled.toggle() } }

    @objc private func showPresets() {
        let m = NSMenu()
        for p in Equalizer.presets {
            let it = m.addItem(withTitle: p.name, action: #selector(pickPreset(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p.name
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: presetButton.bounds.height + 2), in: presetButton)
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        guard let p = Equalizer.presets.first(where: { $0.name == sender.representedObject as? String }) else { return }
        controller?.applyPreset(p)
    }
}

/// Small LCD showing the EQ curve (smooth line through the band gains).
final class EQCurveView: NSView {
    var bands: [Float] = Array(repeating: 0, count: 10) { didSet { needsDisplay = true } }
    var enabled = false { didSet { if enabled != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        Theme.lcd.setFill(); p.fill()
        NSColor.black.setStroke(); p.stroke()
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSRect(x: 3, y: bounds.midY, width: bounds.width - 6, height: 1).fill()

        let inset = bounds.insetBy(dx: 5, dy: 3)
        let pts = bands.enumerated().map { i, g in
            NSPoint(x: inset.minX + inset.width * CGFloat(i) / CGFloat(bands.count - 1),
                    y: inset.midY + CGFloat(g / Equalizer.range) * inset.height / 2)
        }
        let path = NSBezierPath()
        path.move(to: pts[0])
        // Catmull-Rom → Bézier for a smooth curve.
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
            let c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        path.lineWidth = 1.5
        let glow = NSShadow()
        glow.shadowColor = Theme.phosphor.withAlphaComponent(0.8)
        glow.shadowBlurRadius = enabled ? 4 : 0
        NSGraphicsContext.saveGraphicsState()
        glow.set()
        (enabled ? Theme.phosphor : Theme.phosphorDim).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
