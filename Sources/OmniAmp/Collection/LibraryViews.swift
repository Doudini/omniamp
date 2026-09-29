import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// MARK: Album art

/// Small album covers for the library lists. Each is read once from the share (a cover file next to the
/// tracks, else the art embedded in the first track), shrunk, and kept on the Mac: in memory for what was
/// on screen lately, on disk for good. Rows scrolled away before their cover arrived cancel their read.
@MainActor
final class LibraryArt {
    static let shared = LibraryArt()
    nonisolated static let pixels = 96

    private final class Box { let image: CGImage?; init(_ i: CGImage?) { image = i } }
    private let memory = NSCache<NSString, Box>()
    private var waiting: [String: [Int: (CGImage?) -> Void]] = [:]
    private var operations: [String: Operation] = [:]
    private var nextToken = 0
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "omniamp.library-art"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 4
        return q
    }()
    nonisolated static var directory: URL {
        let d = LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("LibraryArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private init() { memory.countLimit = 600 }

    func cached(_ album: LibraryAlbum) -> CGImage?? { memory.object(forKey: album.folder as NSString).map { $0.image } }

    /// Calls back on the main queue (right away when in memory). Returns a token for `cancel`.
    @discardableResult
    func load(_ album: LibraryAlbum, completion: @escaping (CGImage?) -> Void) -> Int {
        let key = album.folder
        if let box = memory.object(forKey: key as NSString) { completion(box.image); return -1 }
        nextToken += 1
        let token = nextToken
        if waiting[key] != nil { waiting[key]![token] = completion; return token }
        waiting[key] = [token: completion]
        let firstPath = album.firstPath
        let op = BlockOperation {
            let img = autoreleasepool { Self.thumbnail(folder: key, firstPath: firstPath) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(key, img) } }
        }
        operations[key] = op
        queue.addOperation(op)
        return token
    }

    func cancel(_ album: LibraryAlbum, token: Int) {
        let key = album.folder
        guard token >= 0, waiting[key]?.removeValue(forKey: token) != nil else { return }
        if waiting[key]?.isEmpty == true {
            waiting[key] = nil
            operations.removeValue(forKey: key)?.cancel()   // not started yet: never read
        }
    }

    /// Posted with the folder (`object`) when it gets a new cover.
    static let coverChanged = Notification.Name("OmniAmpLibraryCoverChanged")

    /// A folder got a new cover: forget the old one (memory and disk), and say so.
    func forget(folder: String) {
        memory.removeObject(forKey: folder as NSString)
        try? FileManager.default.removeItem(at: Self.cacheFile(folder))
        NotificationCenter.default.post(name: Self.coverChanged, object: folder)
    }

    nonisolated private static func cacheFile(_ folder: String) -> URL {
        let name = SHA256.hash(data: Data(folder.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".png")
    }

    private func finish(_ key: String, _ img: CGImage?) {
        memory.setObject(Box(img), forKey: key as NSString)
        operations[key] = nil
        let cbs = waiting.removeValue(forKey: key) ?? [:]
        cbs.values.forEach { $0(img) }
    }

    /// From the disk cache, else read and shrunk (and cached; "none" is cached too, as an empty file).
    nonisolated private static func thumbnail(folder: String, firstPath: String) -> CGImage? {
        let file = cacheFile(folder)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path) {
            if (attrs[.size] as? Int ?? 0) == 0 { return nil }
            return ArtworkStore.image(contentsOf: file, maxPixels: pixels)
        }
        let data = DetailsReader.folderArt(for: firstPath)?.0 ?? DetailsReader.read(path: firstPath).artwork
        guard let data, let img = ArtworkStore.image(data, maxPixels: pixels) else {
            // No cover (or the share is away): remember only when the folder is really there.
            if ExactPath.exists(folder) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            return nil
        }
        if let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        return img
    }
}

// MARK: Cells

/// A text cell for the library lists: one label, centred vertically, reused by identifier.
final class TextCell: NSTableCellView {
    let field = NSTextField(labelWithString: "")
    init(_ id: String) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(id)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A reusable text cell; return the cell (not its field) from viewFor, or the text isn't centred.
func libraryCell(_ table: NSTableView, _ id: String) -> TextCell {
    (table.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: nil) as? TextCell) ?? TextCell(id)
}

/// An icon glyph centred by its drawn shape (a font's line box puts icon glyphs off-centre).
final class GlyphCell: NSView {
    var glyph = "" { didSet { needsDisplay = true } }
    var color: NSColor = Dash.text3 { didSet { needsDisplay = true } }
    var size: CGFloat = 12 { didSet { needsDisplay = true } }

    init(_ id: String) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(id)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !glyph.isEmpty else { return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: [.font: Theme.icon(size), .foregroundColor: color]))
        let ink = CTLineGetImageBounds(line, ctx)
        ctx.textPosition = CGPoint(x: (bounds.midX - ink.midX).rounded(), y: (bounds.midY - ink.midY).rounded())
        CTLineDraw(line, ctx)
    }
}

/// A sidebar entry: icon and name, each centred on the row (one label with both fonts sat high: the icon
/// font's taller line box moved the baseline).
final class SidebarCell: NSTableCellView {
    private let icon = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("sidebar")
        for f in [icon, name] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.lineBreakMode = .byTruncatingTail
            addSubview(f)
        }
        icon.alignment = .center
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(glyph: String, title: String, selected: Bool, enabled: Bool) {
        icon.stringValue = glyph
        icon.font = Fonts.hack(13)
        icon.textColor = enabled ? (selected ? Dash.accent : Dash.text2) : Dash.text3
        name.stringValue = title
        name.font = Dash.font(13, selected ? .semibold : .regular)
        name.textColor = enabled ? Dash.text : Dash.text3
    }
}

/// Text colors in the library (see Dash): details grey, labels muted.
enum LibraryStyle {
    static var dim: NSColor { Dash.text2 }
    static var header: NSColor { Dash.text3 }
}

/// A name with a count on the right; for years, a bar behind it showing how many.
final class BucketCell: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    var fraction: CGFloat? { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("bucket")
        for f in [name, count] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.lineBreakMode = .byTruncatingTail
            addSubview(f)
        }
        count.alignment = .right
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ title: String, _ n: Int?, bold: Bool = false) {
        name.stringValue = title
        name.font = Dash.font(13, bold ? .semibold : .regular)
        name.textColor = Dash.text
        count.stringValue = n.map { $0.formatted() } ?? ""
        count.font = Dash.mono(10.5)
        count.textColor = Dash.text3
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let f = fraction, f > 0 else { return }
        let w = max(2, (bounds.width - 12) * min(1, f))
        Dash.accent.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: w, height: bounds.height - 8), xRadius: 4, yRadius: 4).fill()
    }
}

/// An album row: cover, title, and a line of details.
final class AlbumCell: NSTableCellView {
    private let art = ArtView()
    private let title = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    /// A thin stripe in the kind's color beside the cover.
    private let stripe = NSView()
    private var album: LibraryAlbum?
    private var token = -1

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("album")
        art.cornerRadius = 4
        art.placeholder = Fonts.Icon.music
        art.surface = Dash.cardRaised
        art.iconColor = Dash.text3
        for f in [title, sub, badge] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.lineBreakMode = .byTruncatingTail
            addSubview(f)
        }
        addSubview(art)
        stripe.translatesAutoresizingMaskIntoConstraints = false
        stripe.wantsLayer = true
        stripe.layer?.cornerRadius = 1
        addSubview(stripe)
        badge.alignment = .right
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stripe.centerYAnchor.constraint(equalTo: centerYAnchor),
            stripe.widthAnchor.constraint(equalToConstant: 3), stripe.heightAnchor.constraint(equalToConstant: 40),
            art.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 5),
            art.centerYAnchor.constraint(equalTo: centerYAnchor),
            art.widthAnchor.constraint(equalToConstant: 40), art.heightAnchor.constraint(equalToConstant: 40),
            title.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ a: LibraryAlbum, withArtist: Bool) {
        if let old = album, old.folder != a.folder { LibraryArt.shared.cancel(old, token: token) }
        album = a
        stripe.layer?.backgroundColor = Theme.kind(a.kind).cgColor
        stripe.toolTip = a.kind.title
        let isShow = a.kind == .show && a.showDate != nil
        title.stringValue = isShow ? [a.showDate, a.venue].compactMap { $0 }.joined(separator: "  ") : a.title
        title.font = Dash.font(13, .semibold)
        let none = a.unplayable >= a.tracks
        title.textColor = none ? Dash.text3 : Dash.text
        var parts: [String] = []
        if withArtist { parts.append(a.artist) }
        if !isShow, let y = a.year { parts.append(String(y)) }
        parts.append(a.tracks == 1 ? "1 track" : "\(a.tracks) tracks")
        if a.duration > 0 { parts.append(Self.length(a.duration)) }
        sub.stringValue = parts.joined(separator: " · ")
        sub.font = Dash.font(11.5)
        sub.textColor = Dash.text2
        // Formats OmniAmp can't play: say which, so the release can be converted.
        let fmt = a.unplayableFormat ?? "FORMAT"
        badge.stringValue = none ? "\(fmt) · CAN'T PLAY" : a.unplayable > 0 ? "\(a.unplayable) \(fmt) CAN'T PLAY" : (a.lossless ? "LOSSLESS" : "")
        badge.font = Dash.mono(8.5, bold: true)
        badge.textColor = a.unplayable > 0 ? Theme.warning : Dash.text3
        badge.toolTip = a.unplayable > 0 ? "macOS has no decoder for \(fmt) files (or they're copy-protected). Convert them to FLAC to play them." : nil
        art.image = nil
        if case let .some(img) = LibraryArt.shared.cached(a) { art.image = img; token = -1; return }
        token = LibraryArt.shared.load(a) { [weak self] img in
            guard let self, self.album?.folder == a.folder else { return }
            self.art.image = img
        }
    }

    static func length(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// A group title in the albums list ("SHOWS & BOOTLEGS · 42").
final class HeaderCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let swatch = NSView()
    private var labelLeading: NSLayoutConstraint!
    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("header")
        for v in [label, swatch] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 2
        labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            swatch.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 8), swatch.heightAnchor.constraint(equalToConstant: 8),
            labelLeading,
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `kind`: the group's kind of recording, shown as its color.
    func show(_ text: String, kind: ReleaseKind? = nil) {
        label.stringValue = text.uppercased()
        label.font = Dash.mono(9.5, bold: true)
        label.textColor = Dash.text2
        swatch.isHidden = kind == nil
        swatch.layer?.backgroundColor = kind.map { Theme.kind($0).cgColor }
        labelLeading.constant = kind == nil ? 8 : 21
    }
}

/// Group rows: no selection look, a thin rule under the title.
final class HeaderRowView: NSTableRowView {
    override var isGroupRowStyle: Bool { get { false } set {} }
    override func drawBackground(in dirtyRect: NSRect) {
        Dash.border.setFill()
        NSRect(x: 8, y: 0.5, width: bounds.width - 16, height: 1).fill()
    }
}

// MARK: A–Z

/// "#", A…Z down the side of the artist list: click or drag to jump; letters with no artists are dim.
final class LetterStrip: NSView {
    static let letters = ["#"] + (65...90).map { String(UnicodeScalar($0)!) }
    var present = Set<String>() { didSet { needsDisplay = true } }
    var current: String? { didSet { if current != oldValue { needsDisplay = true } } }
    var onLetter: ((String) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Dash.card.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let h = bounds.height / CGFloat(Self.letters.count)
        let size = min(10, max(7, h * 0.8))
        for (i, l) in Self.letters.enumerated() {
            let on = present.contains(l)
            let color = l == current ? Dash.accent : (on ? Dash.text2 : Dash.text3.withAlphaComponent(0.5))
            let attrs: [NSAttributedString.Key: Any] = [.font: Fonts.hack(size, bold: l == current), .foregroundColor: color]
            let s = NSAttributedString(string: l, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: CGFloat(i) * h + (h - sz.height) / 2))
        }
    }

    private func pick(_ e: NSEvent) {
        let y = convert(e.locationInWindow, from: nil).y
        let i = max(0, min(Self.letters.count - 1, Int(y / (bounds.height / CGFloat(Self.letters.count)))))
        onLetter?(Self.letters[i])
    }

    override func mouseDown(with event: NSEvent) { pick(event) }
    override func mouseDragged(with event: NSEvent) { pick(event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: Timeline

/// An artist's releases along the years, as a shelf: the official releases (albums, EPs, compilations, live
/// albums) as covers standing at their year, title underneath and a bar in the kind's color; concerts and demos
/// as dots on the line below, with a count when several share a year. When the covers don't fit, a year's
/// releases share one cover (the biggest, "×3"). Hover names a release, click opens it.
final class LibraryTimeline: NSView {
    var albums: [LibraryAlbum] = [] { didSet { rebuild() } }
    var selectedKey: String? { didSet { needsDisplay = true } }
    var onSelect: ((LibraryAlbum) -> Void)?

    /// The covers, oldest first: each official release, or when they don't fit, one per year (its biggest; the
    /// others are counted on it).
    private var shelf: [LibraryAlbum] = []
    private var shelfYear: [[LibraryAlbum]] = []
    private var official: [LibraryAlbum] = []
    private var shelfKinds: [ReleaseKind] = []
    private var coverObserver: NSObjectProtocol?
    /// Dots: per kind, per year.
    private var dots: [(kind: ReleaseKind, year: Int, list: [LibraryAlbum])] = []
    private var dotKinds: [ReleaseKind] = []
    private var span: ClosedRange<Int> = 2000...2001
    private var undated = 0
    private var covers: [String: CGImage] = [:]
    private var tokens: [(LibraryAlbum, Int)] = []
    private var hovered: Hit? { didSet { if hovered != oldValue { needsDisplay = true; updateTip() } } }

    private enum Hit: Equatable { case cover(Int), dot(Int) }

    private static let cover: CGFloat = 44
    private let side: CGFloat = 10
    private var shelfTop: CGFloat { 16 }
    private var titleTop: CGFloat { shelfTop + Self.cover + 5 }
    private var lineY: CGFloat { shelf.isEmpty ? 14 : titleTop + 30 }
    private var axisY: CGFloat { lineY + 10 }

    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat { albums.isEmpty ? 0 : axisY + 16 }

    private func rebuild() {
        for (a, t) in tokens { LibraryArt.shared.cancel(a, token: t) }
        tokens = []
        covers = [:]
        hovered = nil
        let dated = albums.filter { $0.year != nil }
        undated = albums.count - dated.count
        // Shows only (the Shows list): all dots, no shelf.
        official = dated.filter(\.kind.isOfficial).sorted { ($0.year!, $0.kind.rawValue, $0.title) < ($1.year!, $1.kind.rawValue, $1.title) }
        shelfKinds = ReleaseKind.allCases.filter { k in official.contains { $0.kind == k } }
        arrangeShelf()
        let rest = dated.filter { !$0.kind.isOfficial }
        var grouped: [ReleaseKind: [Int: [LibraryAlbum]]] = [:]
        for a in rest { grouped[a.kind, default: [:]][a.year!, default: []].append(a) }
        dotKinds = ReleaseKind.allCases.filter { grouped[$0] != nil }
        dots = dotKinds.flatMap { k in grouped[k]!.map { (k, $0.key, $0.value) } }.sorted { ($0.year, $0.kind.rawValue) < ($1.year, $1.kind.rawValue) }
        let years = dated.compactMap(\.year)
        if let lo = years.min(), let hi = years.max() {
            let pad = max(1, (10 - (hi - lo)) / 2)
            span = (lo - pad)...(hi + pad)
        }
        for a in official { loadCover(a) }
        if coverObserver == nil {
            coverObserver = NotificationCenter.default.addObserver(forName: LibraryArt.coverChanged, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self, let folder = n.object as? String, let a = self.official.first(where: { $0.folder == folder }) else { return }
                    self.covers[folder] = nil
                    self.loadCover(a)
                }
            }
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func loadCover(_ a: LibraryAlbum) {
        let key = a.folder
        let t = LibraryArt.shared.load(a) { [weak self] img in
            guard let self, let img else { return }
            self.covers[key] = img
            self.needsDisplay = true
        }
        if t >= 0 { tokens.append((a, t)) }
    }

    /// Every release its own cover when they fit side by side; else a cover per year.
    private func arrangeShelf() {
        let room = bounds.width - 2 * side - Self.cover
        let fits = official.count <= 1 || room / CGFloat(official.count - 1) >= Self.cover + 8
        if fits {
            shelfYear = official.map { [$0] }
        } else {
            let byYear = Dictionary(grouping: official, by: { $0.year! })
            shelfYear = byYear.keys.sorted().map { y in byYear[y]!.sorted { ($0.tracks, $1.title) > ($1.tracks, $0.title) } }
        }
        shelf = shelfYear.map { $0[0] }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { arrangeShelf(); needsDisplay = true }
    }

    private var plot: (minX: CGFloat, maxX: CGFloat) { (side + Self.cover / 2, max(side + Self.cover, bounds.width - side - Self.cover / 2)) }

    private func x(_ year: Int) -> CGFloat {
        let p = plot
        return p.minX + (p.maxX - p.minX) * CGFloat(year - span.lowerBound) / CGFloat(max(1, span.upperBound - span.lowerBound))
    }

    /// Each cover's left edge: at its year, pushed apart where years crowd; overlapping when there are too many.
    private func coverFrames() -> [NSRect] {
        guard !shelf.isEmpty else { return [] }
        let minX = side, maxX = bounds.width - side
        let step = min(Self.cover + 20, (maxX - minX - Self.cover) / CGFloat(max(1, shelf.count - 1)))
        var left = shelf.map { x($0.year!) - Self.cover / 2 }
        for i in left.indices {
            left[i] = max(left[i], minX, i > 0 ? left[i - 1] + step : minX)
        }
        for i in left.indices.reversed() {
            left[i] = min(left[i], maxX - Self.cover, i < left.count - 1 ? left[i + 1] - step : maxX - Self.cover)
        }
        return left.map { NSRect(x: max(minX, $0), y: shelfTop, width: Self.cover, height: Self.cover) }
    }

    /// Dot centres: at the year, kinds of the same year side by side.
    private func dotCenters() -> [NSPoint] {
        var seen: [Int: Int] = [:]
        return dots.map { d in
            let n = seen[d.year, default: 0]
            seen[d.year] = n + 1
            return NSPoint(x: x(d.year) + CGFloat(n) * 11, y: lineY)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !albums.isEmpty else { return }
        let frames = coverFrames()
        // Room for a title: the space to the neighbours (covers can stand close where years crowd).
        let room: [CGFloat] = frames.indices.map { i in
            let left = i > 0 ? frames[i].midX - frames[i - 1].midX : 200
            let right = i < frames.count - 1 ? frames[i + 1].midX - frames[i].midX : 200
            return min(left, right, 110) - 6
        }
        let year: [NSAttributedString.Key: Any] = [.font: Fonts.hack(8.5), .foregroundColor: Dash.text3]
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail

        // The line the dots sit on, and the years under it.
        Dash.border.setFill()
        NSRect(x: side, y: lineY, width: bounds.width - 2 * side, height: 1).fill()
        // What the dots are (the covers explain themselves) on the left, what has no year on the right, and the
        // years in between where they fit.
        var taken: [ClosedRange<CGFloat>] = []
        var lx = side
        let legendKinds = (shelfKinds.count > 1 ? shelfKinds.map { ($0, true) } : []) + dotKinds.map { ($0, false) }
        for (k, isCover) in legendKinds {
            let t = NSAttributedString(string: k.title, attributes: [.font: Dash.font(10.5), .foregroundColor: Dash.text2])
            Theme.kind(k).setFill()
            let mark = NSRect(x: lx, y: axisY + 3, width: 7, height: 7)
            (isCover ? NSBezierPath(roundedRect: mark, xRadius: 1.5, yRadius: 1.5) : NSBezierPath(ovalIn: mark)).fill()
            t.draw(at: NSPoint(x: lx + 11, y: axisY - 1))
            lx += 11 + t.size().width + 14
        }
        if lx > side { taken.append(side...(lx - 8)) }
        if undated > 0 {
            let t = NSAttributedString(string: "+\(undated) undated", attributes: [.font: Dash.font(10.5), .foregroundColor: Dash.text3])
            let ux = bounds.width - side - t.size().width
            t.draw(at: NSPoint(x: ux, y: axisY - 1))
            taken.append((ux - 8)...(bounds.width))
        }
        let years = span.upperBound - span.lowerBound
        let every = years <= 12 ? 1 : years <= 30 ? 5 : 10
        var yr = (span.lowerBound + every - 1) / every * every
        while yr <= span.upperBound {
            let s = NSAttributedString(string: String(yr), attributes: year)
            let w = s.size().width, px = min(max(side, x(yr) - w / 2), bounds.width - w - side)
            Dash.border.setFill()
            NSRect(x: x(yr), y: lineY - 2, width: 1, height: 5).fill()
            if !taken.contains(where: { $0.overlaps(px...(px + w)) }) { s.draw(at: NSPoint(x: px, y: axisY)) }
            yr += every
        }

        var countRight: CGFloat = -1
        for (i, d) in zip(dots.indices, dotCenters()) {
            let item = dots[i]
            let hot = hovered == .dot(i) || item.list.contains { $0.key == selectedKey }
            let r = NSRect(x: d.x - 4, y: d.y - 4, width: 8, height: 8)
            Dash.card.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: -2, dy: -2)).fill()   // a gap where it crosses the line
            Theme.kind(item.kind).setFill()
            NSBezierPath(ovalIn: r).fill()
            if hot {
                Dash.text.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            // How many, above the dot, where it doesn't run into the one before (the tooltip has them all).
            if item.list.count > 1 {
                let c = NSAttributedString(string: "\(item.list.count)", attributes: [.font: Fonts.hack(8.5, bold: true), .foregroundColor: Dash.text2])
                let cx = d.x - c.size().width / 2
                if cx > countRight + 3 {
                    c.draw(at: NSPoint(x: cx, y: d.y - 17))
                    countRight = cx + c.size().width
                }
            }
        }

        // Covers last, the hovered and selected ones on top.
        let order = frames.indices.sorted { a, b in
            func rank(_ i: Int) -> Int { hovered == .cover(i) ? 2 : shelf[i].key == selectedKey ? 1 : 0 }
            return (rank(a), a) < (rank(b), b)
        }
        // Each cover's year above it, where it doesn't run into the one before.
        var yearRight: CGFloat = -1
        for i in frames.indices {
            let s = NSAttributedString(string: String(shelf[i].year!), attributes: year)
            let yx = frames[i].midX - s.size().width / 2
            if yx > yearRight + 4 {
                s.draw(at: NSPoint(x: yx, y: 3))
                yearRight = yx + s.size().width
            }
        }
        for i in order {
            let a = shelf[i], r = frames[i]
            let selected = a.key == selectedKey, hot = hovered == .cover(i)
            let clip = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            if let img = covers[a.folder] {
                NSImage(cgImage: img, size: r.size).draw(in: r)
            } else {
                Dash.cardRaised.setFill()
                r.fill()
                let g = NSAttributedString(string: Fonts.Icon.music, attributes: [.font: Fonts.hack(16), .foregroundColor: Dash.text3])
                g.draw(at: NSPoint(x: r.midX - g.size().width / 2, y: r.midY - g.size().height / 2))
            }
            // Its kind: a bar along the bottom (the legend names them).
            if shelfKinds.count > 1 {
                Theme.kind(a.kind).setFill()
                NSRect(x: r.minX, y: r.maxY - 4, width: r.width, height: 4).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            (selected ? Dash.accent : hot ? Dash.text : Dash.border).setStroke()
            clip.lineWidth = selected || hot ? 2 : 1
            clip.stroke()
            // Several that year: how many, on the cover's corner.
            let more = shelfYear[i].count
            if more > 1 {
                let b = NSAttributedString(string: "×\(more)", attributes: [.font: Fonts.hack(8.5, bold: true), .foregroundColor: Dash.text])
                let br = NSRect(x: r.maxX - b.size().width - 6, y: r.maxY - 13, width: b.size().width + 6, height: 12)
                Dash.page.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: br.offsetBy(dx: 1, dy: 0), xRadius: 3, yRadius: 3).fill()
                b.draw(at: NSPoint(x: br.minX + 3, y: br.minY))
            }
            let roomy = room[i] >= 40
            if roomy || selected || hot {
                let w = roomy ? room[i] : 150
                let t = NSAttributedString(string: a.title, attributes: [
                    .font: Dash.font(10.5, selected || hot ? .semibold : .regular),
                    .foregroundColor: selected || hot ? Dash.text : Dash.text2, .paragraphStyle: para])
                let tr = NSRect(x: min(max(side, r.midX - w / 2), bounds.width - side - w), y: titleTop, width: w, height: 28)
                if !roomy {   // over its neighbours: on a backing
                    Dash.card.setFill()
                    NSBezierPath(roundedRect: tr.insetBy(dx: -2, dy: 0), xRadius: 3, yRadius: 3).fill()
                }
                t.draw(with: tr, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
    }

    private func hit(_ e: NSEvent) -> Hit? {
        let pt = convert(e.locationInWindow, from: nil)
        let frames = coverFrames()
        // Topmost first: covers drawn later are on top.
        if let i = frames.indices.reversed().first(where: { frames[$0].contains(pt) }) { return .cover(i) }
        if abs(pt.y - lineY) <= 9 {
            let c = dotCenters()
            if let i = c.indices.min(by: { abs(c[$0].x - pt.x) < abs(c[$1].x - pt.x) }), abs(c[i].x - pt.x) <= 7 { return .dot(i) }
        }
        return nil
    }

    private func albumsAt(_ h: Hit) -> [LibraryAlbum] {
        switch h {
        case .cover(let i): i < shelfYear.count ? shelfYear[i] : []
        case .dot(let i): i < dots.count ? dots[i].list : []
        }
    }

    private func updateTip() {
        guard let h = hovered, let a = albumsAt(h).first else { toolTip = nil; return }
        let list = albumsAt(h)
        func name(_ a: LibraryAlbum) -> String { a.kind == .show ? [a.showDate, a.venue].compactMap { $0 }.joined(separator: " ") : a.title }
        toolTip = list.count == 1 ? "\(a.year.map(String.init) ?? "") · \(a.kind.title) · \(name(a))"
            : "\(a.year.map(String.init) ?? "") · \(list.count) \(a.kind.title.lowercased()):\n" + list.prefix(10).map(name).joined(separator: "\n")
    }

    override func mouseDown(with event: NSEvent) {
        if let h = hit(event), let first = albumsAt(h).first { onSelect?(first) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = hit(event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
}
