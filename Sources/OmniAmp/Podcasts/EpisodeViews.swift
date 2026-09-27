import AppKit

/// The marker in front of an episode: a dot when new, a check when played, and a small pie that fills up
/// with how far you got when you've started it.
final class EpisodeMarkView: NSView {
    enum State: Equatable {
        case none, new, played
        /// Started; the fraction heard, nil if the length isn't known.
        case progress(Double?)
    }

    var state: State = .none { didSet { if state != oldValue { needsDisplay = true; toolTip = tip } } }

    private var tip: String? {
        switch state {
        case .none: return nil
        case .new: return "New"
        case .played: return "Played"
        case .progress(let f): return f.map { "Started · \(Int(($0 * 100).rounded()))% heard" } ?? "Started"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        switch state {
        case .none:
            break
        case .new:
            Theme.phosphor.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill()
        case .played:
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.icon(9), .foregroundColor: Theme.phosphorDim]
            let s = NSAttributedString(string: Fonts.Icon.check, attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: (c.x - size.width / 2).rounded(), y: (c.y - size.height / 2).rounded()))
        case .progress(let f):
            let r: CGFloat = 4.5
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ring.lineWidth = 1
            Theme.phosphor.withAlphaComponent(0.7).setStroke()
            ring.stroke()
            // The heard part, clockwise from 12 o'clock; at least a sliver so it never looks empty.
            let frac = CGFloat(max(0.08, min(1, f ?? 0.5)))
            let pie = NSBezierPath()
            pie.move(to: c)
            pie.appendArc(withCenter: c, radius: r - 1.5, startAngle: 90, endAngle: 90 - 360 * frac, clockwise: true)
            pie.close()
            Theme.phosphor.setFill()
            pie.fill()
        }
    }
}

/// A table that first offers every key to its owner (which checks modifiers itself); what it doesn't
/// take works as usual (arrows, page keys, ⇧-selection…).
final class KeyTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// A row's small cover: the episode's own image, or the show's.
final class EpisodeArtCell: NSView {
    private let art = ArtView()
    private var url: String?

    init() {
        super.init(frame: .zero)
        art.cornerRadius = 2
        art.placeholder = Fonts.Icon.podcast
        art.translatesAutoresizingMaskIntoConstraints = false
        addSubview(art)
        NSLayoutConstraint.activate([
            art.centerXAnchor.constraint(equalTo: centerXAnchor), art.centerYAnchor.constraint(equalTo: centerYAnchor),
            art.widthAnchor.constraint(equalToConstant: 20), art.heightAnchor.constraint(equalToConstant: 20),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ full: String?) {
        let artwork = LogoStore.thumbnail(full)
        url = artwork
        art.image = LogoStore.shared.cached(artwork, size: .small)
        guard art.image == nil, artwork != nil else { return }
        LogoStore.shared.load(artwork, size: .small) { [weak self] img in
            guard let self, self.url == artwork else { return }
            self.art.image = img
        }
    }
}

/// The collapsible pane under the episode list: cover, title, date / length / progress, and the full show
/// notes with their links clickable.
final class EpisodeNotesView: NSView {
    private let art = ArtView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let scroll = NSTextView.scrollableTextView()
    private var text: NSTextView { scroll.documentView as! NSTextView }
    private var artURL: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.cgColor
        art.cornerRadius = 3
        art.placeholder = Fonts.Icon.podcast
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meta.lineBreakMode = .byTruncatingTail
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.textContainer?.lineFragmentPadding = 0
        for v in [art, title, meta, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            art.widthAnchor.constraint(equalToConstant: 56), art.heightAnchor.constraint(equalToConstant: 56),
            title.topAnchor.constraint(equalTo: art.topAnchor, constant: 1),
            title.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: art.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        applyTheme()
        show(nil, show: nil, status: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var dim: NSColor { Theme.phosphorDim.blended(withFraction: 0.35, of: Theme.phosphor) ?? Theme.phosphorDim }

    func applyTheme() {
        layer?.backgroundColor = Theme.lcd.cgColor
        title.font = Fonts.hack(12, bold: true)
        title.textColor = Theme.playlistText
        meta.font = Fonts.hack(10)
        meta.textColor = dim
        text.linkTextAttributes = [.foregroundColor: Theme.phosphor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .cursor: NSCursor.pointingHand]
        art.needsDisplay = true
    }

    /// `status`: played / how much is left / new, for the meta line.
    func show(_ e: PodcastEpisode?, show: PodcastShow?, status: String?) {
        guard let e, let show else {
            art.isHidden = true
            title.stringValue = ""
            meta.stringValue = ""
            text.textStorage?.setAttributedString(NSAttributedString(string: "Select an episode to read its show notes.",
                                                                     attributes: [.font: Fonts.hack(11), .foregroundColor: dim]))
            return
        }
        art.isHidden = false
        title.stringValue = e.title
        var parts: [String] = []
        if let p = e.published { parts.append(Date(timeIntervalSince1970: p).formatted(date: .long, time: .omitted)) }
        if let d = e.duration { parts.append(TimeFormat.mmss(d)) }
        if let n = e.number { parts.append(e.season.map { "S\($0) · E\(n)" } ?? "Episode \(n)") }
        if let s = status { parts.append(s) }
        meta.stringValue = parts.joined(separator: " · ")
        let want = e.artwork(show: show)
        if want != artURL {
            artURL = want
            art.image = LogoStore.shared.cached(want)
            LogoStore.shared.load(want) { [weak self] img in
                guard let self, self.artURL == want else { return }
                self.art.image = img
            }
        }
        text.textStorage?.setAttributedString(Self.notes(e, font: Fonts.hack(11), color: Theme.playlistText))
        text.scroll(.zero)
    }

    /// Show notes with the feed's links put back on their text, plus any bare web addresses.
    static func notes(_ e: PodcastEpisode, font: NSFont, color: NSColor) -> NSAttributedString {
        let body = e.summary ?? "This episode has no show notes."
        let out = NSMutableAttributedString(string: body, attributes: [.font: font, .foregroundColor: color])
        let ns = body as NSString
        var linked: [NSRange] = []
        func isFree(_ r: NSRange) -> Bool { !linked.contains { NSIntersectionRange($0, r).length > 0 } }
        for pair in e.links ?? [] where pair.count == 2 {
            guard let url = URL(string: pair[1]) else { continue }
            // The first occurrence of the link's text that isn't linked yet.
            var from = 0
            while from < ns.length {
                let r = ns.range(of: pair[0], range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound else { break }
                if isFree(r) { out.addAttribute(.link, value: url, range: r); linked.append(r); break }
                from = r.location + r.length
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in detector.matches(in: body, range: NSRange(location: 0, length: ns.length)) where isFree(m.range) {
                if let url = m.url { out.addAttribute(.link, value: url, range: m.range); linked.append(m.range) }
            }
        }
        return out
    }
}

/// The episode list / notes split: no divider line while the notes are hidden.
final class NotesSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        guard subviews.count > 1, !subviews[1].isHidden else { return }
        super.drawDivider(in: rect)
    }
}

/// Shows | episodes: the 12 pt gap between the two lists is the divider (nothing drawn, drag anywhere in it).
final class PaneSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 12 }
    override func drawDivider(in rect: NSRect) {}
}

/// A row's download state: an outline arrow to download, a filling ring while it comes in, a check once it's
/// on disk, a warning if it failed. Clicking it starts or stops the download (see the window).
final class DownloadMarkView: NSView {
    private var state: PodcastDownloads.State = .none
    private var failed = false

    func set(_ s: PodcastDownloads.State, failure: String?) {
        guard s != state || failed != (failure != nil) else { return }
        state = s
        failed = failure != nil && s == .none
        switch s {
        case .none: toolTip = failure.map { "Download failed: \($0). Click to try again." } ?? "Download for offline listening"
        case .queued: toolTip = "Waiting to download · click to cancel"
        case .downloading(let p): toolTip = "Downloading \(Int(p * 100))% · click to cancel"
        case .done: toolTip = "Downloaded: plays offline"
        }
        needsDisplay = true
    }

    private func glyph(_ g: String, _ color: NSColor, size: CGFloat = 10) {
        let s = NSAttributedString(string: g, attributes: [.font: Theme.icon(size), .foregroundColor: color])
        let z = s.size()
        s.draw(at: NSPoint(x: (bounds.midX - z.width / 2).rounded(), y: (bounds.midY - z.height / 2).rounded()))
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        switch state {
        case .none:
            if failed { glyph(Fonts.Icon.warning, Theme.warning, size: 9) }
            else { glyph(Fonts.Icon.download, Theme.phosphorDim.withAlphaComponent(0.55), size: 9) }
        case .done:
            glyph(Fonts.Icon.downloaded, Theme.phosphor)
        case .queued, .downloading:
            let r: CGFloat = 5
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ring.lineWidth = 1.5
            Theme.phosphorDim.withAlphaComponent(0.5).setStroke()
            ring.stroke()
            if case .downloading(let p) = state {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * CGFloat(max(0.03, p)), clockwise: true)
                arc.lineWidth = 1.5
                Theme.phosphor.setStroke()
                arc.stroke()
            }
        }
    }
}
