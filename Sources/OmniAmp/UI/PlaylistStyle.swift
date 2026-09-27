import AppKit

/// How the modern playlist renders rows: font choice and track numbers (View › Playlist Font).
enum PlaylistStyle {
    enum Font: String, CaseIterable {
        case hack, compact, classic
        var title: String {
            switch self {
            case .hack: return "Hack"
            case .compact: return "Hack Compact"
            case .classic: return "Classic (proportional)"
            }
        }
    }

    static let changed = Notification.Name("OmniAmpPlaylistStyleChanged")

    static var font: Font {
        get { Font(rawValue: UserDefaults.standard.string(forKey: "playlistFont") ?? "") ?? .hack }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "playlistFont"); post() }
    }

    static var showNumbers: Bool {
        get { UserDefaults.standard.object(forKey: "playlistNumbers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "playlistNumbers"); post() }
    }

    private static func post() { NotificationCenter.default.post(name: changed, object: nil) }

    static var rowHeight: CGFloat { font == .hack ? 18 : 16 }

    /// Title (and number) font.
    static func textFont(bold: Bool) -> NSFont {
        switch font {
        case .hack: return Fonts.hack(11.5, bold: bold)
        case .compact: return Fonts.hack(11, bold: bold)
        case .classic:
            // Winamp's playlist used Arial; fall back to the system font.
            return NSFont(name: bold ? "Arial-BoldMT" : "ArialMT", size: 12.5) ?? .systemFont(ofSize: 12, weight: bold ? .bold : .regular)
        }
    }

    /// Times stay monospaced so they line up, whatever the title font.
    static func timeFont(bold: Bool) -> NSFont {
        font == .classic ? .monospacedDigitSystemFont(ofSize: 11.5, weight: bold ? .bold : .regular) : textFont(bold: bold)
    }

    /// Playing-row marker. The Nerd Font icon only exists in Hack; other fonts get the standard Unicode
    /// triangle (text style), which macOS can draw in any font.
    static var playMarker: String { font == .classic ? "\u{25B6}\u{FE0E}" : Fonts.Icon.play }

    /// Hack Compact tightens the letters a little.
    static var kern: CGFloat { font == .compact ? -0.55 : 0 }
}
