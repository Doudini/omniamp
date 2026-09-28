import AppKit

/// Country outlines (Natural Earth 1:110m) in the Equal Earth projection: areas true to size, and it reads
/// like the familiar map. Antarctica is left out (no music from there to show).
struct WorldMap {
    struct Country {
        let iso: String
        let name: String
        /// Projected outline in map units (x right, y up), and its bounding box.
        let path: NSBezierPath
        let bounds: NSRect
    }

    static let shared = WorldMap()
    let countries: [Country]
    /// All countries' extent, in map units.
    let extent: NSRect

    private init() {
        let data = Data(base64Encoded: WorldMapData.countries.filter { !$0.isWhitespace }) ?? Data()
        let b = [UInt8](data)
        var p = 0, out: [Country] = []
        func u16() -> Int { defer { p += 2 }; return p + 2 <= b.count ? Int(b[p]) | Int(b[p + 1]) << 8 : 0 }
        func i16() -> Double { Double(Int16(bitPattern: UInt16(u16()))) / 50 }
        while p + 3 <= b.count {
            let iso = String(decoding: b[p..<(p + 2)], as: UTF8.self)
            let nl = Int(b[p + 2])
            let name = String(decoding: b[(p + 3)..<min(p + 3 + nl, b.count)], as: UTF8.self)
            p += 3 + nl
            let path = NSBezierPath()
            for _ in 0..<u16() {
                let n = u16()
                for i in 0..<n {
                    let pt = Self.project(lon: i16(), lat: i16())
                    if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
                }
                path.close()
            }
            if iso != "AQ" { out.append(Country(iso: iso, name: name, path: path, bounds: path.bounds)) }
        }
        // Large countries first, so ones inside or beside them (Lesotho, the Vatican of this scale) stay on top.
        countries = out.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
        extent = out.reduce(NSRect.null) { $0.union($1.bounds) }
    }

    /// Equal Earth (Šavrič, Patterson & Jenny, 2018).
    static func project(lon: Double, lat: Double) -> NSPoint {
        let a1 = 1.340264, a2 = -0.081106, a3 = 0.000893, a4 = 0.003796, m = sqrt(3) / 2
        let lam = lon * .pi / 180, phi = lat * .pi / 180
        let t = asin(m * sin(phi)), t2 = t * t, t6 = t2 * t2 * t2
        let x = 2 * sqrt(3) * lam * cos(t) / (3 * (9 * a4 * t6 * t2 + 7 * a3 * t6 + 3 * a2 * t2 + a1))
        let y = t * (a4 * t6 * t2 + a3 * t6 + a2 * t2 + a1)
        return NSPoint(x: x, y: y)
    }
}

/// A choropleth of the world: countries lit by how much music comes from there. Hover for figures, click
/// to pick a country.
final class WorldMapView: NSView {
    /// Value per ISO country code, and what the tooltip says for it.
    var values: [String: Double] = [:] { didSet { needsDisplay = true } }
    var describe: (String, String) -> String = { name, _ in name }   // (country name, iso) → tooltip
    var selected: String? { didSet { needsDisplay = true } }
    var onSelect: ((String, String) -> Void)?   // iso, name

    private let map = WorldMap.shared
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true; updateTip() } } }
    private lazy var height: NSLayoutConstraint = {
        let c = heightAnchor.constraint(equalToConstant: 300)
        c.isActive = true
        return c
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Map units → view points (aspect kept, centred).
    private var transform: AffineTransform {
        let e = map.extent
        let s = min(bounds.width / e.width, bounds.height / e.height)
        var t = AffineTransform()
        t.translate(x: (bounds.width - e.width * s) / 2 - e.minX * s, y: (bounds.height - e.height * s) / 2 - e.minY * s)
        t.scale(s)
        return t
    }

    override func layout() {
        // As tall as the width allows at the map's own proportions.
        let h = (bounds.width * map.extent.height / max(map.extent.width, 1)).rounded()
        if bounds.width > 0, abs(height.constant - h) > 0.5 { height.constant = h }
        super.layout()
    }

    /// Five steps of one hue on a log scale: a country with a few plays is still visibly lit.
    static let steps: [CGFloat] = [0.22, 0.4, 0.58, 0.78, 1]

    static func step(_ v: Double, max: Double) -> Int {
        guard v > 0, max > 0 else { return -1 }
        let t = log1p(v) / log1p(max)
        return Swift.min(4, Int(t * 5))
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = transform
        let most = values.values.max() ?? 0
        for (i, c) in map.countries.enumerated() {
            let p = c.path.copy() as! NSBezierPath
            p.transform(using: t)
            let s = Self.step(values[c.iso] ?? 0, max: most)
            (s < 0 ? Theme.phosphorDim.withAlphaComponent(0.14) : Theme.phosphor.withAlphaComponent(Self.steps[s])).setFill()
            p.fill()
            Theme.lcd.setStroke()
            p.lineWidth = 0.6
            p.stroke()
            if i == hovered || c.iso == selected {
                (c.iso == selected ? Theme.current : Theme.current.withAlphaComponent(0.7)).setStroke()
                p.lineWidth = 1.5
                p.stroke()
            }
        }
    }

    private func country(at e: NSEvent) -> Int? {
        var inv = transform
        inv.invert()
        let pt = inv.transform(convert(e.locationInWindow, from: nil))
        // Topmost first: small countries are drawn last.
        return map.countries.indices.reversed().first { map.countries[$0].bounds.contains(pt) && map.countries[$0].path.contains(pt) }
    }

    private func updateTip() {
        toolTip = hovered.map { describe(map.countries[$0].name, map.countries[$0].iso) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }
    override func mouseMoved(with event: NSEvent) { hovered = country(at: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {
        guard let i = country(at: event) else { return }
        onSelect?(map.countries[i].iso, map.countries[i].name)
    }
}
