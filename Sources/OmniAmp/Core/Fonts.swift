import AppKit
import CoreText

/// Registers the bundled Nerd Fonts (Hack) and hands out fonts with system fallbacks.
enum Fonts {
    private static var registered = false

    static func registerBundled() {
        guard !registered else { return }
        registered = true
        guard let dir = fontsDirectory() else { NSLog("OmniAmp: fonts folder not found, using system fonts"); return }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        // Only Hack is used. Prefer TTF: macOS memory-maps it, while a WOFF2 is decompressed into RAM
        // (~16 MB each for these Nerd Fonts). The app bundle ships TTFs; dev runs fall back to fonts/*.woff2.
        let hack = files.filter { $0.lastPathComponent.hasPrefix("HackNerdFont-") }
        let ttf = hack.filter { $0.pathExtension.lowercased() == "ttf" }
        for url in ttf.isEmpty ? hack.filter({ $0.pathExtension.lowercased() == "woff2" }) : ttf {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// App bundle Resources/Fonts, else a `fonts` folder next to the package (swift run / tests).
    private static func fontsDirectory() -> URL? {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Fonts"), fm.fileExists(atPath: r.path) { return r }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<5 {
            guard let d = dir else { break }
            let f = d.appendingPathComponent("fonts")
            if fm.fileExists(atPath: f.appendingPathComponent("HackNerdFont-Regular.woff2").path) { return f }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    static func hack(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "HackNF-Bold" : "HackNF-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// Nerd Font (Font Awesome range) icon glyphs.
    enum Icon {
        static let prev = "\u{F048}"
        static let play = "\u{F04B}"
        static let pause = "\u{F04C}"
        static let stop = "\u{F04D}"
        static let next = "\u{F051}"
        static let eject = "\u{F052}"
        static let shuffle = "\u{F074}"
        static let repeatAll = "\u{F01E}"
        static let volume = "\u{F028}"
        static let music = "\u{F001}"
        static let plus = "\u{F067}"
        static let trash = "\u{F1F8}"
        static let search = "\u{F002}"
        static let radio = "\u{F0439}"
        static let starFilled = "\u{F005}"
        static let starEmpty = "\u{F006}"
        static let podcast = "\u{F0994}"
        static let check = "\u{F00C}"
        static let rss = "\u{F09E}"
        static let globe = "\u{F0AC}"
    }
}
