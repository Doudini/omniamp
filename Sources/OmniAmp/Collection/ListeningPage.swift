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
            Self.text(Self.dayNames[d], 8, LibraryStyle.dim).draw(at: NSPoint(x: 0, y: rect(row: row, hour: 0).minY + 1))
            for h in 0..<24 {
                let r = rect(row: row, hour: h)
                let n = CGFloat(clock[d][h])
                (n == 0 ? Theme.phosphorDim.withAlphaComponent(0.12) : Theme.phosphor.withAlphaComponent(0.15 + 0.85 * n / most)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
                if hovered == row * 24 + h {
                    Theme.current.setStroke()
                    NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 2.5, yRadius: 2.5).stroke()
                }
            }
        }
        for h in stride(from: 0, to: 24, by: 6) {
            Self.text(String(format: "%02d h", h), 8, LibraryStyle.dim).draw(at: NSPoint(x: rect(row: 0, hour: h).minX, y: 7 * 16 + 2))
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
        stack.spacing = 10
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
            if let s = stats, s.plays > 0, let u = history.user { parts.append("\(s.plays.formatted()) plays by \(u)") }
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

    private func header() -> NSView {
        status.font = Fonts.hack(10)
        status.textColor = LibraryStyle.dim
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let userLabel = NSTextField(labelWithString: "LAST.FM USER")
        userLabel.font = Fonts.hack(9, bold: true)
        userLabel.textColor = LibraryStyle.header
        userField.stringValue = history.user ?? ""
        userField.placeholderString = "your last.fm name"
        userField.font = Fonts.hack(11)
        userField.delegate = self
        userField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let sync = ModernButton(glyph: Fonts.Icon.repeatAll, label: "SYNC", target: self, action: #selector(syncClicked))
        sync.glyphSize = 10
        sync.toolTip = "Fetch new plays from last.fm"
        sync.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let lookups = NSButton(checkboxWithTitle: "Look up artist countries (MusicBrainz)", target: self, action: #selector(lookupsToggled(_:)))
        lookups.state = history.lookupsEnabled ? .on : .off
        lookups.font = Fonts.hack(10)
        lookups.toolTip = "One request a second in the background, remembered for good. Needed for the map."
        let h = NSStackView(views: [userLabel, userField, sync, lookups, status])
        h.spacing = 8
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
        let plays = ModernButton(glyph: "", label: "WHAT I PLAY", target: self, action: #selector(showPlays))
        let owned = ModernButton(glyph: "", label: "WHAT I OWN", target: self, action: #selector(showOwnedClicked))
        plays.isOn = !showOwned
        owned.isOn = showOwned
        for b in [plays, owned] { b.heightAnchor.constraint(equalToConstant: 22).isActive = true }
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
        countryPanelTitle.stringValue = "\(Self.flag(c.iso)) \(c.name.uppercased()) · \(owned ? "TRACKS OWNED" : "PLAYS")"
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
        var rows: [NSView] = [header()]
        let history = MainActor.assumeIsolated { self.history }
        guard MainActor.assumeIsolated({ history.canImport }) else {
            rows.append(note("This build of OmniAmp has no last.fm API key, so it can't read your history."))
            return finish(rows)
        }
        guard MainActor.assumeIsolated({ history.user }) != nil else {
            rows.append(note("Type your last.fm user name above (or connect last.fm in Settings), then press SYNC. A public profile is enough: no login needed."))
            return finish(rows)
        }
        guard let s = stats else { return finish(rows) }

        let placed = s.plays > 0 ? Double(s.mappedPlays) / Double(s.plays) : 0
        let since = s.firstPlay.map { Calendar.current.component(.year, from: $0) }
        rows.append(row([
            StatTile(s.plays.formatted(), "plays"),
            StatTile(s.artists.formatted(), "artists played"),
            StatTile(since.map(String.init) ?? "–", "listening since"),
            StatTile((showOwned ? s.ownedByCountry : s.playsByCountry).count.formatted(), "countries"),
            StatTile(String(format: "%.0f%%", placed * 100), "plays on the map",
                     tip: s.pendingArtists > 0 ? "\(s.pendingArtists) artists still to look up" : "the rest: artists MusicBrainz doesn't place"),
        ]))

        // The map, with the selected country's artists under it.
        map.values = showOwned ? s.ownedByCountry : s.playsByCountry
        let mapBox = NSStackView(views: [modeButtons(), map])
        mapBox.orientation = .vertical
        mapBox.alignment = .leading
        mapBox.spacing = 8
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
        countries.bars = source.sorted { $0.value > $1.value }.prefix(15).map {
            let n = (showOwned ? s.ownedArtistsByCountry : s.playedArtistsByCountry)[$0.key] ?? 0
            return .init(id: $0.key, label: "\(Self.flag($0.key)) \(Self.countryName($0.key))", value: $0.value,
                         detail: "\(n) artist\(n == 1 ? "" : "s")")
        }
        countries.tip = { "\($0.label): \(Int($0.value).formatted()) · click for its artists" }
        countries.onClick = { [weak self] b in self?.select(iso: b.id, name: b.label) }
        countryPanelTitle.font = Fonts.hack(9.5, bold: true)
        countryPanelTitle.textColor = LibraryStyle.header
        let countryPanel = titledPanel(countryPanelTitle, countryArtists)
        rows.append(row([panel("Top countries", countries), countryPanel]))
        loadCountry()

        let top = BarListChart()
        top.bars = s.topArtists
        top.tip = { "\($0.label): \(Int($0.value).formatted()) plays · \($0.detail)" }
        top.onClick = { [weak self] b in self?.onArtist?(b.id) }
        let years = YearsChart()
        years.unit = "play"
        years.years = s.years
        rows.append(row([panel("Most played artists", top, note: "plays"), panel("Plays per year", years)]))

        let clock = ClockChart()
        clock.clock = s.clock
        let notOwned = BarListChart()
        notOwned.bars = s.notOwned
        notOwned.tip = { "\($0.label): \(Int($0.value).formatted()) plays, nothing in the library" }
        notOwned.onClick = { [weak self] b in self?.onArtist?(b.id) }
        rows.append(row([panel("When you listen", clock, note: "plays by weekday and hour"),
                         panel("Played a lot, not in your library", notOwned, note: "plays")]))

        let never = BarListChart()
        never.bars = s.neverPlayed
        never.tip = { "\($0.label): \(Int($0.value).formatted()) tracks, never played on last.fm" }
        never.onClick = { [weak self] in self?.onArtist?($0.id) }
        rows.append(row([panel("In your library, never played", never, note: "tracks"), NSView()]))
        finish(rows)
    }

    private func note(_ text: String) -> NSView {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = Fonts.hack(11)
        l.textColor = LibraryStyle.dim
        return l
    }

    private func panel(_ title: String, _ content: NSView, note: String? = nil) -> NSView { StatsPanel(title, content, note: note) }

    /// A panel whose title changes (the selected country).
    private func titledPanel(_ title: NSTextField, _ content: NSView) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = Theme.lcd.cgColor
        box.layer?.cornerRadius = 4
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.black.cgColor
        for v in [title, content] { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: box.topAnchor, constant: 10), title.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            content.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor, constant: -10),
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
