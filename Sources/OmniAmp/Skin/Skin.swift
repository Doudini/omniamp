import AppKit
import ImageIO

/// A classic Winamp 2.x skin (.wsz): bitmaps + PLEDIT.TXT + VISCOLOR.TXT.
final class Skin {
    enum SkinError: LocalizedError {
        case missingMain
        var errorDescription: String? { "This skin has no MAIN.BMP." }
    }

    let name: String
    let url: URL
    private var images: [String: CGImage] = [:]
    private var spriteCache: [String: CGImage] = [:]

    // PLEDIT.TXT
    var plNormal = NSColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1)
    var plCurrent = NSColor.white
    var plNormalBG = NSColor.black
    var plSelectedBG = NSColor(calibratedRed: 0, green: 0, blue: 0.78, alpha: 1)
    var plFontName: String?

    // VISCOLOR.TXT: 0 bg, 1 dots, 2-17 bars (top→bottom), 18-22 oscilloscope, 23 peaks.
    var visColors: [NSColor] = Skin.defaultVisColors

    init(url: URL) throws {
        self.url = url
        name = url.deletingPathExtension().lastPathComponent
        let zip = try ZipArchive(url: url)
        for (file, data) in zip.entries {
            let ext = (file as NSString).pathExtension
            let base = (file as NSString).deletingPathExtension
            if ext == "bmp" || ext == "png" {
                if let src = CGImageSourceCreateWithData(data as CFData, nil),
                   let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    images[base] = Self.decoded(img)
                }
            }
        }
        guard images["main"] != nil else { throw SkinError.missingMain }
        if let d = zip.entries["pledit.txt"] { parsePledit(Self.text(d)) }
        if let d = zip.entries["viscolor.txt"] { parseViscolor(Self.text(d)) }
    }

    /// Decode once into 32-bit BGRA (the screen's native format). ImageIO's BMP images are lazy: without this,
    /// every blit re-decodes (and RLE-unpacks) the whole sheet.
    static func decoded(_ img: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    func has(_ file: String) -> Bool { images[file] != nil }
    func size(of file: String) -> CGSize? { images[file].map { CGSize(width: $0.width, height: $0.height) } }

    /// Sub-image of a sheet (top-left origin). Clipped to the sheet; nil if outside.
    func sprite(_ file: String, _ r: CGRect) -> CGImage? {
        let key = "\(file):\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"
        if let s = spriteCache[key] { return s }
        guard let img = images[file] else { return nil }
        let clipped = r.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1, let s = img.cropping(to: clipped) else { return nil }
        spriteCache[key] = s
        return s
    }

    // MARK: Drawing (in skin pixel coordinates of a flipped view)

    /// Blit a sprite at `dst` (top-left). Returns false if the sprite is missing.
    @discardableResult
    func draw(_ file: String, _ src: CGRect, at dst: CGPoint, in ctx: CGContext) -> Bool {
        guard let s = sprite(file, src) else { return false }
        Self.blit(s, CGRect(x: dst.x, y: dst.y, width: CGFloat(s.width), height: CGFloat(s.height)), ctx)
        return true
    }

    /// Tile a sprite across a rect.
    func tile(_ file: String, _ src: CGRect, in dst: CGRect, ctx: CGContext) {
        guard let s = sprite(file, src) else { return }
        ctx.saveGState()
        ctx.clip(to: dst)
        var y = dst.minY
        while y < dst.maxY {
            var x = dst.minX
            while x < dst.maxX {
                Self.blit(s, CGRect(x: x, y: y, width: src.width, height: src.height), ctx)
                x += src.width
            }
            y += src.height
        }
        ctx.restoreGState()
    }

    static func blit(_ img: CGImage, _ r: CGRect, _ ctx: CGContext) {
        // The view is flipped; flip locally so the bitmap is upright.
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    // MARK: TEXT.BMP bitmap font (5×6 glyphs)

    private static let textMap: [Character: (Int, Int)] = {
        var m: [Character: (Int, Int)] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { m[c] = (i, 0) }
        m["\""] = (26, 0); m["@"] = (27, 0); m[" "] = (30, 0)
        for (i, c) in "0123456789".enumerated() { m[c] = (i, 1) }
        let row1: [Character] = ["…", ".", ":", "(", ")", "-", "'", "!", "_", "+", "\\", "/", "[", "]", "^", "&", "%", ",", "=", "$", "#"]
        for (i, c) in row1.enumerated() { m[c] = (10 + i, 1) }
        m["å"] = (0, 2); m["ö"] = (1, 2); m["ä"] = (2, 2); m["?"] = (3, 2); m["*"] = (4, 2)
        // Look-alikes.
        m["<"] = (13, 1); m[">"] = (14, 1); m["{"] = (22, 1); m["}"] = (23, 1); m["`"] = (16, 1); m["|"] = (21, 1)
        m[";"] = (12, 1); m["~"] = (15, 1)
        return m
    }()

    /// Draws `text` with the skin's bitmap font. Returns the width drawn.
    @discardableResult
    func drawText(_ text: String, at p: CGPoint, in ctx: CGContext) -> CGFloat {
        var x = p.x
        for ch in text.lowercased().folding(options: [.diacriticInsensitive], locale: nil) {
            let (col, row) = Self.textMap[ch] ?? (30, 0)
            draw("text", CGRect(x: col * 5, y: row * 6, width: 5, height: 6), at: CGPoint(x: x, y: p.y), in: ctx)
            x += 5
        }
        return x - p.x
    }

    // MARK: Parsing

    private static func text(_ d: Data) -> String {
        String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
    }

    private func parsePledit(_ s: String) {
        for line in s.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), val = parts[1]
            switch key {
            case "normal": plNormal = Self.hex(val) ?? plNormal
            case "current": plCurrent = Self.hex(val) ?? plCurrent
            case "normalbg": plNormalBG = Self.hex(val) ?? plNormalBG
            case "selectedbg": plSelectedBG = Self.hex(val) ?? plSelectedBG
            case "font": plFontName = val
            default: break
            }
        }
    }

    private func parseViscolor(_ s: String) {
        var colors: [NSColor] = []
        for line in s.components(separatedBy: .newlines) {
            let nums = line.components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted)
                .filter { !$0.isEmpty }.prefix(3).compactMap { Int($0) }
            guard nums.count == 3 else { continue }
            colors.append(NSColor(calibratedRed: CGFloat(nums[0]) / 255, green: CGFloat(nums[1]) / 255, blue: CGFloat(nums[2]) / 255, alpha: 1))
            if colors.count == 24 { break }
        }
        if colors.count >= 18 {
            while colors.count < 24 { colors.append(Self.defaultVisColors[colors.count]) }
            visColors = colors
        }
    }

    static func hex(_ s: String) -> NSColor? {
        let h = s.trimmingCharacters(in: CharacterSet(charactersIn: "# \t"))
        guard h.count >= 6, let v = Int(h.prefix(6), radix: 16) else { return nil }
        return NSColor(calibratedRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static let defaultVisColors: [NSColor] = {
        let rgb: [(Int, Int, Int)] = [
            (0, 0, 0), (24, 33, 41), (239, 49, 16), (206, 41, 16), (214, 90, 0), (214, 102, 0),
            (214, 115, 0), (198, 123, 8), (222, 165, 24), (214, 181, 33), (189, 222, 41), (148, 222, 33),
            (41, 206, 16), (50, 190, 16), (57, 181, 16), (49, 156, 8), (41, 148, 0), (24, 132, 8),
            (255, 255, 255), (214, 214, 222), (181, 189, 189), (160, 170, 175), (148, 156, 165), (150, 150, 150),
        ]
        return rgb.map { NSColor(calibratedRed: CGFloat($0.0) / 255, green: CGFloat($0.1) / 255, blue: CGFloat($0.2) / 255, alpha: 1) }
    }()
}

/// Remembers skins: copies imported .wsz files into Application Support/OmniAmp/Skins.
enum SkinLibrary {
    static var directory: URL {
        let d = LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("Skins", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The skin OmniAmp ships with: Winamp 2.91's base skin (app bundle; the repo copy for dev builds).
    static var bundled: URL? {
        if let u = Bundle.main.url(forResource: "base-2.91", withExtension: "wsz", subdirectory: "Skins") { return u }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/base-2.91.wsz")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }
    static let bundledTitle = "Winamp Classic (Base 2.91)"

    static func isBundled(_ url: URL) -> Bool {
        guard let b = bundled else { return false }
        return url.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// The skin to use: the last one picked, else the built-in one.
    static var active: URL? { current ?? bundled ?? installed.first }

    static var current: URL? {
        get { UserDefaults.standard.string(forKey: "skinPath").map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }
        // The built-in skin is stored as "no choice", so a moved app bundle still finds it.
        set { UserDefaults.standard.set(newValue.flatMap { isBundled($0) ? nil : $0.path }, forKey: "skinPath") }
    }

    static var installed: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "wsz" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Copies the skin into the library (if needed) and returns the library copy.
    static func install(_ url: URL) -> URL {
        if isBundled(url) { return url }
        let dest = directory.appendingPathComponent(url.lastPathComponent)
        if url.standardizedFileURL.path != dest.standardizedFileURL.path {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        return FileManager.default.fileExists(atPath: dest.path) ? dest : url
    }

    static var scale: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: "classicScale"); return v >= 1 ? v : 2 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "classicScale") }
    }
}
