import AppKit

/// Borderless window used for the skinned windows.
final class ClassicWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .miniaturizable],
                   backing: .buffered, defer: false)
        isOpaque = true
        hasShadow = true
        backgroundColor = .black
        acceptsMouseMovedEvents = true
    }
}

/// Base for skinned views: flipped, draws in skin pixels scaled by `scale`, no smoothing.
class SkinCanvasView: NSView {
    var skin: Skin { didSet { needsDisplay = true } }
    var scale: CGFloat { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    init(skin: Skin, scale: CGFloat) {
        self.skin = skin
        self.scale = scale
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Mouse location in skin pixels.
    func skinPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / scale, y: p.y / scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        ctx.scaleBy(x: scale, y: scale)
        drawSkin(ctx)
    }

    func drawSkin(_ ctx: CGContext) {}

    // File drops: media → playlist, .wsz → skin.
    var onDrop: (([URL]) -> Void)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

/// Clickable regions of the main window, in skin pixels (Winamp 2.x layout).
private enum MainHit: Equatable {
    case options, minimize, shade, close
    case prev, play, pause, stop, next, eject
    case shuffle, repeatAll, eq, playlist
    case seek, volume, balance, time, titlebar, none
}

/// The 275×116 skinned main window.
final class ClassicMainView: SkinCanvasView {
    weak var controller: PlayerController?
    var playlistVisible = true { didSet { needsDisplay = true } }
    var onTogglePlaylist: (() -> Void)?
    var eqVisible = false { didSet { needsDisplay = true } }
    var onToggleEQ: (() -> Void)?
    var onMenu: ((NSEvent, NSView) -> Void)?

    private var pressed: MainHit = .none
    private var pressedInside = false
    private var seekDrag: Double?
    private var volumeDrag = false
    private var showRemaining = UserDefaults.standard.bool(forKey: "classicRemaining")
    private var marqueeOffset = 0
    private var tick = 0
    private var levels = [Float](repeating: 0, count: 19)
    private var peaks = [Float](repeating: 0, count: 19)

    static let size = CGSize(width: 275, height: 116)
    override var intrinsicContentSize: NSSize { NSSize(width: Self.size.width * scale, height: Self.size.height * scale) }

    private static let rects: [(MainHit, CGRect)] = [
        (.options, CGRect(x: 6, y: 3, width: 9, height: 9)),
        (.minimize, CGRect(x: 244, y: 3, width: 9, height: 9)),
        (.shade, CGRect(x: 254, y: 3, width: 9, height: 9)),
        (.close, CGRect(x: 264, y: 3, width: 9, height: 9)),
        (.prev, CGRect(x: 16, y: 88, width: 23, height: 18)),
        (.play, CGRect(x: 39, y: 88, width: 23, height: 18)),
        (.pause, CGRect(x: 62, y: 88, width: 23, height: 18)),
        (.stop, CGRect(x: 85, y: 88, width: 23, height: 18)),
        (.next, CGRect(x: 108, y: 88, width: 22, height: 18)),
        (.eject, CGRect(x: 136, y: 89, width: 22, height: 16)),
        (.shuffle, CGRect(x: 164, y: 89, width: 47, height: 15)),
        (.repeatAll, CGRect(x: 210, y: 89, width: 28, height: 15)),
        (.eq, CGRect(x: 219, y: 58, width: 23, height: 12)),
        (.playlist, CGRect(x: 242, y: 58, width: 23, height: 12)),
        (.seek, CGRect(x: 16, y: 72, width: 248, height: 10)),
        (.volume, CGRect(x: 107, y: 57, width: 68, height: 13)),
        (.balance, CGRect(x: 177, y: 57, width: 38, height: 13)),
        (.time, CGRect(x: 36, y: 26, width: 63, height: 13)),
        (.titlebar, CGRect(x: 0, y: 0, width: 275, height: 14)),
    ]

    private func hit(_ p: CGPoint) -> MainHit {
        Self.rects.first { $0.1.contains(p) }?.0 ?? .none
    }

    // MARK: Animation

    func advance() {
        tick += 1
        guard let c = controller else { return }
        let bars = c.player.state == .playing ? c.player.spectrum.bars() : [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
        for i in 0..<19 {
            let v = bars[min(bars.count - 1, i * bars.count / 19)]
            levels[i] = v > levels[i] ? v : max(v, levels[i] - 0.07)
            peaks[i] = levels[i] > peaks[i] ? levels[i] : max(0, peaks[i] - 0.012)
        }
        if tick % 4 == 0 { marqueeOffset += 1 }
        needsDisplay = true
    }

    func resetMarquee() { marqueeOffset = 0 }

    // MARK: Drawing

    override func drawSkin(_ ctx: CGContext) {
        let s = skin
        s.draw("main", CGRect(x: 0, y: 0, width: 275, height: 116), at: .zero, in: ctx)
        let active = window?.isKeyWindow ?? true

        // Title bar + its buttons.
        s.draw("titlebar", CGRect(x: 27, y: active ? 0 : 15, width: 275, height: 14), at: .zero, in: ctx)
        func tb(_ h: MainHit, _ src: CGPoint, _ srcPressed: CGPoint, _ dst: CGPoint) {
            let p = pressed == h && pressedInside
            s.draw("titlebar", CGRect(origin: p ? srcPressed : src, size: CGSize(width: 9, height: 9)), at: dst, in: ctx)
        }
        tb(.options, CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 9), CGPoint(x: 6, y: 3))
        tb(.minimize, CGPoint(x: 9, y: 0), CGPoint(x: 9, y: 9), CGPoint(x: 244, y: 3))
        tb(.shade, CGPoint(x: 0, y: 18), CGPoint(x: 9, y: 18), CGPoint(x: 254, y: 3))
        tb(.close, CGPoint(x: 18, y: 0), CGPoint(x: 18, y: 9), CGPoint(x: 264, y: 3))
        s.draw("titlebar", CGRect(x: 304, y: 0, width: 8, height: 43), at: CGPoint(x: 10, y: 22), in: ctx) // clutterbar

        guard let c = controller else { return }
        let st = c.player.state

        // Play state indicator.
        let psrc: CGFloat = st == .playing ? 0 : (st == .paused ? 9 : 18)
        s.draw("playpaus", CGRect(x: psrc, y: 0, width: 9, height: 9), at: CGPoint(x: 26, y: 28), in: ctx)
        if st == .playing { s.draw("playpaus", CGRect(x: 39, y: 0, width: 3, height: 9), at: CGPoint(x: 24, y: 28), in: ctx) }
        else if st == .paused { s.draw("playpaus", CGRect(x: 36, y: 0, width: 3, height: 9), at: CGPoint(x: 24, y: 28), in: ctx) }

        drawTime(ctx, c)
        drawVisualizer(ctx, active: st == .playing)

        // Marquee.
        let title: String
        if let i = c.currentIndex, i < c.tracks.count { title = c.title(for: i) } else { title = "OmniAmp - drop files or a folder here" }
        drawMarquee(ctx, title)

        if st != .stopped {
            // Winamp's fields are 3 and 2 characters wide; hi-res values get a compact form.
            if let k = c.currentKbps {
                let t = k < 1000 ? String(k) : (k < 10000 ? String(format: "%.1f", Double(k) / 1000) : "\(k / 1000)k")
                s.drawText(String(t.prefix(3)).leftPad(3), at: CGPoint(x: 111, y: 43), in: ctx)
            }
            if let k = c.currentKHz { s.drawText((k < 100 ? String(k) : "hi").leftPad(2), at: CGPoint(x: 156, y: 43), in: ctx) }
        }
        let ch = st == .stopped ? 0 : c.player.channelCount
        s.draw("monoster", CGRect(x: 29, y: ch == 1 ? 0 : 12, width: 27, height: 12), at: CGPoint(x: 212, y: 41), in: ctx)
        s.draw("monoster", CGRect(x: 0, y: ch >= 2 ? 0 : 12, width: 29, height: 12), at: CGPoint(x: 239, y: 41), in: ctx)

        // Volume + balance.
        let vol = Double(c.player.volume)
        let vi = Int((vol * 27).rounded())
        s.draw("volume", CGRect(x: 0, y: vi * 15, width: 68, height: 13), at: CGPoint(x: 107, y: 57), in: ctx)
        let vx = 107 + (vol * (68 - 14)).rounded()
        s.draw("volume", CGRect(x: volumeDrag ? 0 : 15, y: 422, width: 14, height: 11), at: CGPoint(x: vx, y: 58), in: ctx)
        let bal = s.has("balance") ? "balance" : "volume"
        s.draw(bal, CGRect(x: 9, y: 0, width: 38, height: 13), at: CGPoint(x: 177, y: 57), in: ctx)
        s.draw(bal, CGRect(x: 15, y: 422, width: 14, height: 11), at: CGPoint(x: 177 + 12, y: 58), in: ctx)

        // EQ / PL toggles.
        let eqP = pressed == .eq && pressedInside, plP = pressed == .playlist && pressedInside
        s.draw("shufrep", CGRect(x: eqP ? 46 : 0, y: eqVisible ? 73 : 61, width: 23, height: 12), at: CGPoint(x: 219, y: 58), in: ctx)
        s.draw("shufrep", CGRect(x: plP ? 69 : 23, y: playlistVisible ? 73 : 61, width: 23, height: 12), at: CGPoint(x: 242, y: 58), in: ctx)

        // Position bar.
        s.draw("posbar", CGRect(x: 0, y: 0, width: 248, height: 10), at: CGPoint(x: 16, y: 72), in: ctx)
        let d = c.player.duration
        if st != .stopped, d > 0 {
            let f = seekDrag ?? min(1, c.player.currentTime / d)
            s.draw("posbar", CGRect(x: seekDrag != nil ? 278 : 248, y: 0, width: 29, height: 10),
                   at: CGPoint(x: 16 + (f * (248 - 29)).rounded(), y: 72), in: ctx)
        }

        // Transport buttons.
        let cb: [(MainHit, CGRect)] = [
            (.prev, CGRect(x: 0, y: 0, width: 23, height: 18)), (.play, CGRect(x: 23, y: 0, width: 23, height: 18)),
            (.pause, CGRect(x: 46, y: 0, width: 23, height: 18)), (.stop, CGRect(x: 69, y: 0, width: 23, height: 18)),
            (.next, CGRect(x: 92, y: 0, width: 22, height: 18)), (.eject, CGRect(x: 114, y: 0, width: 22, height: 16)),
        ]
        for (h, src) in cb {
            let dst = Self.rects.first { $0.0 == h }!.1.origin
            let p = pressed == h && pressedInside
            s.draw("cbuttons", src.offsetBy(dx: 0, dy: p ? src.height : 0), at: dst, in: ctx)
        }

        // Shuffle / repeat.
        let shP = pressed == .shuffle && pressedInside, reP = pressed == .repeatAll && pressedInside
        s.draw("shufrep", CGRect(x: 28, y: (c.shuffle ? 30 : 0) + (shP ? 15 : 0), width: 47, height: 15), at: CGPoint(x: 164, y: 89), in: ctx)
        s.draw("shufrep", CGRect(x: 0, y: (c.repeatAll ? 30 : 0) + (reP ? 15 : 0), width: 28, height: 15), at: CGPoint(x: 210, y: 89), in: ctx)
    }

    private func drawTime(_ ctx: CGContext, _ c: PlayerController) {
        let st = c.player.state
        guard st != .stopped else { return }
        // Blink while paused.
        if st == .paused, (tick / 15) % 2 == 1 { return }
        let nums = skin.has("nums_ex") ? "nums_ex" : "numbers"
        var t = c.player.currentTime
        if showRemaining { t = max(0, c.player.duration - t) }
        let secs = Int(t)
        let m = min(secs / 60, 99), sec = secs % 60
        func digit(_ d: Int, _ x: CGFloat) {
            skin.draw(nums, CGRect(x: d * 9, y: 0, width: 9, height: 13), at: CGPoint(x: x, y: 26), in: ctx)
        }
        if showRemaining {
            if nums == "nums_ex" { skin.draw(nums, CGRect(x: 99, y: 0, width: 9, height: 13), at: CGPoint(x: 36, y: 26), in: ctx) }
            else { skin.draw(nums, CGRect(x: 20, y: 6, width: 5, height: 1), at: CGPoint(x: 38, y: 32), in: ctx) }
        }
        digit(m / 10, 48); digit(m % 10, 60); digit(sec / 10, 78); digit(sec % 10, 90)
    }

    private func drawVisualizer(_ ctx: CGContext, active: Bool) {
        let vc = skin.visColors
        let origin = CGPoint(x: 24, y: 43)
        // Background dots like Winamp's analyzer grid.
        vc[1].setFill()
        for y in stride(from: 1, to: 16, by: 2) {
            for x in stride(from: 1, to: 76, by: 2) {
                ctx.fill(CGRect(x: origin.x + CGFloat(x), y: origin.y + CGFloat(y), width: 1, height: 1))
            }
        }
        guard active || peaks.contains(where: { $0 > 0.01 }) else { return }
        for i in 0..<19 {
            let x = origin.x + CGFloat(i * 4)
            let h = Int((CGFloat(levels[i]) * 16).rounded())
            for r in 0..<h {
                let row = 15 - r               // from top
                ctx.setFillColor(vc[2 + row].cgColor)
                ctx.fill(CGRect(x: x, y: origin.y + CGFloat(row), width: 3, height: 1))
            }
            let py = 15 - min(15, Int((CGFloat(peaks[i]) * 16).rounded()))
            if peaks[i] > 0.02 {
                ctx.setFillColor(vc[23].cgColor)
                ctx.fill(CGRect(x: x, y: origin.y + CGFloat(py), width: 3, height: 1))
            }
        }
    }

    private func drawMarquee(_ ctx: CGContext, _ title: String) {
        let box = CGRect(x: 111, y: 27, width: 154, height: 6)
        let maxChars = Int(box.width / 5)
        ctx.saveGState()
        ctx.clip(to: box)
        if title.count <= maxChars {
            skin.drawText(title, at: box.origin, in: ctx)
        } else {
            // Winamp scrolls "title *** title" by whole characters.
            let loop = title + "  ***  "
            let chars = Array(loop)
            let start = marqueeOffset % chars.count
            var visible = ""
            for k in 0...maxChars { visible.append(chars[(start + k) % chars.count]) }
            skin.drawText(visible, at: box.origin, in: ctx)
        }
        ctx.restoreGState()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = skinPoint(event)
        let h = hit(p)
        guard let c = controller else { return }
        switch h {
        case .titlebar, .none:
            if event.clickCount == 2, h == .titlebar { return }
            window?.performDrag(with: event)
            return
        case .seek:
            guard c.player.state != .stopped, c.player.duration > 0 else { return }
            track(event) { pt in
                self.seekDrag = max(0, min(1, Double((pt.x - 16 - 14.5) / (248 - 29))))
            }
            if let f = seekDrag { c.seek(fraction: f) }
            seekDrag = nil
        case .volume:
            volumeDrag = true
            track(event) { pt in
                c.setVolume(Float(max(0, min(1, (pt.x - 107 - 7) / (68 - 14)))))
            }
            volumeDrag = false
        case .balance:
            return
        case .time:
            showRemaining.toggle()
            UserDefaults.standard.set(showRemaining, forKey: "classicRemaining")
        case .options:
            onMenu?(event, self)
            return
        default:
            pressed = h
            pressedInside = true
            needsDisplay = true
            let rect = Self.rects.first { $0.0 == h }!.1
            track(event) { pt in self.pressedInside = rect.contains(pt) }
            let fire = pressedInside
            pressed = .none
            if fire { perform(h, c) }
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(event, self) }

    override func scrollWheel(with event: NSEvent) {
        let d = Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.002 : 0.03)
        controller?.changeVolume(by: d)
    }

    /// Runs a drag loop, calling `update` with skin points until mouse-up.
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

    private func perform(_ h: MainHit, _ c: PlayerController) {
        switch h {
        case .prev: c.previous()
        case .play: c.playOrResume()
        case .pause: c.pause()
        case .stop: c.stop()
        case .next: c.next()
        case .eject: c.showOpenPanel(for: window)
        case .shuffle: c.toggleShuffle()
        case .repeatAll: c.toggleRepeat()
        case .playlist: onTogglePlaylist?()
        case .eq: onToggleEQ?()
        case .close: NSApp.terminate(nil)
        case .minimize: window?.miniaturize(nil)
        default: break
        }
    }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
