import AppKit

/// Bar analyzer with peak-hold falloff, or a Winamp-style oscilloscope.
///
/// Built from Core Animation layers so a frame costs a few layer-frame changes instead of redrawing:
/// the segmented bars are two pictures rendered once (all lit, all dim) and a mask whose bar heights
/// change; the oscilloscope is a shape layer with a wider, faint copy as its glow. The window server
/// composites it on the GPU, so the app does almost no work at 20 fps.
final class SpectrumView: NSView {
    private var levels = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    private var peaks = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)

    /// Oscilloscope samples (nil = spectrum mode).
    private var wave: [Float]?

    private let unlit = CALayer()
    private let lit = CALayer()
    private let litMask = CALayer()
    private var barMasks: [CALayer] = []
    private var peakLayers: [CALayer] = []
    private let scopeLine = CALayer()
    private let scopeGlow = CAShapeLayer()
    private let scopeTrace = CAShapeLayer()

    // Bar geometry, recomputed on resize.
    private var barX: [CGFloat] = []
    private var barW: CGFloat = 0
    private var segments = 0
    private var builtFor: (CGSize, CGFloat) = (.zero, 0)
    private static let segH: CGFloat = 2, segGap: CGFloat = 1, barGap: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let root = CALayer()
        lit.mask = litMask
        for l in [unlit, lit, scopeLine] { l.contentsGravity = .resize; root.addSublayer(l) }
        for _ in 0..<levels.count {
            let m = CALayer(); m.backgroundColor = NSColor.white.cgColor; m.anchorPoint = .zero
            litMask.addSublayer(m); barMasks.append(m)
            let p = CALayer(); p.backgroundColor = NSColor(calibratedWhite: 0.9, alpha: 0.9).cgColor; p.anchorPoint = .zero
            root.addSublayer(p); peakLayers.append(p)
        }
        scopeGlow.fillColor = nil
        scopeGlow.lineWidth = 4
        scopeGlow.lineJoin = .round
        scopeTrace.fillColor = nil
        scopeTrace.lineWidth = 1.5
        scopeTrace.lineJoin = .round
        root.addSublayer(scopeGlow)
        root.addSublayer(scopeTrace)
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

    func update(wave w: [Float]) {
        wave = w
        apply()
    }

    func update(with bars: [Float]) {
        let wasScope = wave != nil
        wave = nil
        var changed = wasScope
        for i in 0..<min(bars.count, levels.count) {
            let old = (levels[i], peaks[i])
            // Fast attack, smooth decay.
            levels[i] = bars[i] > levels[i] ? bars[i] : max(bars[i], levels[i] - 0.06)
            peaks[i] = levels[i] > peaks[i] ? levels[i] : max(0, peaks[i] - 0.015)
            changed = changed || old != (levels[i], peaks[i])
        }
        if changed { apply() }
    }

    /// Renders the lit/unlit segment pictures and places the bars for the current size.
    private func rebuildIfNeeded() {
        let scale = window?.backingScaleFactor ?? 2
        guard bounds.width > 0, bounds.height > 4, builtFor != (bounds.size, scale) else { return }
        builtFor = (bounds.size, scale)
        let n = levels.count
        barW = floor((bounds.width - Self.barGap * CGFloat(n - 1)) / CGFloat(n))
        let x0 = (bounds.width - (barW * CGFloat(n) + Self.barGap * CGFloat(n - 1))) / 2
        barX = (0..<n).map { x0 + CGFloat($0) * (barW + Self.barGap) }
        segments = Int((bounds.height - 2) / (Self.segH + Self.segGap))
        unlit.contents = segmentsImage(scale: scale) { Theme.spectrum($0).withAlphaComponent(0.07) }
        lit.contents = segmentsImage(scale: scale) { Theme.spectrum($0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [unlit, lit, litMask] { l.frame = bounds }
        scopeLine.frame = CGRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
        scopeLine.backgroundColor = Theme.phosphorGhost.cgColor
        scopeGlow.frame = bounds
        scopeTrace.frame = bounds
        scopeGlow.strokeColor = Theme.phosphor.withAlphaComponent(0.25).cgColor
        scopeTrace.strokeColor = Theme.phosphor.cgColor
        CATransaction.commit()
    }

    private func segmentsImage(scale: CGFloat, color: (CGFloat) -> NSColor) -> CGImage? {
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        for s in 0..<segments {
            ctx.setFillColor(color(CGFloat(s) / CGFloat(max(segments - 1, 1))).cgColor)
            let y = 1 + CGFloat(s) * (Self.segH + Self.segGap)
            for x in barX { ctx.fill(CGRect(x: x, y: y, width: barW, height: Self.segH)) }
        }
        return ctx.makeImage()
    }

    /// Moves the bar masks and peak markers, or sets the oscilloscope path.
    private func apply() {
        guard segments > 0, !barX.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scope = wave != nil
        for l in [unlit, lit] { l.isHidden = scope }
        for l in [scopeLine, scopeGlow, scopeTrace] as [CALayer] { l.isHidden = !scope }
        let step = Self.segH + Self.segGap
        for i in 0..<levels.count {
            let litSegs = Int((CGFloat(levels[i]) * CGFloat(segments)).rounded())
            barMasks[i].frame = CGRect(x: barX[i], y: 0, width: barW, height: scope ? 0 : 1 + CGFloat(litSegs) * step)
            let showPeak = !scope && peaks[i] > 0.02
            peakLayers[i].isHidden = !showPeak
            if showPeak {
                let py = 1 + min(CGFloat(segments - 1), (CGFloat(peaks[i]) * CGFloat(segments)).rounded()) * step
                peakLayers[i].frame = CGRect(x: barX[i], y: py, width: barW, height: 1)
            }
        }
        if let w = wave {
            let path = CGMutablePath()
            if w.count > 1 {
                let mid = bounds.midY, amp = bounds.height / 2 - 2
                for (i, v) in w.enumerated() {
                    let p = CGPoint(x: CGFloat(i) / CGFloat(w.count - 1) * bounds.width, y: mid + CGFloat(max(-1, min(1, v * 1.6))) * amp)
                    i == 0 ? path.move(to: p) : path.addLine(to: p)
                }
            }
            scopeGlow.path = path
            scopeTrace.path = path
        }
        CATransaction.commit()
    }
}
