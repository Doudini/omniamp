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

/// Big glowing time readout with faint "88:88" ghost segments behind it.
final class LCDTimeView: NSView {
    var text = "00:00" { didSet { if text != oldValue { needsDisplay = true } } }
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    var font = Fonts.hack(30, bold: true)

    override func draw(_ dirtyRect: NSRect) {
        let ghost = String(text.map { $0 == ":" ? ":" : "8" }) as NSString
        let ghostAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.ghostGreen]
        let size = ghost.size(withAttributes: ghostAttrs)
        let origin = NSPoint(x: bounds.width - size.width, y: (bounds.height - size.height) / 2)
        ghost.draw(at: origin, withAttributes: ghostAttrs)
        guard !dimmed else { return }
        let glow = NSShadow()
        glow.shadowColor = Theme.green.withAlphaComponent(0.7)
        glow.shadowBlurRadius = 8
        (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: Theme.green, .shadow: glow])
    }
}

/// Scrolling title on the LCD.
final class MarqueeView: NSView {
    var text = "OmniAmp" { didSet { if text != oldValue { offset = 0; scrollStart = animationTime; needsDisplay = true } } }
    private var offset: CGFloat = 0
    private var scrollStart = animationTime
    private var attrs: [NSAttributedString.Key: Any] {
        let glow = NSShadow()
        glow.shadowColor = Theme.green.withAlphaComponent(0.5)
        glow.shadowBlurRadius = 4
        return [.font: Fonts.hack(13), .foregroundColor: Theme.green, .shadow: glow]
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
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: Theme.panelTop, ending: Theme.panelBottom)?.draw(in: bounds, angle: -90)
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    private func build() {
        for v in [leftBox, rightBox, stateLabel, time, spectrum, marquee, infoLabel, volIcon] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(leftBox)
        addSubview(rightBox)
        [stateLabel, time, spectrum].forEach(leftBox.addSubview)
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
        stateLabel.textColor = Theme.green
        infoLabel.font = Theme.mono(10)
        infoLabel.textColor = Theme.dimGreen.blended(withFraction: 0.5, of: Theme.green)
        volIcon.font = Theme.icon(11)
        volIcon.textColor = Theme.dimGreen

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
            time.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor, constant: -8),
            time.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor, constant: 22),
            time.topAnchor.constraint(equalTo: leftBox.topAnchor, constant: 2),
            time.heightAnchor.constraint(equalToConstant: 40),
            spectrum.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor, constant: 6),
            spectrum.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor, constant: -6),
            spectrum.bottomAnchor.constraint(equalTo: leftBox.bottomAnchor, constant: -6),
            spectrum.heightAnchor.constraint(equalToConstant: 36),

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
        let t = Int(st == .stopped ? 0 : max(0, p.currentTime))
        time.text = String(format: "%02d:%02d", min(t / 60, 99), t % 60)
        time.dimmed = st == .paused && Int(animationTime * 2) % 2 == 0 // blink while paused
        stateLabel.stringValue = st == .playing ? Fonts.Icon.play : (st == .paused ? Fonts.Icon.pause : Fonts.Icon.stop)
        let d = p.duration
        if !seek.isDragging { seek.value = d > 0 && st != .stopped ? p.currentTime / d : 0 }
        spectrum.update(with: st == .playing && Analyzer.isOn ? p.spectrum.bars() : [Float](repeating: 0, count: SpectrumAnalyzer.barCount))
        marquee.tick()
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
        let narrow = bounds.width < 520
        if narrow != compact {
            compact = narrow
            shuffleButton.compact = narrow
            repeatButton.compact = narrow
            updateInfoLines()
        }
        let size: CGFloat = leftBox.frame.width >= 150 ? 30 : 24
        if time.font.pointSize != size { time.font = Fonts.hack(size, bold: true); time.needsDisplay = true }
    }

    /// Format line(s) and the bit-perfect badge. Compact: line 2 of the format replaces the badge row.
    private func updateInfoLines() {
        guard let c = controller else { return }
        let lines = c.currentIndex.map { c.formatLines(for: $0) } ?? ("", "")
        let b = c.outputBadge
        let amber = NSColor(calibratedRed: 1, green: 0.7, blue: 0.2, alpha: 1)
        badge.toolTip = b.map { $0.ok ? "\($0.text): samples reach \(c.player.deviceName) unchanged." : "\($0.text): \(c.player.deviceName) does not support this sample rate; macOS resamples." }
        if compact {
            infoLabel.stringValue = lines.0
            badge.font = Fonts.hack(10)
            badge.stringValue = (b.map { $0.ok ? "\u{25C6} " : "\u{25B2} " } ?? "") + lines.1
            badge.textColor = b.map { $0.ok ? Theme.green : amber } ?? infoLabel.textColor
        } else {
            infoLabel.stringValue = [lines.0, lines.1].filter { !$0.isEmpty }.joined(separator: " · ")
            badge.font = Fonts.hack(9, bold: true)
            badge.stringValue = b.map { ($0.ok ? "\u{25C6} " : "\u{25B2} ") + $0.text } ?? ""
            badge.textColor = b.map { $0.ok ? Theme.green : amber } ?? Theme.green
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
                art.image = ArtworkStore.shared.cached(path)?.thumb
                ArtworkStore.shared.load(path) { [weak self] e in
                    guard let self, self.artPath == path else { return }
                    self.art.image = e.thumb
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
