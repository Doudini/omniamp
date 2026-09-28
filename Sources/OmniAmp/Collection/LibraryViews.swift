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

    /// A folder got a new cover: forget the old one (memory and disk).
    func forget(folder: String) {
        memory.removeObject(forKey: folder as NSString)
        try? FileManager.default.removeItem(at: Self.cacheFile(folder))
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

func libraryLabel(_ table: NSTableView, _ id: String) -> NSTextField {
    ((table.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: nil) as? TextCell) ?? TextCell(id)).field
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

/// An artist's releases along the years: a lane per kind (albums, live, shows, demos…), each year's releases
/// as a block that's brighter the more there are. Click a block to go to that year's first release.
final class LibraryTimeline: NSView {
    var albums: [LibraryAlbum] = [] { didSet { rebuild() } }
    var selectedKey: String? { didSet { needsDisplay = true } }
    var onSelect: ((LibraryAlbum) -> Void)?

    private var lanes: [ReleaseKind] = []
    private var cells: [ReleaseKind: [Int: [LibraryAlbum]]] = [:]
    private var span: ClosedRange<Int> = 2000...2001
    private var undated = 0
    static let laneHeight: CGFloat = 13
    private let labelWidth: CGFloat = 54
    private let axisHeight: CGFloat = 14

    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat { lanes.isEmpty ? 0 : CGFloat(lanes.count) * Self.laneHeight + axisHeight + 8 }

    private func rebuild() {
        cells = [:]
        undated = 0
        var years: [Int] = []
        for a in albums {
            guard let y = a.year else { undated += 1; continue }
            cells[a.kind, default: [:]][y, default: []].append(a)
            years.append(y)
        }
        lanes = ReleaseKind.allCases.filter { cells[$0] != nil }
        // At least a decade wide, so a single year is a mark on a line, not a bar across it.
        if let lo = years.min(), let hi = years.max() {
            let pad = max(1, (10 - (hi - lo)) / 2)
            span = (lo - pad)...(hi + pad)
        }
        toolTip = nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
        updateTrackingAreas()
    }

    private static func short(_ k: ReleaseKind) -> String {
        switch k {
        case .album: "ALBUM"
        case .single: "EP/SGL"
        case .compilation: "COMP"
        case .live: "LIVE"
        case .show: "SHOWS"
        case .unreleased: "DEMOS"
        }
    }

    private var plot: NSRect { NSRect(x: labelWidth, y: 4, width: max(1, bounds.width - labelWidth - 8), height: CGFloat(lanes.count) * Self.laneHeight) }

    private func x(_ year: Int) -> CGFloat {
        let p = plot
        return p.minX + p.width * CGFloat(year - span.lowerBound) / CGFloat(max(1, span.upperBound - span.lowerBound))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !lanes.isEmpty else { return }
        let p = plot
        let yearW = min(12, max(2, p.width / CGFloat(max(1, span.upperBound - span.lowerBound)) - 1))
        let most = cells.values.flatMap { $0.values.map(\.count) }.max() ?? 1
        let label: [NSAttributedString.Key: Any] = [.font: Fonts.hack(8, bold: true), .foregroundColor: Dash.text2]
        for (i, kind) in lanes.enumerated() {
            let y = p.minY + CGFloat(i) * Self.laneHeight
            Theme.kind(kind).setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: y + 3, width: 6, height: 6), xRadius: 1.5, yRadius: 1.5).fill()
            NSAttributedString(string: Self.short(kind), attributes: label).draw(at: NSPoint(x: 12, y: y + 1))
            Dash.grid.setFill()
            NSRect(x: p.minX, y: y + Self.laneHeight / 2, width: p.width, height: 1).fill()
            for (year, list) in cells[kind] ?? [:] {
                let strength = 0.35 + 0.65 * CGFloat(list.count) / CGFloat(most)
                let r = NSRect(x: x(year) - yearW / 2, y: y + 2, width: yearW, height: Self.laneHeight - 4)
                Theme.kind(kind).withAlphaComponent(strength).setFill()
                NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
                if let sel = selectedKey, list.contains(where: { $0.key == sel }) {
                    Theme.current.setStroke()
                    let path = NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), xRadius: 2, yRadius: 2)
                    path.lineWidth = 1.5
                    path.stroke()
                }
            }
        }
        // Axis: a label every 5 or 10 years, as fits.
        let axis: [NSAttributedString.Key: Any] = [.font: Fonts.hack(8), .foregroundColor: Dash.text3]
        let years = span.upperBound - span.lowerBound
        let step = years <= 12 ? 1 : years <= 30 ? 5 : 10
        var yr = (span.lowerBound + step - 1) / step * step
        while yr <= span.upperBound {
            let s = NSAttributedString(string: String(yr), attributes: axis)
            let w = s.size().width
            s.draw(at: NSPoint(x: min(max(p.minX, x(yr) - w / 2), bounds.width - w - 2), y: p.maxY + 2))
            yr += step
        }
        if undated > 0 {
            let s = NSAttributedString(string: "+\(undated) undated", attributes: axis)
            s.draw(at: NSPoint(x: 4, y: p.maxY + 2))
        }
    }

    private func hit(_ e: NSEvent) -> [LibraryAlbum]? {
        let pt = convert(e.locationInWindow, from: nil)
        let p = plot
        guard pt.x >= p.minX - 4, pt.y >= p.minY, pt.y < p.maxY else { return nil }
        let lane = Int((pt.y - p.minY) / Self.laneHeight)
        guard lane < lanes.count, let row = cells[lanes[lane]] else { return nil }
        // The nearest year that has something, within half a year's width or 4 points.
        let yearW = p.width / CGFloat(max(1, span.upperBound - span.lowerBound))
        let best = row.keys.min { abs(x($0) - pt.x) < abs(x($1) - pt.x) }
        guard let y = best, abs(x(y) - pt.x) <= max(4, yearW / 2) else { return nil }
        return row[y]
    }

    override func mouseDown(with event: NSEvent) {
        if let list = hit(event), let first = list.first { onSelect?(first) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let list = hit(event), let a = list.first else { toolTip = nil; return }
        let what = list.count == 1 ? (a.kind == .show ? [a.showDate, a.venue].compactMap { $0 }.joined(separator: " ") : a.title)
                                   : "\(list.count) \(a.kind.title.lowercased())"
        toolTip = "\(a.year.map(String.init) ?? "") · \(what)"
    }
}
