import AppKit
import QuartzCore

/// The visualizer, like Winamp's: click it to cycle spectrum → oscilloscope → L/R meters → off.
/// When off, the UI only needs a slow clock.
enum Analyzer {
    enum Mode: String, CaseIterable {
        case spectrum, oscilloscope, meters, off
        var title: String {
            switch self {
            case .spectrum: return "Spectrum Analyzer"
            case .oscilloscope: return "Oscilloscope"
            case .meters: return "Level Meters (L/R)"
            case .off: return "Off"
            }
        }
    }

    static let changed = Notification.Name("OmniAmpAnalyzerChanged")

    static var mode: Mode {
        get {
            if let m = Mode(rawValue: UserDefaults.standard.string(forKey: Pref.analyzerMode) ?? "") { return m }
            return UserDefaults.standard.object(forKey: Pref.analyzerOn) as? Bool == false ? .off : .spectrum
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Pref.analyzerMode)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static var isOn: Bool { mode != .off }

    /// Click: spectrum → oscilloscope → L/R meters → off → spectrum.
    static func toggle() {
        let all = Mode.allCases
        mode = all[(all.firstIndex(of: mode)! + 1) % all.count]
    }
}

/// Seconds since launch, for animations that must not depend on the frame rate.
var animationTime: Double { CACurrentMediaTime() }

/// Drives UI animation only when someone can see it: 20 fps while playing with the analyzer on, 8 fps with
/// it off (scrolling title), 4 fps while paused (blinking time), and nothing at all when stopped, hidden,
/// minimized or fully covered. Also turns the spectrum
/// analyzer on/off, so background playback does no visual work.
final class DisplayClock {
    private let tick: () -> Void
    private let player: AudioPlayer
    private var windows: [() -> NSWindow?] = []
    private var timer: Timer?
    private var fps: Double = 0
    private var observers: [NSObjectProtocol] = []

    init(player: AudioPlayer, tick: @escaping () -> Void) {
        self.player = player
        self.tick = tick
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
                                          NSApplication.didUnhideNotification, Analyzer.changed]
        for n in names {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.update() })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        timer?.invalidate()
    }

    /// Windows whose visibility counts (weakly held).
    func track(_ ws: [NSWindow]) {
        windows = ws.map { w in { [weak w] in w } }
        update()
    }

    var isVisible: Bool {
        guard !NSApp.isHidden else { return false }
        return windows.contains { get in
            guard let w = get() else { return false }
            return w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
        }
    }

    /// Call when playback state or visibility may have changed.
    func update() {
        let visible = isVisible
        let analyzer = Analyzer.isOn   // spectrum and oscilloscope both need the tap and 20 fps
        let wanted: Double = !visible ? 0 : (player.state == .playing ? (analyzer ? 20 : 8) : (player.state == .paused ? 4 : 0))
        player.setAnalyzerActive(visible && player.state == .playing && analyzer)
        guard wanted != fps else { return }
        fps = wanted
        timer?.invalidate()
        timer = nil
        guard wanted > 0 else { return }
        let t = Timer(timeInterval: 1 / wanted, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.2 / wanted   // let macOS coalesce wakeups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        fps = 0
        player.setAnalyzerActive(false)
    }
}
