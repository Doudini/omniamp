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
    /// Surfaces for the Tinted finish: the hardware's greys leaning to this color.
    let tinted: Surfaces

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: 1) }

    static let all: [ThemePalette] = [
        ThemePalette(id: "green", name: "Green Phosphor",
                     phosphor: rgb(0.22, 1.0, 0.35), dim: rgb(0.10, 0.45, 0.16), playlistText: rgb(0.20, 0.86, 0.30),
                     lcd: rgb(0.01, 0.03, 0.02), selection: rgb(0.10, 0.18, 0.55), current: .white,
                     warning: rgb(1.0, 0.7, 0.2),
                     spectrum: (rgb(0.2, 1.0, 0.3), rgb(0.92, 1.0, 0.06), rgb(1.0, 0.2, 0.1)),
                     tinted: .hex(page: 0x0C130F, card: 0x131C17, cardRaised: 0x18231D, border: 0x1F2C24,
                                  text: 0xE6EDE8, text2: 0x95A69B, text3: 0x5F7066,
                                  panelTop: 0x324038, panelBottom: 0x1B2620, panelEdge: 0x4E6156,
                                  buttonTop: 0x4A5C52, buttonBottom: 0x2A3830, buttonText: 0xD9E0DB, playlist: rgb(0.01, 0.03, 0.02))),
        ThemePalette(id: "amber", name: "Amber",
                     phosphor: rgb(1.0, 0.69, 0.0), dim: rgb(0.50, 0.30, 0.02), playlistText: rgb(0.95, 0.62, 0.05),
                     lcd: rgb(0.04, 0.02, 0.0), selection: rgb(0.36, 0.20, 0.02), current: rgb(1.0, 0.93, 0.75),
                     warning: rgb(1.0, 0.35, 0.25),
                     spectrum: (rgb(0.75, 0.40, 0.0), rgb(1.0, 0.70, 0.05), rgb(1.0, 0.95, 0.70)),
                     tinted: .hex(page: 0x14110D, card: 0x1D1914, cardRaised: 0x242019, border: 0x2C261E,
                                  text: 0xEEEAE4, text2: 0xA89F92, text3: 0x6E665B,
                                  panelTop: 0x403A32, panelBottom: 0x26211B, panelEdge: 0x61594E,
                                  buttonTop: 0x5C544A, buttonBottom: 0x38322A, buttonText: 0xE0DCD6, playlist: rgb(0.04, 0.02, 0.0))),
        ThemePalette(id: "blue", name: "Blue",
                     phosphor: rgb(0.40, 0.72, 1.0), dim: rgb(0.14, 0.30, 0.55), playlistText: rgb(0.40, 0.68, 0.98),
                     lcd: rgb(0.01, 0.02, 0.05), selection: rgb(0.10, 0.20, 0.45), current: rgb(0.92, 0.97, 1.0),
                     warning: rgb(1.0, 0.7, 0.2),
                     spectrum: (rgb(0.15, 0.40, 1.0), rgb(0.45, 0.78, 1.0), rgb(0.92, 0.98, 1.0)),
                     tinted: .hex(page: 0x0C1117, card: 0x141A22, cardRaised: 0x1A212B, border: 0x212A35,
                                  text: 0xE5EBF1, text2: 0x93A0AE, text3: 0x5D6977,
                                  panelTop: 0x303740, panelBottom: 0x1B2026, panelEdge: 0x4C5661,
                                  buttonTop: 0x48515C, buttonBottom: 0x282F38, buttonText: 0xDADFE5, playlist: rgb(0.01, 0.02, 0.05))),
        ThemePalette(id: "cyan", name: "Cyan / Teal",
                     phosphor: rgb(0.25, 0.98, 0.88), dim: rgb(0.06, 0.42, 0.40), playlistText: rgb(0.25, 0.88, 0.80),
                     lcd: rgb(0.0, 0.03, 0.03), selection: rgb(0.03, 0.26, 0.28), current: .white,
                     warning: rgb(1.0, 0.7, 0.2),
                     spectrum: (rgb(0.0, 0.62, 0.55), rgb(0.25, 1.0, 0.90), rgb(0.88, 1.0, 1.0)),
                     tinted: .hex(page: 0x0B1313, card: 0x121C1C, cardRaised: 0x172424, border: 0x1E2D2D,
                                  text: 0xE4EEED, text2: 0x92A6A4, text3: 0x5C706E,
                                  panelTop: 0x324040, panelBottom: 0x1B2626, panelEdge: 0x4E6161,
                                  buttonTop: 0x4A5C5C, buttonBottom: 0x2A3838, buttonText: 0xD9E0E0, playlist: rgb(0.0, 0.03, 0.03))),
        ThemePalette(id: "mono", name: "Monochrome",
                     phosphor: rgb(0.90, 0.91, 0.93), dim: rgb(0.40, 0.41, 0.43), playlistText: rgb(0.78, 0.79, 0.81),
                     lcd: rgb(0.02, 0.02, 0.025), selection: rgb(0.25, 0.26, 0.28), current: .white,
                     warning: rgb(1.0, 0.7, 0.2),
                     spectrum: (rgb(0.42, 0.43, 0.46), rgb(0.80, 0.81, 0.83), rgb(1.0, 1.0, 1.0)),
                     tinted: .hex(page: 0x111111, card: 0x1A1A1A, cardRaised: 0x202020, border: 0x282828,
                                  text: 0xE8E8E8, text2: 0x9E9E9E, text3: 0x666666,
                                  panelTop: 0x363636, panelBottom: 0x202020, panelEdge: 0x555555,
                                  buttonTop: 0x505050, buttonBottom: 0x303030, buttonText: 0xDBDBDB, playlist: rgb(0.02, 0.02, 0.025))),
    ]
}

/// Window, panel and text colors: the player's hardware (window, panels, keys, playlist) and the library,
/// radio and podcast windows (page, cards, text). A finish picks one set; the Tinted one comes with each color.
struct Surfaces {
    let page, card, cardRaised, border: NSColor
    let text, text2, text3: NSColor
    let background, panelTop, panelBottom, panelEdge: NSColor
    let buttonTop, buttonBottom, buttonText: NSColor
    let playlist, lcdEdge: NSColor

    /// From sRGB hex values; the player's window is the page.
    static func hex(page: UInt32, card: UInt32, cardRaised: UInt32, border: UInt32,
                    text: UInt32, text2: UInt32, text3: UInt32,
                    panelTop: UInt32, panelBottom: UInt32, panelEdge: UInt32,
                    buttonTop: UInt32, buttonBottom: UInt32, buttonText: UInt32, playlist: NSColor) -> Surfaces {
        let c = Dash.rgb
        return Surfaces(page: c(page), card: c(card), cardRaised: c(cardRaised), border: c(border),
                        text: c(text), text2: c(text2), text3: c(text3),
                        background: c(page), panelTop: c(panelTop), panelBottom: c(panelBottom), panelEdge: c(panelEdge),
                        buttonTop: c(buttonTop), buttonBottom: c(buttonBottom), buttonText: c(buttonText),
                        playlist: playlist, lcdEdge: .black)
    }
}

/// How the windows are finished, apart from the display color: tinted to match it, neutral hardware grey,
/// or the slate "studio" look.
enum Finish: String, CaseIterable {
    case tinted, hardware, studio

    var name: String {
        switch self {
        case .tinted: "Tinted"
        case .hardware: "Hardware"
        case .studio: "Studio"
        }
    }

    func surfaces(for palette: ThemePalette) -> Surfaces {
        switch self {
        case .tinted: palette.tinted
        case .hardware: Self.hardwareSurfaces
        case .studio: Self.studioSurfaces
        }
    }

    /// Neutral dark grey, the player as it first looked (its chrome values unchanged).
    private static let hardwareSurfaces: Surfaces = {
        let c = { (r: CGFloat, g: CGFloat, b: CGFloat) in NSColor(calibratedRed: r, green: g, blue: b, alpha: 1) }
        let d = Dash.rgb
        return Surfaces(page: d(0x121317), card: d(0x1F2026), cardRaised: d(0x26272E), border: d(0x33353D),
                        text: d(0xE6E7EA), text2: d(0x9A9CA3), text3: d(0x62646B),
                        background: c(0.07, 0.075, 0.09), panelTop: c(0.20, 0.21, 0.25), panelBottom: c(0.12, 0.125, 0.15),
                        panelEdge: c(0.32, 0.33, 0.38), buttonTop: c(0.30, 0.31, 0.36), buttonBottom: c(0.18, 0.185, 0.22),
                        buttonText: NSColor(calibratedWhite: 0.86, alpha: 1), playlist: .black, lcdEdge: .black)
    }()

    /// Slate blue-green, the library's first look.
    private static let studioSurfaces: Surfaces = .hex(page: 0x0D1519, card: 0x152127, cardRaised: 0x1B2A31, border: 0x24353D,
                                                       text: 0xE6ECEE, text2: 0x93A3AA, text3: 0x5E6F76,
                                                       panelTop: 0x2A3A41, panelBottom: 0x18252B, panelEdge: 0x445861,
                                                       buttonTop: 0x3C4F57, buttonBottom: 0x22323A, buttonText: 0xD8E0E3,
                                                       playlist: Dash.rgb(0x070C0E))
}

/// Colors and fonts for the modern look. Phosphor colors come from the selected theme.
enum Theme {
    static let changed = Notification.Name("OmniAmpThemeChanged")

    /// OMNIAMP_THEME=color[:finish] picks both for one run without saving them (test hook).
    private static let override: (color: String?, finish: String?) = {
        guard let v = ProcessInfo.processInfo.environment["OMNIAMP_THEME"] else { return (nil, nil) }
        let parts = v.split(separator: ":").map(String.init)
        return (parts.first, parts.count > 1 ? parts[1] : nil)
    }()

    static private(set) var palette: ThemePalette = {
        let id = override.color ?? UserDefaults.standard.string(forKey: Pref.modernTheme) ?? "green"
        return ThemePalette.all.first { $0.id == id } ?? ThemePalette.all[0]
    }()

    static private(set) var finish: Finish = {
        Finish(rawValue: override.finish ?? UserDefaults.standard.string(forKey: Pref.modernFinish) ?? "") ?? .tinted
    }()

    /// The current window, panel and text colors: the finish, for the tinted one in the palette's color.
    static var surfaces: Surfaces { finish.surfaces(for: palette) }

    static func select(_ id: String) {
        guard let p = ThemePalette.all.first(where: { $0.id == id }) else { return }
        palette = p
        UserDefaults.standard.set(id, forKey: Pref.modernTheme)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func selectFinish(_ f: Finish) {
        finish = f
        UserDefaults.standard.set(f.rawValue, forKey: Pref.modernFinish)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    // Hardware: the finish's window, panels and keys.
    static var background: NSColor { surfaces.background }
    static var panelTop: NSColor { surfaces.panelTop }
    static var panelBottom: NSColor { surfaces.panelBottom }
    static var panelEdge: NSColor { surfaces.panelEdge }
    static var lcdEdge: NSColor { surfaces.lcdEdge }
    static var buttonTop: NSColor { surfaces.buttonTop }
    static var buttonBottom: NSColor { surfaces.buttonBottom }
    static var buttonText: NSColor { surfaces.buttonText }
    /// Behind the playlist.
    static var playlistBackground: NSColor { surfaces.playlist }

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

    /// The kind of a recording, the same in every theme. From AAP-64 (Adigun A. Polack, lospec.com), checked so the
    /// five stay apart on the cards for colour-blind eyes too: blues for official studio releases, a deep green for
    /// official live albums, orange for shows and bootlegs (red read as an error), magenta for demos and unreleased
    /// tracks. The orange is a step darker than AAP-64's #f9a31b and the green AAP-64's darker one: orange next to
    /// a brighter green blurs for red-green colour blindness.
    /// Identity only: amounts stay in the phosphor color, and text stays in text colors.
    static func kind(_ k: ReleaseKind) -> NSColor {
        switch k {
        case .album: ThemePalette.rgb(0x28 / 255, 0x5C / 255, 0xC4 / 255)
        case .single, .compilation: ThemePalette.rgb(0x24 / 255, 0x9F / 255, 0xDE / 255)
        case .live: ThemePalette.rgb(0x1A / 255, 0x7A / 255, 0x3E / 255)
        case .show: ThemePalette.rgb(0xD6 / 255, 0x7A / 255, 0x14 / 255)
        case .unreleased: ThemePalette.rgb(0xBC / 255, 0x4A / 255, 0x9B / 255)
        }
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        Fonts.hack(size, bold: weight.rawValue >= NSFont.Weight.semibold.rawValue)
    }

    static func icon(_ size: CGFloat) -> NSFont { Fonts.hack(size) }
}
