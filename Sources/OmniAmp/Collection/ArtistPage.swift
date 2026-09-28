import AppKit
import CryptoKit
import ImageIO

extension LibraryAlbum {
    /// A point in time: the concert's date, else the middle of its year.
    var when: Double? {
        if let d = showDate, d.count >= 10 {
            let p = d.prefix(10).split(separator: "-").compactMap { Int($0) }
            if p.count == 3 { return Double(p[0]) + (Double(p[1] - 1) * 30.5 + Double(p[2] - 1)) / 366 }
        }
        return year.map { Double($0) + 0.5 }
    }
}

/// An artist's releases (lanes by kind, a mark per release) over your plays of them (a column per month), on
/// one time axis: when they made what, and when you listened.
final class CareerChart: StatsChart {
    var releases: [LibraryAlbum] = [] { didSet { invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true } }
    var months: [(month: String, plays: Int)] = [] { didSet { needsLayout = true; needsDisplay = true } }
    var onRelease: ((LibraryAlbum) -> Void)?
    private static let laneH: CGFloat = 22, labelW: CGFloat = 92, playsH: CGFloat = 90, axisH: CGFloat = 18, gap: CGFloat = 12, r: CGFloat = 3.5

    private var lanes: [VersionLane] { VersionLane.allCases.filter { l in releases.contains { VersionLane($0.kind) == l } } }
    private var lanesH: CGFloat { CGFloat(lanes.count) * Self.laneH }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: lanesH + Self.gap + Self.playsH + Self.axisH)
    }

    private static func monthValue(_ m: String) -> Double? {
        let p = m.split(separator: "-").compactMap { Int($0) }
        return p.count == 2 ? Double(p[0]) + Double(p[1] - 1) / 12 : nil
    }

    private var span: ClosedRange<Double> {
        let ws = releases.compactMap(\.when) + months.compactMap { Self.monthValue($0.month) }
        guard let lo = ws.min(), let hi = ws.max() else { return 2000...2001 }
        return (floor(lo) - 0.2)...(max(ceil(hi) + 0.2, floor(lo) + 3))
    }

    private func x(_ w: Double) -> CGFloat {
        let left = Self.labelW, width = bounds.width - left - 6
        return left + width * CGFloat((w - span.lowerBound) / (span.upperBound - span.lowerBound))
    }

    /// Release marks, packed like the song page's dots (three rows per lane, then overlapping).
    private func marks() -> [(LibraryAlbum, NSPoint)] {
        var out: [(LibraryAlbum, NSPoint)] = []
        var placed: [VersionLane: [NSPoint]] = [:]
        let d = Self.r * 2 + 1
        for a in releases.sorted(by: { ($0.when ?? 0) < ($1.when ?? 0) }) {
            let lane = VersionLane(a.kind)
            guard let row = lanes.firstIndex(of: lane), let w = a.when else { continue }
            let cx = x(w), mid = CGFloat(row) * Self.laneH + Self.laneH / 2
            let taken = placed[lane] ?? []
            let spot = [0, -d, d].map { NSPoint(x: cx, y: mid + $0) }.first { p in !taken.contains { hypot($0.x - p.x, $0.y - p.y) < d } }
                ?? NSPoint(x: cx, y: mid)
            placed[lane, default: []].append(spot)
            out.append((a, spot))
        }
        return out
    }

    private var playsTop: CGFloat { lanesH + Self.gap }

    private func monthRect(_ i: Int, most: Int) -> NSRect? {
        guard let m = Self.monthValue(months[i].month) else { return nil }
        let x0 = x(m), x1 = x(m + 1.0 / 12)
        let h = most > 0 ? Self.playsH * CGFloat(months[i].plays) / CGFloat(most) : 0
        return NSRect(x: x0, y: playsTop + Self.playsH - h, width: max(1, x1 - x0 - 0.5), height: h)
    }

    override func layoutRegions() {
        regions = marks().map { a, c in
            let what = a.kind == .show ? [a.showDate, a.venue].compactMap { $0 }.joined(separator: " ") : "\(a.title)\(a.year.map { " (\($0))" } ?? "")"
            return Region(rect: NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10), tip: "\(what) · \(a.kind.title) · click to open",
                          action: onRelease.map { f in { f(a) } })
        }
        let most = months.map(\.plays).max() ?? 0
        let f = DateFormatter(), out = DateFormatter()
        f.dateFormat = "yyyy-MM"
        out.dateFormat = "MMMM yyyy"
        for i in months.indices {
            guard let r = monthRect(i, most: most) else { continue }
            let label = f.date(from: months[i].month).map(out.string) ?? months[i].month
            regions.append(Region(rect: NSRect(x: r.minX, y: playsTop, width: max(r.width, 2), height: Self.playsH),
                                  tip: "\(label): \(months[i].plays.formatted()) plays", action: nil))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Year grid across both parts.
        let years = span.upperBound - span.lowerBound
        let step = years <= 10 ? 1 : years <= 25 ? 2 : years <= 50 ? 5 : 10
        let bottom = playsTop + Self.playsH
        var yr = Int(ceil(span.lowerBound))
        yr = (yr + step - 1) / step * step
        while Double(yr) <= span.upperBound {
            let px = x(Double(yr))
            Dash.grid.setFill()
            NSRect(x: px, y: 0, width: 1, height: bottom).fill()
            Self.text(String(yr), 8.5, Dash.text3).draw(at: NSPoint(x: px - 12, y: bottom + 3))
            yr += step
        }
        // Lanes: the label is the legend.
        for (row, lane) in lanes.enumerated() {
            let y = CGFloat(row) * Self.laneH
            Theme.kind(lane.kind).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: y + Self.laneH / 2 - 4, width: 8, height: 8), xRadius: 2, yRadius: 2).fill()
            let n = releases.filter { VersionLane($0.kind) == lane }.count
            Self.text("\(lane.title) \(n)", 8.5, Dash.text2, bold: true).draw(at: NSPoint(x: 15, y: y + Self.laneH / 2 - 7))
        }
        let marks = self.marks()
        for (i, (a, c)) in marks.enumerated() {
            let hot = hovered == i
            let rad = hot ? Self.r + 2 : Self.r
            let p = NSBezierPath(roundedRect: NSRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2), xRadius: 1.5, yRadius: 1.5)
            Theme.kind(a.kind).setFill()
            p.fill()
            (hot ? Dash.text : Dash.card).setStroke()
            p.lineWidth = hot ? 2 : 1
            p.stroke()
        }
        // Your plays per month.
        Self.text("YOUR PLAYS", 8.5, Dash.text2, bold: true).draw(at: NSPoint(x: 15, y: playsTop + 2))
        let most = months.map(\.plays).max() ?? 0
        if most == 0 {
            Self.sans("no last.fm plays", 11, Dash.text3).draw(at: NSPoint(x: 15, y: playsTop + 18))
        } else {
            Self.sans("peak \(most.formatted())/month", 11, Dash.text3).draw(at: NSPoint(x: 15, y: playsTop + 18))
            // Plays per month as a smooth area (the months' centres), a dot under the mouse.
            let pts: [NSPoint] = months.indices.compactMap { i in monthRect(i, most: most).map { NSPoint(x: $0.midX, y: $0.minY) } }
            if pts.count > 1 {
                let line = AreaChart.smoothPath(pts, floor: bottom)
                let area = line.copy() as! NSBezierPath
                area.line(to: NSPoint(x: pts.last!.x, y: bottom))
                area.line(to: NSPoint(x: pts[0].x, y: bottom))
                area.close()
                NSGradient(starting: Dash.accent.withAlphaComponent(0.38), ending: Dash.accent.withAlphaComponent(0.03))?.draw(in: area, angle: 90)
                Dash.accent.setStroke()
                line.lineWidth = 1.6
                line.stroke()
            }
            if let h = hovered, h >= marks.count, h - marks.count < months.count, let r = monthRect(h - marks.count, most: most) {
                Dash.text3.withAlphaComponent(0.6).setFill()
                NSRect(x: r.midX, y: playsTop, width: 1, height: Self.playsH).fill()
                Dash.accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: r.midX - 4, y: r.minY - 4, width: 8, height: 8)).fill()
            }
        }
        Dash.border.setFill()
        NSRect(x: Self.labelW, y: bottom, width: bounds.width - Self.labelW - 6, height: 1).fill()
    }
}

/// An artist: what they made, and how you've listened to them.
final class ArtistPage: NSScrollView {
    var onBack: (() -> Void)?
    var onSong: ((String, String) -> Void)?
    var onRelease: ((LibraryAlbum) -> Void)?
    var onBrowse: ((String) -> Void)?
    var onPlay: (([LibraryTrack]) -> Void)?
    private let stack = NSStackView()
    private var dash = ArtistDashboard()
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

    func show(artist key: String) {
        generation += 1
        let gen = generation
        info = nil
        photoImage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let db = try? CollectionDB()
            let d = (try? db?.artistDashboard(key)) ?? ArtistDashboard(key: key)
            let cached: CollectionDB.CachedInfo = (db.flatMap { try? $0.artistInfo(key) }) ?? .unknown
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.dash = d
                if case .found(let i) = cached { self.info = i }
                self.build()
                self.scrollToTop()
                self.loadInfo(key: key, name: d.name, cached: cached, gen: gen)
            }
        }
    }

    // MARK: Photo and bio (Wikipedia, via MusicBrainz and Wikidata)

    private var info: MetadataLookup.ArtistInfo?
    private var photoImage: CGImage?
    private let photo = ArtView()
    private let bio = NSTextField(wrappingLabelWithString: "")
    private let about = NSTextField(labelWithString: "")
    private var wikiButton: Pill?

    /// Looked up when the page opens (never in the background), then kept; the photo is kept on disk.
    private func loadInfo(key: String, name: String, cached: CollectionDB.CachedInfo, gen: Int) {
        let online = UserDefaults.standard.object(forKey: Pref.libraryOnlineLookups) as? Bool ?? true
        Task { @MainActor [weak self] in
            var found: MetadataLookup.ArtistInfo?
            switch cached {
            case .found(let c): found = c
            case .none: return
            case .unknown: break
            }
            if found == nil, online, !name.isEmpty, !["unknown artist", "various artists"].contains(key) {
                let mbid = await Task.detached { try? CollectionDB().artistMBID(key) }.value ?? nil
                let r = await MetadataLookup.shared.artistInfo(name: name, mbid: mbid)
                if !r.failed { let i = r.info; _ = await Task.detached { try? CollectionDB().saveArtistInfo(key, i) }.value }
                found = r.info
            }
            guard let self, gen == self.generation, let found else { return }
            if self.info != found { self.info = found; self.applyInfo() }
            if let url = found.imageURL, let img = await Self.photo(url) {
                guard gen == self.generation else { return }
                self.photoImage = img
                self.photo.image = img
                self.photo.isHidden = false
            }
        }
    }

    /// The photo, from the disk cache or downloaded and kept there (small: 320 px).
    private static func photo(_ url: URL) async -> CGImage? {
        // A stable name (hashValue changes every launch).
        let name = "artist-" + SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".png"
        let file = LibraryArt.directory.appendingPathComponent(name)
        if let img = ArtworkStore.image(contentsOf: file, maxPixels: 320) { return img }
        guard let data = await MetadataLookup.shared.image(url), let img = ArtworkStore.image(data, maxPixels: 320) else { return nil }
        if let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        return img
    }

    private func applyInfo() {
        about.stringValue = info?.description.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        about.isHidden = about.stringValue.isEmpty
        bio.stringValue = info?.extract ?? ""
        bio.isHidden = bio.stringValue.isEmpty
        wikiButton?.isHidden = info?.pageURL == nil
        photo.isHidden = photoImage == nil
    }

    @objc private func openWikipedia() {
        if let u = info?.pageURL { NSWorkspace.shared.open(u) }
    }

    private func button(_ glyph: String, _ label: String, _ action: Selector, tip: String, prominent: Bool = false) -> Pill {
        let b = Pill(label, glyph: glyph.isEmpty ? nil : glyph, target: self, action: action)
        b.prominent = prominent
        b.toolTip = tip
        return b
    }

    @objc private func back() { onBack?() }
    @objc private func browse() { onBrowse?(dash.key) }

    /// Your most played songs, one recording each (the studio one where there is one), most played first.
    @objc private func playFavorites() {
        let key = dash.key, songs = dash.topSongs.filter { $0.versions > 0 }.prefix(25).map(\.titleKey)
        DispatchQueue.global(qos: .userInitiated).async {
            let db = try? CollectionDB()
            let tracks: [LibraryTrack] = songs.compactMap { t in
                let v = (try? db?.versions(artist: key, titleKey: t)) ?? []
                return (v.first { $0.kind == .album && $0.track.playable } ?? v.first { $0.track.playable })?.track
            }
            DispatchQueue.main.async { [weak self] in self?.onPlay?(tracks) }
        }
    }

    private static func flag(_ iso: String) -> String {
        iso.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }

    private func build() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let d = dash
        let title = NSTextField(labelWithString: d.name.isEmpty ? "Unknown artist" : d.name)
        title.font = Dash.font(24, .semibold)
        title.textColor = Dash.text
        title.lineBreakMode = .byTruncatingTail
        var headerViews: [NSView] = [button("", "‹  Back", #selector(back), tip: "Back"), title]
        if let c = d.country {
            let place = NSTextField(labelWithString: "\(Self.flag(c)) \(Locale.current.localizedString(forRegionCode: c) ?? c)")
            place.font = Dash.font(13)
            place.textColor = Dash.text2
            headerViews.append(place)
        }
        let top = NSStackView(views: headerViews)
        top.spacing = 12

        let f = DateFormatter()
        f.dateStyle = .medium
        var summary = d.releases.isEmpty ? ["not in your library"]
            : ["\(d.releases.count.formatted()) release\(d.releases.count == 1 ? "" : "s")", "\(d.ownedTracks.formatted()) tracks",
               d.ownedSeconds >= 3600 ? String(format: "%.1f h", d.ownedSeconds / 3600) : AlbumCell.length(d.ownedSeconds)]
        if d.plays > 0 { summary.append("\(d.plays.formatted()) plays") }
        let line1 = NSTextField(labelWithString: summary.joined(separator: " · "))
        line1.font = Dash.font(12.5)
        line1.textColor = Dash.text2
        var lines: [NSView] = [line1]
        if let first = d.firstPlay {
            let years = d.lastPlay.map { Calendar.current.dateComponents([.year], from: first.date, to: $0).year ?? 0 } ?? 0
            let l = NSTextField(labelWithString: "First played \(f.string(from: first.date)): “\(first.title)”"
                                + (d.lastPlay.map { " · last \(f.string(from: $0))" } ?? "") + (years > 0 ? " · \(years) years of listening" : ""))
            l.font = Dash.font(12.5)
            l.textColor = Dash.text3
            lines.append(l)
        }
        var actions: [NSView] = d.releases.isEmpty ? []
            : [button(Fonts.Icon.folder, "Browse releases", #selector(browse), tip: "This artist's releases and tracks")]
        if d.topSongs.contains(where: { $0.versions > 0 }) {
            actions.insert(button(Fonts.Icon.play, "Play your favorites", #selector(playFavorites),
                                  tip: "Your most played songs by them, one recording each", prominent: true), at: 0)
        }
        let actionRow = NSStackView(views: actions)
        actionRow.spacing = 6
        about.font = Dash.font(13, .medium)
        about.textColor = Dash.text
        bio.font = Dash.font(12.5)
        bio.textColor = Dash.text2
        bio.maximumNumberOfLines = 4
        bio.lineBreakMode = .byWordWrapping          // wraps; the fourth line ends in "…"
        bio.cell?.truncatesLastVisibleLine = true
        bio.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let wiki = button("", "Wikipedia ↗", #selector(openWikipedia), tip: "Read more on Wikipedia")
        wikiButton = wiki
        actionRow.addArrangedSubview(wiki)
        let text = NSStackView(views: [top] + lines + [about, bio, actionRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 5
        text.setCustomSpacing(10, after: lines.last ?? top)
        text.setCustomSpacing(10, after: bio)
        photo.cornerRadius = 10
        photo.surface = Dash.cardRaised
        photo.iconColor = Dash.text3
        photo.placeholder = LibraryWindowController.Section.artists.glyph
        photo.image = photoImage
        photo.widthAnchor.constraint(equalToConstant: 132).isActive = true
        photo.heightAnchor.constraint(equalToConstant: 132).isActive = true
        // The text takes the width beside the photo; the bio wraps across it (up to 4 lines).
        for v in [about, bio] { v.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true }
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [photo, text])
        header.alignment = .top
        header.distribution = .fill
        header.spacing = 18
        applyInfo()
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let career = CareerChart()
        career.releases = d.releases
        career.months = d.months
        career.onRelease = { [weak self] in self?.onRelease?($0) }
        add(StatsPanel(d.releases.isEmpty ? "Your listening" : "Their releases and your listening", career,
                       note: d.releases.isEmpty ? "plays per month" : "hover for details · click a release to open it"))

        let top15 = BarListChart()
        top15.bars = d.topSongs.map { .init(id: $0.titleKey, label: $0.title, value: Double($0.plays),
                                            count: $0.versions == 0 ? nil : $0.versions) }
        top15.tip = { b in "\(b.label): \(Int(b.value).formatted()) plays · "
            + (b.count.map { "\($0) version\($0 == 1 ? "" : "s") in the library · click to see them" } ?? "not in the library") }
        top15.onClick = { [weak self] b in
            guard let self, b.count != nil else { return }   // nothing to show for a song not in the library
            self.onSong?(self.dash.key, b.id)
        }
        let recorded = BarListChart()
        recorded.bars = d.mostRecorded.map { .init(id: $0.titleKey, label: $0.title, value: Double($0.versions)) }
        recorded.format = { "\(Int($0))×" }
        recorded.tip = { "\($0.label): \(Int($0.value)) recordings · click to see them all" }
        recorded.onClick = { [weak self] b in if let self { self.onSong?(self.dash.key, b.id) } }
        // Their songs you play, the ones you have most versions of, and what you own of them.
        let kinds = DonutChart()
        let byKind = Dictionary(grouping: d.releases, by: \.kind)
        kinds.slices = ReleaseKind.allCases.compactMap { k in
            byKind[k].map { DonutChart.Slice(label: k.title, value: Double($0.count), color: Theme.kind(k)) }
        }
        kinds.center = (d.releases.count.formatted(), d.releases.count == 1 ? "release" : "releases")
        kinds.unit = "releases"
        var thirds: [(NSView, Int)] = [(StatsPanel("Your top songs", top15, note: d.topSongs.isEmpty ? "no last.fm plays yet" : "plays (versions you own)"), 1)]
        if !d.mostRecorded.isEmpty { thirds.append((StatsPanel("Most versions", recorded, note: "recordings"), 1)) }
        if !d.releases.isEmpty { thirds.append((StatsPanel("What you own of them", kinds, note: "by kind"), 1)) }
        if thirds.count == 1 { thirds[0].1 = 3 } else if thirds.count == 2 { thirds[0].1 = 2 }
        add(dashGrid(thirds))

        let albums = BarListChart()
        albums.bars = d.playedAlbums
        // Owned: its kind's color; not in the library: neutral (never a kind's color).
        albums.color = { [kinds = d.playedAlbumKinds] in kinds[$0.id].map(Theme.kind) ?? Dash.text3 }
        albums.tip = { [kinds = d.playedAlbumKinds] b in "\(b.label): \(Int(b.value).formatted()) plays\(kinds[b.id] == nil ? " · not in the library" : "")" }
        var last: [(NSView, Int)] = []
        if !d.playedAlbums.isEmpty { last.append((StatsPanel("Albums you play most", albums, note: "plays, by the release last.fm saw"), 2)) }
        if !d.showsPerYear.isEmpty {
            let shows = YearsChart()
            shows.unit = "show"
            shows.color = Theme.kind(.show)
            shows.years = d.showsPerYear
            last.append((StatsPanel("Shows you own", shows, note: "by year of the concert"), last.isEmpty ? 3 : 1))
        }
        if last.count == 1 { last[0].1 = 3 }
        if !last.isEmpty { add(dashGrid(last)) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(spacer)
        Dash.relaxWidth(stack)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.distribution = .fillEqually
        r.alignment = .top
        r.spacing = 12
        for v in views { v.setContentHuggingPriority(.required, for: .vertical) }
        return r
    }

    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        v.setContentHuggingPriority(.required, for: .vertical)
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
