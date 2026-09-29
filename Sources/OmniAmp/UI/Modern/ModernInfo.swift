import AppKit

/// Album art framed like part of the LCD: dark bezel, slight glass sheen, and a dim icon when there's no art
/// (a note for music, a radio for stations, …).
final class ArtView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var placeholder = Fonts.Icon.music { didSet { if placeholder != oldValue { needsDisplay = true } } }

    /// The placeholder for a track: what kind of thing is playing.
    static func placeholder(for t: Track?) -> String {
        guard let t else { return Fonts.Icon.music }
        if t.isStream { return Fonts.Icon.radio }
        if t.isWebFile { return Fonts.Icon.globe }
        if t.isEpisode { return Fonts.Icon.podcast }
        return Fonts.Icon.music
    }
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var cornerRadius: CGFloat = 3
    /// The placeholder's colors (the library's cards); nil: the LCD look.
    var surface: NSColor? { didSet { needsDisplay = true } }
    var iconColor: NSColor? { didSet { needsDisplay = true } }

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
            (surface ?? Theme.lcd).setFill(); bounds.fill()
            // Centered on the glyph's drawn shape (its text box has uneven spacing around icon glyphs).
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.icon(bounds.height * 0.4), .foregroundColor: iconColor ?? Theme.phosphorDim.withAlphaComponent(0.6)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: placeholder, attributes: attrs))
            if let ctx = NSGraphicsContext.current?.cgContext {
                let ink = CTLineGetImageBounds(line, ctx)
                ctx.textPosition = CGPoint(x: (bounds.midX - ink.midX).rounded(), y: (bounds.midY - ink.midY).rounded())
                CTLineDraw(line, ctx)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if surface != nil {
            // On a card: a hairline, no bezel.
            Dash.border.setStroke(); path.lineWidth = 1; path.stroke()
            return
        }
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
    /// `logo`: a station or podcast image (web) instead of a file's embedded cover.
    func show(path: String, thumb: CGImage?, lines: String, near anchor: NSRect, logo: String? = nil,
              placeholder: String = Fonts.Icon.music) {
        self.path = path
        art.placeholder = placeholder
        art.image = logo.map { LogoStore.shared.cached($0) } ?? thumb
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
        if let logo {
            if art.image == nil {
                LogoStore.shared.load(logo) { [weak self] img in
                    guard let self, self.path == path else { return }
                    self.art.image = img
                }
            }
            return
        }
        guard thumb != nil else { return }
        ArtworkStore.shared.largeImage(path, maxPixels: Int(Self.artSize * 2)) { [weak self] img in
            guard let self, self.path == path, let img else { return }
            self.art.image = img
        }
    }

    deinit { panel.orderOut(nil) }

    func hide() {
        path = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) { [weak self] in
            guard let self, self.path == nil else { return }
            self.panel.orderOut(nil)
            self.art.image = nil   // drop the large bitmap
        }
    }
}

/// INFO drawer: art + all metadata for the playing track (or the one selected in the playlist), or an
/// ON AIR view for radio. The drawer keeps the height the user gave it; text that doesn't fit scrolls
/// (the cover stays put).
final class ModernInfoView: NSView {

    weak var controller: PlayerController?
    var onReveal: ((String) -> Void)?
    /// Content changed (text or cover arrived).
    var onContentChange: (() -> Void)?

    private let art = ArtView()
    /// The text column scrolls inside the drawer.
    private let textScroll = NSScrollView()
    private let textDoc = FlippedView()
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
    private let modeLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let title = NSTextField(labelWithString: "")
    private let byline = NSTextField(labelWithString: "")       // artist (radio: current artist)
    private let albumTitle = NSTextField(labelWithString: "")   // album (year) (radio: current song)
    private let numbers = NSTextField(labelWithString: "")
    private let credits = NSTextField(labelWithString: "")
    private let format = NSTextField(labelWithString: "")
    private let file = NSTextField(labelWithString: "")
    private let albumLine = NSTextField(labelWithString: "")
    /// Notes (podcasts) or the comment tag (music): laid out for reading, links clickable.
    private let comment = NotesTextView()
    private var commentColor: NSColor { Theme.phosphorDim.blended(withFraction: 0.35, of: Theme.phosphor)! }
    private let rule = NSBox()
    private var revealButton: ModernButton!
    private var shownPath: String?
    private var shownLogo: String?
    private var artSize: NSLayoutConstraint!
    static let artFull: CGFloat = 120
    static let artCompact: CGFloat = 84

    /// Narrow windows: smaller cover, so text gets room.
    var compact = false {
        didSet { if compact != oldValue { artSize.constant = compact ? Self.artCompact : Self.artFull; onContentChange?() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // The LCD background is a gradient layer (no backing bitmap): faint sheen at the top, black edge.
    override func makeBackingLayer() -> CALayer { CAGradientLayer() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { styleBackground() }
    private func styleBackground() {
        guard let g = layer as? CAGradientLayer else { return }
        let sheen = Theme.lcd.blended(withFraction: 0.03, of: .white) ?? Theme.lcd
        g.colors = [sheen, Theme.lcd, Theme.lcd].map(\.cgColor)
        g.locations = [0, 0.4, 1]
        g.startPoint = CGPoint(x: 0.5, y: 1)
        g.endPoint = CGPoint(x: 0.5, y: 0)
        g.cornerRadius = 4
        g.masksToBounds = true
        g.borderWidth = 1
        g.borderColor = Theme.lcdEdge.cgColor
    }

    /// Wrapping label: up to `lines` lines, the last one truncated if the text is longer still.
    private func style(_ l: NSTextField, _ size: CGFloat, bold: Bool = false, color: NSColor, lines: Int = 2) {
        l.font = Fonts.hack(size, bold: bold)
        l.textColor = color
        l.maximumNumberOfLines = lines
        l.lineBreakMode = lines == 1 ? .byTruncatingMiddle : .byWordWrapping
        l.cell?.truncatesLastVisibleLine = true
        l.cell?.wraps = lines != 1
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        l.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private var labels: [NSTextField] { [title, byline, albumTitle, numbers, credits, format, file, albumLine] }

    private func build() {
        let dim = Theme.phosphorDim.blended(withFraction: 0.35, of: Theme.phosphor)!
        style(title, 14, bold: true, color: NSColor(calibratedWhite: 0.95, alpha: 1))
        style(byline, 12, color: Theme.phosphor)
        style(albumTitle, 11.5, color: Theme.phosphor.blended(withFraction: 0.25, of: Theme.phosphorDim)!)
        style(numbers, 10.5, color: dim)
        style(credits, 10.5, color: dim)
        style(format, 10.5, color: Theme.phosphor)
        style(file, 10, color: dim, lines: 1)
        style(albumLine, 10, color: dim)
        modeLabel.font = Fonts.hack(8.5, bold: true)
        modeLabel.textColor = Theme.phosphorDim
        modeLabel.alignment = .right

        rule.boxType = .custom
        rule.fillColor = Theme.phosphorDim.withAlphaComponent(0.35)
        rule.borderWidth = 0
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        revealButton = ModernButton(glyph: Fonts.Icon.search, label: "REVEAL", target: self, action: #selector(reveal))
        revealButton.glyphSize = 9
        revealButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
        revealButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let fileRow = NSStackView(views: [file, revealButton])
        fileRow.spacing = 8

        for v in [title, byline, albumTitle, numbers, credits, rule, format, fileRow, albumLine, comment] as [NSView] { stack.addArrangedSubview(v) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(8, after: credits)
        stack.setCustomSpacing(8, after: rule)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.scrollerStyle = .overlay
        textScroll.borderType = .noBorder
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textDoc.translatesAutoresizingMaskIntoConstraints = false
        textScroll.documentView = textDoc
        textDoc.addSubview(stack)
        addSubview(art)
        addSubview(textScroll)
        addSubview(modeLabel)
        art.cornerRadius = 4

        artSize = art.widthAnchor.constraint(equalToConstant: Self.artFull)
        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            art.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            artSize,
            art.heightAnchor.constraint(equalTo: art.widthAnchor),
            textScroll.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 12),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            textScroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            textScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            textDoc.topAnchor.constraint(equalTo: textScroll.contentView.topAnchor),
            textDoc.leadingAnchor.constraint(equalTo: textScroll.contentView.leadingAnchor),
            textDoc.widthAnchor.constraint(equalTo: textScroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: textDoc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: textDoc.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: textDoc.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: textDoc.bottomAnchor, constant: -4),
            fileRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rule.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            modeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])
        for l in labels where l !== file && l !== title { l.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        comment.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        // The title wraps before it reaches the NOW PLAYING / ON AIR tag.
        let titleWidth = title.widthAnchor.constraint(equalTo: stack.widthAnchor)
        titleWidth.priority = .defaultHigh
        titleWidth.isActive = true
        title.trailingAnchor.constraint(lessThanOrEqualTo: modeLabel.leadingAnchor, constant: -8).isActive = true
    }

    private func setWrapWidths(_ width: CGFloat) {
        let textWidth = max(80, width - 8 - artSize.constant - 12 - 4 - 6)
        for l in labels { l.preferredMaxLayoutWidth = textWidth }
        title.preferredMaxLayoutWidth = max(60, textWidth - (modeLabel.stringValue.isEmpty ? 0 : modeLabel.intrinsicContentSize.width + 8))
    }

    override func layout() {
        setWrapWidths(bounds.width)
        super.layout()
        styleBackground()
    }

    /// Show a track (index into the playlist). `pinned` = chosen in the playlist rather than now playing.
    func show(index: Int?, pinned: Bool) {
        guard let c = controller, let i = index, i < c.tracks.count else {
            shownPath = nil
            art.image = nil
            title.stringValue = "Nothing playing"
            modeLabel.stringValue = ""
            for l in [byline, albumTitle, numbers, credits, format, albumLine, comment] { l.isHidden = true }
            rule.isHidden = true
            file.stringValue = ""
            revealButton.isHidden = true
            onContentChange?()
            return
        }
        let t = c.tracks[i]
        let pathChanged = shownPath != t.path
        if pathChanged { textScroll.contentView.scroll(to: .zero); textScroll.reflectScrolledClipView(textScroll.contentView) }   // a new track: from the top
        art.placeholder = ArtView.placeholder(for: t)
        shownPath = t.path
        modeLabel.stringValue = pinned ? "SELECTED" : (i == c.currentIndex ? (t.isStream ? "● ON AIR" : "NOW PLAYING") : "")
        revealButton.isHidden = t.isRemote
        rule.isHidden = false
        if t.isRemote {
            if t.isStream { applyRadio(index: i) } else { applyEpisode(index: i) }
            if pathChanged || art.image == nil || shownLogo != t.logo {
                shownLogo = t.logo
                art.image = LogoStore.shared.cached(t.logo)
                LogoStore.shared.load(t.logo) { [weak self] img in
                    guard let self, self.shownPath == t.path else { return }
                    self.art.image = img
                }
            }
            onContentChange?()
            return
        }
        // Basics from the playlist right away; full tags + art fill in when loaded.
        apply(index: i, details: ArtworkStore.shared.cached(t.path)?.details, thumb: ArtworkStore.shared.cached(t.path)?.thumb,
              artPixels: ArtworkStore.shared.cached(t.path)?.artPixels)
        let id = c.store.id(at: i)   // the list may be reordered before the tags arrive
        ArtworkStore.shared.load(t.path) { [weak self] e in
            guard let self, self.shownPath == t.path, let j = self.controller?.store.index(ofID: id) else { return }
            self.apply(index: j, details: e.details, thumb: e.thumb, artPixels: e.artPixels)
            self.onContentChange?()
        }
        onContentChange?()
    }

    /// Radio: station, the song on air (artist / title), LIVE + genre/country, format, stream URL.
    private func applyRadio(index i: Int) {
        guard let c = controller else { return }
        let t = c.tracks[i]
        let playing = i == c.currentIndex && c.player.isStreaming
        title.stringValue = t.title ?? c.player.streamInfo?.name ?? "Internet radio"
        let song = playing ? c.player.streamTitle : nil
        if let s = song, let r = s.range(of: " - ") {
            byline.stringValue = String(s[..<r.lowerBound])
            albumTitle.stringValue = String(s[r.upperBound...])
        } else {
            byline.stringValue = song ?? (playing ? (c.player.isBuffering ? "Buffering…" : "") : "")
            albumTitle.stringValue = ""
        }
        byline.isHidden = byline.stringValue.isEmpty
        albumTitle.isHidden = albumTitle.stringValue.isEmpty
        byline.toolTip = song
        albumTitle.toolTip = song
        numbers.stringValue = (["LIVE", t.stationTags].compactMap { $0 }).joined(separator: " · ")
        numbers.isHidden = false
        credits.isHidden = true
        if let err = c.player.streamError, i == c.currentIndex, !playing {
            format.stringValue = "Couldn't connect: \(err)"
        } else {
            format.stringValue = c.formatDescription(for: i)
        }
        format.isHidden = format.stringValue.isEmpty
        file.stringValue = t.path
        file.toolTip = t.path
        albumLine.isHidden = true
        comment.isHidden = true
    }

    /// Podcast episode: title, show, release date, length, format, show notes.
    private func applyEpisode(index i: Int) {
        guard let c = controller else { return }
        let t = c.tracks[i]
        title.stringValue = t.title ?? "Episode"
        byline.stringValue = t.podcast ?? ""
        byline.isHidden = byline.stringValue.isEmpty
        byline.toolTip = nil
        albumTitle.stringValue = t.published.map { Date(timeIntervalSince1970: $0).formatted(date: .long, time: .omitted) } ?? ""
        albumTitle.isHidden = albumTitle.stringValue.isEmpty
        albumTitle.toolTip = nil
        let played = PodcastLibrary.shared.isPlayed(t.path) ? "played" : ""
        numbers.stringValue = [t.isWebFile ? "WEB" : "PODCAST", TimeFormat.mmss(t.duration), played].filter { !$0.isEmpty }.joined(separator: " · ")
        numbers.isHidden = false
        credits.isHidden = true
        if let err = c.player.streamError, i == c.currentIndex, c.player.state == .stopped {
            format.stringValue = "Couldn't load: \(err)"
        } else {
            format.stringValue = c.formatDescription(for: i)
        }
        format.isHidden = format.stringValue.isEmpty
        file.stringValue = t.path
        file.toolTip = t.path
        albumLine.isHidden = true
        // The whole notes (the drawer scrolls), with the feed's links on their text when the feed is known.
        let notes = t.summary ?? ""
        comment.show(NotesText.attributed(notes, links: PodcastLibrary.shared.knownEpisode(t.path)?.links,
                                          font: Fonts.hack(10), color: commentColor))
        comment.isHidden = notes.isEmpty
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

        let cm = d?.comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        comment.show(NotesText.attributed(cm.isEmpty ? "" : "“\(cm)”", font: Fonts.hack(10), color: commentColor))
        comment.isHidden = cm.isEmpty
    }

    @objc private func reveal() {
        if let p = shownPath { onReveal?(p) }
    }
}

// MARK: - VoiceOver

extension ArtView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { onClick != nil ? .button : .image }
    override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? "Cover art" }
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}
