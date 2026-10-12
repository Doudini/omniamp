import AppKit

/// A list that scrolls itself without a scroll view (the classic playlist draws its own rows).
@MainActor
protocol DragScrollable: NSView {
    /// Moves the content with the pointer: `dy` > 0 when it moved up (window coordinates). Returns false at an end.
    func dragScroll(by dy: CGFloat) -> Bool
}

/// Middle-button drag scrolls whatever list is under the pointer like a touchscreen: the content follows the
/// pointer, and a flick keeps it gliding for a moment. For mice and for tablet pens (set a pen button to middle
/// click), which have no scroll wheel; the scroll bar shows while it moves. One monitor for every window.
@MainActor
final class DragScroll {
    private enum Target {
        case scroll(NSScrollView)
        case custom(DragScrollable)
    }

    private var monitor: Any?
    private var target: Target?
    private var last: NSPoint = .zero
    /// Recent moves (time, dx, dy) for the flick's speed.
    private var samples: [(t: TimeInterval, dx: CGFloat, dy: CGFloat)] = []
    private var glide: Timer?
    private var velocity: CGVector = .zero

    init() {
        let events: NSEvent.EventTypeMask = [.otherMouseDown, .otherMouseDragged, .otherMouseUp, .leftMouseDown, .rightMouseDown, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] ev in
            // Local monitors run on the main thread. true = the event was ours (swallow it).
            let handled = MainActor.assumeIsolated { self?.handle(ev) ?? false }
            return handled ? nil : ev
        }
    }

    @discardableResult
    func handle(_ ev: NSEvent, in window: NSWindow? = nil) -> Bool {   // internal for tests
        switch ev.type {
        case .otherMouseDown:
            guard ev.buttonNumber == 2, let t = target(at: ev, in: window ?? ev.window) else { return false }
            stopGlide()
            target = t
            last = ev.locationInWindow
            samples = []
            NSCursor.closedHand.push()
            return true
        case .otherMouseDragged:
            guard target != nil else { return false }
            let p = ev.locationInWindow
            let dx = p.x - last.x, dy = p.y - last.y
            last = p
            samples.append((ev.timestamp, dx, dy))
            samples.removeAll { ev.timestamp - $0.t > 0.08 }
            move(dx: dx, dy: dy)
            return true
        case .otherMouseUp:
            guard target != nil else { return false }
            NSCursor.pop()
            // Only a move in the last moments before letting go flicks: stopping first, then releasing, doesn't.
            if let first = samples.first, ev.timestamp - first.t < 0.08 {
                let dt = max(ev.timestamp - first.t, 1.0 / 120)
                velocity = CGVector(dx: samples.reduce(0) { $0 + $1.dx } / dt, dy: samples.reduce(0) { $0 + $1.dy } / dt)
                if hypot(velocity.dx, velocity.dy) > 300 { startGlide(); return true }
            }
            target = nil
            return true
        default:
            // A click or the wheel stops a glide (the event itself goes on as usual).
            if glide != nil { stopGlide() }
            return false
        }
    }

    /// The innermost list under the pointer that has something to scroll (a list in a page that fits whole
    /// leaves it to the page).
    // The window is passed in by tests: a window never shown on a headless CI runner has no number, so ev.window is nil.
    private func target(at ev: NSEvent, in window: NSWindow?) -> Target? {
        guard let content = window?.contentView, let frame = content.superview else { return nil }
        var view = content.hitTest(frame.convert(ev.locationInWindow, from: nil))
        while let v = view {
            if let custom = v as? DragScrollable { return .custom(custom) }
            if let scroll = v as? NSScrollView, Self.canScroll(scroll) { return .scroll(scroll) }
            view = v.superview
        }
        return nil
    }

    private static func canScroll(_ scroll: NSScrollView) -> Bool {
        guard let doc = scroll.documentView else { return false }
        let clip = scroll.contentView, insets = scroll.contentInsets
        return doc.frame.height + insets.top + insets.bottom > clip.frame.height + 0.5
            || doc.frame.width + insets.left + insets.right > clip.frame.width + 0.5
    }

    /// The pointer moved by (dx, dy) in window coordinates; false when the content is already at its end.
    @discardableResult
    private func move(dx: CGFloat, dy: CGFloat) -> Bool {
        switch target {
        case .scroll(let scroll):
            let clip = scroll.contentView
            var o = clip.bounds.origin
            o.x -= dx
            o.y += clip.isFlipped ? dy : -dy
            let to = clip.constrainBoundsRect(NSRect(origin: o, size: clip.bounds.size)).origin
            guard to != clip.bounds.origin else { return false }
            clip.scroll(to: to)
            scroll.reflectScrolledClipView(clip)
            scroll.flashScrollers()
            return true
        case .custom(let view):
            return view.dragScroll(by: dy)
        case nil:
            return false
        }
    }

    private func startGlide() {
        var previous = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime, dt = now - previous
                previous = now
                // Friction: the speed halves about every 0.15 s.
                let keep = pow(0.01, dt)
                self.velocity = CGVector(dx: self.velocity.dx * keep, dy: self.velocity.dy * keep)
                let moved = self.move(dx: self.velocity.dx * dt, dy: self.velocity.dy * dt)
                if !moved || hypot(self.velocity.dx, self.velocity.dy) < 20 { self.stopGlide() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        glide = timer
    }

    private func stopGlide() {
        glide?.invalidate()
        glide = nil
        target = nil
    }
}
