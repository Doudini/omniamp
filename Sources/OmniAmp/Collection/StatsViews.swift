import AppKit

// The Stats page's charts, drawn in the modern look: one phosphor hue, brighter for more; labels and values
// in text colors; every mark has a tooltip, and most open the library at what they show.

/// A chart with hover tooltips and clickable marks. Subclasses fill `regions` in `layoutRegions()` and draw.
class StatsChart: NSView, NSViewToolTipOwner {
    struct Region {
        let rect: NSRect
        let tip: String
        let action: (() -> Void)?
    }
    var regions: [Region] = []
    var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)   // as tall as its content, not as its row
    }
    required init?(coder: NSCoder) { fatalError() }

    func layoutRegions() {}

    override func layout() {
        super.layout()
        layoutRegions()
        removeAllToolTips()
        for r in regions { addToolTip(r.rect, owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        regions.first { $0.rect.contains(point) }?.tip ?? ""
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    private func index(_ e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        return regions.firstIndex { $0.rect.contains(p) }
    }
    override func mouseMoved(with event: NSEvent) { hovered = index(event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) { if let i = index(event) { regions[i].action?() } }
    override func resetCursorRects() {
        for r in regions where r.action != nil { addCursorRect(r.rect, cursor: .pointingHand) }
    }

    // Shared drawing.
    static func text(_ s: String, _ size: CGFloat, _ color: NSColor, bold: Bool = false) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: Fonts.hack(size, bold: bold), .foregroundColor: color])
    }

    /// A bar with rounded ends, in the phosphor color (brighter when hovered).
    static func bar(_ r: NSRect, strength: CGFloat = 0.85, hot: Bool) {
        guard r.width > 0.5, r.height > 0.5 else { return }
        Theme.phosphor.withAlphaComponent(hot ? 1 : strength).setFill()
        let radius = min(2, r.width / 2, r.height / 2)
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }
}

/// Label, bar, value per row ("Indie Rock ▇▇▇▇▇ 4,210 · 312 releases").
final class BarListChart: StatsChart {
    var bars: [LibraryStats.Bar] = [] { didSet { invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true } }
    var format: (Double) -> String = { Int($0).formatted() }
    var tip: (LibraryStats.Bar) -> String = { "\($0.label): \(Int($0.value).formatted())" }
    var onClick: ((LibraryStats.Bar) -> Void)?
    var footnote: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    static let rowHeight: CGFloat = 20

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(bars.count) * Self.rowHeight + (footnote == nil ? 0 : 18))
    }

    private var labelWidth: CGFloat { min(bounds.width * 0.42, 190) }
    private let valueWidth: CGFloat = 130

    override func layoutRegions() {
        regions = bars.enumerated().map { i, b in
            Region(rect: NSRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight),
                   tip: tip(b), action: onClick.map { f in { f(b) } })
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let most = max(bars.map(\.value).max() ?? 1, 0.0001)
        let barX = labelWidth + 8, barW = max(10, bounds.width - barX - valueWidth - 8)
        for (i, b) in bars.enumerated() {
            let y = CGFloat(i) * Self.rowHeight
            let hot = hovered == i
            if hot {
                Theme.phosphor.withAlphaComponent(0.06).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight).fill()
            }
            let label = Self.text(b.label, 10.5, hot ? Theme.current : Theme.playlistText)
            label.draw(with: NSRect(x: 4, y: y + 3, width: labelWidth - 4, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            Self.bar(NSRect(x: barX, y: y + 6, width: barW * CGFloat(b.value / most), height: 8), hot: hot)
            let value = NSMutableAttributedString(attributedString: Self.text(format(b.value), 10, Theme.playlistText))
            if !b.detail.isEmpty { value.append(Self.text("  " + b.detail, 9, LibraryStyle.dim)) }
            value.draw(with: NSRect(x: bounds.width - valueWidth, y: y + 3, width: valueWidth - 2, height: 15),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if let footnote {
            Self.text(footnote, 9, LibraryStyle.dim).draw(at: NSPoint(x: 4, y: CGFloat(bars.count) * Self.rowHeight + 3))
        }
    }
}

/// Releases per year as thin columns, with decade labels underneath.
final class YearsChart: StatsChart {
    var years: [(year: Int, releases: Int)] = [] { didSet { needsLayout = true; needsDisplay = true } }
    var onClick: ((Int) -> Void)?
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 150) }

    private var span: ClosedRange<Int> {
        guard let lo = years.first?.year, let hi = years.last?.year else { return 2000...2001 }
        return (lo / 10 * 10)...max(hi, lo / 10 * 10 + 9)
    }
    private var plot: NSRect { NSRect(x: 4, y: 6, width: bounds.width - 8, height: bounds.height - 26) }
    private var step: CGFloat { plot.width / CGFloat(span.count) }

    override func layoutRegions() {
        let p = plot, s = step
        regions = years.map { y in
            let x = p.minX + CGFloat(y.year - span.lowerBound) * s
            return Region(rect: NSRect(x: x, y: p.minY, width: max(s, 3), height: p.height),
                          tip: "\(y.year): \(y.releases.formatted()) release\(y.releases == 1 ? "" : "s")",
                          action: onClick.map { f in { f(y.year) } })
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = plot, s = step
        let most = CGFloat(max(years.map(\.releases).max() ?? 1, 1))
        Theme.phosphorDim.withAlphaComponent(0.4).setFill()
        NSRect(x: p.minX, y: p.maxY, width: p.width, height: 1).fill()
        for (i, y) in years.enumerated() {
            let h = max(2, p.height * CGFloat(y.releases) / most)
            let x = p.minX + CGFloat(y.year - span.lowerBound) * s
            Self.bar(NSRect(x: x + (s > 4 ? 1 : 0), y: p.maxY - h, width: max(1.5, s - (s > 4 ? 2 : 0.5)), height: h), hot: hovered == i)
        }
        var decade = span.lowerBound
        while decade <= span.upperBound {
            let x = p.minX + CGFloat(decade - span.lowerBound) * s
            Theme.phosphorDim.withAlphaComponent(0.4).setFill()
            NSRect(x: x, y: p.maxY, width: 1, height: 4).fill()
            Self.text("\(decade)s", 8.5, LibraryStyle.dim).draw(at: NSPoint(x: x + 2, y: p.maxY + 5))
            decade += 10
        }
    }
}

/// The collection's size over time (running total of tracks, by the date of the files).
final class GrowthChart: StatsChart {
    var points: [(month: String, total: Int)] = [] { didSet { needsLayout = true; needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 150) }
    private var plot: NSRect { NSRect(x: 4, y: 16, width: bounds.width - 8, height: bounds.height - 36) }

    private func month(_ m: String) -> Int {
        let parts = m.split(separator: "-").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 12 + parts[1] - 1 : 0
    }

    private func point(_ i: Int) -> NSPoint {
        let p = plot
        guard let first = points.first.map({ month($0.month) }), let last = points.last.map({ month($0.month) }) else { return .zero }
        let total = CGFloat(max(points.last?.total ?? 1, 1))
        let x = p.minX + p.width * CGFloat(month(points[i].month) - first) / CGFloat(max(last - first, 1))
        return NSPoint(x: x, y: p.maxY - p.height * CGFloat(points[i].total) / total)
    }

    override func layoutRegions() {
        // One hover region per point, as wide as the gap to its neighbours.
        regions = points.indices.map { i in
            let x = point(i).x
            let prev = i > 0 ? point(i - 1).x : x - 4, next = i + 1 < points.count ? point(i + 1).x : x + 4
            return Region(rect: NSRect(x: (prev + x) / 2, y: 0, width: max(2, (next - prev) / 2), height: bounds.height),
                          tip: "\(points[i].month): \(points[i].total.formatted()) tracks", action: nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else {
            Self.text("Not enough history yet.", 10, LibraryStyle.dim).draw(at: NSPoint(x: 4, y: 20))
            return
        }
        let p = plot
        let line = NSBezierPath()
        line.move(to: point(0))
        for i in 1..<points.count { line.line(to: point(i)) }
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: point(points.count - 1).x, y: p.maxY))
        area.line(to: NSPoint(x: point(0).x, y: p.maxY))
        area.close()
        Theme.phosphor.withAlphaComponent(0.12).setFill()
        area.fill()
        Theme.phosphor.setStroke()
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.stroke()
        Theme.phosphorDim.withAlphaComponent(0.4).setFill()
        NSRect(x: p.minX, y: p.maxY, width: p.width, height: 1).fill()
        if let h = hovered, h < points.count {
            let pt = point(h)
            Theme.phosphorDim.setFill()
            NSRect(x: pt.x, y: p.minY, width: 1, height: p.height).fill()
            Theme.current.setFill()
            NSBezierPath(ovalIn: NSRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)).fill()
        }
        // First and last month, and the total now.
        Self.text(points[0].month, 8.5, LibraryStyle.dim).draw(at: NSPoint(x: p.minX, y: p.maxY + 3))
        let end = Self.text(points[points.count - 1].month, 8.5, LibraryStyle.dim)
        end.draw(at: NSPoint(x: p.maxX - end.size().width, y: p.maxY + 3))
        let now = Self.text("\(points[points.count - 1].total.formatted()) tracks", 10, Theme.playlistText, bold: true)
        now.draw(at: NSPoint(x: p.maxX - now.size().width, y: 0))
    }
}

/// Shows owned by month of the concert: a column per year, a row per month; brighter for more shows.
final class ShowCalendar: StatsChart {
    var months: [String: Int] = [:] { didSet { needsLayout = true; needsDisplay = true } }
    var onClick: ((Int) -> Void)?
    private static let gap: CGFloat = 2, labelW: CGFloat = 30, top: CGFloat = 4

    private var years: [Int] {
        let ys = months.keys.compactMap { Int($0.prefix(4)) }
        guard let lo = ys.min(), let hi = ys.max() else { return [] }
        return Array(lo...hi)
    }

    /// Square cells as large as fit the width (at most 14 points).
    private var cell: CGFloat {
        let n = CGFloat(max(years.count, 1))
        return max(4, min(14, (bounds.width - Self.labelW - 4) / n - Self.gap))
    }

    /// Its height follows the cell size, which follows the width.
    private lazy var height: NSLayoutConstraint = {
        let c = heightAnchor.constraint(equalToConstant: Self.top + 12 * 16 + 34)
        c.isActive = true
        return c
    }()

    override func layout() {
        let h = Self.top + 12 * (cell + Self.gap) + 34
        if abs(height.constant - h) > 0.5 { height.constant = h }
        super.layout()
    }

    private func rect(col: Int, month: Int) -> NSRect {
        NSRect(x: Self.labelW + CGFloat(col) * (cell + Self.gap), y: Self.top + CGFloat(month) * (cell + Self.gap), width: cell, height: cell)
    }

    private static let monthNames: [String] = {
        let f = DateFormatter()
        f.locale = .current
        return f.shortMonthSymbols
    }()

    override func layoutRegions() {
        regions = []
        for (col, y) in years.enumerated() {
            for m in 0..<12 {
                let n = months[String(format: "%04d-%02d", y, m + 1)] ?? 0
                guard n > 0 else { continue }
                regions.append(Region(rect: rect(col: col, month: m), tip: "\(Self.monthNames[m]) \(y): \(n) show\(n == 1 ? "" : "s")",
                                      action: onClick.map { f in { f(y) } }))
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !years.isEmpty else {
            Self.text("No dated shows yet.", 10, LibraryStyle.dim).draw(at: NSPoint(x: 4, y: 4))
            return
        }
        for m in stride(from: 0, to: 12, by: 3) {
            Self.text(Self.monthNames[m], 8, LibraryStyle.dim).draw(at: NSPoint(x: 0, y: rect(col: 0, month: m).minY + cell / 2 - 6))
        }
        let most = CGFloat(max(months.values.max() ?? 1, 1))
        let hotRect = hovered.flatMap { $0 < regions.count ? regions[$0].rect : nil }
        let bottom = rect(col: 0, month: 11).maxY
        var lastLabel = -CGFloat.infinity
        for (col, y) in years.enumerated() {
            let x = rect(col: col, month: 0).minX
            // Year labels where there's room: every 5th year, and the first and last.
            if (y % 5 == 0 || col == 0 || col == years.count - 1), x - lastLabel > 30 {
                Self.text(String(y), 8, LibraryStyle.dim).draw(at: NSPoint(x: x, y: bottom + 3))
                lastLabel = x
            }
            for m in 0..<12 {
                let r = rect(col: col, month: m)
                let n = CGFloat(months[String(format: "%04d-%02d", y, m + 1)] ?? 0)
                if n == 0 {
                    Theme.phosphorDim.withAlphaComponent(0.12).setFill()
                } else {
                    // Four steps of one hue: a single show is still clearly lit.
                    let step = min(3, Int((n / most * 4).rounded(.up)) - 1)
                    Theme.phosphor.withAlphaComponent([0.35, 0.55, 0.78, 1][max(0, step)]).setFill()
                }
                NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
                if r == hotRect {
                    Theme.current.setStroke()
                    NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 2.5, yRadius: 2.5).stroke()
                }
            }
        }
        // Legend: fewer … more.
        let ly = bottom + 18
        var x = Self.labelW
        Self.text("fewer", 8, LibraryStyle.dim).draw(at: NSPoint(x: x, y: ly - 1))
        x += 34
        for a in [0.35, 0.55, 0.78, 1.0] {
            Theme.phosphor.withAlphaComponent(a).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: ly, width: 10, height: 10), xRadius: 2, yRadius: 2).fill()
            x += 13
        }
        Self.text("more", 8, LibraryStyle.dim).draw(at: NSPoint(x: x + 3, y: ly - 1))
    }
}

/// A big number with a caption.
final class StatTile: NSView {
    init(_ value: String, _ caption: String, tip: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let v = NSTextField(labelWithString: value)
        v.font = Fonts.hack(20, bold: true)
        v.textColor = Theme.phosphor
        let c = NSTextField(labelWithString: caption.uppercased())
        c.font = Fonts.hack(8.5, bold: true)
        c.textColor = LibraryStyle.header
        let s = NSStackView(views: [v, c])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 2
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), s.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10), s.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        toolTip = tip
        wantsLayer = true
        layer?.backgroundColor = Theme.lcd.cgColor
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A titled LCD panel around a chart.
final class StatsPanel: NSView {
    init(_ title: String, _ content: NSView, note: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.lcd.cgColor
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.cgColor
        let t = NSTextField(labelWithString: title.uppercased())
        t.font = Fonts.hack(9.5, bold: true)
        t.textColor = LibraryStyle.header
        let n = NSTextField(labelWithString: note ?? "")
        n.font = Fonts.hack(8.5)
        n.textColor = Theme.phosphorDim
        for v in [t, n, content] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            t.topAnchor.constraint(equalTo: topAnchor, constant: 10), t.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            n.firstBaselineAnchor.constraint(equalTo: t.firstBaselineAnchor), n.leadingAnchor.constraint(equalTo: t.trailingAnchor, constant: 8),
            n.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        // Charts are exactly as tall as their content (the page is rebuilt when the figures change).
        let h = content.intrinsicContentSize.height
        if h > 0 { content.heightAnchor.constraint(equalToConstant: h).isActive = true }
        if let calendar = content as? ShowCalendar { calendar.needsLayout = true }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A flipped container, so the page scrolls from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The Stats page: tiles, then charts in two columns. Clicks go back to the library through the callbacks.
final class StatsPage: NSScrollView {
    var onGenre: ((String) -> Void)?
    var onYear: ((Int) -> Void)?
    var onArtist: ((String) -> Void)?
    var onSearch: ((String) -> Void)?
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = false
        hasVerticalScroller = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func showLoading() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let l = NSTextField(labelWithString: "Counting…")
        l.font = Fonts.hack(11)
        l.textColor = LibraryStyle.dim
        stack.addArrangedSubview(l)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.distribution = .fillEqually
        r.alignment = .top
        for v in views { v.setContentHuggingPriority(.required, for: .vertical) }
        r.spacing = 10
        return r
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let c = NSStackView(views: views)
        c.orientation = .vertical
        c.spacing = 10
        c.alignment = .leading
        for v in views { v.widthAnchor.constraint(equalTo: c.widthAnchor).isActive = true }
        return c
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func hours(_ h: Double) -> String { h >= 100 ? "\(Int(h.rounded())) h" : String(format: "%.1f h", h) }

    func show(_ s: LibraryStats) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let days = s.seconds / 86400
        let lossless = s.tracks > 0 ? Double(s.losslessTracks) / Double(s.tracks) : 0
        let tiles: [NSView] = [
            StatTile(s.tracks.formatted(), "tracks", tip: s.unplayable > 0 ? "\(s.unplayable.formatted()) of them in formats OmniAmp can't play" : nil),
            StatTile(s.releases.formatted(), "releases"),
            StatTile(s.artists.formatted(), "artists"),
            StatTile(days >= 1 ? String(format: "%.1f days", days) : Self.hours(s.seconds / 3600), "of music",
                     tip: "\(Int(s.seconds / 3600).formatted()) hours: that long to play everything once"),
            StatTile(Self.size(s.bytes), "on disk"),
            StatTile(String(format: "%.0f%%", lossless * 100), "lossless", tip: "\(s.losslessTracks.formatted()) lossless tracks"),
            StatTile(s.shows.formatted(), "shows"),
        ]
        var rows: [NSView] = [row(tiles)]

        // A few releases dated a century early (bad tags) would squash the rest: the axis starts where 1% have come.
        let totalYears = s.years.reduce(0) { $0 + $1.releases }
        var cut = 0, before = 0
        while cut < s.years.count, Double(before + s.years[cut].releases) < Double(totalYears) * 0.01 { before += s.years[cut].releases; cut += 1 }
        let years = YearsChart()
        years.years = Array(s.years.dropFirst(cut))
        years.onClick = { [weak self] in self?.onYear?($0) }
        let decade = Dictionary(grouping: s.years, by: { $0.year / 10 * 10 }).mapValues { $0.reduce(0) { $0 + $1.releases } }
            .max { $0.value < $1.value }
        let early = before > 0 ? " · \(before) earlier not shown" : ""
        rows.append(StatsPanel("Release years", years, note: decade.map { "most from the \($0.key)s\(early) · click a year to open it" }))
        if let y = ProcessInfo.processInfo.environment["OMNIAMP_STATS_SCROLL"].flatMap(Double.init) {   // test hook: lower charts
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.documentView?.scroll(NSPoint(x: 0, y: y)) }
        }

        let genres = BarListChart()
        genres.bars = s.genres
        genres.tip = { "\($0.label): \(Int($0.value).formatted()) tracks, \($0.detail)" }
        genres.onClick = { [weak self] in self?.onGenre?($0.id) }
        if s.otherGenres > 0 { genres.footnote = "+ \(s.otherGenres) more genres" }
        let genrePanel = StatsPanel("Genres", genres, note: s.genres.isEmpty ? "no genre tags yet" : "tracks")

        let kinds = BarListChart()
        kinds.bars = s.kinds
        kinds.tip = { "\($0.label): \(Int($0.value).formatted()) releases, \($0.detail)" }
        let kindPanel = StatsPanel("What kind of recordings", kinds, note: "releases")
        let formats = BarListChart()
        formats.bars = Array(s.formats.prefix(8))
        formats.tip = { "\($0.label): \(Int($0.value).formatted()) tracks" }
        let formatPanel = StatsPanel("Formats", formats, note: "tracks")
        rows.append(row([genrePanel, column([kindPanel, formatPanel])]))

        let songs = BarListChart()
        songs.bars = s.songs.map { .init(id: $0.title, label: "\($0.title) — \($0.artist)", value: Double($0.versions),
                                         detail: $0.unofficial > 0 ? "\($0.unofficial) unofficial" : "") }
        songs.format = { "\(Int($0))×" }
        songs.tip = { "\($0.label): on \(Int($0.value)) releases\($0.detail.isEmpty ? "" : ", \($0.detail)") · click to find them" }
        songs.onClick = { [weak self] in self?.onSearch?($0.id) }
        let songPanel = StatsPanel("Songs you have most versions of", songs, note: s.songs.isEmpty ? "none on 3+ releases yet" : "releases")

        let artists = BarListChart()
        artists.bars = s.topArtists
        artists.format = { Self.hours($0) }
        artists.tip = { "\($0.label): \(Self.hours($0.value)) · \($0.detail)" }
        artists.onClick = { [weak self] in self?.onArtist?($0.id) }
        rows.append(row([songPanel, StatsPanel("Most hours of music", artists)]))

        let calendar = ShowCalendar()
        calendar.months = s.showMonths
        calendar.onClick = { [weak self] in self?.onYear?($0) }
        let growth = GrowthChart()
        growth.points = s.growth
        rows.append(row([StatsPanel("Shows by date of the concert", calendar), StatsPanel("Collection over time", growth, note: "by file date")]))

        for r in rows {
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            r.setContentHuggingPriority(.required, for: .vertical)
        }
        // Spare height (a page shorter than the window) goes here, not into the last row's panels.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(spacer)
    }
}
