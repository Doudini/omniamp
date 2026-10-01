import AppKit

/// Above the Tracks list: a slim strip with the filter's conditions as chips (× takes one away, Clear all of them),
/// and under it a panel that folds open (closed by default) to set them: a year range over a chart of the library's
/// years, how often and how lately songs were played, when they were added, genres, kinds of release, and two presets.
/// It only shows and edits a TrackFilter; the list does the filtering.
@MainActor
final class TrackFilterBar: NSView {
    var filter = TrackFilter() { didSet { if filter != oldValue { sync() } } }
    /// A change from the strip or the panel.
    var onChange: ((TrackFilter) -> Void)?
    /// A preset: its filter, and the sort that goes with it (Forgotten favourites: most played first).
    var onPreset: ((TrackFilter, TrackSort?) -> Void)?
    var isOpen: Bool { get { !panel.isHidden } set { setOpen(newValue, animated: false) } }
    var onToggle: ((Bool) -> Void)?

    static let stripHeight: CGFloat = 32
    private let toggle: Pill
    private let chips = NSStackView()
    private let clear: Pill
    private let panel = NSView()
    private var panelHeight: NSLayoutConstraint!
    private let years = YearRangeSlider()
    private var playPills: [(Pill, TrackFilter.Plays)] = []
    private var lastPills: [(Pill, TrackFilter.LastPlayed)] = []
    private var addedPills: [(Pill, TrackFilter.Added)] = []
    private var kindPills: [(Pill, TrackFilter.KindGroup)] = []
    private let genreRow = NSStackView()
    private var addGenre: Pill!
    /// The library's genres and how many tracks each has, for the genre menu.
    private var genreCounts: [(String, Int)] = []
    private var content: NSStackView!

    override init(frame: NSRect) {
        toggle = Pill("Filters", glyph: "▸", target: nil, action: #selector(toggled))
        clear = Pill("Clear", target: nil, action: #selector(clearAll))
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        toggle.target = self
        clear.target = self
        toggle.toolTip = "Narrow the list by year, plays, when it was added, genre or kind"
        chips.orientation = .horizontal
        chips.spacing = 6
        chips.setClippingResistancePriority(.defaultLow, for: .horizontal)
        chips.setHuggingPriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let strip = NSStackView(views: [toggle, chips, spacer, clear])
        strip.orientation = .horizontal
        strip.spacing = 8
        strip.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        strip.translatesAutoresizingMaskIntoConstraints = false

        buildPanel()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.masksToBounds = true
        panel.isHidden = true
        for v in [strip, panel] as [NSView] { addSubview(v) }
        panelHeight = panel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: Self.stripHeight),
            panel.topAnchor.constraint(equalTo: strip.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            panelHeight,
        ])
        sync()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Panel

    private func buildPanel() {
        func label(_ s: String) -> NSTextField {
            let l = Dash.label(s, Dash.font(11.5, .medium), Dash.text3)
            l.widthAnchor.constraint(equalToConstant: 84).isActive = true
            return l
        }
        func row(_ title: String, _ views: [NSView]) -> NSStackView {
            let r = NSStackView(views: [label(title)] + views)
            r.orientation = .horizontal
            r.spacing = 6
            r.alignment = .centerY
            return r
        }
        func pills<V>(_ options: [(String, V)], _ action: Selector) -> [(Pill, V)] {
            options.enumerated().map { i, o in
                let p = Pill(o.0, target: self, action: action)
                p.tag = i
                return (p, o.1)
            }
        }
        let forgotten = Pill("Forgotten favourites", target: self, action: #selector(presetForgotten))
        forgotten.toolTip = "Songs you played 10+ times but not in the last 5 years, most played first"
        let never = Pill("Never played", target: self, action: #selector(presetNever))
        never.toolTip = "Tracks with no plays (from Last.fm or OmniAmp)"
        years.target = self
        years.action = #selector(yearsChanged)
        years.widthAnchor.constraint(lessThanOrEqualToConstant: 560).isActive = true
        let yearsWide = years.widthAnchor.constraint(equalToConstant: 560)
        yearsWide.priority = .defaultLow
        yearsWide.isActive = true
        playPills = pills([("Any", .any), ("Never", .never), ("1+", .atLeast(1)), ("10+", .atLeast(10)), ("50+", .atLeast(50)),
                           ("100+", .atLeast(100))], #selector(playsClicked(_:)))
        lastPills = pills([("Any", .any), ("This year", .thisYear), ("Over a year ago", .yearsAgo(1)), ("Over 5 years ago", .yearsAgo(5)),
                           ("Never", .never)], #selector(lastClicked(_:)))
        addedPills = pills([("Any", .any), ("Last 30 days", .days(30)), ("This year", .thisYear)], #selector(addedClicked(_:)))
        kindPills = pills(TrackFilter.KindGroup.allCases.map { ($0.title, $0) }, #selector(kindClicked(_:)))
        addGenre = Pill("Add", glyph: "+", target: self, action: #selector(genreMenu(_:)))
        genreRow.orientation = .horizontal
        genreRow.spacing = 6
        let plays = row("Plays", playPills.map(\.0))
        plays.toolTip = "Plays of the song, from your Last.fm history and OmniAmp's own"
        content = NSStackView(views: [
            row("Presets", [forgotten, never]),
            row("Year", [years]),
            plays,
            row("Last played", lastPills.map(\.0)),
            row("Added", addedPills.map(\.0)),
            row("Genre", [genreRow, addGenre]),
            row("Kind", kindPills.map(\.0)),
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: panel.topAnchor),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor),
        ])
    }

    /// The library as the slider and the genre menu see it (from all tracks, not the filtered ones).
    func setLibrary(years counts: [Int: Int], genres: [(String, Int)]) {
        years.histogram = counts
        genreCounts = genres
        sync()
    }

    private func setOpen(_ open: Bool, animated: Bool) {
        let h = open ? content.fittingSize.height : 0
        if open { panel.isHidden = false }
        toggle.glyph = open ? "▾" : "▸"
        toggle.needsDisplay = true
        guard animated else {
            panelHeight.constant = h
            panel.isHidden = !open
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            panelHeight.animator().constant = h
            superview?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if !open { self?.panel.isHidden = true } }
        })
    }

    // MARK: Showing the filter

    private func sync() {
        let f = filter
        toggle.isOn = !f.isEmpty
        clear.isHidden = f.isEmpty
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for c in f.conditions {
            let chip = FilterChip(f.title(c)) { [weak self] in
                guard let self else { return }
                self.change(self.filter.removing(c))
            }
            chips.addArrangedSubview(chip)
        }
        years.selection = f.years
        for (p, v) in playPills { p.isOn = f.plays == v }
        for (p, v) in lastPills { p.isOn = f.lastPlayed == v }
        for (p, v) in addedPills { p.isOn = f.added == v }
        for (p, v) in kindPills { p.isOn = f.kinds.contains(v) }
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for g in f.genres {
            genreRow.addArrangedSubview(FilterChip(g) { [weak self] in
                guard let self else { return }
                self.change(self.filter.removing(.genre(g)))
            })
        }
        genreRow.isHidden = f.genres.isEmpty   // empty, it would push Add to the far end
        addGenre.isEnabled = !genreCounts.isEmpty
    }

    private func change(_ f: TrackFilter) {
        filter = f
        onChange?(f)
    }

    // MARK: Actions

    @objc private func toggled() {
        let open = panel.isHidden
        setOpen(open, animated: true)
        onToggle?(open)
    }

    @objc private func clearAll() { change(TrackFilter()) }
    @objc private func presetForgotten() { filter = .forgottenFavourites; onPreset?(.forgottenFavourites, TrackSort(column: .plays, ascending: false)) }
    @objc private func presetNever() { filter = .neverPlayed; onPreset?(.neverPlayed, nil) }

    @objc private func yearsChanged() {
        var f = filter
        f.years = years.selection
        change(f)
    }

    @objc private func playsClicked(_ sender: Pill) {
        var f = filter
        f.plays = playPills[sender.tag].1
        change(f)
    }

    @objc private func lastClicked(_ sender: Pill) {
        var f = filter
        f.lastPlayed = lastPills[sender.tag].1
        change(f)
    }

    @objc private func addedClicked(_ sender: Pill) {
        var f = filter
        f.added = addedPills[sender.tag].1
        change(f)
    }

    @objc private func kindClicked(_ sender: Pill) {
        var f = filter
        let k = kindPills[sender.tag].1
        if f.kinds.contains(k) { f.kinds.remove(k) } else { f.kinds.insert(k) }
        // All four on is the same as none: every kind.
        if f.kinds.count == TrackFilter.KindGroup.allCases.count { f.kinds = [] }
        change(f)
    }

    /// The library's genres, most tracks first; the ones already chosen left out.
    @objc private func genreMenu(_ sender: Pill) {
        let menu = NSMenu()
        let chosen = Set(filter.genres.map(Keys.fold))
        for (g, n) in genreCounts where !chosen.contains(Keys.fold(g)) {
            let item = menu.addItem(withTitle: "\(g)  (\(n.formatted()))", action: #selector(genrePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = g
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func genrePicked(_ item: NSMenuItem) {
        guard let g = item.representedObject as? String else { return }
        var f = filter
        f.genres.append(g)
        change(f)
    }
}

// MARK: - Chip

/// A condition in the strip: its name and an × that takes it away.
final class FilterChip: NSControl {
    private let title: String
    private let onRemove: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ title: String, onRemove: @escaping () -> Void) {
        self.title = title
        self.onRemove = onRemove
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        toolTip = "Remove “\(title)”"
    }
    required init?(coder: NSCoder) { fatalError() }

    private var text: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: Dash.font(11.5, .medium), .foregroundColor: Dash.accent])
    }
    override var intrinsicContentSize: NSSize { NSSize(width: text.size().width + 34, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        Dash.accent.withAlphaComponent(hovering ? 0.24 : 0.14).setFill()
        path.fill()
        Dash.accent.withAlphaComponent(0.45).setStroke()
        path.stroke()
        let t = text, s = t.size()
        t.draw(at: NSPoint(x: 10, y: (bounds.height - s.height) / 2))
        let x = NSAttributedString(string: "×", attributes: [.font: Dash.font(12, .semibold), .foregroundColor: hovering ? Dash.text : Dash.text2])
        let xs = x.size()
        x.draw(at: NSPoint(x: bounds.width - xs.width - 9, y: (bounds.height - xs.height) / 2))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onRemove() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Remove filter \(title)" }
    override func accessibilityPerformPress() -> Bool { onRemove(); return true }
}

// MARK: - Year range

/// Two handles over the library's years, with a faint chart of how many tracks each year has behind them. Dragging
/// sends the action as it goes; a double-click (or both handles at the ends) means any year.
final class YearRangeSlider: NSControl {
    var histogram: [Int: Int] = [:] { didSet { span = Self.span(histogram); needsDisplay = true } }
    /// nil: any year.
    var selection: ClosedRange<Int>? { didSet { if selection != oldValue { needsDisplay = true } } }
    private var dragging: Int?   // 0 the low handle, 1 the high one

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 360, height: 46) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isContinuous = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The years the slider covers: from the decade the library really starts in (a few tracks tagged 1901 or 1000
    /// don't squash the rest into a corner) to its last year. A handle at an end means "and earlier" / "and later".
    private var span: ClosedRange<Int> = 1960...2030
    static func span(_ histogram: [Int: Int]) -> ClosedRange<Int> {
        guard let hi = histogram.keys.max() else { return 1960...2030 }
        let total = histogram.values.reduce(0, +)
        var seen = 0, lo = histogram.keys.min()!
        for y in histogram.keys.sorted() {
            seen += histogram[y]!
            if Double(seen) > Double(total) * 0.005 { lo = y; break }
        }
        lo = lo / 10 * 10
        return lo...max(hi, lo + 1)
    }
    private var shown: ClosedRange<Int> { selection.map { $0.clamped(to: span) } ?? span }
    private var track: NSRect { NSRect(x: 8, y: 30, width: bounds.width - 16, height: 3) }

    private func x(_ year: Int) -> CGFloat {
        let s = span, t = track
        return t.minX + CGFloat(year - s.lowerBound) / CGFloat(s.upperBound - s.lowerBound) * t.width
    }
    private func year(_ x: CGFloat) -> Int {
        let s = span, t = track
        let f = max(0, min(1, (x - t.minX) / max(1, t.width)))
        return s.lowerBound + Int((f * CGFloat(s.upperBound - s.lowerBound)).rounded())
    }

    override func draw(_ dirtyRect: NSRect) {
        let s = span, sel = shown, t = track
        // The chart: a bar a year, the chosen years in the chart color.
        let most = CGFloat(histogram.values.max() ?? 1), chartTop: CGFloat = 2, chartH = t.minY - 6 - chartTop
        let barW = max(1, t.width / CGFloat(s.upperBound - s.lowerBound + 1) - 1)
        for (y, n) in histogram where s.contains(y) {
            let h = max(1, CGFloat(n) / most * chartH)
            (sel.contains(y) ? Dash.amount : Dash.compare.withAlphaComponent(0.35)).setFill()
            NSRect(x: x(y) - barW / 2, y: t.minY - 6 - h, width: barW, height: h).fill()
        }
        // The track, the chosen part brighter, and the handles.
        Dash.border.setFill()
        NSBezierPath(roundedRect: t, xRadius: 1.5, yRadius: 1.5).fill()
        let a = x(sel.lowerBound), b = x(sel.upperBound)
        (selection == nil ? Dash.text3 : Dash.accent).setFill()
        NSRect(x: a, y: t.minY, width: max(2, b - a), height: t.height).fill()
        for hx in [a, b] {
            let knob = NSRect(x: hx - 6, y: t.midY - 6, width: 12, height: 12)
            Dash.cardRaised.setFill()
            NSBezierPath(ovalIn: knob).fill()
            (selection == nil ? Dash.text3 : Dash.accent).setStroke()
            let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }
        // The years at the handles (any year: the library's span, faint).
        let attrs: [NSAttributedString.Key: Any] = [.font: Dash.mono(10), .foregroundColor: selection == nil ? Dash.text3 : Dash.text2]
        let lo = NSAttributedString(string: String(sel.lowerBound), attributes: attrs)
        let hi = NSAttributedString(string: String(sel.upperBound), attributes: attrs)
        let ly = t.maxY + 2
        let lx = max(0, min(a - lo.size().width / 2, bounds.width - lo.size().width))
        var hx = max(0, min(b - hi.size().width / 2, bounds.width - hi.size().width))
        if hx < lx + lo.size().width + 4 { hx = min(bounds.width - hi.size().width, lx + lo.size().width + 4) }
        lo.draw(at: NSPoint(x: lx, y: ly))
        if sel.upperBound != sel.lowerBound { hi.draw(at: NSPoint(x: hx, y: ly)) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { set(nil); return }
        let p = convert(event.locationInWindow, from: nil), sel = shown
        // The nearer handle; between them, the one on that side.
        dragging = abs(p.x - x(sel.lowerBound)) <= abs(p.x - x(sel.upperBound)) ? 0 : 1
        drag(to: p.x)
    }

    override func mouseDragged(with event: NSEvent) { drag(to: convert(event.locationInWindow, from: nil).x) }
    override func mouseUp(with event: NSEvent) { dragging = nil }

    private func drag(to px: CGFloat) {
        guard let d = dragging else { return }
        let sel = shown, y = year(px)
        let r = d == 0 ? min(y, sel.upperBound)...sel.upperBound : sel.lowerBound...max(y, sel.lowerBound)
        // At an end: open that way (the years before or after the slider's range count too).
        let lo = r.lowerBound <= span.lowerBound ? TrackFilter.earliest : r.lowerBound
        let hi = r.upperBound >= span.upperBound ? TrackFilter.latest : r.upperBound
        set(lo == TrackFilter.earliest && hi == TrackFilter.latest ? nil : lo...hi)
    }

    private func set(_ r: ClosedRange<Int>?) {
        guard r != selection else { return }
        selection = r
        sendAction(action, to: target)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        selection.map { "Years \($0.lowerBound) to \($0.upperBound)" } ?? "Any year"
    }
}
