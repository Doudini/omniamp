import AppKit

/// Above the Tracks list: a slim strip with the filter's conditions as chips (× takes one away, Clear all of them)
/// and the presets, and under it a panel that folds open (closed by default) to set them: on the left a year range
/// over a chart of the library's years, on the right how often and how lately songs were played (Listening) and when
/// they were added, their kind and genres (Library). It only shows and edits a TrackFilter; the list filters.
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
    private let presets: Pill
    private let clear: Pill
    private let panel = NSView()
    private var panelHeight: NSLayoutConstraint!
    private let years = YearRangeSlider()
    private static let playOptions: [(String, TrackFilter.Plays)] = [("Any", .any), ("Never", .never), ("1+", .atLeast(1)),
                                                                      ("10+", .atLeast(10)), ("50+", .atLeast(50)), ("100+", .atLeast(100))]
    private static let lastOptions: [(String, TrackFilter.LastPlayed)] = [("Any", .any), ("This year", .thisYear), ("1+ yrs ago", .yearsAgo(1)),
                                                                           ("5+ yrs ago", .yearsAgo(5)), ("Never", .never)]
    private static let addedOptions: [(String, TrackFilter.Added)] = [("Any", .any), ("30 days", .days(30)), ("This year", .thisYear)]
    private let plays = SegmentedPicker(playOptions.map(\.0))
    private let last = SegmentedPicker(lastOptions.map(\.0))
    private let added = SegmentedPicker(addedOptions.map(\.0))
    private let kinds = SegmentedPicker(TrackFilter.KindGroup.allCases.map(\.title), multiple: true)
    private let genreRow = NSStackView()
    private let addGenre = SegmentedPicker(["+ Genre"], momentary: true)
    /// The library's genres and how many tracks each has, for the genre menu.
    private var genreCounts: [(String, Int)] = []
    private var content: NSView!

    override init(frame: NSRect) {
        toggle = Pill("Filters", glyph: "▸", target: nil, action: #selector(toggled))
        presets = Pill("Presets ▾", target: nil, action: #selector(presetMenu(_:)))
        clear = Pill("Clear", target: nil, action: #selector(clearAll))
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for p in [toggle, presets, clear] { p.target = self }
        toggle.toolTip = "Narrow the list by year, plays, when it was added, kind or genre"
        presets.toolTip = "Ready-made filters"
        chips.orientation = .horizontal
        chips.spacing = 6
        chips.setClippingResistancePriority(.defaultLow, for: .horizontal)
        chips.setHuggingPriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let strip = NSStackView(views: [toggle, chips, spacer, presets, clear])
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

    /// Year on the left (the chart has room to read as a picture of the library); the choices on the right, under
    /// two small headings.
    private func buildPanel() {
        func heading(_ s: String) -> NSTextField {
            let l = Dash.label("", Dash.font(10, .semibold), Dash.text3)
            l.attributedStringValue = NSAttributedString(string: s.uppercased(), attributes: [
                .font: Dash.font(10, .semibold), .foregroundColor: Dash.text3, .kern: 1.2,
            ])
            return l
        }
        func row(_ title: String, _ view: NSView) -> NSStackView {
            let l = Dash.label(title, Dash.font(11.5), Dash.text2)
            l.widthAnchor.constraint(equalToConstant: 76).isActive = true
            let r = NSStackView(views: [l, view])
            r.orientation = .horizontal
            r.spacing = 8
            r.alignment = .centerY
            r.setHuggingPriority(.required, for: .horizontal)   // as wide as its choices (Add stays beside the genres)
            return r
        }
        for (picker, action) in [(plays, #selector(playsChanged)), (last, #selector(lastChanged)), (added, #selector(addedChanged)),
                                 (kinds, #selector(kindsChanged)), (addGenre, #selector(genreMenu(_:)))] {
            picker.target = self
            picker.action = action
        }
        plays.toolTip = "Plays of the song, from your Last.fm history and OmniAmp's own"
        last.toolTip = "When the song was last played"
        kinds.toolTip = "Albums (with singles and compilations), official live albums, shows and bootlegs, demos and outtakes. None chosen: all"
        genreRow.orientation = .horizontal
        genreRow.spacing = 6
        let genres = NSStackView(views: [genreRow, addGenre])
        genres.orientation = .horizontal
        genres.spacing = 6
        genres.setHuggingPriority(.required, for: .horizontal)
        genreRow.setHuggingPriority(.required, for: .horizontal)

        years.target = self
        years.action = #selector(yearsChanged)
        let left = NSStackView(views: [heading("Year"), years])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6
        left.distribution = .fill
        // The chart takes the column's height (as tall as the choices beside it).
        years.setContentHuggingPriority(.defaultLow, for: .vertical)
        years.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true

        let right = NSStackView(views: [
            heading("Listening"), row("Plays", plays), row("Last played", last),
            heading("Library"), row("Added", added), row("Kind", kinds), row("Genre", genres),
        ])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 6
        right.setCustomSpacing(12, after: right.arrangedSubviews[2])
        right.setContentHuggingPriority(.required, for: .horizontal)

        let box = NSView()
        for v in [left, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
        }
        let leftWide = left.widthAnchor.constraint(equalToConstant: 520)
        leftWide.priority = .defaultLow
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: box.topAnchor),
            left.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            left.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            leftWide,
            years.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
            right.topAnchor.constraint(equalTo: box.topAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 32),
            right.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
            right.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        box.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            box.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            box.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
        ])
        content = box
    }

    /// The library as the slider and the genre menu see it (from all tracks, not the filtered ones).
    func setLibrary(years counts: [Int: Int], genres: [(String, Int)]) {
        years.histogram = counts
        genreCounts = genres
        sync()
    }

    private func setOpen(_ open: Bool, animated: Bool) {
        let h = open ? content.fittingSize.height + 8 : 0
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
        plays.selected = Set(Self.playOptions.indices.filter { Self.playOptions[$0].1 == f.plays })
        last.selected = Set(Self.lastOptions.indices.filter { Self.lastOptions[$0].1 == f.lastPlayed })
        added.selected = Set(Self.addedOptions.indices.filter { Self.addedOptions[$0].1 == f.added })
        kinds.selected = Set(TrackFilter.KindGroup.allCases.indices.filter { f.kinds.contains(TrackFilter.KindGroup.allCases[$0]) })
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for g in f.genres {
            genreRow.addArrangedSubview(FilterChip(g) { [weak self] in
                guard let self else { return }
                self.change(self.filter.removing(.genre(g)))
            })
        }
        genreRow.isHidden = f.genres.isEmpty
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

    @objc private func presetMenu(_ sender: Pill) {
        let menu = NSMenu()
        for (title, tip, action) in [("Forgotten favourites", "Songs you played 10+ times but not in the last 5 years, most played first",
                                      #selector(presetForgotten)),
                                     ("Never played", "Tracks with no plays (from Last.fm or OmniAmp)", #selector(presetNever))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.toolTip = tip
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func presetForgotten() { filter = .forgottenFavourites; onPreset?(.forgottenFavourites, TrackSort(column: .plays, ascending: false)) }
    @objc private func presetNever() { filter = .neverPlayed; onPreset?(.neverPlayed, nil) }

    @objc private func yearsChanged() {
        var f = filter
        f.years = years.selection
        change(f)
    }

    @objc private func playsChanged() {
        var f = filter
        f.plays = plays.selected.first.map { Self.playOptions[$0].1 } ?? .any
        change(f)
    }

    @objc private func lastChanged() {
        var f = filter
        f.lastPlayed = last.selected.first.map { Self.lastOptions[$0].1 } ?? .any
        change(f)
    }

    @objc private func addedChanged() {
        var f = filter
        f.added = added.selected.first.map { Self.addedOptions[$0].1 } ?? .any
        change(f)
    }

    @objc private func kindsChanged() {
        var f = filter
        f.kinds = Set(kinds.selected.map { TrackFilter.KindGroup.allCases[$0] })
        // All four on is the same as none: every kind.
        if f.kinds.count == TrackFilter.KindGroup.allCases.count { f.kinds = [] }
        change(f)
    }

    /// The library's genres, most tracks first; the ones already chosen left out.
    @objc private func genreMenu(_ sender: SegmentedPicker) {
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

// MARK: - Segmented picker

/// Choices in one rounded box, divided by hairlines: one at a time (the first being "any", drawn quietly so only a
/// real choice stands out), several (none on: all), or a single momentary button in the same style.
final class SegmentedPicker: NSControl {
    let titles: [String]
    let multiple: Bool
    let momentary: Bool
    var selected: Set<Int> = [] { didSet { if selected != oldValue { needsDisplay = true } } }
    private var hover: Int? { didSet { if hover != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    init(_ titles: [String], multiple: Bool = false, momentary: Bool = false) {
        self.titles = titles
        self.multiple = multiple
        self.momentary = momentary
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let pad: CGFloat = 10
    private func text(_ i: Int, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: titles[i], attributes: [.font: Dash.font(11.5, .medium), .foregroundColor: color])
    }
    private var widths: [CGFloat] { titles.indices.map { ceil(text($0, .white).size().width) + 2 * Self.pad } }
    override var intrinsicContentSize: NSSize { NSSize(width: widths.reduce(0, +), height: 22) }

    private func segment(at x: CGFloat) -> Int? {
        var left: CGFloat = 0
        for (i, w) in widths.enumerated() {
            if x >= left, x < left + w { return i }
            left += w
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5), radius = r.height / 2
        let outline = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        Dash.card.setFill()
        outline.fill()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        var x: CGFloat = 0
        for (i, w) in widths.enumerated() {
            let seg = NSRect(x: x, y: 0, width: w, height: bounds.height)
            let on = momentary ? pressed : selected.contains(i)
            // The "any" choice (the first of one-at-a-time choices) is quiet when it's on: nothing is filtered.
            let quiet = !multiple && !momentary && i == 0
            if on {
                (quiet ? Dash.cardRaised : Dash.accent.withAlphaComponent(0.18)).setFill()
                seg.fill()
            } else if hover == i, isEnabled {
                Dash.cardRaised.setFill()
                seg.fill()
            }
            if i > 0 {
                Dash.border.setFill()
                NSRect(x: x, y: 4, width: 1, height: bounds.height - 8).fill()
            }
            let color: NSColor = !isEnabled ? Dash.text3 : on && !quiet ? Dash.accent : on || hover == i ? Dash.text : Dash.text2
            let t = text(i, color), s = t.size()
            t.draw(at: NSPoint(x: x + (w - s.width) / 2, y: (bounds.height - s.height) / 2))
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
        let anyOn = !momentary && selected.contains(where: { multiple || $0 > 0 })
        (anyOn ? Dash.accent.withAlphaComponent(0.45) : Dash.border).setStroke()
        outline.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { hover = segment(at: convert(event.locationInWindow, from: nil).x) }
    override func mouseExited(with event: NSEvent) { hover = nil }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let i = segment(at: convert(event.locationInWindow, from: nil).x) else { return }
        if momentary {
            pressed = true
            sendAction(action, to: target)
            pressed = false
            return
        }
        if multiple {
            if selected.contains(i) { selected.remove(i) } else { selected.insert(i) }
        } else {
            guard !selected.contains(i) else { return }
            selected = [i]
        }
        sendAction(action, to: target)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { momentary ? .button : .radioGroup }
    override func accessibilityLabel() -> String? { toolTip ?? titles.joined(separator: ", ") }
    override func accessibilityValue() -> Any? { selected.sorted().map { titles[$0] }.joined(separator: ", ") }
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
    override var intrinsicContentSize: NSSize { NSSize(width: 360, height: 70) }

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
    /// The track along the bottom (the years under it); the chart fills what's above.
    private var track: NSRect { NSRect(x: 8, y: bounds.height - 20, width: bounds.width - 16, height: 3) }

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
        // The chart: a bar a year (square root: a year with a few tracks still shows), the chosen years in the chart
        // color, over a faint baseline.
        let most = sqrt(CGFloat(histogram.values.max() ?? 1)), chartTop: CGFloat = 2, base = t.minY - 6, chartH = base - chartTop
        let barW = max(1, t.width / CGFloat(s.upperBound - s.lowerBound + 1) - 1)
        Dash.border.withAlphaComponent(0.6).setFill()
        NSRect(x: t.minX, y: base, width: t.width, height: 1).fill()
        for (y, n) in histogram where s.contains(y) {
            let h = max(2, sqrt(CGFloat(n)) / most * chartH)
            (sel.contains(y) ? Dash.amount : Dash.compare.withAlphaComponent(0.35)).setFill()
            NSRect(x: x(y) - barW / 2, y: base - h, width: barW, height: h).fill()
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
