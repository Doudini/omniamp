import AppKit

/// Winamp keys (Z X C V B, Space, arrows, + −, S R L I E J Q) in the player's own windows (not the
/// radio/podcast lists or open panels), unless a text field is being edited. Held transport keys don't
/// repeat; arrows and page keys do.
@MainActor
final class WinampKeys {
    private var monitor: Any?

    init(controller: PlayerController, look: @escaping () -> LookController?, queueSelected: @escaping () -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak controller] ev in
            // Local monitors run on the main thread. true = the key was ours (swallow it).
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let c = controller, let w = ev.window, let look = look(), look.owns(w) else { return false }
                if w.firstResponder is NSText { return false } // typing in the filter
                // Holding a transport key shouldn't fire it again and again (holding B skipped many tracks); list
                // navigation (arrows, page keys) and seeking must repeat, so only these keys are held back.
                let key = Self.winampKey(ev)
                if ev.isARepeat, let k = key, ["z", "x", "c", "v", "b", "q", "j", " ", "s", "r", "i", "e", "l"].contains(k) { return true }
                let mods = ev.modifierFlags.intersection([.command, .control, .option])
                guard mods.isEmpty else { return false }
                switch key {
                case "z": c.previous()
                case "x": c.playOrResume()
                case "c": c.pause()
                case "v":
                    if ev.modifierFlags.contains(.shift) { c.stopAfterCurrent.toggle() } else { c.stop() }
                case "b": c.next()
                case "j": look.focusFilter()
                case "q": queueSelected()
                case " ": c.togglePlayPause()
                case "s": c.toggleShuffle()
                case "r": c.toggleRepeat()
                case "l": look.showCurrentTrack()
                case "i": look.toggleInfo()
                case "e": look.toggleEQ()
                case "+", "=": c.changeVolume(by: 0.05)   // = is + without Shift on most layouts
                case "-", "_": c.changeVolume(by: -0.05)
                default:
                    let shift = ev.modifierFlags.contains(.shift)
                    switch ev.keyCode {
                    case 123: c.seek(by: shift ? -30 : -5)   // ← / ⇧←
                    case 124: c.seek(by: shift ? 30 : 5)     // → / ⇧→
                    case 69: c.changeVolume(by: 0.05)        // keypad +
                    case 78: c.changeVolume(by: -0.05)       // keypad −
                    default: return false
                    }
                }
                return true
            }
            return handled ? nil : ev
        }
    }

    // Lives as long as the app; released on the main thread, where monitors are removed.
    deinit { MainActor.assumeIsolated { monitor.map(NSEvent.removeMonitor) } }

    /// The typed letter; on a non-Latin layout (Cyrillic, Greek…) the letter at that key's US position, so
    /// Z X C V B and the rest still work where Winamp users expect them.
    private static func winampKey(_ ev: NSEvent) -> String? {
        let typed = ev.charactersIgnoringModifiers?.lowercased()
        if let t = typed, t.unicodeScalars.allSatisfy({ $0.isASCII }) { return t }
        let us: [UInt16: String] = [6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 38: "j", 1: "s", 15: "r", 37: "l", 34: "i", 14: "e"]
        return us[ev.keyCode] ?? typed
    }
}
