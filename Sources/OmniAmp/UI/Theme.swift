import AppKit

/// A color scheme for the modern look, modelled on monochrome monitor phosphors.
struct ThemePalette {
    let id: String
    let name: String
    /// Main lit color (LCD digits, text, fills).
    let phosphor: NSColor
    /// Unlit / secondary color.
    let dim: NSColor
    let playlistText: NSColor
    /// Near-black with a slight tint, like the glass of that monitor.
    let lcd: NSColor
    /// Playlist selection background.
    let selection: NSColor
    /// Playing track in the playlist.
    let current: NSColor
    /// Warnings (e.g. RESAMPLED badge); must stand out from the phosphor.
    let warning: NSColor
    /// Analyzer gradient: bottom, middle (60%), top.
    let spectrum: (NSColor, NSColor, NSColor)

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: 1) }

    static let all: [ThemePalette] = [
        ThemePalette(id: "green", name: "Green Phosphor",
                     phosphor: rgb(0.22, 1.0, 0.35), dim: rgb(0.10, 0.45, 0.16), playlistText: rgb(0.20, 0.86, 0.30),
                     lcd: rgb(0.01, 0.03, 0.02), selection: rgb(0.10, 0.18, 0.55), current: .white,
                     warning: rgb(1.0, 0.7, 0.2),
                     spectrum: (rgb(0.2, 1.0, 0.3), rgb(0.92, 1.0, 0.06), rgb(1.0, 0.2, 0.1))),
        ThemePalette(id: "amber", name: "Amber",
                     phosphor: rgb(1.0, 0.69, 0.0), dim: rgb(0.50, 0.30, 0.02), playlistText: rgb(0.95, 0.62, 0.05),
                     lcd: rgb(0.04, 0.02, 0.0), selection: rgb(0.36, 0.20, 0.02), current: rgb(1.0, 0.93, 0.75),
                     warning: rgb(1.0, 0.35, 0.25),
                     spectrum: (rgb(0.75, 0.40, 0.0), rgb(1.0, 0.70, 0.05), rgb(1.0, 0.95, 0.70))),
        ThemePalette(id: "blue", name: "Blue",
                     phosphor: rgb(0.40, 0.72, 1.0), dim: rgb(0.14, 0.30, 0.55), playlistText: rgb(0.40, 0.68, 0.98),
                     lcd: rgb(0.01, 0.02, 0.05), selection: rgb(0.10, 0.20, 0.45), current: rgb(0.92, 0.97, 1.0),
                     warning: rgb(1.0, 0.7, 0.2),
                     spectrum: (rgb(0.15, 0.40, 1.0), rgb(0.45, 0.78, 1.0), rgb(0.92, 0.98, 1.0))),
        ThemePalette(id: "cyan", name: "Cyan / Teal",
                     phosphor: rgb(0.25, 0.98, 0.88), dim: rgb(0.06, 0.42, 0.40), playlistText: rgb(0.25, 0.88, 0.80),
                     lcd: rgb(0.0, 0.03, 0.03), selection: rgb(0.03, 0.26, 0.28), current: .white,
                     warning: rgb(1.0, 0.7, 0.2),
                     spectrum: (rgb(0.0, 0.62, 0.55), rgb(0.25, 1.0, 0.90), rgb(0.88, 1.0, 1.0))),
        ThemePalette(id: "mono", name: "Monochrome",
                     phosphor: rgb(0.90, 0.91, 0.93), dim: rgb(0.40, 0.41, 0.43), playlistText: rgb(0.78, 0.79, 0.81),
                     lcd: rgb(0.02, 0.02, 0.025), selection: rgb(0.25, 0.26, 0.28), current: .white,
                     warning: rgb(1.0, 0.7, 0.2),
                     spectrum: (rgb(0.42, 0.43, 0.46), rgb(0.80, 0.81, 0.83), rgb(1.0, 1.0, 1.0))),
    ]
}

/// Colors and fonts for the modern look. Phosphor colors come from the selected theme.
enum Theme {
    static let changed = Notification.Name("OmniAmpThemeChanged")

    static var palette: ThemePalette = {
        let id = UserDefaults.standard.string(forKey: "modernTheme") ?? "green"
        return ThemePalette.all.first { $0.id == id } ?? ThemePalette.all[0]
    }()

    static func select(_ id: String) {
        guard let p = ThemePalette.all.first(where: { $0.id == id }) else { return }
        palette = p
        UserDefaults.standard.set(id, forKey: "modernTheme")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    // Hardware (unchanged across themes).
    static let background = NSColor(calibratedRed: 0.07, green: 0.075, blue: 0.09, alpha: 1)
    static let panelTop = NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.25, alpha: 1)
    static let panelBottom = NSColor(calibratedRed: 0.12, green: 0.125, blue: 0.15, alpha: 1)
    static let panelEdge = NSColor(calibratedRed: 0.32, green: 0.33, blue: 0.38, alpha: 1)
    static let lcdEdge = NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 1)
    static let buttonTop = NSColor(calibratedRed: 0.30, green: 0.31, blue: 0.36, alpha: 1)
    static let buttonBottom = NSColor(calibratedRed: 0.18, green: 0.185, blue: 0.22, alpha: 1)
    static let buttonText = NSColor(calibratedWhite: 0.86, alpha: 1)

    // Phosphor (per theme).
    static var lcd: NSColor { palette.lcd }
    static var phosphor: NSColor { palette.phosphor }
    static var phosphorDim: NSColor { palette.dim }
    static var phosphorGhost: NSColor { palette.phosphor.withAlphaComponent(0.07) }
    static var playlistText: NSColor { palette.playlistText }
    static var current: NSColor { palette.current }
    static var selection: NSColor { palette.selection }
    static var warning: NSColor { palette.warning }

    /// Analyzer color at height t (0 bottom … 1 top).
    static func spectrum(_ t: CGFloat) -> NSColor {
        let (a, b, c) = palette.spectrum
        return t < 0.6 ? a.blended(withFraction: t / 0.6, of: b)! : b.blended(withFraction: (t - 0.6) / 0.4, of: c)!
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        Fonts.hack(size, bold: weight.rawValue >= NSFont.Weight.semibold.rawValue)
    }

    static func icon(_ size: CGFloat) -> NSFont { Fonts.hack(size) }
}
