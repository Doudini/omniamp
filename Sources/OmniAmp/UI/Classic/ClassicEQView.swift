import AppKit

/// The 275×116 skinned equalizer window (EQMAIN.BMP).
final class ClassicEQView: SkinCanvasView {
    weak var controller: PlayerController?
    var onClose: (() -> Void)?
    var onPresets: ((NSEvent, NSView) -> Void)?

    private var draggingSlider: Int?      // -1 = preamp, 0...9 bands
    private var pressedOn = false
    private var pressedPresets = false
    private var pressedClose = false

    static let size = CGSize(width: 275, height: 116)
    override var intrinsicContentSize: NSSize { NSSize(width: Self.size.width * scale, height: Self.size.height * scale) }

    private static let onRect = CGRect(x: 14, y: 18, width: 26, height: 12)
    private static let presetsRect = CGRect(x: 217, y: 18, width: 44, height: 12)
    private static let closeRect = CGRect(x: 264, y: 3, width: 9, height: 9)

    private func sliderRect(_ i: Int) -> CGRect {
        CGRect(x: i < 0 ? 21 : 78 + CGFloat(i) * 18, y: 38, width: 14, height: 63)
    }

    private func gain(_ i: Int) -> Float {
        guard let s = controller?.eqSettings else { return 0 }
        return i < 0 ? s.preamp : s.bands[i]
    }

    // MARK: Drawing

    override func drawSkin(_ ctx: CGContext) {
        let s = skin
        guard s.has("eqmain") else {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(origin: .zero, size: Self.size))
            s.drawText("this skin has no equalizer", at: CGPoint(x: 70, y: 55), in: ctx)
            return
        }
        s.draw("eqmain", CGRect(x: 0, y: 0, width: 275, height: 116), at: .zero, in: ctx)
        let active = window?.isKeyWindow ?? false
        s.draw("eqmain", CGRect(x: 0, y: active ? 134 : 149, width: 275, height: 14), at: .zero, in: ctx)
        if pressedClose { s.draw("eqmain", CGRect(x: 0, y: 116, width: 9, height: 9), at: Self.closeRect.origin, in: ctx) }

        let on = controller?.eqSettings.enabled ?? false
        let onX: CGFloat = pressedOn ? (on ? 187 : 128) : (on ? 69 : 10)
        s.draw("eqmain", CGRect(x: onX, y: 119, width: 26, height: 12), at: Self.onRect.origin, in: ctx)
        s.draw("eqmain", CGRect(x: 35, y: 119, width: 32, height: 12), at: CGPoint(x: 40, y: 18), in: ctx) // AUTO (off)
        s.draw("eqmain", CGRect(x: 224, y: pressedPresets ? 176 : 164, width: 44, height: 12), at: Self.presetsRect.origin, in: ctx)

        drawGraph(ctx)
        for i in -1..<10 { drawSlider(i, ctx) }
    }

    private func drawSlider(_ i: Int, _ ctx: CGContext) {
        let r = sliderRect(i)
        let f = CGFloat((gain(i) + Equalizer.range) / (2 * Equalizer.range))   // 0 bottom … 1 top
        let k = Int((f * 27).rounded())
        skin.draw("eqmain", CGRect(x: 13 + (k % 14) * 15, y: 164 + (k / 14) * 65, width: 14, height: 63), at: r.origin, in: ctx)
        let ty = r.minY + ((1 - f) * 51).rounded()
        skin.draw("eqmain", CGRect(x: 0, y: draggingSlider == i ? 176 : 164, width: 11, height: 11), at: CGPoint(x: r.minX + 1, y: ty), in: ctx)
    }

    /// Response curve drawn with the skin's own graph line colors (one color per row).
    private func drawGraph(_ ctx: CGContext) {
        let origin = CGPoint(x: 86, y: 17)
        skin.draw("eqmain", CGRect(x: 0, y: 294, width: 113, height: 19), at: origin, in: ctx)
        guard let s = controller?.eqSettings else { return }
        let n = s.bands.count
        let width = 109
        var lastY: Int?
        for x in 0..<width {
            // Catmull-Rom through the band gains.
            let t = CGFloat(x) / CGFloat(width - 1) * CGFloat(n - 1)
            let i = min(n - 2, Int(t)), u = t - CGFloat(i)
            let p0 = CGFloat(s.bands[max(0, i - 1)]), p1 = CGFloat(s.bands[i])
            let p2 = CGFloat(s.bands[i + 1]), p3 = CGFloat(s.bands[min(n - 1, i + 2)])
            let v = 0.5 * ((2 * p1) + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u + (-p0 + 3 * p1 - 3 * p2 + p3) * u * u * u)
            let y = max(0, min(18, Int((9 - v / CGFloat(Equalizer.range) * 9).rounded())))
            // Fill vertical gaps so steep slopes stay connected.
            let from = lastY.map { min($0, y) } ?? y, to = lastY.map { max($0, y) } ?? y
            for yy in from...to {
                skin.draw("eqmain", CGRect(x: 115, y: 294 + yy, width: 1, height: 1),
                          at: CGPoint(x: origin.x + 2 + CGFloat(x), y: origin.y + CGFloat(yy)), in: ctx)
            }
            lastY = y
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = skinPoint(event)
        guard let c = controller else { return }
        if Self.closeRect.contains(p) {
            pressedClose = true
            let inside = trackButton(event, Self.closeRect) { self.pressedClose = $0 }
            if inside { onClose?() }
            return
        }
        if Self.onRect.contains(p) {
            pressedOn = true
            if trackButton(event, Self.onRect, { self.pressedOn = $0 }) {
                var s = c.eqSettings; s.enabled.toggle(); c.setEQ(s)
            }
            return
        }
        if Self.presetsRect.contains(p) {
            pressedPresets = true; needsDisplay = true
            onPresets?(event, self)
            pressedPresets = false; needsDisplay = true
            return
        }
        if let i = (-1..<10).first(where: { sliderRect($0).contains(p) }) {
            if event.clickCount == 2 { setGain(i, 0); return }
            draggingSlider = i
            track(event) { pt in
                let r = self.sliderRect(i)
                let f = 1 - (pt.y - r.minY - 5.5) / 51
                self.setGain(i, Float(max(0, min(1, f))) * 2 * Equalizer.range - Equalizer.range)
            }
            draggingSlider = nil
            needsDisplay = true
            return
        }
        window?.performDrag(with: event)
    }

    private func setGain(_ i: Int, _ g: Float) {
        guard let c = controller else { return }
        var s = c.eqSettings
        // Snap near zero like Winamp's center detent.
        let v = abs(g) < 0.6 ? 0 : g
        if i < 0 { s.preamp = v } else { s.bands[i] = v }
        c.setEQ(s)
    }

    private func track(_ event: NSEvent, _ update: (CGPoint) -> Void) {
        update(skinPoint(event))
        needsDisplay = true
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            update(skinPoint(e))
            needsDisplay = true
            displayIfNeeded()
            if e.type == .leftMouseUp { break }
        }
    }

    /// Press-and-release button tracking; returns true if released inside.
    private func trackButton(_ event: NSEvent, _ rect: CGRect, _ setPressed: @escaping (Bool) -> Void) -> Bool {
        var inside = true
        track(event) { pt in inside = rect.contains(pt); setPressed(inside) }
        setPressed(false)
        needsDisplay = true
        return inside
    }
}
