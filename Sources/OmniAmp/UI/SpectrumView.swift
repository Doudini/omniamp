import AppKit

/// The visualizer on the modern LCD, like a hi-fi analyzer: segmented bars with peak hold over a small
/// frequency scale, a Winamp-style oscilloscope, or left/right level meters over a dB scale.
///
/// Built from Core Animation layers so a frame costs a few layer-frame changes instead of redrawing:
/// segmented bars and meters are pictures rendered once (all lit, all dim) plus masks whose sizes change;
/// the oscilloscope is a shape layer with a wider, faint copy as its glow. The window server composites
/// it on the GPU, so the app does almost no work at 20 fps.
final class SpectrumView: NSView {
    private enum Shown { case bars, scope, meters }
    private var shown = Shown.bars

    private var levels = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    private var peaks = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    /// Frames a peak has been held, then how fast it falls (it speeds up, like a hi-fi analyzer).
    private var peakHold = [Int](repeating: 0, count: SpectrumAnalyzer.barCount)
    private var peakFall = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    private var meter: [Float] = [0, 0]
    private var meterPeak: [Float] = [0, 0]
    private var meterHold = [0, 0]

    /// Oscilloscope samples.
    private var wave: [Float] = []

    private let unlit = CALayer()
    private let lit = CALayer()
    private let litMask = CALayer()
    private var barMasks: [CALayer] = []
    private var peakLayers: [CALayer] = []
    private let meterUnlit = CALayer()
    private let meterLit = CALayer()
    private let meterMask = CALayer()
    private var meterMasks: [CALayer] = []
    private var meterPeaks: [CALayer] = []
    private let scopeLine = CALayer()
    private let scopeGlow = CAShapeLayer()
    private let scopeTrace = CAShapeLayer()
    private var freqLabels: [CATextLayer] = []
    private var dbLabels: [CATextLayer] = []
    private var channelLabels: [CATextLayer] = []

    // Geometry, recomputed on resize.
    private var barX: [CGFloat] = []
    private var barW: CGFloat = 0
    private var segments = 0
    private var area = CGRect.zero        // where bars / meters live (above the scale)
    private var meterRows: [CGRect] = []
    private var meterSegs = 0
    private var builtFor: (CGSize, CGFloat) = (.zero, 0)
    private static let segH: CGFloat = 2, segGap: CGFloat = 1, barGap: CGFloat = 2
    private static let scaleH: CGFloat = 8
    private static let meterSegW: CGFloat = 2, meterGapW: CGFloat = 1, meterLabelW: CGFloat = 8

    /// Scale marks: frequencies (the analyzer's bands run 40 Hz … 16 kHz on a log scale) and meter dB.
    private static let freqMarks: [(String, Float)] = [("60", 60), ("250", 250), ("1K", 1000), ("4K", 4000), ("16K", 16000)]
    private static let dbMarks: [(String, Float)] = [("-30", -30), ("-20", -20), ("-10", -10), ("0", 0)]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let root = CALayer()
        lit.mask = litMask
        meterLit.mask = meterMask
        for l in [unlit, lit, meterUnlit, meterLit, scopeLine] { l.contentsGravity = .resize; root.addSublayer(l) }
        func bar(_ color: CGColor) -> CALayer {
            let l = CALayer(); l.backgroundColor = color; l.anchorPoint = .zero; return l
        }
        let peakColor = NSColor(calibratedWhite: 0.9, alpha: 0.9).cgColor
        for _ in 0..<levels.count {
            let m = bar(NSColor.white.cgColor); litMask.addSublayer(m); barMasks.append(m)
            let p = bar(peakColor); root.addSublayer(p); peakLayers.append(p)
        }
        for _ in 0..<2 {
            let m = bar(NSColor.white.cgColor); meterMask.addSublayer(m); meterMasks.append(m)
            let p = bar(peakColor); root.addSublayer(p); meterPeaks.append(p)
        }
        scopeGlow.fillColor = nil
        scopeGlow.lineWidth = 4
        scopeGlow.lineJoin = .round
        scopeTrace.fillColor = nil
        scopeTrace.lineWidth = 1.5
        scopeTrace.lineJoin = .round
        root.addSublayer(scopeGlow)
        root.addSublayer(scopeTrace)
        func label(_ s: String) -> CATextLayer {
            let t = CATextLayer()
            t.string = s
            t.font = Fonts.hack(6.5) as CTFont
            t.fontSize = 6.5
            t.alignmentMode = .center
            t.anchorPoint = CGPoint(x: 0.5, y: 0)
            root.addSublayer(t)
            return t
        }
        freqLabels = Self.freqMarks.map { label($0.0) }
        dbLabels = Self.dbMarks.map { label($0.0) }
        channelLabels = ["L", "R"].map { label($0) }
        root.actions = ["contents": NSNull()]
        return root
    }

    override func mouseDown(with event: NSEvent) { Analyzer.toggle() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func layout() {
        super.layout()
        rebuildIfNeeded()
        apply()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        builtFor = (.zero, 0)
        needsLayout = true
    }

    // MARK: Updates (20 fps while visible and playing)

    func update(wave w: [Float]) {
        shown = .scope
        wave = w
        apply()
    }

    func update(with bars: [Float]) {
        let changed = shown != .bars
        shown = .bars
        var moved = changed
        for i in 0..<min(bars.count, levels.count) {
            let old = (levels[i], peaks[i])
            // Fast attack, smooth decay.
            levels[i] = bars[i] > levels[i] ? bars[i] : max(bars[i], levels[i] - 0.06)
            // Peak hold: hangs ~0.6 s, then falls faster and faster.
            if levels[i] >= peaks[i] {
                peaks[i] = levels[i]; peakHold[i] = 0; peakFall[i] = 0
            } else if peakHold[i] < 12 {
                peakHold[i] += 1
            } else {
                peakFall[i] = min(0.08, peakFall[i] + 0.004)
                peaks[i] = max(levels[i], peaks[i] - peakFall[i])
            }
            moved = moved || old != (levels[i], peaks[i])
        }
        if moved { apply() }
    }

    func update(levels l: (left: Float, right: Float)) {
        shown = .meters
        for (i, v) in [l.left, l.right].enumerated() {
            meter[i] = v > meter[i] ? v : max(v, meter[i] - 0.04)
            if meter[i] >= meterPeak[i] {
                meterPeak[i] = meter[i]; meterHold[i] = 0
            } else if meterHold[i] < 20 {
                meterHold[i] += 1
            } else {
                meterPeak[i] = max(meter[i], meterPeak[i] - 0.02)
            }
        }
        apply()
    }

    // MARK: Layout

    /// Renders the lit/unlit pictures and places bars, meters and scale labels for the current size.
    private func rebuildIfNeeded() {
        let scale = window?.backingScaleFactor ?? 2
        guard bounds.width > 0, bounds.height > Self.scaleH + 6, builtFor != (bounds.size, scale) else { return }
        builtFor = (bounds.size, scale)
        area = CGRect(x: 0, y: Self.scaleH + 1, width: bounds.width, height: bounds.height - Self.scaleH - 1)

        // Spectrum bars.
        let n = levels.count
        barW = floor((area.width - Self.barGap * CGFloat(n - 1)) / CGFloat(n))
        let x0 = (area.width - (barW * CGFloat(n) + Self.barGap * CGFloat(n - 1))) / 2
        barX = (0..<n).map { x0 + CGFloat($0) * (barW + Self.barGap) }
        segments = Int((area.height - 1) / (Self.segH + Self.segGap))
        unlit.contents = picture(scale: scale) { ctx in self.drawBars(ctx) { Theme.spectrum($0).withAlphaComponent(0.07) } }
        lit.contents = picture(scale: scale) { ctx in self.drawBars(ctx) { Theme.spectrum($0) } }

        // Level meters: two rows, "L"/"R" in front.
        let rowH = max(4, floor((area.height - 6) / 2))
        let mx = Self.meterLabelW + 2
        meterRows = [CGRect(x: mx, y: area.minY + area.height / 2 + 2, width: area.width - mx - 2, height: rowH),
                     CGRect(x: mx, y: area.minY + area.height / 2 - 2 - rowH, width: area.width - mx - 2, height: rowH)]
        meterSegs = Int((meterRows[0].width + Self.meterGapW) / (Self.meterSegW + Self.meterGapW))
        meterUnlit.contents = picture(scale: scale) { ctx in self.drawMeters(ctx) { Self.meterColor($0).withAlphaComponent(0.08) } }
        meterLit.contents = picture(scale: scale) { ctx in self.drawMeters(ctx) { Self.meterColor($0) } }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [unlit, lit, litMask, meterUnlit, meterLit, meterMask] { l.frame = bounds }
        scopeLine.frame = CGRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
        scopeLine.backgroundColor = Theme.phosphorGhost.cgColor
        scopeGlow.frame = bounds
        scopeTrace.frame = bounds
        scopeGlow.strokeColor = Theme.phosphor.withAlphaComponent(0.25).cgColor
        scopeTrace.strokeColor = Theme.phosphor.cgColor
        let labelColor = Theme.phosphorDim.cgColor
        for l in freqLabels + dbLabels + channelLabels {
            l.foregroundColor = labelColor
            l.contentsScale = scale
            l.bounds = CGRect(x: 0, y: 0, width: 22, height: Self.scaleH)
        }
        for (i, m) in Self.freqMarks.enumerated() {
            // Band b spans 40·400^(b/n) … 40·400^((b+1)/n) Hz.
            let b = CGFloat(log(m.1 / 40) / log(400)) * CGFloat(n)
            let x = min(area.width - 8, max(8, x0 + b * (barW + Self.barGap)))
            freqLabels[i].position = CGPoint(x: x, y: -1)
        }
        for (i, m) in Self.dbMarks.enumerated() {
            let f = CGFloat((m.1 + 40) / 40)
            let x = min(bounds.width - 6, max(meterRows[0].minX + 6, meterRows[0].minX + f * meterRows[0].width))
            dbLabels[i].position = CGPoint(x: x, y: -1)
        }
        for (i, row) in meterRows.enumerated() {
            channelLabels[i].bounds = CGRect(x: 0, y: 0, width: Self.meterLabelW, height: Self.scaleH)
            channelLabels[i].position = CGPoint(x: Self.meterLabelW / 2, y: row.midY - Self.scaleH / 2)
        }
        CATransaction.commit()
    }

    private func picture(scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        return ctx.makeImage()
    }

    private func drawBars(_ ctx: CGContext, color: (CGFloat) -> NSColor) {
        for s in 0..<segments {
            ctx.setFillColor(color(CGFloat(s) / CGFloat(max(segments - 1, 1))).cgColor)
            let y = area.minY + 1 + CGFloat(s) * (Self.segH + Self.segGap)
            for x in barX { ctx.fill(CGRect(x: x, y: y, width: barW, height: Self.segH)) }
        }
    }

    private func drawMeters(_ ctx: CGContext, color: (CGFloat) -> NSColor) {
        for s in 0..<meterSegs {
            ctx.setFillColor(color(CGFloat(s) / CGFloat(max(meterSegs - 1, 1))).cgColor)
            for row in meterRows {
                ctx.fill(CGRect(x: row.minX + CGFloat(s) * (Self.meterSegW + Self.meterGapW), y: row.minY, width: Self.meterSegW, height: row.height))
            }
        }
    }

    /// Meter colors like a tape deck's: the theme's phosphor up to -10 dB, then amber, then red near 0 dB.
    private static func meterColor(_ t: CGFloat) -> NSColor {
        let db = -40 + 40 * t
        if db >= -3 { return NSColor(calibratedRed: 1, green: 0.25, blue: 0.2, alpha: 1) }
        if db >= -10 { return NSColor(calibratedRed: 1, green: 0.72, blue: 0.2, alpha: 1) }
        return Theme.phosphor
    }

    // MARK: Frame

    /// Moves the masks and peak markers, or sets the oscilloscope path.
    private func apply() {
        guard segments > 0, !barX.isEmpty, meterRows.count == 2 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bars = shown == .bars, scope = shown == .scope, meters = shown == .meters
        for l in [unlit, lit] { l.isHidden = !bars }
        for l in freqLabels { l.isHidden = !bars }
        for l in [meterUnlit, meterLit] { l.isHidden = !meters }
        for l in dbLabels + channelLabels + meterPeaks { l.isHidden = !meters }
        for l in [scopeLine, scopeGlow, scopeTrace] as [CALayer] { l.isHidden = !scope }

        if bars {
            let step = Self.segH + Self.segGap
            for i in 0..<levels.count {
                let litSegs = Int((CGFloat(levels[i]) * CGFloat(segments)).rounded())
                barMasks[i].frame = CGRect(x: barX[i], y: area.minY, width: barW, height: 1 + CGFloat(litSegs) * step)
                let showPeak = peaks[i] > 0.02
                peakLayers[i].isHidden = !showPeak
                if showPeak {
                    let py = area.minY + 1 + min(CGFloat(segments - 1), (CGFloat(peaks[i]) * CGFloat(segments)).rounded()) * step
                    peakLayers[i].frame = CGRect(x: barX[i], y: py, width: barW, height: 1)
                }
            }
        } else {
            peakLayers.forEach { $0.isHidden = true }
        }
        if meters {
            let step = Self.meterSegW + Self.meterGapW
            for (i, row) in meterRows.enumerated() {
                let segs = Int((CGFloat(meter[i]) * CGFloat(meterSegs)).rounded())
                meterMasks[i].frame = CGRect(x: row.minX, y: row.minY, width: CGFloat(segs) * step, height: row.height)
                let ps = min(meterSegs - 1, Int((CGFloat(meterPeak[i]) * CGFloat(meterSegs)).rounded()))
                meterPeaks[i].isHidden = meterPeak[i] < 0.02
                meterPeaks[i].frame = CGRect(x: row.minX + CGFloat(ps) * step, y: row.minY, width: Self.meterSegW, height: row.height)
            }
        }
        if scope {
            let path = CGMutablePath()
            if wave.count > 1 {
                let mid = bounds.midY, amp = bounds.height / 2 - 2
                for (i, v) in wave.enumerated() {
                    let p = CGPoint(x: CGFloat(i) / CGFloat(wave.count - 1) * bounds.width, y: mid + CGFloat(max(-1, min(1, v * 1.6))) * amp)
                    i == 0 ? path.move(to: p) : path.addLine(to: p)
                }
            }
            scopeGlow.path = path
            scopeTrace.path = path
        }
        CATransaction.commit()
    }
}
