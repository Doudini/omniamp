import AppKit

/// Album art framed like part of the LCD: dark bezel, slight glass sheen, dim note glyph when there's no art.
final class ArtView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var cornerRadius: CGFloat = 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard onHover != nil else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let img = image, let ctx = NSGraphicsContext.current?.cgContext {
            // Aspect-fill.
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let s = max(bounds.width / iw, bounds.height / ih)
            let w = iw * s, h = ih * s
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h))
            // Glass sheen so it sits "inside" the LCD.
            NSGradient(starting: NSColor.white.withAlphaComponent(0.10), ending: .clear)?
                .draw(in: NSRect(x: 0, y: bounds.height * 0.5, width: bounds.width, height: bounds.height * 0.5), angle: -90)
        } else {
            Theme.lcd.setFill(); bounds.fill()
            let glyph = Fonts.Icon.music as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.icon(bounds.height * 0.4), .foregroundColor: Theme.phosphorDim.withAlphaComponent(0.6)]
            let sz = glyph.size(withAttributes: attrs)
            glyph.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.setStroke(); path.lineWidth = 1; path.stroke()
        Theme.panelEdge.withAlphaComponent(0.35).setStroke()
        NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: max(0, cornerRadius - 1), yRadius: max(0, cornerRadius - 1)).stroke()
    }
}

/// Floating card with big art + a few lines, shown while hovering the panel art.
final class HoverCard {
    private let panel: NSPanel
    private let art = ArtView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private var path: String?
    static let artSize: CGFloat = 260

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.artSize + 24, height: Self.artSize + 70),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.black.cgColor
        panel.contentView = bg
        art.cornerRadius = 5
        text.font = Fonts.hack(11)
        text.textColor = Theme.phosphor
        text.maximumNumberOfLines = 3
        text.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(art)
        bg.addSubview(text)
        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: bg.topAnchor, constant: 12),
            art.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            art.widthAnchor.constraint(equalToConstant: Self.artSize),
            art.heightAnchor.constraint(equalToConstant: Self.artSize),
            text.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 8),
            text.leadingAnchor.constraint(equalTo: art.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: art.trailingAnchor),
        ])
    }

    /// Show next to `anchor` (screen rect of the thumbnail). The small thumbnail shows at once; the sharp
    /// large rendering replaces it when ready.
    func show(path: String, thumb: CGImage?, lines: String, near anchor: NSRect) {
        self.path = path
        art.image = thumb
        text.stringValue = lines
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
        if origin.y < screen.minY { origin.y = anchor.maxY + 6 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        guard thumb != nil else { return }
        ArtworkStore.shared.largeImage(path, maxPixels: Int(Self.artSize * 2)) { [weak self] img in
            guard let self, self.path == path, let img else { return }
            self.art.image = img
        }
    }

    func hide() {
        path = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) { [weak self] in
            guard let self, self.path == nil else { return }
            self.panel.orderOut(nil)
            self.art.image = nil   // drop the large bitmap
        }
    }
}

/// INFO drawer: big art + all metadata for the playing track (or the one selected in the playlist).
final class ModernInfoView: NSView {
    weak var controller: PlayerController?
    var onReveal: ((String) -> Void)?

    private let art = ArtView()
    private let modeLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let title = NSTextField(labelWithString: "")
    private let byline = NSTextField(labelWithString: "")       // artist
    private let albumTitle = NSTextField(labelWithString: "")   // album (year)
    private let numbers = NSTextField(labelWithString: "")
    private let credits = NSTextField(labelWithString: "")
    private let format = NSTextField(labelWithString: "")
    private let file = NSTextField(labelWithString: "")
    private let albumLine = NSTextField(labelWithString: "")
    private let comment = NSTextField(labelWithString: "")
    private var revealButton: ModernButton!
    private var shownPath: String?
    /// Full: the cover fills the drawer height. Compact (narrow windows): a smaller cover, so text gets room.
    private var fullArt: [NSLayoutConstraint] = []
    private var compactArt: [NSLayoutConstraint] = []
    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            NSLayoutConstraint.deactivate(compact ? fullArt : compactArt)
            NSLayoutConstraint.activate(compact ? compactArt : fullArt)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        Theme.lcd.setFill(); p.fill()
        NSGradient(starting: NSColor.white.withAlphaComponent(0.03), ending: .clear)?
            .draw(in: NSRect(x: 0, y: bounds.height * 0.6, width: bounds.width, height: bounds.height * 0.4), angle: -90)
        NSColor.black.setStroke(); p.stroke()
    }

    private func style(_ l: NSTextField, _ size: CGFloat, bold: Bool = false, color: NSColor, truncate: NSLineBreakMode = .byTruncatingTail) {
        l.font = Fonts.hack(size, bold: bold)
        l.textColor = color
        l.lineBreakMode = truncate
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func build() {
        let dim = Theme.phosphorDim.blended(withFraction: 0.35, of: Theme.phosphor)!
        style(title, 14, bold: true, color: NSColor(calibratedWhite: 0.95, alpha: 1))
        style(byline, 12, color: Theme.phosphor)
        style(albumTitle, 11.5, color: Theme.phosphor.blended(withFraction: 0.25, of: Theme.phosphorDim)!)
        style(numbers, 10.5, color: dim)
        style(credits, 10.5, color: dim)
        style(format, 10.5, color: Theme.phosphor)
        style(file, 10, color: dim, truncate: .byTruncatingMiddle)
        style(albumLine, 10, color: dim)
        style(comment, 10, color: dim)
        style(modeLabel, 8.5, bold: true, color: Theme.phosphorDim)
        modeLabel.alignment = .right

        let rule = NSBox()
        rule.boxType = .custom
        rule.fillColor = Theme.phosphorDim.withAlphaComponent(0.35)
        rule.borderWidth = 0
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        revealButton = ModernButton(glyph: Fonts.Icon.search, label: "REVEAL", target: self, action: #selector(reveal))
        revealButton.glyphSize = 9
        let fileRow = NSStackView(views: [file, revealButton])
        fileRow.spacing = 8
        revealButton.heightAnchor.constraint(equalToConstant: 18).isActive = true

        for v in [title, byline, albumTitle, numbers, credits, rule, format, fileRow, albumLine, comment] as [NSView] { stack.addArrangedSubview(v) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(8, after: credits)
        stack.setCustomSpacing(8, after: rule)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(art)
        addSubview(stack)
        addSubview(modeLabel)
        art.cornerRadius = 4

        fullArt = [art.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)]
        compactArt = [art.widthAnchor.constraint(equalToConstant: 88)]
        NSLayoutConstraint.activate(fullArt)
        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            art.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            art.widthAnchor.constraint(equalTo: art.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            rule.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fileRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            modeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            modeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: modeLabel.leadingAnchor, constant: -8),
        ])
        for l in [title, byline, albumTitle, numbers, credits, format, albumLine, comment] {
            l.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
    }

    /// Show a track (index into the playlist). `pinned` = chosen in the playlist rather than now playing.
    func show(index: Int?, pinned: Bool) {
        guard let c = controller, let i = index, i < c.tracks.count else {
            shownPath = nil
            art.image = nil
            title.stringValue = "Nothing playing"
            modeLabel.stringValue = ""
            for l in [byline, albumTitle, numbers, credits, format, albumLine, comment] { l.isHidden = true }
            file.stringValue = ""
            revealButton.isHidden = true
            return
        }
        let t = c.tracks[i]
        shownPath = t.path
        modeLabel.stringValue = pinned ? "SELECTED" : (i == c.currentIndex ? "NOW PLAYING" : "")
        revealButton.isHidden = false
        // Basics from the playlist right away; full tags + art fill in when loaded.
        apply(index: i, details: nil, thumb: nil, artPixels: nil)
        ArtworkStore.shared.load(t.path) { [weak self] e in
            guard let self, self.shownPath == t.path else { return }
            self.apply(index: i, details: e.details, thumb: e.thumb, artPixels: e.artPixels)
        }
    }

    private func apply(index i: Int, details d: TrackDetails?, thumb: CGImage?, artPixels: CGSize?) {
        guard let c = controller, i < c.tracks.count else { return }
        let t = c.tracks[i]
        art.image = thumb
        // CUE tracks: the sheet knows the track; the file's own tags describe the whole album file.
        let cue = t.cueStart != nil
        title.stringValue = (cue ? t.title : nil) ?? d?.title ?? t.title ?? t.fileStem
        let artist = cue ? (t.artist ?? d?.artist) : (d?.artist ?? t.artist)
        let album = cue ? (t.album ?? d?.album) : (d?.album ?? t.album)
        // Artist and album on their own lines, so a long album name can't push the artist out of view.
        byline.stringValue = artist ?? ""
        byline.isHidden = byline.stringValue.isEmpty
        var al = album ?? ""
        if let y = d?.year { al += al.isEmpty ? y : " (\(y))" }
        albumTitle.stringValue = al
        albumTitle.isHidden = al.isEmpty
        byline.toolTip = artist
        albumTitle.toolTip = al.isEmpty ? nil : al

        var nums: [String] = []
        if cue, let n = t.cueNumber { nums.append("Track \(n) (CUE)") }
        else if let n = d?.track { nums.append("Track \(n)" + (d?.trackTotal.map { " / \($0)" } ?? "")) }
        if let n = d?.disc, (d?.discTotal ?? 2) > 1 { nums.append("Disc \(n)" + (d?.discTotal.map { " / \($0)" } ?? "")) }
        if let g = d?.genre { nums.append(g) }
        nums.append(TimeFormat.mmss(t.duration))
        numbers.stringValue = nums.filter { !$0.isEmpty }.joined(separator: " · ")
        numbers.isHidden = numbers.stringValue.isEmpty

        var cred: [String] = []
        if let aa = d?.albumArtist, aa != artist { cred.append("Album artist: \(aa)") }
        if let comp = d?.composer { cred.append("Composer: \(comp)") }
        credits.stringValue = cred.joined(separator: " · ")
        credits.isHidden = cred.isEmpty

        format.stringValue = c.formatDescription(for: i)
        format.isHidden = format.stringValue.isEmpty
        let mb = Double(t.size) / 1_048_576
        file.stringValue = String(format: "%.1f MB · ", mb) + (t.path as NSString).abbreviatingWithTildeInPath
        file.toolTip = t.path

        var albumBits: [String] = []
        if let s = c.albumSummary(for: i), s.count > 1 { albumBits.append("Album in playlist: \(s.count) tracks · \(TimeFormat.mmss(s.duration))") }
        if let px = artPixels {
            albumBits.append("Cover \(Int(px.width))×\(Int(px.height))" + (d?.artworkSource.map { $0 == "embedded" ? " (embedded)" : " (\($0))" } ?? ""))
        }
        albumLine.stringValue = albumBits.joined(separator: " · ")
        albumLine.isHidden = albumBits.isEmpty

        let cm = d?.comment?.replacingOccurrences(of: "\n", with: " ")
        comment.stringValue = cm.map { "“\($0)”" } ?? ""
        comment.toolTip = d?.comment
        comment.isHidden = cm?.isEmpty ?? true
    }

    @objc private func reveal() {
        if let p = shownPath { onReveal?(p) }
    }
}
