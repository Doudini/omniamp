import AppKit

/// Bar analyzer with peak-hold falloff. Colors are a bottom→top gradient.
final class SpectrumView: NSView {
    private var levels = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    private var peaks = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    var drawsBackground = false

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
        for i in 0..<n {
            let x = x0 + CGFloat(i) * (w + gap)
            let lit = Int((CGFloat(levels[i]) * CGFloat(segments)).rounded())
            for s in 0..<segments {
                let t = CGFloat(s) / CGFloat(max(segments - 1, 1))
                let color = t < 0.6
                    ? NSColor(calibratedRed: 0.2 + t * 1.2, green: 1.0, blue: 0.3 - t * 0.4, alpha: 1)
                    : NSColor(calibratedRed: 1, green: 1.0 - (t - 0.6) * 2.0, blue: 0.1, alpha: 1)
                (s < lit ? color : color.withAlphaComponent(0.07)).setFill()
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
