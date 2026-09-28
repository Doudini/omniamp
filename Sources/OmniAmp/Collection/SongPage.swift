import AppKit

/// The lanes of a song's timeline: what kind of recording, grouped the way a collector thinks of them.
enum VersionLane: Int, CaseIterable {
    case studio, other, live, show, demo

    init(_ k: ReleaseKind) {
        switch k {
        case .album: self = .studio
        case .single, .compilation: self = .other
        case .live: self = .live
        case .show: self = .show
        case .unreleased: self = .demo
        }
    }

    var title: String {
        switch self {
        case .studio: "ALBUMS"
        case .other: "EP / COMP"
        case .live: "LIVE"
        case .show: "SHOWS"
        case .demo: "DEMOS"
        }
    }

    /// The color of its kind (Theme.kind).
    var kind: ReleaseKind {
        switch self {
        case .studio: .album
        case .other: .single
        case .live: .live
        case .show: .show
        case .demo: .unreleased
        }
    }
}

/// Every recording of a song along the years: a lane per kind, a dot per recording. Hover for the details, click
/// to play that one.
final class VersionTimeline: StatsChart {
    var versions: [SongVersion] = [] { didSet { invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true } }
    var playsFor: (SongVersion) -> Int = { _ in 0 }
    var onPlay: ((SongVersion) -> Void)?
    private static let laneH: CGFloat = 36, labelW: CGFloat = 92, axisH: CGFloat = 20, r: CGFloat = 4.5

    private var dated: [SongVersion] { versions.filter { $0.when != nil } }
    private var lanes: [VersionLane] { VersionLane.allCases.filter { l in versions.contains { VersionLane($0.kind) == l } } }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(max(lanes.count, 1)) * Self.laneH + Self.axisH)
    }

    private var span: ClosedRange<Double> {
        let ws = dated.compactMap(\.when)
        guard let lo = ws.min(), let hi = ws.max() else { return 2000...2001 }
        let pad = max(0.5, (hi - lo) * 0.04)
        return (lo - pad)...(max(hi + pad, lo + 2))
    }

    private func x(_ w: Double) -> CGFloat {
        let left = Self.labelW + Self.r, width = bounds.width - left - Self.r - 4
        return left + width * CGFloat((w - span.lowerBound) / (span.upperBound - span.lowerBound))
    }

    /// Dot centres, packed like a beeswarm: a dot that would cover another takes the nearest free spot above or
    /// below the lane's line (three rows); only when those are taken too do dots overlap.
    private func centres() -> [(SongVersion, NSPoint)] {
        var out: [(SongVersion, NSPoint)] = []
        var placed: [VersionLane: [NSPoint]] = [:]
        let d = Self.r * 2 + 1
        for v in dated {
            let lane = VersionLane(v.kind)
            guard let row = lanes.firstIndex(of: lane), let w = v.when else { continue }
            let cx = x(w), mid = CGFloat(row) * Self.laneH + Self.laneH / 2
            let taken = placed[lane] ?? []
            let spot = [0, -d, d].map { NSPoint(x: cx, y: mid + $0) }.first { p in
                !taken.contains { hypot($0.x - p.x, $0.y - p.y) < d }
            } ?? NSPoint(x: cx, y: mid)
            placed[lane, default: []].append(spot)
            out.append((v, spot))
        }
        return out
    }

    override func layoutRegions() {
        regions = centres().map { v, c in
            let plays = playsFor(v)
            let tip = [v.label, v.track.duration.map(AlbumCell.length), v.track.format,
                       plays > 0 ? "\(plays) play\(plays == 1 ? "" : "s")" : nil, v.track.playable ? "click to play" : "can't play this format"]
                .compactMap { $0 }.joined(separator: " · ")
            return Region(rect: NSRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14), tip: tip, action: onPlay.map { f in { f(v) } })
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (row, lane) in lanes.enumerated() {
            let y = CGFloat(row) * Self.laneH
            // The lane's label with its color: the legend is the labels.
            Theme.kind(lane.kind).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: y + Self.laneH / 2 - 4, width: 8, height: 8), xRadius: 2, yRadius: 2).fill()
            let n = versions.filter { VersionLane($0.kind) == lane }.count
            Self.text("\(lane.title) \(n)", 9, Dash.text2, bold: true).draw(at: NSPoint(x: 15, y: y + Self.laneH / 2 - 7))
            Dash.grid.setFill()
            NSRect(x: Self.labelW, y: y + Self.laneH / 2, width: bounds.width - Self.labelW - 4, height: 1).fill()
        }
        // Axis: years, every 1, 2, 5 or 10 as fits.
        let years = span.upperBound - span.lowerBound
        let step = years <= 8 ? 1 : years <= 16 ? 2 : years <= 40 ? 5 : 10
        let baseY = CGFloat(lanes.count) * Self.laneH
        var yr = Int(span.lowerBound.rounded(.up))
        yr = (yr + step - 1) / step * step
        while Double(yr) <= span.upperBound {
            let px = x(Double(yr))
            Dash.grid.setFill()
            NSRect(x: px, y: 0, width: 1, height: baseY).fill()
            Self.text(String(yr), 8.5, Dash.text3).draw(at: NSPoint(x: px - 12, y: baseY + 4))
            yr += step
        }
        let undated = versions.count - dated.count
        if undated > 0 { Self.text("+\(undated) undated", 8.5, Dash.text3).draw(at: NSPoint(x: 15, y: baseY + 4)) }
        for (i, (v, c)) in centres().enumerated() {
            let hot = hovered == i
            let rad = hot ? Self.r + 2 : Self.r
            let dot = NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
            Theme.kind(v.kind).withAlphaComponent(v.track.playable ? 1 : 0.35).setFill()
            dot.fill()
            // A ring in the background color keeps overlapping dots apart; white when hovered.
            (hot ? Dash.text : Dash.card).setStroke()
            dot.lineWidth = hot ? 2 : 1.5
            dot.stroke()
        }
    }
}

/// One song across all its recordings: when each was made, how long each is, which you play.
final class SongPage: NSScrollView {
    var onBack: (() -> Void)?
    var onArtist: ((String) -> Void)?
    var onPlay: (([LibraryTrack]) -> Void)?
    var onAdd: (([LibraryTrack]) -> Void)?
    private let stack = NSStackView()
    private var versions: [SongVersion] = []
    private var plays = SongPlays()
    private var artistKey = ""
    private var generation = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = false
        hasVerticalScroller = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Show a song (artist key and title key); read off the main thread.
    func show(artist: String, titleKey: String) {
        artistKey = artist
        generation += 1
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let db = try? CollectionDB()
            let v = (try? db?.versions(artist: artist, titleKey: titleKey)) ?? []
            let p = (try? db?.songPlays(artist: artist, titleKey: titleKey)) ?? SongPlays()
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.versions = v
                self.plays = p
                self.build()
                self.scrollToTop()
            }
        }
    }

    /// Plays of a version: last.fm plays carry the album name they were played from.
    private func plays(_ v: SongVersion) -> Int {
        plays.byAlbum[Keys.fold(v.release)] ?? plays.byAlbum[Keys.fold(v.track.album)] ?? 0
    }

    private func button(_ glyph: String, _ label: String, _ action: Selector, tip: String, prominent: Bool = false) -> Pill {
        let b = Pill(label, glyph: glyph.isEmpty ? nil : glyph, target: self, action: action)
        b.prominent = prominent
        b.toolTip = tip
        return b
    }

    @objc private func back() { onBack?() }
    @objc private func openArtist() { onArtist?(artistKey) }
    @objc private func playAll() { onPlay?(versions.map(\.track)) }
    @objc private func playLive() { onPlay?(versions.filter { [.live, .show].contains($0.kind) }.map(\.track)) }
    @objc private func addAll() { onAdd?(versions.map(\.track)) }

    private func build() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let first = versions.first else {
            let l = NSTextField(labelWithString: "No recordings of this song in the library.")
            l.font = Dash.font(13)
            l.textColor = Dash.text2
            stack.addArrangedSubview(button("", "‹  Back", #selector(back), tip: "Back to the library"))
            stack.addArrangedSubview(l)
            return
        }

        // Title, artist, the counts; then the actions.
        let title = NSTextField(labelWithString: Self.bestTitle(versions))
        title.font = Dash.font(24, .semibold)
        title.textColor = Dash.text
        title.lineBreakMode = .byTruncatingTail
        let artist = NSButton(title: first.track.artist, target: self, action: #selector(openArtist))
        artist.isBordered = false
        artist.attributedTitle = NSAttributedString(string: first.track.artist, attributes: [.font: Dash.font(14, .semibold),
                                                                                             .foregroundColor: Dash.accent])
        artist.toolTip = "Open the artist"
        let official = versions.filter { $0.kind.isOfficial }.count
        let years = versions.compactMap { $0.when.map { Int($0) } }
        var summary = "\(versions.count) recording\(versions.count == 1 ? "" : "s") · \(official) official · \(versions.count - official) unofficial"
        if let lo = years.min(), let hi = years.max() { summary += lo == hi ? " · \(lo)" : " · \(lo)–\(hi)" }
        if plays.total > 0 { summary += " · \(plays.total.formatted()) plays" }
        let sub = NSTextField(labelWithString: summary)
        sub.font = Dash.font(12.5)
        sub.textColor = Dash.text2
        let names = NSStackView(views: [artist, sub])
        names.spacing = 10
        let top = NSStackView(views: [button("", "‹  Back", #selector(back), tip: "Back to the library"), title])
        top.spacing = 12
        let live = versions.contains { [.live, .show].contains($0.kind) }
        var actions: [NSView] = [button(Fonts.Icon.play, "Play all in order", #selector(playAll), tip: "Oldest to newest: the song's whole story", prominent: true)]
        if live { actions.append(button(Fonts.Icon.play, "Live only", #selector(playLive), tip: "Live albums and shows, oldest first")) }
        actions.append(button(Fonts.Icon.plus, "Add all", #selector(addAll), tip: "Add every version to the playlist"))
        let actionRow = NSStackView(views: actions)
        actionRow.spacing = 6
        let header = NSStackView(views: [top, names, actionRow])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        stack.addArrangedSubview(header)

        let timeline = VersionTimeline()
        timeline.playsFor = { [weak self] in self?.plays($0) ?? 0 }
        timeline.onPlay = { [weak self] v in self?.onPlay?([v.track]) }
        timeline.versions = versions
        add(StatsPanel("Versions through time", timeline, note: "a dot per recording · hover for details, click to play"))

        // Lengths, in the same order: jams grow, demos are short.
        let lengths = BarListChart()
        let byKey = Dictionary(versions.map { ($0.track.key, $0) }, uniquingKeysWith: { a, _ in a })
        let durations = versions.compactMap(\.track.duration)
        let longest = durations.max(), shortest = durations.min()
        lengths.bars = versions.map { v in
            let d = v.track.duration ?? 0
            let mark = durations.count > 2 && d == longest ? "longest · " : (durations.count > 2 && d == shortest ? "shortest · " : "")
            return .init(id: v.track.key, label: v.label, value: d, detail: mark + v.track.format)
        }
        lengths.format = { $0 > 0 ? AlbumCell.length($0) : "–" }
        lengths.color = { byKey[$0.id].map { Theme.kind($0.kind) } }
        lengths.tip = { "\($0.label): \($0.value > 0 ? AlbumCell.length($0.value) : "length unknown") · click to play" }
        lengths.onClick = { [weak self] b in if let v = byKey[b.id] { self?.onPlay?([v.track]) } }

        // Your plays: which versions, and when.
        var right: [NSView] = []
        if plays.total > 0 {
            let perVersion = BarListChart()
            var bars: [LibraryStats.Bar] = []
            var counted = Set<String>()
            for v in versions {
                let n = plays(v), album = Keys.fold(v.release)
                guard n > 0, counted.insert(album).inserted else { continue }
                bars.append(.init(id: v.track.key, label: v.label, value: Double(n)))
            }
            let other = plays.total - bars.reduce(0) { $0 + Int($1.value) }
            bars.sort { $0.value > $1.value }
            if other > 0 { bars.append(.init(id: "", label: "other releases", value: Double(other), detail: "not in library")) }
            perVersion.bars = Array(bars.prefix(12))
            perVersion.color = { byKey[$0.id].map { Theme.kind($0.kind) } ?? Dash.text3 }
            perVersion.tip = { "\($0.label): \(Int($0.value).formatted()) plays" }
            let years = YearsChart()
            years.unit = "play"
            years.years = plays.byYear
            let f = DateFormatter()
            f.dateStyle = .medium
            let note = [plays.first.map { "first \(f.string(from: $0))" }, plays.last.map { "last \(f.string(from: $0))" }]
                .compactMap { $0 }.joined(separator: " · ")
            right = [StatsPanel("Your plays of this song", perVersion, note: "by the release last.fm saw"),
                     StatsPanel("Plays per year", years, note: note)]
        } else {
            let l = NSTextField(wrappingLabelWithString: "No last.fm plays of this song yet (LISTENING imports your history).")
            l.font = Dash.font(12)
            l.textColor = Dash.text2
            right = [StatsPanel("Your plays of this song", l)]
        }
        let rightColumn = NSStackView(views: right)
        rightColumn.orientation = .vertical
        rightColumn.spacing = 12
        for v in right { v.widthAnchor.constraint(equalTo: rightColumn.widthAnchor).isActive = true }
        add(dashGrid([(StatsPanel("Length of each version", lengths, note: "oldest first · click to play"), 2), (rightColumn, 1)]))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(spacer)
        Dash.relaxWidth(stack)
    }

    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        v.setContentHuggingPriority(.required, for: .vertical)
    }

    /// The song's name without version notes ("About A Girl", not "About A Girl (Live Version)"): the most common
    /// spelling among the plain ones, studio recordings first.
    static func bestTitle(_ versions: [SongVersion]) -> String {
        let plain = versions.filter { Keys.fold($0.track.title) == Keys.title($0.track.title) }
        let pool = plain.contains { $0.kind == .album } ? plain.filter { $0.kind == .album } : (plain.isEmpty ? versions : plain)
        let counts = Dictionary(grouping: pool.map(\.track.title), by: { $0 }).mapValues(\.count)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? versions.first?.track.title ?? ""
    }

    /// After the new content has its size (scrolling before would land short of the top).
    private func scrollToTop() {
        layoutSubtreeIfNeeded()
        // Test hook: OMNIAMP_STATS_SCROLL=<y> for screenshots of the lower part.
        let y = ProcessInfo.processInfo.environment["OMNIAMP_STATS_SCROLL"].flatMap(Double.init) ?? 0
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }
}
