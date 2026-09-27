import AppKit

/// Black LCD well with an inner shadow.
final class LCDBox: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        Theme.lcd.setFill(); p.fill()
        // Subtle scanline-ish top sheen.
        NSGradient(starting: NSColor.white.withAlphaComponent(0.04), ending: .clear)?
            .draw(in: NSRect(x: 0, y: bounds.height * 0.55, width: bounds.width, height: bounds.height * 0.45), angle: -90)
        NSColor.black.setStroke(); p.lineWidth = 1; p.stroke()
        Theme.panelEdge.withAlphaComponent(0.5).setStroke()
        let under = NSBezierPath()
        under.move(to: NSPoint(x: 4, y: 0.5)); under.line(to: NSPoint(x: bounds.width - 4, y: 0.5))
        under.stroke()
    }
}

/// The time as a 7-segment display, like an 80s tape-deck counter: slanted segments with pointed ends, the
/// unlit segments of "88:88" faintly visible, a phosphor glow, and a colon that blinks while paused.
/// Click it to switch between elapsed and remaining time.
///
/// Made of shape layers: a tick only swaps the lit segments' paths (once a second), and the glow is
/// rasterized once per change, so the app does no drawing of its own.
final class LCDTimeView: NSView {
    /// "MM:SS".
    var text = "00:00" { didSet { if text != oldValue { updateDigits() } } }
    /// Paused: the colon goes dark (blinks).
    var dimmed = false { didSet { if dimmed != oldValue { colon.isHidden = dimmed } } }
    /// Height of a digit in points.
    var digitHeight: CGFloat = 28 { didSet { if digitHeight != oldValue { geometry = nil; needsLayout = true } } }
    var onClick: (() -> Void)?

    private let ghost = CAShapeLayer()
    private let litGroup = CALayer()
    private var digits: [CAShapeLayer] = []
    private let colon = CAShapeLayer()
    private var geometry: (size: CGSize, cells: [CGFloat])?

    // Proportions (relative to the digit height).
    private static let widthRatio: CGFloat = 0.56, thickRatio: CGFloat = 0.15, spaceRatio: CGFloat = 0.2, colonRatio: CGFloat = 0.34
    private static let slant: CGFloat = tan(8 * .pi / 180)

    /// Segments per digit: a top, b upper right, c lower right, d bottom, e lower left, f upper left, g middle.
    private static let segmentsFor: [Character: String] = [
        "0": "abcdef", "1": "bc", "2": "abged", "3": "abgcd", "4": "fgbc", "5": "afgcd",
        "6": "afgedc", "7": "abc", "8": "abcdefg", "9": "abcdfg", "-": "g", " ": "",
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let root = CALayer()
        root.addSublayer(ghost)
        root.addSublayer(litGroup)
        for _ in 0..<4 { let d = CAShapeLayer(); litGroup.addSublayer(d); digits.append(d) }
        litGroup.addSublayer(colon)
        // Glow around the lit segments, cached as a bitmap until the digits change.
        litGroup.shadowOffset = .zero
        litGroup.shadowRadius = 4
        litGroup.shadowOpacity = 0.8
        litGroup.shouldRasterize = true
        return root
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        litGroup.rasterizationScale = window?.backingScaleFactor ?? 2
        for l in [ghost, colon] + digits { l.contentsScale = window?.backingScaleFactor ?? 2 }
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, geometry?.size != bounds.size else { return }
        let h = digitHeight, w = h * Self.widthRatio, sp = h * Self.spaceRatio, cw = h * Self.colonRatio
        let total = 4 * w + 2 * sp + cw + h * Self.slant
        let x0 = ((bounds.width - total) / 2).rounded()
        // Cell x origins: digit, digit, colon, digit, digit.
        let cells = [x0, x0 + w + sp, x0 + 2 * w + sp, x0 + 2 * w + sp + cw, x0 + 3 * w + 2 * sp + cw]
        geometry = (bounds.size, cells)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [ghost, colon] + digits as [CALayer] { l.frame = bounds }
        litGroup.frame = bounds
        litGroup.shadowColor = Theme.phosphor.cgColor
        litGroup.rasterizationScale = window?.backingScaleFactor ?? 2
        ghost.fillColor = Theme.phosphorGhost.cgColor
        colon.fillColor = Theme.phosphor.cgColor
        digits.forEach { $0.fillColor = Theme.phosphor.cgColor }
        // Unlit: every segment of 88:88.
        let g = CGMutablePath()
        for i in [0, 1, 3, 4] { g.addPath(digitPath("abcdefg", x: cells[i])) }
        g.addPath(colonPath(x: cells[2]))
        ghost.path = g
        colon.path = colonPath(x: cells[2])
        CATransaction.commit()
        updateDigits()
    }

    private func updateDigits() {
        guard let cells = geometry?.cells else { return }
        let chars = Array(text.filter { $0 != ":" }.suffix(4))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, cell) in [cells[0], cells[1], cells[3], cells[4]].enumerated() {
            let c = i < chars.count ? chars[i] : " "
            digits[i].path = digitPath(Self.segmentsFor[c] ?? "", x: cell)
        }
        CATransaction.commit()
    }

    /// The lit segments of one digit whose cell starts at `x`, vertically centered, slanted.
    private func digitPath(_ segs: String, x: CGFloat) -> CGPath {
        let h = digitHeight, w = h * Self.widthRatio, t = h * Self.thickRatio, gap = max(0.5, t * 0.14)
        let y0 = ((bounds.height - h) / 2).rounded()
        let p = CGMutablePath()
        // Hexagonal segment between two centre points along one axis.
        func horizontal(_ yc: CGFloat) -> [CGPoint] {
            let a = t / 2 + gap, b = w - t / 2 - gap
            return [CGPoint(x: a, y: yc), CGPoint(x: a + t / 2, y: yc + t / 2), CGPoint(x: b - t / 2, y: yc + t / 2),
                    CGPoint(x: b, y: yc), CGPoint(x: b - t / 2, y: yc - t / 2), CGPoint(x: a + t / 2, y: yc - t / 2)]
        }
        func vertical(_ xc: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> [CGPoint] {
            let a = lo + gap, b = hi - gap
            return [CGPoint(x: xc, y: a), CGPoint(x: xc + t / 2, y: a + t / 2), CGPoint(x: xc + t / 2, y: b - t / 2),
                    CGPoint(x: xc, y: b), CGPoint(x: xc - t / 2, y: b - t / 2), CGPoint(x: xc - t / 2, y: a + t / 2)]
        }
        let top = h - t / 2, mid = h / 2, bottom = t / 2, left = t / 2, right = w - t / 2
        for s in segs {
            let pts: [CGPoint]
            switch s {
            case "a": pts = horizontal(top)
            case "b": pts = vertical(right, mid, top)
            case "c": pts = vertical(right, bottom, mid)
            case "d": pts = horizontal(bottom)
            case "e": pts = vertical(left, bottom, mid)
            case "f": pts = vertical(left, mid, top)
            default: pts = horizontal(mid)
            }
            // Lean the digit to the right, like the displays it imitates.
            p.addLines(between: pts.map { CGPoint(x: x + $0.x + $0.y * Self.slant, y: y0 + $0.y) })
            p.closeSubpath()
        }
        return p
    }

    private func colonPath(x: CGFloat) -> CGPath {
        let h = digitHeight, t = h * Self.thickRatio, cw = h * Self.colonRatio
        let y0 = ((bounds.height - h) / 2).rounded()
        let p = CGMutablePath()
        for fy in [0.3, 0.7] as [CGFloat] {
            let y = h * fy
            p.addRect(CGRect(x: x + (cw - t) / 2 + y * Self.slant, y: y0 + y - t / 2, width: t, height: t))
        }
        return p
    }
}

/// Scrolling title on the LCD.
final class MarqueeView: NSView {
    var text = "OmniAmp" { didSet { if text != oldValue { offset = 0; scrollStart = animationTime; needsDisplay = true } } }
    private var offset: CGFloat = 0
    private var scrollStart = animationTime
    private var attrs: [NSAttributedString.Key: Any] {
        let glow = NSShadow()
        glow.shadowColor = Theme.phosphor.withAlphaComponent(0.5)
        glow.shadowBlurRadius = 4
        return [.font: Fonts.hack(13), .foregroundColor: Theme.phosphor, .shadow: glow]
    }

    func tick() {
        let w = (text as NSString).size(withAttributes: attrs).width
        guard w > bounds.width - 8 else { if offset != 0 { offset = 0; needsDisplay = true }; return }
        // 12 points per second, whatever the frame rate.
        let o = CGFloat(Int((animationTime - scrollStart) * 12)).truncatingRemainder(dividingBy: w + 48)
        guard o != offset else { return }
        offset = o
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let s = text as NSString
        let a = attrs
        let size = s.size(withAttributes: a)
        let y = (bounds.height - size.height) / 2
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds.insetBy(dx: 2, dy: -4)).addClip()
        s.draw(at: NSPoint(x: 4 - offset, y: y), withAttributes: a)
        if size.width > bounds.width - 8 {
            s.draw(at: NSPoint(x: 4 - offset + size.width + 48, y: y), withAttributes: a)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Top panel for the modern look.
final class ModernPanelView: NSView {

    weak var controller: PlayerController?
    var onToggleEQ: (() -> Void)?
    var onToggleInfo: (() -> Void)?
    /// Cover clicked: show the playing track's info.
    var onArtClick: (() -> Void)?
    private(set) var eqButton: ModernButton!
    private(set) var infoButton: ModernButton!
    /// Album art of the playing track, framed inside the right LCD box.
    let art = ArtView()
    private let hoverCard = HoverCard()
    private var hoverWork: DispatchWorkItem?
    private var artPath: String?

    private let leftBox = LCDBox()
    private let rightBox = LCDBox()
    private let stateLabel = NSTextField(labelWithString: "")
    /// What is playing: local music, radio, podcast or a web file (blinks while a stream buffers).
    private let sourceLabel = NSTextField(labelWithString: "")
    /// "REM" while the counter shows remaining time; "LIVE" for radio, which has no length.
    private let remainTag = NSTextField(labelWithString: "REM")
    private var showRemaining = UserDefaults.standard.bool(forKey: "modernRemaining") {
        didSet { UserDefaults.standard.set(showRemaining, forKey: "modernRemaining") }
    }
    let time = LCDTimeView()
    let spectrum = SpectrumView()
    let marquee = MarqueeView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let volIcon = NSTextField(labelWithString: Fonts.Icon.volume)
    let seek = ModernSlider()
    let volume = ModernSlider()
    private var shuffleButton: ModernButton!
    private var repeatButton: ModernButton!
    private var topConstraint: NSLayoutConstraint!
    /// Extra space at the top for a transparent titlebar.
    var topInset: CGFloat = 0 { didSet { topConstraint.constant = 10 + topInset } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // The background is a gradient layer (no backing bitmap): top highlight line, gradient, black bottom line.
    override func makeBackingLayer() -> CALayer { CAGradientLayer() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { styleBackground() }
    private func styleBackground() {
        guard let g = layer as? CAGradientLayer, bounds.height > 2 else { return }
        let px = NSNumber(value: Double(1 / bounds.height))
        let top = Theme.panelTop.blended(withFraction: 0.08, of: .white) ?? Theme.panelTop
        g.colors = [top, top, Theme.panelTop, Theme.panelBottom, NSColor.black, NSColor.black].map(\.cgColor)
        g.locations = [0, px, px, NSNumber(value: 1 - px.doubleValue), NSNumber(value: 1 - px.doubleValue), 1]
        g.startPoint = CGPoint(x: 0.5, y: 1)
        g.endPoint = CGPoint(x: 0.5, y: 0)
    }

    private func build() {
        for v in [leftBox, rightBox, stateLabel, sourceLabel, remainTag, time, spectrum, marquee, infoLabel, volIcon] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(leftBox)
        addSubview(rightBox)
        [stateLabel, sourceLabel, remainTag, time, spectrum].forEach(leftBox.addSubview)
        sourceLabel.font = Theme.icon(10)
        sourceLabel.textColor = Theme.phosphor.withAlphaComponent(0.55)
        sourceLabel.alignment = .center
        remainTag.font = Fonts.hack(6.5, bold: true)
        remainTag.textColor = Theme.phosphor
        remainTag.isHidden = !showRemaining
        time.onClick = { [weak self] in
            guard let self, self.controller?.currentTrack?.isStream != true else { return }   // live radio has no length
            self.showRemaining.toggle()
            self.remainTag.isHidden = !self.showRemaining
            self.refresh(tick: 0)
        }
        time.toolTip = "Click: elapsed / remaining time"
        [art, marquee, infoLabel, volIcon, volume, badge].forEach(rightBox.addSubview)
        art.onHover = { [weak self] inside in self?.hover(inside) }
        art.onClick = { [weak self] in self?.hover(false); self?.onArtClick?() }
        art.toolTip = nil
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = Fonts.hack(9, bold: true)
        badge.alignment = .left
        badge.lineBreakMode = .byTruncatingTail
        infoLabel.lineBreakMode = .byTruncatingTail
        badge.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stateLabel.font = Theme.icon(10)
        stateLabel.textColor = Theme.phosphor
        infoLabel.font = Theme.mono(10)
        infoLabel.textColor = Theme.phosphorDim.blended(withFraction: 0.5, of: Theme.phosphor)
        volIcon.font = Theme.icon(11)
        volIcon.textColor = Theme.phosphorDim

        volume.knobWidth = 10
        volume.onChange = { [weak self] v in self?.controller?.setVolume(Float(v)) }
        seek.target = self
        seek.action = #selector(seekReleased)

        shuffleButton = ModernButton(glyph: Fonts.Icon.shuffle, label: "SHUF", target: self, action: #selector(shuffleTapped))
        repeatButton = ModernButton(glyph: Fonts.Icon.repeatAll, label: "REP", target: self, action: #selector(repeatTapped))
        shuffleButton.isToggle = true; repeatButton.isToggle = true
        shuffleButton.glyphSize = 10; repeatButton.glyphSize = 10
        rightBox.addSubview(shuffleButton)
        rightBox.addSubview(repeatButton)
        addSubview(seek)

        let transport = [
            ModernButton(glyph: Fonts.Icon.prev, target: self, action: #selector(prev)),
            ModernButton(glyph: Fonts.Icon.play, target: self, action: #selector(play)),
            ModernButton(glyph: Fonts.Icon.pause, target: self, action: #selector(pause)),
            ModernButton(glyph: Fonts.Icon.stop, target: self, action: #selector(stop)),
            ModernButton(glyph: Fonts.Icon.next, target: self, action: #selector(next)),
        ]
        let tips = ["Previous (Z)", "Play (X)", "Pause (C)", "Stop (V)", "Next (B)"]
        for (b, t) in zip(transport, tips) { b.toolTip = t }
        let eject = ModernButton(glyph: Fonts.Icon.eject, target: self, action: #selector(open))
        eject.toolTip = "Add files or folder (⌘O)"
        let buttons = NSStackView(views: transport)
        buttons.spacing = 3
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)
        addSubview(eject)
        eqButton = ModernButton(glyph: "", label: "EQ", target: self, action: #selector(eqTapped))
        eqButton.toolTip = "Equalizer"
        addSubview(eqButton)
        infoButton = ModernButton(glyph: "", label: "INFO", target: self, action: #selector(infoTapped))
        infoButton.toolTip = "Track and album info"
        addSubview(infoButton)

        topConstraint = leftBox.topAnchor.constraint(equalTo: topAnchor, constant: 10)
        NSLayoutConstraint.activate([
            topConstraint,
            leftBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leftBox.widthAnchor.constraint(lessThanOrEqualToConstant: 158),
            leftBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 118),
            leftBox.heightAnchor.constraint(equalToConstant: 88),

            stateLabel.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor, constant: 8),
            stateLabel.topAnchor.constraint(equalTo: leftBox.topAnchor, constant: 8),
            sourceLabel.centerXAnchor.constraint(equalTo: stateLabel.centerXAnchor),
            sourceLabel.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 3),
            remainTag.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor, constant: -7),
            remainTag.topAnchor.constraint(equalTo: leftBox.topAnchor, constant: 6),
            time.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor, constant: -6),
            time.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor, constant: 6),
            time.topAnchor.constraint(equalTo: leftBox.topAnchor, constant: 4),
            time.heightAnchor.constraint(equalToConstant: 36),
            spectrum.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor, constant: 6),
            spectrum.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor, constant: -6),
            spectrum.bottomAnchor.constraint(equalTo: leftBox.bottomAnchor, constant: -4),
            spectrum.heightAnchor.constraint(equalToConstant: 42),

            rightBox.leadingAnchor.constraint(equalTo: leftBox.trailingAnchor, constant: 8),
            rightBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rightBox.topAnchor.constraint(equalTo: leftBox.topAnchor),
            rightBox.heightAnchor.constraint(equalTo: leftBox.heightAnchor),

            art.leadingAnchor.constraint(equalTo: rightBox.leadingAnchor, constant: 6),
            art.topAnchor.constraint(equalTo: rightBox.topAnchor, constant: 6),
            art.bottomAnchor.constraint(equalTo: rightBox.bottomAnchor, constant: -6),
            art.widthAnchor.constraint(equalTo: art.heightAnchor),
            marquee.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 4),
            marquee.trailingAnchor.constraint(equalTo: rightBox.trailingAnchor, constant: -4),
            marquee.topAnchor.constraint(equalTo: rightBox.topAnchor, constant: 6),
            marquee.heightAnchor.constraint(equalToConstant: 22),

            infoLabel.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 8),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightBox.trailingAnchor, constant: -6),
            infoLabel.topAnchor.constraint(equalTo: marquee.bottomAnchor, constant: 2),
            badge.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 8),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: rightBox.trailingAnchor, constant: -6),
            badge.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 1),

            volIcon.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 8),
            volIcon.centerYAnchor.constraint(equalTo: repeatButton.centerYAnchor),
            volume.leadingAnchor.constraint(equalTo: volIcon.trailingAnchor, constant: 4),
            volume.centerYAnchor.constraint(equalTo: repeatButton.centerYAnchor),
            volume.widthAnchor.constraint(lessThanOrEqualToConstant: 84),
            volume.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            volume.heightAnchor.constraint(equalToConstant: 16),

            repeatButton.trailingAnchor.constraint(equalTo: rightBox.trailingAnchor, constant: -6),
            repeatButton.bottomAnchor.constraint(equalTo: rightBox.bottomAnchor, constant: -6),
            repeatButton.heightAnchor.constraint(equalToConstant: 20),
            shuffleButton.trailingAnchor.constraint(equalTo: repeatButton.leadingAnchor, constant: -4),
            shuffleButton.centerYAnchor.constraint(equalTo: repeatButton.centerYAnchor),
            shuffleButton.heightAnchor.constraint(equalToConstant: 20),
            shuffleButton.leadingAnchor.constraint(greaterThanOrEqualTo: volume.trailingAnchor, constant: 8),

            seek.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            seek.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            seek.topAnchor.constraint(equalTo: leftBox.bottomAnchor, constant: 8),
            seek.heightAnchor.constraint(equalToConstant: 16),

            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            buttons.topAnchor.constraint(equalTo: seek.bottomAnchor, constant: 8),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            eject.leadingAnchor.constraint(equalTo: buttons.trailingAnchor, constant: 10),
            eject.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            eqButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            eqButton.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            eqButton.widthAnchor.constraint(equalToConstant: 44),
            infoButton.trailingAnchor.constraint(equalTo: eqButton.leadingAnchor, constant: -4),
            infoButton.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            infoButton.widthAnchor.constraint(equalToConstant: 50),
        ])
    }

    // MARK: Display

    func refresh(tick: Int) {
        guard let c = controller else { return }
        let p = c.player
        let st = p.state
        let d = p.duration
        let track = c.currentTrack
        let live = track?.isStream == true
        let remaining = showRemaining && !live && d > 0 && st != .stopped
        let t = Int(st == .stopped ? 0 : max(0, remaining ? d - p.currentTime : p.currentTime))
        remainTag.stringValue = live ? "LIVE" : "REM"
        remainTag.isHidden = !(live || showRemaining)
        updateSource(track, buffering: st == .playing && p.isBuffering && track?.isRemote == true)
        time.text = String(format: "%02d:%02d", min(t / 60, 99), t % 60)
        time.dimmed = st == .paused && Int(animationTime * 2) % 2 == 0 // the colon blinks while paused
        stateLabel.stringValue = st == .playing ? Fonts.Icon.play : (st == .paused ? Fonts.Icon.pause : Fonts.Icon.stop)
        if !seek.isDragging { seek.value = d > 0 && st != .stopped ? p.currentTime / d : 0 }
        if Analyzer.mode == .oscilloscope {
            spectrum.update(wave: st == .playing ? p.spectrum.wave() : [])
        } else if Analyzer.mode == .meters {
            spectrum.update(levels: st == .playing ? p.spectrum.levels() : (0, 0))
        } else {
            spectrum.update(with: st == .playing && Analyzer.isOn ? p.spectrum.bars() : [Float](repeating: 0, count: SpectrumAnalyzer.barCount))
        }
        marquee.tick()
    }

    /// The source icon under play/pause; it blinks while a stream or episode is buffering.
    private func updateSource(_ t: Track?, buffering: Bool) {
        let glyph: String
        switch t {
        case nil: glyph = ""
        case let t? where t.isStream: glyph = Fonts.Icon.radio
        case let t? where t.isWebFile: glyph = Fonts.Icon.globe
        case let t? where t.isEpisode: glyph = Fonts.Icon.podcast
        default: glyph = Fonts.Icon.music
        }
        if sourceLabel.stringValue != glyph { sourceLabel.stringValue = glyph }
        sourceLabel.toolTip = t.map { $0.isStream ? "Internet radio" : ($0.isWebFile ? "Web audio file" : ($0.isEpisode ? "Podcast" : "Local file")) }
        let blinkOff = buffering && Int(animationTime * 3) % 2 == 1
        if sourceLabel.isHidden != blinkOff { sourceLabel.isHidden = blinkOff }
    }

    /// Narrow windows (< 520 pt): smaller time, format on two lines, icon-only toggles.
    private(set) var compact = false
    private var leftWidth: NSLayoutConstraint?

    override func layout() {
        if leftWidth == nil {
            // Left display takes ~30% of the width between 118 and 158 pt.
            let c = leftBox.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.3)
            // Must stay below the window's resize priority (500), or this 30% rule would stop the window
            // growing once the display hits its 158 pt cap.
            c.priority = NSLayoutConstraint.Priority(450)
            c.isActive = true
            leftWidth = c
        }
        super.layout()
        styleBackground()
        let narrow = bounds.width < 520
        if narrow != compact {
            compact = narrow
            shuffleButton.compact = narrow
            repeatButton.compact = narrow
            updateInfoLines()
        }
        time.digitHeight = leftBox.frame.width >= 150 ? 29 : 23
    }

    /// Format line(s) and the bit-perfect badge. Compact: line 2 of the format replaces the badge row.
    private func updateInfoLines() {
        guard let c = controller else { return }
        let lines = c.currentIndex.map { c.formatLines(for: $0) } ?? ("", "")
        let b = c.outputBadge
        let amber = Theme.warning
        badge.toolTip = b.map { $0.ok ? "\($0.text): samples reach \(c.player.deviceName) unchanged." : "\($0.text): \(c.player.deviceName) does not support this sample rate; macOS resamples." }
        if compact {
            infoLabel.stringValue = lines.0
            badge.font = Fonts.hack(10)
            badge.stringValue = (b.map { $0.ok ? "\u{25C6} " : "\u{25B2} " } ?? "") + lines.1
            badge.textColor = b.map { $0.ok ? Theme.phosphor : amber } ?? infoLabel.textColor
        } else {
            infoLabel.stringValue = [lines.0, lines.1].filter { !$0.isEmpty }.joined(separator: " · ")
            badge.font = Fonts.hack(9, bold: true)
            badge.stringValue = b.map { ($0.ok ? "\u{25C6} " : "\u{25B2} ") + $0.text } ?? ""
            badge.textColor = b.map { $0.ok ? Theme.phosphor : amber } ?? Theme.phosphor
        }
    }

    func refreshTrackInfo() {
        guard let c = controller else { return }
        if let i = c.currentIndex, i < c.tracks.count {
            marquee.text = c.title(for: i)
            updateInfoLines()
            let path = c.tracks[i].path
            if path != artPath {
                artPath = path
                let t = c.tracks[i]
                if t.isRemote {
                    // Radio / podcasts: the station logo or show artwork takes the cover's place.
                    art.image = LogoStore.shared.cached(t.logo)
                    LogoStore.shared.load(t.logo) { [weak self] img in
                        guard let self, self.artPath == path else { return }
                        self.art.image = img
                    }
                } else {
                    art.image = ArtworkStore.shared.cached(path)?.thumb
                    ArtworkStore.shared.load(path) { [weak self] e in
                        guard let self, self.artPath == path else { return }
                        self.art.image = e.thumb
                    }
                }
            }
        } else {
            marquee.text = "OmniAmp · drop a folder to start"
            updateInfoLines()
            artPath = nil
            art.image = nil
        }
    }

    func refreshOptions() {
        guard let c = controller else { return }
        shuffleButton.isOn = c.shuffle
        repeatButton.isOn = c.repeatAll
        if !volume.isDragging { volume.value = Double(c.player.volume) }
        volume.alphaValue = c.player.volumeAdjustable ? 1 : 0.35
        volume.isEnabled = c.player.volumeAdjustable
        volume.toolTip = c.player.bitPerfect ? (c.player.volumeAdjustable ? "Device volume (bit-perfect mode)" : "Fixed at 100% in bit-perfect mode") : nil
        updateInfoLines()
    }

    // MARK: Actions

    @objc private func prev() { controller?.previous() }
    @objc private func play() { controller?.playOrResume() }
    @objc private func pause() { controller?.pause() }
    @objc private func stop() { controller?.stop() }
    @objc private func next() { controller?.next() }
    @objc private func open() { controller?.showOpenPanel(for: window) }
    @objc private func shuffleTapped() { controller?.toggleShuffle() }
    @objc private func repeatTapped() { controller?.toggleRepeat() }
    @objc private func eqTapped() { onToggleEQ?() }
    @objc private func infoTapped() { onToggleInfo?() }

    /// Hover the art for a big version (after a short delay, so passing the mouse over it doesn't flash).
    private func hover(_ inside: Bool) {
        hoverWork?.cancel()
        guard inside else { hoverCard.hide(); return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, let c = self.controller, let i = c.currentIndex, i < c.tracks.count, let win = self.window else { return }
            let t = c.tracks[i]
            let e = ArtworkStore.shared.cached(t.path)
            let d = e?.details
            var lines = [d?.album ?? t.album, [d?.albumArtist ?? d?.artist ?? t.artist, d?.year].compactMap { $0 }.joined(separator: " · ")]
                .compactMap { $0 }.filter { !$0.isEmpty }
            if lines.isEmpty { lines = [t.displayTitle] }
            let anchor = win.convertToScreen(self.art.convert(self.art.bounds, to: nil))
            self.hoverCard.show(path: t.path, thumb: e?.thumb, lines: lines.joined(separator: "\n"), near: anchor)
        }
        hoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }
    @objc private func seekReleased() { controller?.seek(fraction: seek.value) }
}
