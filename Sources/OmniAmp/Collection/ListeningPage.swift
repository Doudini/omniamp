import AppKit

/// Plays by weekday and hour: when you listen. Rows Monday…Sunday, columns 0–23 h.
final class ClockChart: StatsChart {
    var clock: [[Int]] = [] { didSet { needsLayout = true; needsDisplay = true } }
    private static let labelW: CGFloat = 30, gap: CGFloat = 2
    /// Monday first; the data counts from Sunday (0).
    private static let order = [1, 2, 3, 4, 5, 6, 0]
    private static let dayNames: [String] = {
        let f = DateFormatter()
        f.locale = .current
        return f.shortWeekdaySymbols
    }()
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 7 * 16 + 18) }

    private var cell: CGFloat { max(4, min(20, (bounds.width - Self.labelW) / 24 - Self.gap)) }
    private func rect(row: Int, hour: Int) -> NSRect {
        NSRect(x: Self.labelW + CGFloat(hour) * (cell + Self.gap), y: CGFloat(row) * 16, width: cell, height: 14)
    }

    override func layoutRegions() {
        regions = []
        guard clock.count == 7 else { return }
        for (row, d) in Self.order.enumerated() {
            for h in 0..<24 {
                let n = clock[d][h]
                regions.append(Region(rect: rect(row: row, hour: h),
                                      tip: "\(Self.dayNames[d]) \(String(format: "%02d:00–%02d:00", h, (h + 1) % 24)): \(n.formatted()) plays",
                                      action: nil))
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard clock.count == 7 else { return }
        let most = CGFloat(max(clock.flatMap { $0 }.max() ?? 1, 1))
        for (row, d) in Self.order.enumerated() {
            Self.text(Self.dayNames[d], 8.5, Dash.text3).draw(at: NSPoint(x: 0, y: rect(row: row, hour: 0).minY + 1))
            for h in 0..<24 {
                let r = rect(row: row, hour: h)
                let n = CGFloat(clock[d][h])
                (n == 0 ? Dash.cardRaised : Dash.accent.withAlphaComponent(0.15 + 0.85 * n / most)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
                if hovered == row * 24 + h {
                    Dash.text.setStroke()
                    NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 2.5, yRadius: 2.5).stroke()
                }
            }
        }
        for h in stride(from: 0, to: 24, by: 6) {
            Self.text(String(format: "%02d h", h), 8.5, Dash.text3).draw(at: NSPoint(x: rect(row: 0, hour: h).minX, y: 7 * 16 + 2))
        }
    }
}

/// Last.fm history and the world: where the music you play and own comes from, and when you listen.
final class ListeningPage: NSScrollView, NSTextFieldDelegate {
    var onArtist: ((String) -> Void)?
    private let stack = NSStackView()
    private let history = ListeningHistory.shared
    private var stats: ListeningStats?
    private var showOwned = false
    private var country: (iso: String, name: String)?
    private let map = WorldMapView()
    private let countryArtists = BarListChart()
    private var countryPanelTitle = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let userField = NSTextField()
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
        map.describe = { [weak self] name, iso in self?.tip(name: name, iso: iso) ?? name }
        map.onSelect = { [weak self] iso, name in self?.select(iso: iso, name: name) }
        countryArtists.onClick = { [weak self] in self?.onArtist?($0.id) }
        NotificationCenter.default.addObserver(forName: ListeningHistory.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: MusicCollection.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isHidden == false { self?.reload() } }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// Shown: figures now, and an update from last.fm if it's been a while.
    @MainActor func appear() {
        history.refreshIfStale()
        reload()
    }

    private var lastBuild = Date.distantPast
    private var trailing = false

    /// New figures. While an import or lookups keep changing them, at most every 10 s (a rebuild resets hover).
    @MainActor func reload() {
        updateStatus()
        let wait = 10 - Date().timeIntervalSince(lastBuild)
        if wait > 0, stats != nil {
            if !trailing {
                trailing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    MainActor.assumeIsolated { self?.trailing = false; self?.reload() }
                }
            }
            return
        }
        lastBuild = Date()
        generation += 1
        let gen = generation
        updateStatus()
        DispatchQueue.global(qos: .userInitiated).async {
            let s = try? CollectionDB().listeningStats()
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation, let s else { return }
                self.stats = s
                self.build()
            }
        }
    }

    // MARK: Status

    @MainActor private func updateStatus() {
        var parts: [String] = []
        switch history.phase {
        case .importing(let done, let total): parts.append("Importing last.fm plays… \(done.formatted()) of \(total.formatted())")
        case .failed(let msg): parts.append("last.fm: \(msg)")
        case .idle:
            break   // the heading says how many plays
        }
        if history.lookupsRunning, let s = stats, s.pendingArtists > 0 {
            parts.append("finding artist countries on MusicBrainz, \(s.pendingArtists.formatted()) to go")
        }
        status.stringValue = parts.joined(separator: " · ")
    }

    // MARK: Building

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.distribution = .fillEqually
        r.alignment = .top
        r.spacing = 10
        for v in views { v.setContentHuggingPriority(.required, for: .vertical) }
        return r
    }

    private static func countryName(_ iso: String) -> String { Locale.current.localizedString(forRegionCode: iso) ?? iso }

    /// 🇨🇭 from "CH".
    private static func flag(_ iso: String) -> String {
        iso.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }

    private func tip(name: String, iso: String) -> String {
        guard let s = stats else { return name }
        let label = Self.countryName(iso)
        if showOwned {
            let n = Int(s.ownedByCountry[iso] ?? 0), a = s.ownedArtistsByCountry[iso] ?? 0
            return n == 0 ? "\(label): nothing in your library" : "\(label): \(n.formatted()) tracks by \(a) artist\(a == 1 ? "" : "s")"
        }
        let n = Int(s.playsByCountry[iso] ?? 0), a = s.playedArtistsByCountry[iso] ?? 0
        return n == 0 ? "\(label): no plays" : "\(label): \(n.formatted()) plays of \(a) artist\(a == 1 ? "" : "s")"
    }

    /// Account, sync and lookups: a quiet row under the heading.
    private func controls() -> NSView {
        status.font = Dash.font(11.5)
        status.textColor = Dash.text2
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let userLabel = Dash.label("last.fm", Dash.font(12, .medium), Dash.text2)
        userField.stringValue = MainActor.assumeIsolated { history.user } ?? ""
        userField.placeholderString = "your last.fm name"
        userField.font = Dash.font(12.5)
        userField.delegate = self
        userField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let sync = Pill("Sync", glyph: Fonts.Icon.repeatAll, target: self, action: #selector(syncClicked))
        sync.toolTip = "Fetch new plays from last.fm"
        let lookups = NSButton(checkboxWithTitle: "Look up artist countries", target: self, action: #selector(lookupsToggled(_:)))
        lookups.state = MainActor.assumeIsolated { history.lookupsEnabled } ? .on : .off
        lookups.font = Dash.font(12)
        lookups.toolTip = "MusicBrainz, one request a second in the background, remembered for good. Needed for the map."
        let h = NSStackView(views: [userLabel, userField, sync, lookups, status])
        h.spacing = 10
        h.setCustomSpacing(18, after: sync)
        return h
    }

    @objc private func syncClicked() {
        commitUser()
        MainActor.assumeIsolated { history.sync(); history.startLookups(); updateStatus() }
    }

    @objc private func lookupsToggled(_ b: NSButton) {
        MainActor.assumeIsolated { history.setLookupsEnabled(b.state == .on); updateStatus() }
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitUser() }

    private func commitUser() {
        let name = userField.stringValue
        MainActor.assumeIsolated { history.setUser(name) }
    }

    private func modeButtons() -> NSView {
        let plays = Pill("What I play", target: self, action: #selector(showPlays))
        let owned = Pill("What I own", target: self, action: #selector(showOwnedClicked))
        plays.isOn = !showOwned
        owned.isOn = showOwned
        let v = NSStackView(views: [plays, owned])
        v.spacing = 6
        return v
    }

    @objc private func showPlays() { showOwned = false; build() }
    @objc private func showOwnedClicked() { showOwned = true; build() }

    private func select(iso: String, name: String) {
        country = (iso, Self.countryName(iso))
        map.selected = iso
        loadCountry()
    }

    private func loadCountry() {
        guard let c = country else { return }
        let owned = showOwned
        countryPanelTitle.attributedStringValue = {
            let t = NSMutableAttributedString(string: "\(Self.flag(c.iso))  ", attributes: [.font: Dash.font(13)])
            t.append(Dash.title(c.name))
            t.append(NSAttributedString(string: "   " + (owned ? "tracks owned" : "plays"), attributes: [.font: Dash.font(11), .foregroundColor: Dash.text3]))
            return t
        }()
        DispatchQueue.global(qos: .userInitiated).async {
            let bars = (try? CollectionDB().artists(country: c.iso, owned: owned)) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.country?.iso == c.iso, self.showOwned == owned else { return }
                self.countryArtists.bars = bars
                self.countryArtists.footnote = bars.isEmpty ? "Nothing from here yet." : nil
                self.countryArtists.tip = { "\($0.label): \(Int($0.value).formatted()) \(owned ? "tracks" : "plays") · click to open" }
                self.countryArtists.invalidateIntrinsicContentSize()
            }
        }
    }

    private func build() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let history = MainActor.assumeIsolated { self.history }
        var subtitle: String?
        if let st = stats, st.plays > 0, let first = st.firstPlay, let u = MainActor.assumeIsolated({ history.user }) {
            let f = DateFormatter()
            f.dateStyle = .medium
            subtitle = "\(st.plays.formatted()) plays by \(u) since \(f.string(from: first))"
        }
        var rows: [NSView] = [dashHeading("Your listening", subtitle), controls()]
        guard MainActor.assumeIsolated({ history.canImport }) else {
            rows.append(note("This build of OmniAmp has no last.fm API key, so it can't read your history."))
            return finish(rows)
        }
        guard MainActor.assumeIsolated({ history.user }) != nil else {
            rows.append(note("Type your last.fm user name above (or connect last.fm in Settings), then press Sync. A public profile is enough: no login needed."))
            return finish(rows)
        }
        guard let s = stats else { return finish(rows) }

        // Key figures: this year against last.
        let year = Calendar.current.component(.year, from: Date())
        let perYear = Dictionary(uniqueKeysWithValues: s.years.map { ($0.year, $0.releases) })
        let now = perYear[year] ?? 0, last = perYear[year - 1] ?? 0
        let delta: (String, Bool)? = last > 0 ? (String(format: "%.0f%% vs %d", abs(Double(now - last) / Double(last) * 100), year - 1), now >= last) : nil
        let placed = s.plays > 0 ? Double(s.mappedPlays) / Double(s.plays) : 0
        let since = s.firstPlay.map { Calendar.current.component(.year, from: $0) }
        rows.append(dashRow([
            StatTile(s.plays.formatted(), "plays"),
            StatTile(now.formatted(), "plays in \(year)", delta: delta, spark: (year - 9...year).map { Double(perYear[$0] ?? 0) }),
            StatTile(s.artists.formatted(), "artists played"),
            StatTile((showOwned ? s.ownedByCountry : s.playsByCountry).count.formatted(), "countries"),
            StatTile(since.map(String.init) ?? "–", "listening since",
                     tip: s.pendingArtists > 0 ? "\(s.pendingArtists) artists still to place on the map" : String(format: "%.0f%% of plays on the map", placed * 100)),
        ]))

        // Plays over the years, and how much of it you own.
        let area = AreaChart()
        area.points = s.years.map { .init(x: Double($0.year), y: Double($0.releases), label: String($0.year)) }
        area.unit = "plays"
        let owned = DonutChart()
        owned.slices = [DonutChart.Slice(label: "Artists in your library", value: Double(s.ownedPlays), color: Dash.accent),
                        DonutChart.Slice(label: "Not in your library", value: Double(max(0, s.plays - s.ownedPlays)), color: Dash.accent2)]
        owned.center = (s.plays > 0 ? String(format: "%.0f%%", Double(s.ownedPlays) / Double(s.plays) * 100) : "–", "owned")
        owned.unit = "plays"
        rows.append(dashRow([panel("Plays per year", area, note: "hover for the figures"),
                             panel("What you play, do you own it?", owned, note: "by artist")], weights: [1.6, 1]))

        // The map, with the country's artists under it.
        map.values = showOwned ? s.ownedByCountry : s.playsByCountry
        let mapBox = NSStackView(views: [modeButtons(), map])
        mapBox.orientation = .vertical
        mapBox.alignment = .leading
        mapBox.spacing = 10
        map.widthAnchor.constraint(equalTo: mapBox.widthAnchor).isActive = true
        let mapped = showOwned ? s.mappedOwnedTracks : s.mappedPlays, all = showOwned ? s.ownedTracks : s.plays
        rows.append(panel(showOwned ? "Where the music you own comes from" : "Where the music you play comes from", mapBox,
                          note: "by artist · \(mapped.formatted()) of \(all.formatted()) \(showOwned ? "tracks" : "plays") placed · click a country"))
        if country == nil, let top = (showOwned ? s.ownedByCountry : s.playsByCountry).max(by: { $0.value < $1.value }) {
            country = (top.key, Self.countryName(top.key))
        }
        map.selected = country?.iso
        let countries = BarListChart()
        let source = showOwned ? s.ownedByCountry : s.playsByCountry
        countries.bars = source.sorted { $0.value > $1.value }.prefix(12).map {
            let n = (showOwned ? s.ownedArtistsByCountry : s.playedArtistsByCountry)[$0.key] ?? 0
            return .init(id: $0.key, label: "\(Self.flag($0.key))  \(Self.countryName($0.key))", value: $0.value,
                         detail: "\(n) artist\(n == 1 ? "" : "s")")
        }
        countries.tip = { "\($0.label): \(Int($0.value).formatted()) · click for its artists" }
        countries.onClick = { [weak self] b in self?.select(iso: b.id, name: b.label) }
        let countryPanel = titledPanel(countryPanelTitle, countryArtists)
        rows.append(dashRow([panel("Top countries", countries), countryPanel]))
        loadCountry()

        // Who, and when.
        let top = BarListChart()
        top.bars = s.topArtists
        top.tip = { "\($0.label): \(Int($0.value).formatted()) plays · \($0.detail) · click for the artist page" }
        top.onClick = { [weak self] b in self?.onArtist?(b.id) }
        let clock = ClockChart()
        clock.clock = s.clock
        let weekend = s.clock.enumerated().filter { $0.offset == 0 || $0.offset == 6 }.reduce(0) { $0 + $1.element.reduce(0, +) }
        let week = s.clock.flatMap { $0 }.reduce(0, +) - weekend
        let days = DonutChart()
        days.slices = [DonutChart.Slice(label: "Weekdays", value: Double(week), color: Dash.accent),
                       DonutChart.Slice(label: "Weekends", value: Double(weekend), color: Dash.accent2)]
        days.center = (week + weekend > 0 ? String(format: "%.0f%%", Double(weekend) / Double(week + weekend) * 100) : "–", "weekends")
        days.unit = "plays"
        let when = NSStackView(views: [panel("When you listen", clock, note: "by weekday and hour"), panel("Weekdays or weekends", days)])
        when.orientation = .vertical
        when.spacing = 12
        for v in when.arrangedSubviews { v.widthAnchor.constraint(equalTo: when.widthAnchor).isActive = true }
        rows.append(dashRow([panel("Most played artists", top, note: "plays"), when]))

        let notOwned = BarListChart()
        notOwned.bars = s.notOwned
        notOwned.color = { _ in Dash.accent2 }
        notOwned.tip = { "\($0.label): \(Int($0.value).formatted()) plays, nothing in the library · click for the artist page" }
        notOwned.onClick = { [weak self] b in self?.onArtist?(b.id) }
        let never = BarListChart()
        never.bars = s.neverPlayed
        never.format = { "\(Int($0))" }
        never.tip = { "\($0.label): \(Int($0.value).formatted()) tracks, never played on last.fm · click for the artist page" }
        never.onClick = { [weak self] in self?.onArtist?($0.id) }
        rows.append(dashRow([panel("Played a lot, not in your library", notOwned, note: "plays"),
                             panel("In your library, never played", never, note: "tracks")]))
        finish(rows)
    }

    private func note(_ text: String) -> NSView {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = Dash.font(13)
        l.textColor = Dash.text2
        return l
    }

    private func panel(_ title: String, _ content: NSView, note: String? = nil) -> NSView { StatsPanel(title, content, note: note) }

    /// A card whose title changes (the selected country).
    private func titledPanel(_ title: NSTextField, _ content: NSView) -> NSView {
        let box = NSView()
        Dash.styleCard(box)
        for v in [title, content] { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: box.topAnchor, constant: 13), title.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor, constant: -14),
            box.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        return box
    }

    private func finish(_ rows: [NSView]) {
        for r in rows {
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            r.setContentHuggingPriority(.required, for: .vertical)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(spacer)
        MainActor.assumeIsolated { updateStatus() }
        if let y = ProcessInfo.processInfo.environment["OMNIAMP_STATS_SCROLL"].flatMap(Double.init) {   // test hook: lower charts
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.documentView?.scroll(NSPoint(x: 0, y: y)) }
        }
    }
}
