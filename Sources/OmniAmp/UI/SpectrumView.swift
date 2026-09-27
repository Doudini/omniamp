import AppKit

/// Bar analyzer with peak-hold falloff. Colors are a bottom→top gradient.
final class SpectrumView: NSView {
    private var levels = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    private var peaks = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    var drawsBackground = false
    /// Segment colors (lit, unlit) for the current height, built once instead of every frame.
    private var palette: [(NSColor, NSColor)] = []

    override func mouseDown(with event: NSEvent) { Analyzer.toggle() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    func update(with bars: [Float]) {
        var changed = false
        for i in 0..<min(bars.count, levels.count) {
            let old = (levels[i], peaks[i])
            // Fast attack, smooth decay.
            levels[i] = bars[i] > levels[i] ? bars[i] : max(bars[i], levels[i] - 0.06)
            peaks[i] = levels[i] > peaks[i] ? levels[i] : max(0, peaks[i] - 0.015)
            changed = changed || old != (levels[i], peaks[i])
        }
        if changed { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if drawsBackground { Theme.lcd.setFill(); bounds.fill() }
        let n = levels.count
        let gap: CGFloat = 2
        let w = floor((bounds.width - gap * CGFloat(n - 1)) / CGFloat(n))
        let x0 = (bounds.width - (w * CGFloat(n) + gap * CGFloat(n - 1))) / 2
        let h = bounds.height - 2
        let segH: CGFloat = 2, segGap: CGFloat = 1
        let segments = Int(h / (segH + segGap))
        if palette.count != segments {
            palette = (0..<segments).map { s in
                let t = CGFloat(s) / CGFloat(max(segments - 1, 1))
                let c = Theme.spectrum(t)
                return (c, c.withAlphaComponent(0.07))
            }
        }
        for i in 0..<n {
            let x = x0 + CGFloat(i) * (w + gap)
            let lit = Int((CGFloat(levels[i]) * CGFloat(segments)).rounded())
            for s in 0..<segments {
                (s < lit ? palette[s].0 : palette[s].1).setFill()
                NSRect(x: x, y: 1 + CGFloat(s) * (segH + segGap), width: w, height: segH).fill()
            }
            if peaks[i] > 0.02 {
                NSColor(calibratedWhite: 0.9, alpha: 0.9).setFill()
                let py = 1 + min(CGFloat(segments - 1), (CGFloat(peaks[i]) * CGFloat(segments)).rounded()) * (segH + segGap)
                NSRect(x: x, y: py, width: w, height: 1).fill()
            }
        }
    }
}
