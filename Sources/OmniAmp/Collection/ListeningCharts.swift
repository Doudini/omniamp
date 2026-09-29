import AppKit

extension Dash {
    /// Categorical colors for artists (the dataviz reference palette, dark steps), checked on our cards: neighbours
    /// stay apart for color-blind eyes too. Fixed order; a ninth artist folds into "other" (gray).
    static let series: [NSColor] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500, 0xD55181, 0x008300, 0x9085E9, 0xE66767].map { rgb(UInt32($0)) }
    static let other = rgb(0x4A5A61)
}

/// Your top artists as a river through the years: each band's thickness is that artist's plays that year,
/// stacked around a middle line. Bands are labelled where they're wide enough (a legend lists them all);
/// hover shows the figures and highlights the band, click opens the artist.
final class RiverChart: StatsChart {
    var river = ListeningRiver() { didSet { needsDisplay = true } }
    var onArtist: ((String) -> Void)?
    private var hot: (series: Int, year: Int)? { didSet { if hot?.series != oldValue?.series || hot?.year != oldValue?.year { needsDisplay = true; updateTip() } } }
    private static let legendH: CGFloat = 30, axisH: CGFloat = 18

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 300) }

    private var plot: NSRect { NSRect(x: 8, y: 6, width: bounds.width - 16, height: bounds.height - Self.legendH - Self.axisH - 10) }
    /// The bands: artists in order, then "other".
    private var bands: [(name: String, key: String?, plays: [Int], color: NSColor)] {
        river.series.enumerated().map { i, s in (s.name, s.key, s.plays, Dash.series[i % Dash.series.count]) }
            + [("Other artists", nil, river.other, Dash.other)]
    }

    private func x(_ i: Int) -> CGFloat {
        let p = plot
        return river.years.count > 1 ? p.minX + p.width * CGFloat(i) / CGFloat(river.years.count - 1) : p.midX
    }

    /// Each band's top and bottom edge per year (view y), centred on the middle line.
    private func edges() -> [[(top: CGFloat, bottom: CGFloat)]] {
        let p = plot, b = bands
        let totals = river.years.indices.map { i in b.reduce(0) { $0 + $1.plays[i] } }
        let most = CGFloat(max(totals.max() ?? 1, 1))
        var out = Array(repeating: [(top: CGFloat, bottom: CGFloat)](), count: b.count)
        for i in river.years.indices {
            var y = p.midY - p.height * CGFloat(totals[i]) / most / 2
            for (j, band) in b.enumerated() {
                let h = p.height * CGFloat(band.plays[i]) / most
                out[j].append((y, y + h))
                y += h
            }
        }
        return out
    }

    private func path(_ e: [(top: CGFloat, bottom: CGFloat)]) -> NSBezierPath {
        let tops = e.indices.map { NSPoint(x: x($0), y: e[$0].top) }
        let bottoms = e.indices.reversed().map { NSPoint(x: x($0), y: e[$0].bottom) }
        let p = AreaChart.smoothPath(tops, floor: .greatestFiniteMagnitude)
        let back = AreaChart.smoothPath(bottoms, floor: .greatestFiniteMagnitude)
        p.line(to: bottoms[0])
        // Append the bottom edge (right to left) to close the band.
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 1..<back.elementCount {
            switch back.element(at: i, associatedPoints: &pts) {
            case .curveTo: p.curve(to: pts[2], controlPoint1: pts[0], controlPoint2: pts[1])
            case .lineTo: p.line(to: pts[0])
            default: break
            }
        }
        p.close()
        return p
    }

    override func draw(_ dirtyRect: NSRect) {
        guard river.years.count > 1 else {
            Self.sans("Not enough history yet.", 12, Dash.text3).draw(at: NSPoint(x: 8, y: 20))
            return
        }
        let e = edges(), b = bands
        // Year grid behind the river.
        let p = plot
        for (i, y) in river.years.enumerated() where river.years.count <= 12 || y % 5 == 0 || i == 0 || i == river.years.count - 1 {
            Dash.grid.setFill()
            NSRect(x: x(i), y: p.minY, width: 1, height: p.height).fill()
            let s = Self.text(String(y), 8.5, Dash.text3)
            s.draw(at: NSPoint(x: min(max(p.minX, x(i) - s.size().width / 2), bounds.width - s.size().width - 2), y: p.maxY + 4))
        }
        for (j, band) in b.enumerated() {
            let shape = path(e[j])
            band.color.withAlphaComponent(hot == nil || hot?.series == j ? 0.92 : 0.35).setFill()
            shape.fill()
            // A thin line in the card color between bands.
            Dash.card.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        // Direct labels: in the thickest year that has room and doesn't cover another label (thin bands rely on the legend).
        var placed: [NSRect] = []
        for (j, band) in b.enumerated() {
            let label = Self.sans(band.name, 11.5, Dash.text, .semibold)
            let w = label.size().width, lh = label.size().height
            let years = e[j].indices.sorted { e[j][$0].bottom - e[j][$0].top > e[j][$1].bottom - e[j][$1].top }
            for i in years {
                let h = e[j][i].bottom - e[j][i].top
                guard h >= 18 else { break }
                let cx = min(max(p.minX + 4, x(i) - w / 2), p.maxX - w - 4)
                let r = NSRect(x: cx, y: (e[j][i].top + e[j][i].bottom) / 2 - lh / 2, width: w, height: lh)
                guard !placed.contains(where: { $0.insetBy(dx: -6, dy: -2).intersects(r) }) else { continue }
                label.draw(at: r.origin)
                placed.append(r)
                break
            }
        }
        if let h = hot, h.year < river.years.count {
            Dash.text.withAlphaComponent(0.5).setFill()
            NSRect(x: x(h.year), y: p.minY, width: 1, height: p.height).fill()
        }
        // Legend: every band (the thin ones have no label in the river).
        var lx: CGFloat = 8
        let ly = bounds.height - Self.legendH + 8
        for band in b {
            let t = Self.sans(band.name, 11.5, Dash.text2)
            if lx + t.size().width + 24 > bounds.width { break }
            band.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: lx, y: ly + 3, width: 10, height: 10), xRadius: 3, yRadius: 3).fill()
            t.draw(at: NSPoint(x: lx + 15, y: ly))
            lx += t.size().width + 30
        }
    }

    // MARK: Hover and click

    private func hit(_ e: NSEvent) -> (series: Int, year: Int)? {
        guard river.years.count > 1 else { return nil }
        let pt = convert(e.locationInWindow, from: nil), p = plot
        guard p.insetBy(dx: -4, dy: 0).contains(pt) else { return nil }
        let at = max(0, min(CGFloat(river.years.count - 1), (pt.x - p.minX) / p.width * CGFloat(river.years.count - 1)))
        let i = Int(at.rounded())
        // The bands' edges where the pointer is, between the two years around it (they're drawn as curves there).
        let i0 = Int(at.rounded(.down)), i1 = min(river.years.count - 1, i0 + 1), t = at - CGFloat(i0)
        let e = edges()
        func edge(_ j: Int) -> (top: CGFloat, bottom: CGFloat) {
            (e[j][i0].top + (e[j][i1].top - e[j][i0].top) * t, e[j][i0].bottom + (e[j][i1].bottom - e[j][i0].bottom) * t)
        }
        guard let j = e.indices.first(where: { pt.y >= edge($0).top && pt.y <= edge($0).bottom }) else { return nil }
        return (j, i)
    }

    private func updateTip() {
        guard let h = hot else { toolTip = nil; return }
        let b = bands[h.series]
        let total = bands.reduce(0) { $0 + $1.plays[h.year] }
        let n = b.plays[h.year]
        toolTip = "\(river.years[h.year]) · \(b.name): \(n.formatted()) plays"
            + (total > 0 ? String(format: " (%.0f%% of the year)", Double(n) / Double(total) * 100) : "")
            + (b.key != nil ? " · click for the artist page" : "")
    }

    override func mouseMoved(with event: NSEvent) { hot = hit(event) }
    override func mouseExited(with event: NSEvent) { hot = nil }
    override func mouseDown(with event: NSEvent) {
        if let h = hit(event), let key = bands[h.series].key { onArtist?(key) }
    }
}

/// A short list of lines: a muted lead ("1991"), a white main text, a grey detail; each clickable.
final class RowListChart: StatsChart {
    struct Row {
        let lead: String
        let main: String
        let detail: String
        var color: NSColor? = nil
        var tip: String = ""
        var action: (() -> Void)? = nil
        /// The marker as an outline: something you don't have.
        var hollow = false
        /// A small button at the end of the row ("Download"), with its own action.
        var button: String? = nil
        var buttonAction: (() -> Void)? = nil
    }
    var rows: [Row] = [] { didSet { invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true } }
    var empty = "Nothing."
    static let rowHeight: CGFloat = 28
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: max(28, CGFloat(rows.count) * Self.rowHeight)) }

    private var mouse: NSPoint? { didSet { needsDisplay = true } }

    private func buttonText(_ r: Row) -> NSAttributedString? {
        r.button.map { Self.sans($0, 11.5, Dash.text, .medium) }
    }

    /// The row's button, right-aligned.
    private func buttonRect(_ i: Int) -> NSRect? {
        guard i < rows.count, let t = buttonText(rows[i]) else { return nil }
        let w = t.size().width + 22
        return NSRect(x: bounds.width - w - 4, y: CGFloat(i) * Self.rowHeight + 3, width: w, height: Self.rowHeight - 6)
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        super.mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        mouse = nil
        super.mouseExited(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = rows.indices.first(where: { buttonRect($0)?.contains(p) ?? false }), let a = rows[i].buttonAction { a(); return }
        super.mouseDown(with: event)
    }

    override func layoutRegions() {
        regions = rows.enumerated().map { i, r in
            Region(rect: NSRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight), tip: r.tip, action: r.action)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else {
            Self.sans(empty, 12, Dash.text3).draw(at: NSPoint(x: 6, y: 5))
            return
        }
        // Only the rows in view (a list can be thousands long).
        let first = max(0, Int(dirtyRect.minY / Self.rowHeight)), last = min(rows.count - 1, Int(dirtyRect.maxY / Self.rowHeight))
        guard first <= last else { return }
        for i in first...last {
            let r = rows[i]
            let y = CGFloat(i) * Self.rowHeight
            if hovered == i {
                Dash.cardRaised.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: y + 1, width: bounds.width, height: Self.rowHeight - 2), xRadius: 5, yRadius: 5).fill()
            }
            var x: CGFloat = 8
            if let c = r.color {
                if r.hollow {
                    c.setStroke()
                    let box = NSBezierPath(roundedRect: NSRect(x: x + 0.5, y: y + 10.5, width: 7, height: 7), xRadius: 2, yRadius: 2)
                    box.lineWidth = 1
                    box.stroke()
                } else {
                    c.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: y + 10, width: 8, height: 8), xRadius: 2, yRadius: 2).fill()
                }
                x += 16
            }
            let lead = Self.text(r.lead, 11, Dash.text3, bold: true)
            lead.draw(at: NSPoint(x: x, y: y + 6))
            x += max(46, lead.size().width + 12)
            let text = NSMutableAttributedString(attributedString: Self.sans(r.main, 12.5, Dash.text, .medium))
            if !r.detail.isEmpty { text.append(Self.sans("   " + r.detail, 11.5, Dash.text2)) }
            var right = bounds.width - 8
            if let b = buttonRect(i), let t = buttonText(r) {
                let over = mouse.map(b.contains) ?? false
                (over ? Dash.accent.withAlphaComponent(0.25) : Dash.cardRaised).setFill()
                let pill = NSBezierPath(roundedRect: b, xRadius: b.height / 2, yRadius: b.height / 2)
                pill.fill()
                (over ? Dash.accent.withAlphaComponent(0.6) : Dash.border).setStroke()
                pill.lineWidth = 1
                pill.stroke()
                t.draw(at: NSPoint(x: b.midX - t.size().width / 2, y: b.midY - t.size().height / 2))
                right = b.minX - 10
            }
            text.draw(with: NSRect(x: x, y: y + 5, width: right - x, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
