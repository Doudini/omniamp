import AppKit

// The library's charts (see Dash for the tokens). Names and labels in text colors, numbers in Hack, data in the
// theme's accent (amounts) or a kind's color (identity); recessive grid and axes. Every mark has a tooltip, and
// most open the library at what they show.

/// A chart with hover tooltips and clickable marks. Subclasses fill `regions` in `layoutRegions()` and draw.
class StatsChart: NSView, NSViewToolTipOwner {
    struct Region {
        let rect: NSRect
        let tip: String
        let action: (() -> Void)?
    }
    var regions: [Region] = []
    var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    /// Grows to fill its card when the row is taller (line and column charts); lists and maps don't.
    var stretches: Bool { false }

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

    /// Numbers and labels: Hack.
    static func text(_ s: String, _ size: CGFloat, _ color: NSColor, bold: Bool = false) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: Fonts.hack(size, bold: bold), .foregroundColor: color])
    }

    /// Names: the system font.
    static func sans(_ s: String, _ size: CGFloat, _ color: NSColor, _ weight: NSFont.Weight = .regular) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: Dash.font(size, weight), .foregroundColor: color])
    }

    /// A bar with rounded ends, in the accent unless given a color (full strength when hovered).
    static func bar(_ r: NSRect, color: NSColor? = nil, strength: CGFloat = 0.85, hot: Bool, radius: CGFloat = 3) {
        guard r.width > 0.5, r.height > 0.5 else { return }
        (color ?? Dash.accent).withAlphaComponent(hot ? 1 : strength).setFill()
        let rad = min(radius, r.width / 2, r.height / 2)
        NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).fill()
    }

    /// A round number at or above `v` for an axis top (1, 2, 2.5, 5 × 10ⁿ).
    static func niceMax(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let p = pow(10, floor(log10(v))), f = v / p
        let n: Double = f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10
        return n * p
    }

    /// "1.2k", "35", "3.4M".
    static func short(_ v: Double) -> String {
        let a = abs(v)
        func trim(_ x: Double, _ unit: String) -> String {
            x == x.rounded() || x >= 10 ? String(format: "%.0f", x) + unit : String(format: "%.1f", x) + unit
        }
        if a >= 1_000_000 { return trim(v / 1_000_000, "M") }
        if a >= 1000 { return trim(v / 1000, "k") }
        return a == a.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// How many grid lines make round steps up to `top` (a niceMax): 50 → 5 (10s), 20 → 4 (5s), 2.5k → 5 (500s).
    static func gridLines(_ top: Double) -> Int {
        guard top > 0 else { return 4 }
        let m = top / pow(10, floor(log10(top)))
        return m == 2 ? 4 : 5
    }

    /// Horizontal grid lines with their values on the left; returns the plot area right of them.
    static func grid(in r: NSRect, top: Double, lines: Int? = nil, labelWidth: CGFloat = 34) -> NSRect {
        let lines = lines ?? gridLines(top)
        let plot = NSRect(x: r.minX + labelWidth, y: r.minY, width: r.width - labelWidth, height: r.height)
        for i in 0...lines {
            let v = top * Double(i) / Double(lines)
            let y = plot.maxY - plot.height * CGFloat(i) / CGFloat(lines)
            (i == 0 ? Dash.border : Dash.grid).setFill()
            NSRect(x: plot.minX, y: y, width: plot.width, height: 1).fill()
            let s = text(short(v), 8.5, Dash.text3)
            s.draw(at: NSPoint(x: plot.minX - s.size().width - 6, y: y - 6))
        }
        return plot
    }
}

/// Label, bar, value per row: names in white, the value in Hack, details grey.
final class BarListChart: StatsChart {
    var bars: [LibraryStats.Bar] = [] { didSet { invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true } }
    var format: (Double) -> String = { Int($0).formatted() }
    var tip: (LibraryStats.Bar) -> String = { "\($0.label): \(Int($0.value).formatted())" }
    var onClick: ((LibraryStats.Bar) -> Void)?
    /// A color per bar (what kind of recording it is); nil: the accent.
    var color: ((LibraryStats.Bar) -> NSColor?)?
    var footnote: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    static let rowHeight: CGFloat = 26

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(bars.count) * Self.rowHeight + (footnote == nil ? 0 : 20))
    }

    private let nameFont = Dash.font(12.5)

    /// The name column: as wide as the longest name, at most 45% of the width.
    private var labelWidth: CGFloat {
        let widest = bars.map { ($0.label as NSString).size(withAttributes: [.font: nameFont]).width }.max() ?? 0
        return min(widest + 14, bounds.width * 0.45)
    }

    private func valueText(_ b: LibraryStats.Bar) -> NSAttributedString {
        let v = NSMutableAttributedString(attributedString: Self.text(format(b.value), 11, Dash.text, bold: true))
        if let c = b.count { v.append(Self.text(" (\(c.formatted()))", 10.5, Dash.text3)) }
        if !b.detail.isEmpty { v.append(Self.sans("  " + b.detail, 10.5, Dash.text3)) }
        return v
    }

    /// The figures' column: as wide as the widest, so the numbers all start right after the bars.
    private var valueWidth: CGFloat { min((bars.map { valueText($0).size().width }.max() ?? 0) + 4, bounds.width * 0.4) }

    override func layoutRegions() {
        regions = bars.enumerated().map { i, b in
            Region(rect: NSRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight),
                   tip: tip(b), action: onClick.map { f in { f(b) } })
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let most = max(bars.map(\.value).max() ?? 1, 0.0001)
        let lw = labelWidth, vw = valueWidth
        let barX = lw + 8, barW = max(10, bounds.width - barX - vw - 10)
        for (i, b) in bars.enumerated() {
            let y = CGFloat(i) * Self.rowHeight
            let hot = hovered == i
            if hot {
                Dash.cardRaised.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: y + 1, width: bounds.width, height: Self.rowHeight - 2), xRadius: 5, yRadius: 5).fill()
            }
            NSAttributedString(string: b.label, attributes: [.font: hot ? Dash.font(12.5, .medium) : nameFont, .foregroundColor: Dash.text])
                .draw(with: NSRect(x: 6, y: y + 5, width: lw - 6, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            // A faint track, then the bar.
            Dash.grid.setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: y + 9, width: barW, height: 8), xRadius: 4, yRadius: 4).fill()
            Self.bar(NSRect(x: barX, y: y + 9, width: max(3, barW * CGFloat(b.value / most)), height: 8), color: color?(b), hot: hot, radius: 4)
            valueText(b).draw(with: NSRect(x: barX + barW + 10, y: y + 5, width: vw, height: 17),
                              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if let footnote {
            Self.sans(footnote, 11, Dash.text3).draw(at: NSPoint(x: 6, y: CGFloat(bars.count) * Self.rowHeight + 3))
        }
    }
}

/// Values per year as rounded columns on a light grid, decades underneath; optionally a smoothed trend line
/// of the same values (same unit, same axis) in the second accent.
final class YearsChart: StatsChart {
    var years: [(year: Int, releases: Int)] = [] { didSet { needsLayout = true; needsDisplay = true } }
    var onClick: ((Int) -> Void)?
    /// What the columns count ("release", "play").
    var unit = "release"
    /// The columns' color when they're all one kind of thing (shows); nil: the accent.
    var color: NSColor?
    /// A 3-year moving average over the columns.
    var trend = false
    override var stretches: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 170) }

    private var span: ClosedRange<Int> {
        guard let lo = years.first?.year, let hi = years.last?.year else { return 2000...2001 }
        return lo...max(hi, lo + 1)
    }
    private var top: Double { Self.niceMax(Double(years.map(\.releases).max() ?? 1)) }
    private var plot: NSRect { NSRect(x: 0, y: 14, width: bounds.width, height: bounds.height - 34) }
    private func area() -> NSRect {
        let full = plot, labelWidth: CGFloat = 34
        return NSRect(x: full.minX + labelWidth, y: full.minY, width: full.width - labelWidth, height: full.height)
    }
    private var step: CGFloat { area().width / CGFloat(span.count) }

    override func layoutRegions() {
        let p = area(), s = step
        regions = years.map { y in
            let x = p.minX + CGFloat(y.year - span.lowerBound) * s
            return Region(rect: NSRect(x: x, y: p.minY - 14, width: max(s, 3), height: p.height + 14),
                          tip: "\(y.year): \(y.releases.formatted()) \(unit)\(y.releases == 1 ? "" : "s")",
                          action: onClick.map { f in { f(y.year) } })
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Self.grid(in: plot, top: top), s = step
        let gap: CGFloat = s > 6 ? max(1, s * 0.2) : 0.5
        var centres: [NSPoint] = []
        for (i, y) in years.enumerated() {
            let h = max(2, p.height * CGFloat(Double(y.releases) / top))
            let x = p.minX + CGFloat(y.year - span.lowerBound) * s
            let hot = hovered == i
            // Rounded at the top only: a column standing on the axis.
            let r = NSRect(x: x + gap / 2, y: p.maxY - h, width: max(1.5, s - gap), height: h)
            (color ?? Dash.accent).withAlphaComponent(hot ? 1 : 0.8).setFill()
            let rad = min(3, r.width / 2)
            let path = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad)
            path.append(NSBezierPath(rect: NSRect(x: r.minX, y: r.maxY - rad, width: r.width, height: rad)))
            path.fill()
            if hot {
                let v = Self.text(y.releases.formatted(), 10, Dash.text, bold: true)
                v.draw(at: NSPoint(x: min(max(p.minX, r.midX - v.size().width / 2), bounds.width - v.size().width), y: r.minY - 15))
            }
            centres.append(NSPoint(x: r.midX, y: 0))
        }
        if trend, years.count >= 3 {
            var pts: [NSPoint] = []
            for i in years.indices {
                let win = years[max(0, i - 1)...min(years.count - 1, i + 1)]
                let avg = Double(win.reduce(0) { $0 + $1.releases }) / Double(win.count)
                pts.append(NSPoint(x: centres[i].x, y: p.maxY - p.height * CGFloat(avg / top)))
            }
            let line = AreaChart.smoothPath(pts, floor: p.maxY)
            Dash.accent2.setStroke()
            line.lineWidth = 2
            line.stroke()
        }
        // Decades (or every year when there are few).
        let every = span.count <= 12 ? 1 : span.count <= 30 ? 5 : 10
        var y0 = (span.lowerBound + every - 1) / every * every
        while y0 <= span.upperBound {
            let x = p.minX + CGFloat(y0 - span.lowerBound) * s
            Self.text(every == 10 ? "\(y0)s" : "\(y0)", 8.5, Dash.text3).draw(at: NSPoint(x: x, y: p.maxY + 5))
            y0 += every
        }
    }
}

/// A line over time with a soft gradient under it: smooth, dots when there are few points, the peak labelled,
/// a guide under the mouse.
class AreaChart: StatsChart {
    struct Point {
        let x: Double
        let y: Double
        /// For the tooltip: "March 2008".
        let label: String
    }
    var points: [Point] = [] { didSet { needsLayout = true; needsDisplay = true } }
    var unit = "plays"
    var height: CGFloat = 170 { didSet { invalidateIntrinsicContentSize() } }
    var color: NSColor?
    /// Axis labels along x: value → text (years by default).
    var xTicks: ((ClosedRange<Double>) -> [(Double, String)])?
    override var stretches: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }

    private var top: Double { Self.niceMax(points.map(\.y).max() ?? 1) }
    private var xSpan: ClosedRange<Double> {
        guard let lo = points.first?.x, let hi = points.last?.x, hi > lo else { return 0...1 }
        return lo...hi
    }
    private var frameRect: NSRect { NSRect(x: 0, y: 16, width: bounds.width - 8, height: bounds.height - 36) }
    private var plotRect: NSRect {
        let f = frameRect
        return NSRect(x: f.minX + 34, y: f.minY, width: f.width - 34, height: f.height)
    }

    private func pos(_ p: Point, in r: NSRect) -> NSPoint {
        NSPoint(x: r.minX + r.width * CGFloat((p.x - xSpan.lowerBound) / (xSpan.upperBound - xSpan.lowerBound)),
                y: r.maxY - r.height * CGFloat(p.y / top))
    }

    /// Catmull-Rom through the points as Béziers, never dipping below `floor` (counts don't go negative).
    static func smoothPath(_ pts: [NSPoint], floor: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 2 else { pts.dropFirst().forEach { path.line(to: $0) }; return path }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
            let c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(floor, p1.y + (p2.y - p0.y) / 6))
            let c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(floor, p2.y - (p3.y - p1.y) / 6))
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        return path
    }

    override func layoutRegions() {
        let r = plotRect
        let xs = points.map { pos($0, in: r).x }
        regions = points.indices.map { i in
            let lo = i > 0 ? (xs[i - 1] + xs[i]) / 2 : xs[i] - 4, hi = i + 1 < xs.count ? (xs[i] + xs[i + 1]) / 2 : xs[i] + 4
            return Region(rect: NSRect(x: lo, y: 0, width: max(1, hi - lo), height: bounds.height),
                          tip: "\(points[i].label): \(Int(points[i].y).formatted()) \(unit)", action: nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else {
            Self.sans(points.isEmpty ? "Nothing yet." : "Not enough history yet.", 12, Dash.text3).draw(at: NSPoint(x: 4, y: 20))
            return
        }
        let r = Self.grid(in: frameRect, top: top)
        let c = color ?? Dash.accent
        let pts = points.map { pos($0, in: r) }
        let line = Self.smoothPath(pts, floor: r.maxY)
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: pts.last!.x, y: r.maxY))
        area.line(to: NSPoint(x: pts[0].x, y: r.maxY))
        area.close()
        NSGradient(starting: c.withAlphaComponent(0.34), ending: c.withAlphaComponent(0.02))?.draw(in: area, angle: 90)
        c.setStroke()
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.stroke()
        // Dots when they can be told apart; the peak labelled.
        let dots = points.count <= 40
        let peak = points.indices.max { points[$0].y < points[$1].y } ?? 0
        for (i, p) in pts.enumerated() where dots || i == peak || i == hovered {
            let rad: CGFloat = i == hovered ? 5 : 3.5
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2))
            c.setFill()
            dot.fill()
            Dash.card.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
        let peakLabel = Self.text(Self.short(points[peak].y), 10, Dash.text, bold: true)
        let pp = pts[peak]
        peakLabel.draw(at: NSPoint(x: min(max(r.minX, pp.x - peakLabel.size().width / 2), bounds.width - peakLabel.size().width - 2),
                                   y: max(0, pp.y - 18)))
        if let h = hovered, h < pts.count {
            Dash.text3.withAlphaComponent(0.6).setFill()
            NSRect(x: pts[h].x, y: r.minY, width: 1, height: r.height).fill()
        }
        // X axis: years unless told otherwise.
        let ticks = xTicks?(xSpan) ?? Self.yearTicks(xSpan)
        var lastX = -CGFloat.infinity
        for (v, label) in ticks {
            let x = r.minX + r.width * CGFloat((v - xSpan.lowerBound) / (xSpan.upperBound - xSpan.lowerBound))
            let s = Self.text(label, 8.5, Dash.text3)
            let lx = min(max(r.minX, x - s.size().width / 2), bounds.width - s.size().width - 2)
            guard lx - lastX > s.size().width + 8 else { continue }
            s.draw(at: NSPoint(x: lx, y: r.maxY + 5))
            lastX = lx
        }
    }

    static func yearTicks(_ span: ClosedRange<Double>) -> [(Double, String)] {
        let years = span.upperBound - span.lowerBound
        let step = years <= 8 ? 1.0 : years <= 20 ? 2 : years <= 50 ? 5 : 10
        var y = (span.lowerBound / step).rounded(.up) * step, out: [(Double, String)] = []
        while y <= span.upperBound { out.append((y, String(Int(y)))); y += step }
        return out
    }
}

/// The collection's size over time (running total of tracks, by the date of the files).
final class GrowthChart: AreaChart {
    var growth: [(month: String, total: Int)] = [] {
        didSet {
            let f = DateFormatter(), out = DateFormatter()
            f.dateFormat = "yyyy-MM"
            out.dateFormat = "MMMM yyyy"
            points = growth.compactMap { g in
                let p = g.month.split(separator: "-").compactMap { Int($0) }
                guard p.count == 2 else { return nil }
                return Point(x: Double(p[0]) + Double(p[1] - 1) / 12, y: Double(g.total), label: f.date(from: g.month).map(out.string) ?? g.month)
            }
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        unit = "tracks"
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Parts of a whole as a ring: a gap between slices, the total (or a share) in the middle, a legend with
/// percentages beside it. Slices carry their own colors (kinds) or take the accent's family.
final class DonutChart: StatsChart {
    struct Slice {
        let label: String
        let value: Double
        let color: NSColor
        var id: String? = nil
    }
    var slices: [Slice] = [] { didSet { needsLayout = true; needsDisplay = true } }
    var center: (value: String, caption: String)?
    var unit = ""
    var onClick: ((Slice) -> Void)?
    /// Beside the ring when the legend fits there, under it otherwise (nothing cut off); the height follows.
    private var stacked: Bool {
        let legend = 52 + (slices.map { Self.sans($0.label, 12, Dash.text2).size().width }.max() ?? 0)
        return bounds.width < 150 + 30 + legend
    }
    private static let rowH: CGFloat = 22
    private lazy var height: NSLayoutConstraint = {
        let c = heightAnchor.constraint(equalToConstant: 160)
        c.isActive = true
        return c
    }()

    override func layout() {
        let h = stacked ? min(150, bounds.width * 0.6) + 14 + CGFloat(slices.count) * Self.rowH : max(150, CGFloat(slices.count) * Self.rowH + 10)
        if bounds.width > 0, abs(height.constant - h) > 0.5 { height.constant = h }
        super.layout()
    }

    /// Two shades of the accent and a neutral: for a two- or three-part split that isn't about kinds.
    static var pair: [NSColor] { [Dash.accent, Dash.accent2, Dash.text3] }

    private var ring: (c: NSPoint, r: CGFloat) {
        if stacked {
            let d = min(150, bounds.width * 0.6)
            return (NSPoint(x: bounds.midX, y: d / 2 + 2), d / 2 - 4)
        }
        let r = min(bounds.height, bounds.width * 0.36) / 2 - 6
        return (NSPoint(x: r + 8, y: bounds.height / 2), r)
    }
    private var total: Double { max(slices.reduce(0) { $0 + $1.value }, 0.000_001) }

    private func angles() -> [(start: CGFloat, end: CGFloat)] {
        var a: CGFloat = -90, out: [(CGFloat, CGFloat)] = []
        for s in slices {
            let sweep = 360 * CGFloat(s.value / total)
            out.append((a, a + sweep))
            a += sweep
        }
        return out
    }

    /// Where the legend starts (x) and its first row (y).
    private var legendOrigin: NSPoint {
        let (c, r) = ring
        if stacked {
            // Centred as a block under the ring.
            let w = slices.map { 48 + (Self.sans($0.label, 12, Dash.text2).size().width) }.max() ?? 0
            return NSPoint(x: max(4, (bounds.width - w) / 2), y: c.y + r + 18)
        }
        let h = CGFloat(slices.count) * Self.rowH
        return NSPoint(x: c.x + r + 22, y: (bounds.height - h) / 2 + 2)
    }

    override func layoutRegions() {
        let o = legendOrigin
        regions = slices.enumerated().map { i, s in
            let pct = s.value / total * 100
            return Region(rect: NSRect(x: o.x - 4, y: o.y + CGFloat(i) * Self.rowH - 3, width: bounds.width - o.x, height: 20),
                          tip: "\(s.label): \(Int(s.value).formatted()) \(unit) · \(String(format: "%.1f", pct))%",
                          action: onClick.map { f in { f(s) } })
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let (c, r) = ring
        let width: CGFloat = max(10, r * 0.28)
        let gapDeg: CGFloat = slices.filter { $0.value > 0 }.count > 1 ? 1.5 : 0
        for (i, (s, a)) in zip(slices, angles()).enumerated() where s.value > 0 {
            let hot = hovered == i
            let path = NSBezierPath()
            // Flipped view: angles run clockwise.
            path.appendArc(withCenter: c, radius: r + (hot ? 2 : 0), startAngle: a.start + gapDeg / 2, endAngle: max(a.start + gapDeg / 2, a.end - gapDeg / 2))
            path.lineWidth = hot ? width + 3 : width
            s.color.withAlphaComponent(hovered == nil || hot ? 1 : 0.55).setStroke()
            path.stroke()
        }
        if let center {
            let v = Self.text(center.value, 17, Dash.text, bold: true), cap = Self.sans(center.caption, 10.5, Dash.text2)
            v.draw(at: NSPoint(x: c.x - v.size().width / 2, y: c.y - v.size().height + 2))
            cap.draw(at: NSPoint(x: c.x - cap.size().width / 2, y: c.y + 2))
        }
        let o = legendOrigin
        for (i, s) in slices.enumerated() {
            let y = o.y + CGFloat(i) * Self.rowH
            s.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: o.x, y: y + 3, width: 10, height: 10), xRadius: 3, yRadius: 3).fill()
            let share = s.value / total * 100
            let pct = Self.text(share > 0 && share < 1 ? "<1%" : String(format: "%.0f%%", share), 11, Dash.text, bold: true)
            pct.draw(at: NSPoint(x: o.x + 16, y: y))
            Self.sans(s.label, 12, hovered == i ? Dash.text : Dash.text2)
                .draw(with: NSRect(x: o.x + 48, y: y, width: max(10, bounds.width - o.x - 48), height: 17),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

/// Shows owned by month of the concert: a column per year, a row per month; stronger red for more shows.
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
            Self.sans("No dated shows yet.", 12, Dash.text3).draw(at: NSPoint(x: 4, y: 4))
            return
        }
        for m in stride(from: 0, to: 12, by: 3) {
            Self.text(Self.monthNames[m], 8, Dash.text3).draw(at: NSPoint(x: 0, y: rect(col: 0, month: m).minY + cell / 2 - 6))
        }
        let most = CGFloat(max(months.values.max() ?? 1, 1))
        let hotRect = hovered.flatMap { $0 < regions.count ? regions[$0].rect : nil }
        let bottom = rect(col: 0, month: 11).maxY
        let red = Theme.kind(.show)
        var lastLabel = -CGFloat.infinity
        for (col, y) in years.enumerated() {
            let x = rect(col: col, month: 0).minX
            if (y % 5 == 0 || col == 0 || col == years.count - 1), x - lastLabel > 30 {
                Self.text(String(y), 8, Dash.text3).draw(at: NSPoint(x: x, y: bottom + 3))
                lastLabel = x
            }
            for m in 0..<12 {
                let r = rect(col: col, month: m)
                let n = CGFloat(months[String(format: "%04d-%02d", y, m + 1)] ?? 0)
                if n == 0 {
                    Dash.cardRaised.setFill()
                } else {
                    // Four steps of one hue: a single show is still clearly lit.
                    let step = min(3, Int((n / most * 4).rounded(.up)) - 1)
                    red.withAlphaComponent([0.4, 0.6, 0.8, 1][max(0, step)]).setFill()
                }
                NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5).fill()
                if r == hotRect {
                    Dash.text.setStroke()
                    NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3).stroke()
                }
            }
        }
        let ly = bottom + 18
        var x = Self.labelW
        Self.sans("fewer", 10, Dash.text3).draw(at: NSPoint(x: x, y: ly - 2))
        x += 36
        for a in [0.4, 0.6, 0.8, 1.0] {
            red.withAlphaComponent(a).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: ly, width: 10, height: 10), xRadius: 2.5, yRadius: 2.5).fill()
            x += 13
        }
        Self.sans("more", 10, Dash.text3).draw(at: NSPoint(x: x + 3, y: ly - 2))
    }
}

/// A card around a chart: an accent title, an optional grey note, the chart.
final class StatsPanel: NSView {
    init(_ title: String, _ content: NSView, note: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        Dash.styleCard(self)
        let t = NSTextField(labelWithAttributedString: Dash.title(title))
        let n = Dash.label(note ?? "", Dash.font(11), Dash.text3)
        n.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [t, n, content] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            t.topAnchor.constraint(equalTo: topAnchor, constant: 14), t.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            n.firstBaselineAnchor.constraint(equalTo: t.firstBaselineAnchor), n.leadingAnchor.constraint(equalTo: t.trailingAnchor, constant: 10),
            n.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            // At most: a card stretched to its row's height keeps its content at the top.
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14),
        ])
        let h = content.intrinsicContentSize.height
        if let chart = content as? StatsChart, chart.stretches, h > 0 {
            // Line and column charts fill the card: at least their own height, as tall as the row makes it.
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: h).isActive = true
            content.setContentHuggingPriority(.defaultLow, for: .vertical)
            let fill = content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
            fill.priority = .init(700)
            fill.isActive = true
        } else if h > 0, !(content is DonutChart) {
            // Everything else is exactly as tall as its content (the page is rebuilt when the figures change).
            content.heightAnchor.constraint(equalToConstant: h).isActive = true
        }
        if let calendar = content as? ShowCalendar { calendar.needsLayout = true }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A flipped container, so the page scrolls from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A row of the page grid: each card spans `span` of `columns` equal columns (12 pt gaps), so cards line up
/// with the rows above and below; all as tall as the tallest, their content at the top.
func dashGrid(_ items: [(NSView, Int)], columns: Int = 3, gap: CGFloat = 12) -> NSView {
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    var previous: NSView?
    for (v, span) in items {
        v.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(v)
        let s = CGFloat(span), c = CGFloat(columns)
        // span × column + the gaps inside it; a column is (row − all gaps) / columns.
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: row.topAnchor),
            v.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: previous?.trailingAnchor ?? row.leadingAnchor, constant: previous == nil ? 0 : gap),
            v.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: s / c, constant: (s - 1) * gap - gap * (c - 1) * s / c),
        ])
        previous = v
    }
    // As short as the tallest card allows.
    let hug = row.heightAnchor.constraint(equalToConstant: 0)
    hug.priority = .init(200)
    hug.isActive = true
    return row
}

/// A row of cards; `weights` share the width (default equal).
func dashRow(_ views: [NSView], weights: [CGFloat]? = nil, spacing: CGFloat = 12) -> NSView {
    let r = NSStackView(views: views)
    r.alignment = .top
    r.spacing = spacing
    for v in views { v.setContentHuggingPriority(.required, for: .vertical) }
    if let w = weights, w.count == views.count, views.count > 1 {
        r.distribution = .fill
        let total = w.reduce(0, +)
        for (v, x) in zip(views.dropFirst(), w.dropFirst()) {
            v.widthAnchor.constraint(equalTo: views[0].widthAnchor, multiplier: x / w[0]).isActive = true
        }
        _ = total
    } else {
        r.distribution = .fillEqually
    }
    return r
}

/// A page heading: big white title, grey line under it.
func dashHeading(_ title: String, _ subtitle: String?) -> NSView {
    let t = Dash.label(title, Dash.font(22, .semibold), Dash.text)
    var views: [NSView] = [t]
    if let subtitle { views.append(Dash.label(subtitle, Dash.font(12.5), Dash.text2)) }
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = 3
    return s
}

/// The Stats page: key figures, then charts in cards. Clicks go back to the library through the callbacks.
final class StatsPage: NSScrollView {
    var onGenre: ((String) -> Void)?
    var onYear: ((Int) -> Void)?
    var onArtist: ((String) -> Void)?
    var onSearch: ((String) -> Void)?
    /// A song: its artist key and title key.
    var onSong: ((String, String) -> Void)?
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
        stack.spacing = 12
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
        stack.addArrangedSubview(Dash.label("Counting…", Dash.font(13), Dash.text2))
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func hours(_ h: Double) -> String { h >= 100 ? "\(Int(h.rounded())) h" : String(format: "%.1f h", h) }

    func show(_ s: LibraryStats) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let days = s.seconds / 86400
        let lossless = s.tracks > 0 ? Double(s.losslessTracks) / Double(s.tracks) : 0
        var rows: [NSView] = [dashHeading("Your collection", "\(s.artists.formatted()) artists, \(s.releases.formatted()) releases, "
                                          + "\(s.tracks.formatted()) tracks · \(Self.size(s.bytes)) on disk")]

        // Added per year (by file date), for "this year vs last year".
        var perYear: [Int: Int] = [:]
        var previous = 0
        for g in s.growth {
            if let y = Int(g.month.prefix(4)) { perYear[y, default: 0] += g.total - previous }
            previous = g.total
        }
        let thisYear = Calendar.current.component(.year, from: Date())
        let added = perYear[thisYear] ?? 0, before = perYear[thisYear - 1] ?? 0
        let delta: (String, Bool)? = before > 0 ? (String(format: "%.0f%% vs %d", abs(Double(added - before) / Double(before) * 100), thisYear - 1),
                                                   added >= before) : nil
        let spark = (thisYear - 9...thisYear).map { Double(perYear[$0] ?? 0) }
        let display = HiFiDisplay()
        let gb = Double(s.bytes) / 1_000_000_000
        display.items = [
            .init(value: s.tracks.formatted(), label: "tracks",
                  tip: s.unplayable > 0 ? "\(s.tracks.formatted()) tracks, \(s.unplayable.formatted()) of them in formats OmniAmp can't play" : nil),
            .init(value: s.releases.formatted(), label: "releases"),
            .init(value: s.artists.formatted(), label: "artists"),
            .init(value: days >= 1 ? String(format: "%.1f", days) : String(format: "%.1f", s.seconds / 3600), label: days >= 1 ? "days of music" : "hours of music",
                  tip: "\(Int(s.seconds / 3600).formatted()) hours: that long to play everything once"),
            .init(value: gb >= 1000 ? String(format: "%.2f", gb / 1000) : String(format: "%.1f", gb), label: gb >= 1000 ? "TB on disk" : "GB on disk"),
            .init(value: added.formatted(), label: "added \(thisYear)", tip: "\(added.formatted()) tracks added in \(thisYear), by the date of the files",
                  meter: spark, delta: delta),
        ]
        rows.append(dashGrid([(display, 1)], columns: 1))

        // Release years, and what kind of recordings.
        let totalYears = s.years.reduce(0) { $0 + $1.releases }
        var cut = 0, early = 0
        while cut < s.years.count, Double(early + s.years[cut].releases) < Double(totalYears) * 0.01 { early += s.years[cut].releases; cut += 1 }
        let years = YearsChart()
        years.years = Array(s.years.dropFirst(cut))
        years.trend = true
        years.onClick = { [weak self] in self?.onYear?($0) }
        let decade = Dictionary(grouping: s.years, by: { $0.year / 10 * 10 }).mapValues { $0.reduce(0) { $0 + $1.releases } }
            .max { $0.value < $1.value }
        let kinds = DonutChart()
        kinds.slices = s.kinds.compactMap { b in
            Int(b.id).flatMap(ReleaseKind.init(rawValue:)).map { DonutChart.Slice(label: $0.title, value: b.value, color: Theme.kind($0)) }
        }
        kinds.center = (s.releases.formatted(), "releases")
        kinds.unit = "releases"
        let official = s.kinds.filter { Int($0.id).flatMap(ReleaseKind.init(rawValue:))?.isOfficial ?? false }.reduce(0) { $0 + $1.value }
        rows.append(dashGrid([
            (StatsPanel("Release years", years, note: (decade.map { "most from the \($0.key)s" } ?? "") + (early > 0 ? " · \(early) earlier not shown" : "")
                        + " · line: 3-year average · click a year"), 2),
            (StatsPanel("Kinds of recordings", kinds, note: s.releases > 0 ? String(format: "%.0f%% official", official / Double(s.releases) * 100) : nil), 1),
        ]))

        // Growth, and how it's stored.
        let growth = GrowthChart()
        growth.growth = s.growth
        let formats = DonutChart()
        let lossy = s.tracks - s.losslessTracks - s.unplayable
        formats.slices = [DonutChart.Slice(label: "Lossless", value: Double(s.losslessTracks), color: Dash.accent),
                          DonutChart.Slice(label: "Lossy", value: Double(max(0, lossy)), color: Dash.accent2)]
            + (s.unplayable > 0 ? [DonutChart.Slice(label: "Can't play", value: Double(s.unplayable), color: Dash.text3)] : [])
        formats.center = (String(format: "%.0f%%", lossless * 100), "lossless")
        formats.unit = "tracks"
        let formatList = s.formats.prefix(3).map { "\($0.label) \(Int($0.value).formatted())" }.joined(separator: " · ")
        rows.append(dashGrid([
            (StatsPanel("Collection over time", growth, note: "tracks, by file date"), 2),
            (StatsPanel("Lossless or lossy", formats, note: formatList), 1),
        ]))

        // Lists in thirds.
        let genres = BarListChart()
        genres.bars = Array(s.genres.prefix(12))
        genres.tip = { "\($0.label): \(Int($0.value).formatted()) tracks on \(($0.count ?? 0).formatted()) releases · click to open" }
        genres.onClick = { [weak self] in self?.onGenre?($0.id) }
        if s.otherGenres > 0 { genres.footnote = "+ \(s.otherGenres) more genres" }
        let songs = BarListChart()
        songs.bars = s.songs.map { .init(id: $0.artistKey + "\u{1}" + $0.titleKey, label: "\($0.title) — \($0.artist)", value: Double($0.versions),
                                         count: $0.unofficial > 0 ? $0.unofficial : nil) }
        songs.format = { "\(Int($0))×" }
        songs.tip = { "\($0.label): on \(Int($0.value)) releases\($0.count.map { ", \($0) of them unofficial" } ?? "") · click to see them all" }
        songs.onClick = { [weak self] b in
            let parts = b.id.components(separatedBy: "\u{1}")
            if parts.count == 2 { self?.onSong?(parts[0], parts[1]) }
        }
        let artists = BarListChart()
        artists.bars = s.topArtists
        artists.format = { Self.hours($0) }
        artists.tip = { "\($0.label): \(Self.hours($0.value)) on \(($0.count ?? 0).formatted()) releases · click for the artist page" }
        artists.onClick = { [weak self] in self?.onArtist?($0.id) }
        rows.append(dashGrid([(StatsPanel("Genres", genres, note: s.genres.isEmpty ? "no genre tags yet" : "tracks (releases)"), 1),
                              (StatsPanel("Most versions", songs, note: s.songs.isEmpty ? "none on 3+ releases yet" : "releases (unofficial)"), 1),
                              (StatsPanel("Most hours", artists, note: "hours (releases)"), 1)]))

        let calendar = ShowCalendar()
        calendar.months = s.showMonths
        calendar.onClick = { [weak self] in self?.onYear?($0) }
        rows.append(dashGrid([(StatsPanel("Shows by date of the concert", calendar, note: "\(s.shows.formatted()) shows · click a year"), 3)]))

        for r in rows {
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            r.setContentHuggingPriority(.required, for: .vertical)
        }
        stack.setCustomSpacing(16, after: rows[0])
        Dash.relaxWidth(stack)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(spacer)
        // From the top (or, test hook OMNIAMP_STATS_SCROLL, further down for screenshots).
        layoutSubtreeIfNeeded()
        let y = ProcessInfo.processInfo.environment["OMNIAMP_STATS_SCROLL"].flatMap(Double.init) ?? 0
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }
}

/// The key figures as the front panel of hi-fi gear: one dark glass display, glowing digits over their unlit
/// segments, tiny caps labels, thin separators; a trend as a small level meter. Hover a figure for details.
final class HiFiDisplay: StatsChart {
    struct Item {
        let value: String
        let label: String
        var tip: String? = nil
        /// Recent values for a level meter beside the figure (oldest first).
        var meter: [Double]? = nil
        /// A change against before ("25% vs 2025").
        var delta: (text: String, up: Bool)? = nil
    }
    var items: [Item] = [] { didSet { needsLayout = true; needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 96) }

    private func cell(_ i: Int) -> NSRect {
        let w = bounds.width / CGFloat(max(items.count, 1))
        return NSRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height)
    }

    override func layoutRegions() {
        regions = items.indices.map { i in Region(rect: cell(i), tip: items[i].tip ?? "\(items[i].value) \(items[i].label.lowercased())", action: nil) }
    }

    private static func isNumeric(_ s: String) -> Bool { s.allSatisfy { $0.isNumber || ".,'’ –-".contains($0) } }

    /// The figures' size: as large as the widest number fits its cell (30 pt down to 14), the same for all numbers.
    /// A name (not a number) doesn't count: it's cut to its column instead.
    private func digitSize() -> CGFloat {
        let room = bounds.width / CGFloat(max(items.count, 1)) - 28
        var size: CGFloat = 30
        while size > 14, items.contains(where: { Self.isNumeric($0.value)
                && ($0.value as NSString).size(withAttributes: [.font: Dash.mono(size, bold: true)]).width + ($0.meter == nil ? 0 : 30) > room }) {
            size -= 1
        }
        return size
    }

    override func draw(_ dirtyRect: NSRect) {
        let glass = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        // Dark glass, a faint sheen at the top, scanlines.
        Theme.lcd.setFill()
        glass.fill()
        NSGraphicsContext.saveGraphicsState()
        glass.addClip()
        NSGradient(starting: NSColor.white.withAlphaComponent(0.05), ending: .clear)?
            .draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.45), angle: 90)
        NSColor.black.withAlphaComponent(0.18).setFill()
        var y: CGFloat = 1
        while y < bounds.height { NSRect(x: 0, y: y, width: bounds.width, height: 1).fill(); y += 3 }
        NSGraphicsContext.restoreGraphicsState()
        Dash.border.setStroke()
        glass.lineWidth = 1
        glass.stroke()

        let size = digitSize()
        // The block (figure, then label) centred in the panel.
        let top = ((bounds.height - (size * 1.25 + 6 + 12)) / 2).rounded()
        let glow = NSShadow()
        glow.shadowColor = Theme.phosphor.withAlphaComponent(0.55)
        glow.shadowBlurRadius = 8
        glow.shadowOffset = .zero
        for (i, item) in items.enumerated() {
            let r = cell(i)
            if i > 0 {
                Theme.phosphorDim.withAlphaComponent(0.25).setFill()
                NSRect(x: r.minX, y: 16, width: 1, height: bounds.height - 32).fill()
            }
            let text = item.value
            let x = r.minX + 16, room = r.width - 26
            let numeric = Self.isNumeric(text)
            // A name: a size between the numbers' and 15 pt, and cut to its column (never into the next).
            var font = Dash.mono(size, bold: true)
            if !numeric {
                var ns = size
                while ns > 15, (text as NSString).size(withAttributes: [.font: Dash.mono(ns, bold: true)]).width > room { ns -= 1 }
                font = Dash.mono(ns, bold: true)
            }
            let textTop = top + (size - font.pointSize) * 0.8
            // Unlit segments behind the digits (a real LCD shows its 8s faintly).
            if numeric {
                let ghost = String(text.map { $0.isNumber ? "8" : $0 })
                NSAttributedString(string: ghost, attributes: [.font: font, .foregroundColor: Theme.phosphor.withAlphaComponent(0.07)])
                    .draw(at: NSPoint(x: x, y: textTop))
            }
            NSGraphicsContext.saveGraphicsState()
            glow.set()
            let lit = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: hovered == i ? Theme.current : Theme.phosphor])
            lit.draw(with: NSRect(x: x, y: textTop, width: room, height: font.pointSize * 1.4),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSGraphicsContext.restoreGraphicsState()
            // The level meter: bars of the recent values, the last one brightest.
            if let m = item.meter, let hi = m.max(), hi > 0 {
                let w = lit.size().width, bars = m.suffix(6)
                let mx = x + w + 10, mh = size * 0.8
                for (j, v) in bars.enumerated() {
                    let h = max(2, mh * CGFloat(v / hi))
                    Theme.phosphor.withAlphaComponent(j == bars.count - 1 ? 0.95 : 0.4).setFill()
                    NSRect(x: mx + CGFloat(j) * 4, y: top + size * 1.1 - h, width: 3, height: h).fill()
                }
            }
            var label = item.label.uppercased()
            if item.delta != nil { label += "  " }
            let l = NSMutableAttributedString(string: label, attributes: [.font: Dash.mono(9, bold: true), .foregroundColor: Theme.phosphorDim, .kern: 0.8])
            if let d = item.delta {
                l.append(NSAttributedString(string: (d.up ? "▲ " : "▼ ") + d.text, attributes: [.font: Dash.mono(9, bold: true),
                                                                                              .foregroundColor: d.up ? Dash.up : Dash.down]))
            }
            l.draw(with: NSRect(x: x, y: top + size * 1.25 + 6, width: r.width - 22, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
