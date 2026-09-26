import AppKit

/// Colors and fonts for the modern look.
enum Theme {
    static let background = NSColor(calibratedRed: 0.07, green: 0.075, blue: 0.09, alpha: 1)
    static let panelTop = NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.25, alpha: 1)
    static let panelBottom = NSColor(calibratedRed: 0.12, green: 0.125, blue: 0.15, alpha: 1)
    static let panelEdge = NSColor(calibratedRed: 0.32, green: 0.33, blue: 0.38, alpha: 1)
    static let lcd = NSColor(calibratedRed: 0.01, green: 0.03, blue: 0.02, alpha: 1)
    static let lcdEdge = NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 1)
    static let green = NSColor(calibratedRed: 0.22, green: 1.0, blue: 0.35, alpha: 1)
    static let dimGreen = NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.16, alpha: 1)
    static let ghostGreen = NSColor(calibratedRed: 0.22, green: 1.0, blue: 0.35, alpha: 0.07)
    static let playlistText = NSColor(calibratedRed: 0.20, green: 0.86, blue: 0.30, alpha: 1)
    static let current = NSColor.white
    static let selection = NSColor(calibratedRed: 0.10, green: 0.18, blue: 0.55, alpha: 1)
    static let buttonTop = NSColor(calibratedRed: 0.30, green: 0.31, blue: 0.36, alpha: 1)
    static let buttonBottom = NSColor(calibratedRed: 0.18, green: 0.185, blue: 0.22, alpha: 1)
    static let buttonText = NSColor(calibratedWhite: 0.86, alpha: 1)

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        Fonts.hack(size, bold: weight.rawValue >= NSFont.Weight.semibold.rawValue)
    }

    static func icon(_ size: CGFloat) -> NSFont { Fonts.hack(size) }
}
