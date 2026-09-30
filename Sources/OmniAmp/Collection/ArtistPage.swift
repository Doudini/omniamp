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
    var releases: [LibraryAlbum] = [] { didSet { measure(); invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true } }
    var months: [(month: String, plays: Int)] = [] { didSet { measure(); needsLayout = true; needsDisplay = true } }
    var onRelease: ((LibraryAlbum) -> Void)?
    private static let laneH: CGFloat = 22, labelW: CGFloat = 92, playsH: CGFloat = 90, axisH: CGFloat = 18, gap: CGFloat = 12, r: CGFloat = 3.5

    // Worked out when the data changes (and the marks per width), not on every hover redraw: an artist can have
    // thousands of shows.
    private var lanes: [VersionLane] = []
    private var span: ClosedRange<Double> = 2000...2001
    private var cachedMarks: (width: CGFloat, marks: [(LibraryAlbum, NSPoint)])?

    private func measure() {
        lanes = VersionLane.allCases.filter { l in releases.contains { VersionLane($0.kind) == l } }
        let ws = releases.compactMap(\.when) + months.compactMap { Self.monthValue($0.month) }
        if let lo = ws.min(), let hi = ws.max() {
            span = (floor(lo) - 0.2)...(max(ceil(hi) + 0.2, floor(lo) + 3))
        } else {
            span = 2000...2001
        }
        cachedMarks = nil
    }
    private var lanesH: CGFloat { CGFloat(lanes.count) * Self.laneH }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: lanesH + Self.gap + Self.playsH + Self.axisH)
    }

    private static func monthValue(_ m: String) -> Double? {
        let p = m.split(separator: "-").compactMap { Int($0) }
        return p.count == 2 ? Double(p[0]) + Double(p[1] - 1) / 12 : nil
    }

    private func x(_ w: Double) -> CGFloat {
        let left = Self.labelW, width = bounds.width - left - 6
        return left + width * CGFloat((w - span.lowerBound) / (span.upperBound - span.lowerBound))
    }

    /// Release marks, packed like the song page's dots (three rows per lane, then overlapping).
    private func marks() -> [(LibraryAlbum, NSPoint)] {
        if let c = cachedMarks, c.width == bounds.width { return c.marks }
        var out: [(LibraryAlbum, NSPoint)] = []
        var placed: [VersionLane: [NSPoint]] = [:]
        let d = Self.r * 2 + 1
        for a in releases.sorted(by: { ($0.when ?? 0) < ($1.when ?? 0) }) {
            let lane = VersionLane(a.kind)
            guard let row = lanes.firstIndex(of: lane), let w = a.when else { continue }
            let cx = x(w), mid = CGFloat(row) * Self.laneH + Self.laneH / 2
            // In date order, so only the last few marks can be that close.
            let near = (placed[lane] ?? []).reversed().prefix { cx - $0.x < d }
            let spot = [0, -d, d].map { NSPoint(x: cx, y: mid + $0) }.first { p in !near.contains { hypot($0.x - p.x, $0.y - p.y) < d } }
                ?? NSPoint(x: cx, y: mid)
            placed[lane, default: []].append(spot)
            out.append((a, spot))
        }
        cachedMarks = (bounds.width, out)
        return out
    }

    private var playsTop: CGFloat { lanesH + Self.gap }
    private static let monthIn: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f }()
    private static let monthOut: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f }()

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
        let f = Self.monthIn, out = Self.monthOut
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
                NSGradient(starting: Dash.amount.withAlphaComponent(0.38), ending: Dash.amount.withAlphaComponent(0.03))?.draw(in: area, angle: 90)
                Dash.amount.setStroke()
                line.lineWidth = 1.6
                line.stroke()
            }
            if let h = hovered, h >= marks.count, h - marks.count < months.count, let r = monthRect(h - marks.count, most: most) {
                Dash.text3.withAlphaComponent(0.6).setFill()
                NSRect(x: r.midX, y: playsTop, width: 1, height: Self.playsH).fill()
                Dash.amount.setFill()
                NSBezierPath(ovalIn: NSRect(x: r.midX - 4, y: r.minY - 4, width: 8, height: 8)).fill()
            }
        }
        Dash.border.setFill()
        NSRect(x: Self.labelW, y: bottom, width: bounds.width - Self.labelW - 6, height: 1).fill()
    }
}

/// An artist: what they made, and how you've listened to them.
final class ArtistPage: DashPage {
    var onBack: (() -> Void)?
    var onSong: ((String, String) -> Void)?
    var onRelease: ((LibraryAlbum) -> Void)?
    var onBrowse: ((String) -> Void)?
    var onPlay: (([LibraryTrack]) -> Void)?
    /// The Shows list at this artist.
    var onShows: ((String) -> Void)?
    private var dash = ArtistDashboard()
    private var generation = 0

    override init() {
        super.init()
        photo.widthAnchor.constraint(equalToConstant: 132).isActive = true
        photo.heightAnchor.constraint(equalToConstant: 132).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private let observers = Observers()
    private var watchingDownloads = false

    /// Its lookups (photo, discography, more recordings): cancelled when another artist opens or the pages close,
    /// so nothing keeps asking MusicBrainz for a page that's gone.
    private var lookups: [Task<Void, Never>] = []

    /// Leaving the pages (not a song page over this one: Back comes here again, lookups done).
    func stopLookups() {
        lookups.forEach { $0.cancel() }
        lookups = []
    }

    func show(artist key: String) {
        lookups.forEach { $0.cancel() }
        lookups = []
        liveExpanded = ProcessInfo.processInfo.environment["OMNIAMP_LIVE_SHOW_ALL"] != nil   // test hook
        liveLoadingMore = false
        if !watchingDownloads {
            watchingDownloads = true
            observers.add(NotificationCenter.default.addObserver(forName: LiveArchiveDownloads.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isHidden == false { self?.fillDiscography() } }
            })
        }
        generation += 1
        let gen = generation
        info = nil
        photoImage = nil
        // Another artist: the last one's page goes now, not when the new one has been read (it showed for a moment).
        if dash.key != key {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            dash = ArtistDashboard(key: key)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let db = try? CollectionDB()
            let d = (try? db?.artistDashboard(key)) ?? ArtistDashboard(key: key)
            let cached: CollectionDB.CachedInfo = (db.flatMap { try? $0.artistInfo(key) }) ?? .unknown
            let disco = (db.flatMap { try? $0.discography(key) }) ?? (nil, true)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.dash = d
                self.discography = disco.0
                if case .found(let i) = cached { self.info = i }
                self.build()
                self.scrollToTop()
                self.loadInfo(key: key, name: d.name, cached: cached, gen: gen)
                self.loadDiscography(key: key, name: d.name, stale: disco.1, gen: gen)
            }
        }
    }

    // MARK: Photo and bio (Wikipedia, via MusicBrainz and Wikidata)

    private var info: MetadataLookup.ArtistInfo?
    private var photoImage: CGImage?
    /// Kept across artists (its size set once, in init).
    private let photo = ArtView()
    private let bio = NSTextField(wrappingLabelWithString: "")
    private let about = NSTextField(labelWithString: "")
    private var wikiButton: Pill?

    /// Looked up when the page opens (never in the background), then kept; the photo is kept on disk.
    private func loadInfo(key: String, name: String, cached: CollectionDB.CachedInfo, gen: Int) {
        let online = UserDefaults.standard.object(forKey: Pref.libraryOnlineLookups) as? Bool ?? true
        lookups.append(Task { @MainActor [weak self] in
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
        })
    }

    /// An artist's photo for elsewhere (the Listening display): from their saved info, looked up once when it's
    /// never been (as opening their page would). Nil when there's none or lookups are off.
    nonisolated static func photo(artistKey key: String, name: String) async -> CGImage? {
        let cached = await Task.detached { (try? CollectionDB().artistInfo(key)) ?? .unknown }.value
        var found: MetadataLookup.ArtistInfo?
        switch cached {
        case .found(let c): found = c
        case .none: return nil
        case .unknown: break
        }
        let online = UserDefaults.standard.object(forKey: Pref.libraryOnlineLookups) as? Bool ?? true
        if found == nil, online, !name.isEmpty, !["unknown artist", "various artists"].contains(key) {
            let mbid = await Task.detached { try? CollectionDB().artistMBID(key) }.value ?? nil
            let r = await MetadataLookup.shared.artistInfo(name: name, mbid: mbid)
            if !r.failed { let i = r.info; _ = await Task.detached { try? CollectionDB().saveArtistInfo(key, i) }.value }
            found = r.info
        }
        guard let url = found?.imageURL else { return nil }
        return await photo(url)
    }

    /// The photo, from the disk cache or downloaded and kept there (small: 320 px). Nonisolated: decoding a
    /// multi-MB original and writing the PNG happen off the main thread.
    nonisolated private static func photo(_ url: URL) async -> CGImage? {
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

    // MARK: Discography and bootlegs (MusicBrainz)

    private var discography: ArtistDiscography?
    private var discographyLoading = false
    private let discoSlot = NSStackView()

    /// Looked up when the page opens and the kept one is a month old (or there is none); never in the background.
    private func loadDiscography(key: String, name: String, stale: Bool, gen: Int) {
        let online = UserDefaults.standard.object(forKey: Pref.libraryOnlineLookups) as? Bool ?? true
        guard stale, online, !name.isEmpty, !["unknown artist", "various artists", ""].contains(key) else { return }
        let known = discography?.mbid
        let album = dash.releases.first { $0.kind == .album }?.title ?? dash.releases.first?.title
        discographyLoading = discography == nil
        fillDiscography()
        lookups.append(Task { @MainActor [weak self] in
            var mbid = known
            if mbid == nil { mbid = await Task.detached { try? CollectionDB().artistMBID(key) }.value ?? nil }
            if mbid == nil { mbid = await MetadataLookup.shared.artistPlace(name: name, mbid: nil, album: album).mbid }
            var found: ArtistDiscography?
            if let mbid, let d = await MetadataLookup.shared.discography(mbid: mbid, artist: name) {
                _ = await Task.detached { try? CollectionDB().saveDiscography(key, d) }.value
                found = d
            }
            guard let self, gen == self.generation else { return }
            self.discographyLoading = false
            if let found { self.discography = found }
            self.fillDiscography()
        })
    }

    private func fillDiscography() {
        discoSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let d = discography else {
            if discographyLoading {
                let wait = RowListChart()
                wait.empty = "Looking up their releases on MusicBrainz…"
                let card = StatsPanel("Discography", wait, note: "and known bootlegs")
                discoSlot.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: discoSlot.widthAnchor).isActive = true
            }
            Dash.relaxWidth(discoSlot)
            return
        }
        let owned = dash.releases
        let listed = d.listed(owned: owned)
        let open: (URL) -> Void = { NSWorkspace.shared.open($0) }
        let official = RowListChart()
        official.rows = listed.map { r, o in
            let kind = r.isLive ? "Live" : r.isCompilation ? "Compilation" : r.type
            return .init(lead: r.year.map(String.init) ?? "–", main: r.title, detail: kind + (o == nil ? " · missing" : ""),
                         color: o.map { Theme.kind($0.kind) } ?? Dash.text3,
                         tip: o == nil ? "Not in your library · click to see it on MusicBrainz" : "In your library · click to open it",
                         action: { [weak self] in if let o { self?.onRelease?(o) } else { open(r.url) } }, hollow: o == nil)
        }
        official.empty = "MusicBrainz lists no albums for them."
        let have = listed.filter { $0.owned != nil }.count
        let studio = listed.filter { $0.release.isStudio && $0.release.type == "Album" }
        var note = "you have \(have) of \(listed.count)"
        if !studio.isEmpty { note += " · \(studio.filter { $0.owned != nil }.count) of \(studio.count) studio albums" }
        var cards: [(NSView, Int)] = [(StatsPanel("Discography (\(listed.count))", official, note: note + " · outlined: missing"), 1)]

        // Bootlegs: the ones you don't have yet (the ones you have are under Shows), by date.
        // (Not by an official album you have: a bootleg can share its title.)
        let officialKeys = Set(d.official.compactMap { ArtistDiscography.owned($0, in: owned)?.key })
        let unofficial = owned.filter { !officialKeys.contains($0.key) }
        let mine = d.bootlegs.filter { ArtistDiscography.owned($0, in: unofficial) != nil }.count
        let missing = d.bootlegs.filter { ArtistDiscography.owned($0, in: unofficial) == nil }
        let shown = missing.prefix(25)
        let boots = RowListChart()
        boots.rows = shown.map { r in
            .init(lead: r.showDate ?? r.year.map(String.init) ?? "–", main: ArtistDiscography.withoutDate(r.title, r.showDate), detail: "",
                  color: Dash.text3, tip: "Not in your library · click to see it on MusicBrainz", action: { open(r.url) }, hollow: true)
        }
        if missing.count > shown.count {
            boots.rows.append(.init(lead: "", main: "All \(d.bootlegTotal.formatted()) on MusicBrainz ↗", detail: "\((missing.count - shown.count).formatted()) more you don't have",
                                    tip: "Their releases on MusicBrainz, bootlegs included",
                                    action: { open(d.artistURL.appendingPathComponent("releases")) }))
        }
        if d.bootlegTotal > 0 {
            cards.append((StatsPanel("Bootlegs on MusicBrainz (\(d.bootlegTotal.formatted()))", boots,
                                     note: "unofficial releases · you have \(mine)"), 1))
        } else {
            cards[0].1 = 2
        }
        for grid in [dashGrid(cards, columns: 2, equalHeights: false)] + [liveArchiveCard(d)].compactMap({ $0 }) {
            discoSlot.addArrangedSubview(grid)
            grid.widthAnchor.constraint(equalTo: discoSlot.widthAnchor).isActive = true
        }
        Dash.relaxWidth(discoSlot)
    }

    /// Their concerts on the Live Music Archive: the ones you don't have can be downloaded into the library.
    /// Owned ones are marked in the accent ("you have it"), not the shows' kind color: every row is a show, and
    /// that red read as an error next to a download.
    private func liveArchiveCard(_ d: ArtistDiscography) -> NSView? {
        guard let recs = d.liveRecordings, !recs.isEmpty else { return nil }
        // Test hook: OMNIAMP_LIVE_DOWNLOAD=<archive.org id>[:mp3] downloads that recording once.
        if let hook = ProcessInfo.processInfo.environment["OMNIAMP_LIVE_DOWNLOAD"], !Self.hookRan {
            let parts = hook.split(separator: ":")
            if let r = recs.first(where: { $0.id == parts.first.map(String.init) }) {
                Self.hookRan = true
                LiveArchiveDownloads.shared.start(r, artist: dash.name, format: parts.last == "mp3" ? .mp3 : .lossless)
            }
        }
        let owned = Dictionary(dash.releases.compactMap { a in a.showDate.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        let downloads = LiveArchiveDownloads.shared
        // Up to 40: all of them, or when there are more, the ones you don't have.
        // Downloads (running or done this session) always stay in the list, even once they're in the library.
        let missing = recs.filter { $0.date.flatMap { owned[$0] } == nil || downloads.states[$0.id] != nil }
        let shown = liveExpanded || recs.count <= 40 ? recs : Array(missing.prefix(40))
        let list = RowListChart()
        list.rows = shown.map { r in
            let mine = r.date.flatMap { owned[$0] }
            var detail = [r.city, r.kind].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            var button: String? = mine == nil ? "⤓ Download" : nil
            let name = dash.name
            var press: () -> Void = { LiveArchiveDownloads.shared.start(r, artist: name, format: .lossless) }
            switch downloads.states[r.id] {
            case .running(let done, let total)? where downloads.installing.contains(r.id) || (total > 0 && done >= total):
                detail = "adding to your library…"
                button = nil
                _ = (done, total)
            case .running(let done, let total)?:
                detail = total == 0 ? "starting download…" : "downloading \(done + 1) of \(total) files…"
                button = "Cancel"
                press = { LiveArchiveDownloads.shared.cancel(r.id) }
            case .paused(let done, let total)?:
                detail = "paused" + (total > 0 ? ": \(done) of \(total) files" : "")
                button = "Resume"
                press = { LiveArchiveDownloads.shared.resume(r.id) }
            case .finished?: detail = "downloaded ✓ · in your library"; button = nil
            case .failed(let why)?:
                detail = "download failed: \(why)"
                button = "Retry"
                press = { LiveArchiveDownloads.shared.resume(r.id) }
            case nil: if mine != nil { detail += " · in your library" }
            }
            return .init(lead: r.date ?? "–", main: r.venue ?? r.id, detail: detail, color: mine != nil ? Dash.accent : Dash.text3,
                         tip: (r.source.map { "Source: \($0)\n" } ?? "") + (mine != nil ? "You have this show · click to open it or for more"
                            : "Download: FLAC (lossless) into your library · click the row for MP3 or archive.org"),
                         action: { [weak self] in self?.liveArchiveMenu(r, owned: mine) }, hollow: mine == nil,
                         button: button, buttonAction: press)
        }
        let n = max(d.liveArchive ?? recs.count, recs.count)
        if !liveExpanded, n > shown.count {
            list.rows.append(.init(lead: "", main: "Show all \(n.formatted()) ›", detail: "every recording, the ones you have too",
                                   tip: "List the whole catalog here", action: { [weak self] in
                                       self?.liveExpanded = true
                                       self?.fillDiscography()
                                   }))
        }
        if liveExpanded, recs.count < n {
            list.rows.append(.init(lead: "", main: liveLoadingMore ? "Loading…" : "Load \(min(MetadataLookup.liveArchiveLimit, n - recs.count).formatted()) more ›",
                                   detail: "\(recs.count.formatted()) of \(n.formatted()) listed", tip: "The next ones from archive.org",
                                   action: { [weak self] in self?.loadMoreLive() }))
        }
        if liveExpanded, recs.count > 40 {
            list.rows.append(.init(lead: "", main: "‹ Show fewer", detail: "", tip: "Back to the ones you don't have", action: { [weak self] in
                self?.liveExpanded = false
                self?.fillDiscography()
            }))
        }
        let have = recs.filter { $0.date.flatMap { owned[$0] } != nil }.count
        let note = "concert tapes the artist allows to share, free · you have \(have)"
            + (recs.count > 40 && !liveExpanded ? " · the others by date" : "")
        return StatsPanel("Live Music Archive (\(n.formatted()))", list, note: note)
    }

    private static var hookRan = false
    /// The Live Music Archive card lists everything (Show all), and whether the next page is on its way.
    private var liveExpanded = false
    private var liveLoadingMore = false

    /// The next page of the artist's recordings, added to the kept list.
    private func loadMoreLive() {
        guard !liveLoadingMore, let base = discography, let recs = base.liveRecordings else { return }
        liveLoadingMore = true
        fillDiscography()
        let key = dash.key, name = dash.name, gen = generation
        let page = recs.count / MetadataLookup.liveArchiveLimit + 1
        lookups.append(Task { @MainActor [weak self] in
            let more = await MetadataLookup.shared.liveArchive(name, page: page)
            guard let self, gen == self.generation else { return }
            self.liveLoadingMore = false
            if let more {
                var d = base
                let known = Set(recs.map(\.id))
                d.liveRecordings = recs + more.recordings.filter { !known.contains($0.id) }
                d.liveArchive = more.total
                self.discography = d
                let saved = d
                _ = await Task.detached { try? CollectionDB().saveDiscography(key, saved) }.value
            }
            self.fillDiscography()
        })
    }

    private func liveArchiveMenu(_ r: LiveRecording, owned: LibraryAlbum?) {
        let menu = NSMenu()
        func item(_ title: String, _ run: @escaping () -> Void) {
            let i = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            let target = MenuAction(run)
            i.target = target
            i.representedObject = target   // keeps it alive with the menu
            menu.addItem(i)
        }
        if let owned { item("Open in Library") { [weak self] in self?.onRelease?(owned) } }
        let name = dash.name
        let state = LiveArchiveDownloads.shared.states[r.id]
        if LiveArchiveDownloads.shared.isRunning(r.id) {
            item("Cancel Download") { LiveArchiveDownloads.shared.cancel(r.id) }
        } else if case .paused? = state {
            item("Resume Download") { LiveArchiveDownloads.shared.resume(r.id) }
            item("Discard Download") { LiveArchiveDownloads.shared.cancel(r.id) }
        } else {
            item(owned == nil ? "Download FLAC (lossless)" : "Download FLAC Again (another source?)") {
                LiveArchiveDownloads.shared.start(r, artist: name, format: .lossless)
            }
            item("Download MP3") { LiveArchiveDownloads.shared.start(r, artist: name, format: .mp3) }
        }
        menu.addItem(.separator())
        item("Open on archive.org ↗") { NSWorkspace.shared.open(r.url) }
        let folder = LiveArchiveDownloads.shared.folder
        item("Download Folder: " + (folder.map { ($0 as NSString).lastPathComponent } ?? "not chosen yet") + "…") {
            LiveArchiveDownloads.shared.chooseFolder()
        }
        guard let event = NSApp.currentEvent else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func back() { onBack?() }
    @objc private func browse() { onBrowse?(dash.key) }

    /// Your most played songs, one recording each (the studio one where there is one), most played first.
    @objc private func playFavorites() {
        let key = dash.key, songs = dash.topSongs.filter { $0.versions > 0 }.prefix(25).map(\.titleKey)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
        let owned = d.releases.filter { $0.kind == .show }.sorted { ($0.showDate ?? "") < ($1.showDate ?? "") }
        if owned.count > 0, owned.count <= 12 {
            // A few shows: the shows themselves.
            let list = RowListChart()
            list.rows = owned.map { a in
                .init(lead: a.showDate ?? a.year.map(String.init) ?? "–", main: a.venue ?? ArtistDiscography.withoutDate(a.title, a.showDate),
                      detail: "\(a.tracks) tracks", color: Theme.kind(.show), tip: "\(a.title) · click to open it",
                      action: { [weak self] in self?.onRelease?(a) })
            }
            last.append((StatsPanel("Shows you own (\(owned.count))", list, note: "click one to open it"), last.isEmpty ? 3 : 1))
        } else if !d.showsPerYear.isEmpty {
            let shows = YearsChart()
            shows.unit = "show"
            shows.color = Theme.kind(.show)
            shows.years = d.showsPerYear
            let byYear = Dictionary(grouping: owned) { $0.year ?? 0 }
            shows.more = { y in
                let list = (byYear[y] ?? []).map { "\($0.showDate ?? "") \($0.venue ?? $0.title)" }
                return list.prefix(8).joined(separator: "\n") + (list.count > 8 ? "\n…" : "")
            }
            shows.onClick = { [weak self] _ in if let self { self.onShows?(self.dash.key) } }
            last.append((StatsPanel("Shows you own (\(owned.count))", shows, note: "concert recordings, by year · click for the list"),
                         last.isEmpty ? 3 : 1))
        }
        if last.count == 1 { last[0].1 = 3 }
        if !last.isEmpty { add(dashGrid(last)) }
        discoSlot.orientation = .vertical
        discoSlot.translatesAutoresizingMaskIntoConstraints = false
        add(discoSlot)
        fillDiscography()

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(spacer)
        Dash.relaxWidth(stack)
    }

}

/// A menu item's action as a closure.
final class MenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func run(_ sender: Any?) { run() }
}
