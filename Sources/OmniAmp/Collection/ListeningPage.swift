import AppKit
import os

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
                (n == 0 ? Dash.cardRaised : Dash.amount.withAlphaComponent(0.15 + 0.85 * n / most)).setFill()
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
final class ListeningPage: DashPage, NSTextFieldDelegate {
    var onArtist: ((String) -> Void)?
    /// A release to play (a show recorded on this day).
    var onPlayRelease: ((LibraryAlbum) -> Void)?
    private let history = ListeningHistory.shared
    /// Everything the page shows, with what it was computed from.
    private struct Figures: @unchecked Sendable {
        let version: String
        let stats: ListeningStats?
        let river: ListeningRiver
        let today: OnThisDay
        let years: [Int]
    }
    /// Kept while the window is closed too: reopening Listening is instant until plays, places or the library change.
    /// The last figures, for any page that opens next (read and written off the main thread).
    nonisolated private static let cache = OSAllocatedUnfairLock<Figures?>(initialState: nil)

    private var stats: ListeningStats?
    private var river = ListeningRiver()
    private var today = OnThisDay()
    private var playYears: [Int] = []

    /// Which plays "Most played artists" counts.
    enum Period: Equatable {
        case days(Int)
        case year(Int)
        case all
    }
    private var period: Period = .all
    private let topChart = BarListChart()
    private var periodPills: [(Pill, Period)] = []
    private let yearMenu = DashPopUp()
    private let periodNote = NSTextField(labelWithString: "")
    private var showOwned = false
    /// The most played artist's photo, kept across rebuilds.
    private var topPhoto: (key: String, image: CGImage?)?
    private var country: (iso: String, name: String)?
    private let map = WorldMapView()
    private let countryArtists = BarListChart()
    private var countryPanelTitle = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let userField = DashField()
    private var generation = 0

    override init() {
        super.init()
        map.describe = { [weak self] name, iso in self?.tip(name: name, iso: iso) ?? name }
        map.onSelect = { [weak self] iso, name in self?.select(iso: iso, name: name) }
        countryArtists.onClick = { [weak self] in self?.onArtist?($0.id) }
        // Only while on screen: appear() reloads when it's shown again (lookups change the figures every few seconds).
        // A new day ("On this day", "last 7 days") or time zone: the figures again, if on screen.
        for name in [ListeningHistory.changed, MusicCollection.changed, .NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            observers.add(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isHidden == false { self?.figuresChanged() } }
            })
        }
        // Behind other windows or in the Dock, changes wait (lookups post every few seconds, for hours): the
        // figures come when the window is seen again.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification] {
            observers.add(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, window == self.window.map(ObjectIdentifier.init), self.stale, !self.isHidden, self.onScreen else { return }
                    self.reload()
                }
            })
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private let observers = Observers()

    /// Shown: figures now, and an update from last.fm if it's been a while.
    @MainActor func appear() {
        history.refreshIfStale()
        reload()
    }

    private var lastBuild = Date.distantPast
    private var trailing = false
    /// Figures changed while the window couldn't be seen.
    private var stale = false
    /// The figures the page shows (their version): the same again needs no rebuild.
    private var builtVersion: String?

    private var onScreen: Bool {
        guard let w = window else { return false }
        return w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
    }

    /// Figures changed: new ones now if the page can be seen, else when it's seen again.
    @MainActor private func figuresChanged() {
        if onScreen { reload() } else { stale = true }
    }

    /// New figures. While an import or lookups keep changing them, at most every 10 s (a rebuild resets hover).
    @MainActor func reload() {
        stale = false
        updateStatus()
        let wait = 10 - Date().timeIntervalSince(lastBuild)
        if wait > 0, stats != nil {
            if !trailing {
                trailing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    MainActor.assumeIsolated { self?.trailing = false; self?.figuresChanged() }
                }
            }
            return
        }
        lastBuild = Date()
        generation += 1
        let gen = generation
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let db = try? CollectionDB()
            try? db?.fillPlayCalendar()
            // The same plays, places and library as last time (and the same day): the figures from then.
            let version = ((try? db?.listeningVersion()) ?? nil).map { $0 + "/" + Date().formatted(.iso8601.year().month().day()) }
            let data: ListeningPage.Figures
            if let version, let hit = ListeningPage.cache.withLock({ $0?.version == version ? $0 : nil }) {
                data = hit
            } else {
                data = ListeningPage.Figures(version: version ?? "", stats: try? db?.listeningStats(), river: (try? db?.river()) ?? ListeningRiver(),
                                    today: (try? db?.onThisDay()) ?? OnThisDay(), years: (try? db?.playYears()) ?? [])
                if version != nil { ListeningPage.cache.withLock { $0 = data } }
            }
            let s = data.stats, river = data.river, today = data.today, years = data.years
            DispatchQueue.main.async { [weak self] in
                // No figures (the query failed): the page still builds, with its name field and a note.
                guard let self, gen == self.generation else { return }
                // Same figures (a new version each day) for the same account: the page as it is.
                let built = data.version.isEmpty ? nil : data.version + "|\(self.history.user ?? "")|\(self.history.canImport)"
                if built != nil, built == self.builtVersion { return }
                self.builtVersion = built
                self.stats = s
                self.river = river
                self.today = today
                self.playYears = years
                let figures = Date()
                self.build()
                self.layoutSubtreeIfNeeded()
                if ProcessInfo.processInfo.environment["OMNIAMP_DEBUG"] != nil {
                    NSLog("OmniAmp: listening page: figures %.0f ms, building %.0f ms", figures.timeIntervalSince(started) * 1000,
                          Date().timeIntervalSince(figures) * 1000)
                }
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
        let lookups = DashCheck(checkboxWithTitle: "Look up artist countries", target: self, action: #selector(lookupsToggled(_:)))
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
        if let st = stats, st.plays > 0, let first = st.firstPlay {
            let f = DateFormatter()
            f.dateStyle = .medium
            let who = MainActor.assumeIsolated({ history.user }).map { " by \($0)" } ?? ""
            subtitle = "\(st.plays.formatted()) plays of \(st.artists.formatted()) artists\(who) since \(f.string(from: first))"
        }
        var rows: [NSView] = [dashHeading("Your listening", subtitle), controls()]
        // Plays OmniAmp kept itself show without last.fm; the notes only when there's nothing at all.
        let hasPlays = (stats?.plays ?? 0) > 0
        guard hasPlays || MainActor.assumeIsolated({ history.canImport }) else {
            rows.append(note("This build of OmniAmp has no last.fm API key, so it can't read your history. What you play in OmniAmp shows up here."))
            return finish(rows)
        }
        guard hasPlays || MainActor.assumeIsolated({ history.user }) != nil else {
            rows.append(note("Type your last.fm user name above (or connect last.fm in Settings), then press Sync. A public profile is enough: no login needed. What you play in OmniAmp shows up here too."))
            return finish(rows)
        }
        guard let s = stats else { return finish(rows) }

        // 1. Key figures: the most played artist with their photo, then this year, countries, artists and time.
        let year = Calendar.current.component(.year, from: Date())
        let perYear = Dictionary(uniqueKeysWithValues: s.years.map { ($0.year, $0.releases) })
        // This year so far against last year up to the same date (not all of last year).
        let now = perYear[year] ?? 0, last = s.lastYearToDate
        let delta: (String, Bool)? = last > 0 ? (String(format: "%.0f%% vs ’%02d", abs(Double(now - last) / Double(last) * 100), (year - 1) % 100), now >= last) : nil
        let placed = s.plays > 0 ? Double(s.mappedPlays) / Double(s.plays) : 0
        var pace: (year: Int, projected: Int)?
        if now > 0, let start = Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1)),
           let end = Calendar.current.date(from: DateComponents(year: year + 1, month: 1, day: 1)) {
            let done = Date().timeIntervalSince(start) / end.timeIntervalSince(start)
            if done > 0.05, done < 1 { pace = (year, Int((Double(now) / done).rounded())) }
        }
        let byCountry = showOwned ? s.ownedByCountry : s.playsByCountry
        let topCountries = byCountry.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        let ownedShare = s.artists > 0 ? Double(s.ownedArtists) / Double(s.artists) : 0
        // Scrobbles have no length: reckoned at the library's average track (4 minutes when there's no library).
        let perPlay = s.averageTrackSeconds > 30 ? s.averageTrackSeconds : 240
        let listenedDays = Double(s.plays) * perPlay / 86400
        let display = HiFiDisplay()
        if let top = s.topArtists.first {
            let years = s.topArtistByYear.filter { Keys.artist($0.value.name) == top.id }.keys.sorted()
            var lines = [String(format: "%@ plays · %.0f%%", Int(top.value).formatted(), top.value / Double(max(s.plays, 1)) * 100)]
            if years.count == 1 { lines.append("#1 in \(years[0])") }
            else if years.count > 1 { lines.append("#1 in \(years.count) years") }
            if let owned = top.count { lines.append("\(owned.formatted()) tracks owned") }
            display.feature = .init(kicker: "most played", title: top.label, lines: lines,
                                    tip: "\(top.label) · click for the artist", action: { [weak self] in self?.onArtist?(top.id) })
            if topPhoto?.key == top.id {
                display.featureImage = topPhoto?.image
            } else {
                Task { @MainActor [weak self, weak display] in
                    let img = await ArtistPage.photo(artistKey: top.id, name: top.label)
                    self?.topPhoto = (top.id, img)
                    display?.featureImage = img
                }
            }
        }
        display.items = [
            .init(value: now.formatted(), label: "plays \(year)",
                  tip: (last > 0 ? "\(now.formatted()) plays in \(year) so far, \(last.formatted()) by this date in \(year - 1)" : "\(now.formatted()) plays in \(year) so far")
                    + (pace.map { " · on pace for ~\($0.projected.formatted())" } ?? ""),
                  meter: (year - 9...year).map { Double(perYear[$0] ?? 0) }, delta: delta,
                  note: delta == nil ? pace.map { "~\($0.projected.formatted()) at this pace" } : nil),
            .init(value: byCountry.count.formatted(), label: "countries",
                  tip: showOwned ? "Countries of the artists in your library" : String(format: "%.0f%% of plays placed on the map", placed * 100),
                  flags: topCountries.map(Self.flag).joined(),
                  note: byCountry.count > topCountries.count ? "+\(byCountry.count - topCountries.count) more" : nil),
            .init(value: s.artists.formatted(), label: "artists",
                  tip: "\(s.ownedArtists.formatted()) of the \(s.artists.formatted()) artists you've played are in your library",
                  share: ownedShare, note: "\(s.ownedArtists.formatted()) owned"),
            .init(value: listenedDays >= 365 ? String(format: "%.1f", listenedDays / 365.25) : String(format: "%.0f", listenedDays),
                  label: listenedDays >= 365 ? "years listened" : "days listened",
                  tip: "\(s.plays.formatted()) plays at \(Int(perPlay) / 60)m \(Int(perPlay) % 60)s each (your library's average track): about \(Int(listenedDays).formatted()) days",
                  note: listenedDays >= 365 ? "\(Int(listenedDays).formatted()) days" : nil),
        ]
        rows.append(dashGrid([(display, 1)], columns: 1))

        // 2. The story: plays per year, and how much of it you own.
        // Every year's total written on its column; this year so far, with where it's heading at this pace.
        let area = YearsChart()
        area.years = s.years
        area.unit = "play"
        area.valueLabels = true
        area.pace = pace
        let paceNow = area.pace
        area.more = { [top = s.topArtistByYear] y in
            var lines: [String] = []
            if let prev = perYear[y - 1], prev > 0, let n = perYear[y], y != paceNow?.year {
                let change = Double(n - prev) / Double(prev) * 100
                lines.append(String(format: "%@%.0f%% vs %d", change >= 0 ? "▲ " : "▼ ", abs(change), y - 1))
            }
            if let p = paceNow, p.year == y { lines.append("so far · on pace for ~\(p.projected.formatted())") }
            if let t = top[y] { lines.append("most played: \(t.name) (\(t.plays.formatted()))") }
            lines.append("click for that year's most played")
            return lines.joined(separator: "\n")
        }
        area.onClick = { [weak self] y in self?.showYear(y) }
        let owned = DonutChart()
        owned.showsRing = true
        owned.slices = [DonutChart.Slice(label: "Artists in your library", value: Double(s.ownedPlays), color: Dash.amount),
                        DonutChart.Slice(label: "Not in your library", value: Double(max(0, s.plays - s.ownedPlays)), color: Dash.compare)]
        owned.center = (s.plays > 0 ? String(format: "%.0f%%", Double(s.ownedPlays) / Double(s.plays) * 100) : "–", "owned")
        owned.unit = "plays"
        rows.append(dashGrid([(panel("Plays per year", area, note: paceNow == nil ? "hover for more · click a year"
                                                                  : "\(year): so far, dashed: at this pace · click a year"), 2),
                              (panel("Artists you own", owned, note: "by artist"), 1)]))

        // 3. Who, through the years.
        let riverChart = RiverChart()
        riverChart.river = river
        riverChart.onArtist = { [weak self] in self?.onArtist?($0) }
        rows.append(dashGrid([(panel("Your top artists through the years", riverChart,
                                     note: "plays per year of your \(river.series.count) most played artists · click a band for the artist"), 3)]))

        // 4. Most played by period, and when you listen.
        let clock = ClockChart()
        clock.clock = s.clock
        let weekend = s.clock.enumerated().filter { $0.offset == 0 || $0.offset == 6 }.reduce(0) { $0 + $1.element.reduce(0, +) }
        let week = s.clock.flatMap { $0 }.reduce(0, +) - weekend
        let days = DonutChart()
        days.slices = [DonutChart.Slice(label: "Weekdays", value: Double(week), color: Dash.amount),
                       DonutChart.Slice(label: "Weekends", value: Double(weekend), color: Dash.compare)]
        days.center = (week + weekend > 0 ? String(format: "%.0f%%", Double(weekend) / Double(week + weekend) * 100) : "–", "weekends")
        days.unit = "plays"
        let when = NSStackView(views: [clock, days])
        when.orientation = .vertical
        when.alignment = .leading
        when.spacing = 16
        for v in [clock, days] { v.widthAnchor.constraint(equalTo: when.widthAnchor).isActive = true }
        // In words: the busiest hour and day.
        let names = Calendar.current.shortWeekdaySymbols
        let byDay = s.clock.map { $0.reduce(0, +) }, byHour = (0..<24).map { h in s.clock.reduce(0) { $0 + $1[h] } }
        var whenNote = "weekday × hour"
        if let d = byDay.indices.max(by: { byDay[$0] < byDay[$1] }), let h = byHour.indices.max(by: { byHour[$0] < byHour[$1] }), byHour[h] > 0 {
            whenNote = "peak \(String(format: "%02d:00", h)) · \(names[d])"
        }
        rows.append(dashGrid([(mostPlayedCard(), 2), (panel("When you listen", when, note: whenNote), 1)]))

        // 5. Where: the map, then the countries with the chosen one's artists.
        map.values = showOwned ? s.ownedByCountry : s.playsByCountry
        let mapBox = NSStackView(views: [modeButtons(), map])
        mapBox.orientation = .vertical
        mapBox.alignment = .leading
        mapBox.spacing = 10
        map.widthAnchor.constraint(equalTo: mapBox.widthAnchor).isActive = true
        let mapped = showOwned ? s.mappedOwnedTracks : s.mappedPlays, all = showOwned ? s.ownedTracks : s.plays
        rows.append(dashGrid([(panel(showOwned ? "Where the music you own comes from" : "Where the music you play comes from", mapBox,
                                     note: "by artist · \(mapped.formatted()) of \(all.formatted()) \(showOwned ? "tracks" : "plays") placed · click a country"), 3)]))
        if country == nil, let top = (showOwned ? s.ownedByCountry : s.playsByCountry).max(by: { $0.value < $1.value }) {
            country = (top.key, Self.countryName(top.key))
        }
        map.selected = country?.iso
        let countries = BarListChart()
        let source = showOwned ? s.ownedByCountry : s.playsByCountry
        countries.bars = source.sorted { $0.value > $1.value }.prefix(12).map {
            let n = (showOwned ? s.ownedArtistsByCountry : s.playedArtistsByCountry)[$0.key] ?? 0
            return .init(id: $0.key, label: "\(Self.flag($0.key))  \(Self.countryName($0.key))", value: $0.value,
                         count: n)
        }
        let unit = showOwned ? "tracks" : "plays"
        countries.tip = { b in "\(b.label): \(Int(b.value).formatted()) \(unit) by \(b.count ?? 0) artist\(b.count == 1 ? "" : "s") · click for its artists" }
        countries.onClick = { [weak self] b in self?.select(iso: b.id, name: b.label) }
        countryPanelTitle.font = Dash.font(13)
        let artistsColumn = NSStackView(views: [countryPanelTitle, countryArtists])
        artistsColumn.orientation = .vertical
        artistsColumn.alignment = .leading
        artistsColumn.spacing = 10
        countryArtists.widthAnchor.constraint(equalTo: artistsColumn.widthAnchor).isActive = true
        let split = NSStackView(views: [countries, artistsColumn])
        split.alignment = .top
        split.distribution = .fillEqually
        split.spacing = 28
        rows.append(dashGrid([(panel("Top countries", split, note: "\(showOwned ? "tracks" : "plays") (artists) · click a country for its artists"), 3)]))
        loadCountry()

        // 6. Nice to know: gaps in the library, and this day in other years.
        let notOwned = BarListChart()
        notOwned.bars = Array(s.notOwned.prefix(10))
        notOwned.color = { _ in Dash.compare }
        notOwned.tip = { "\($0.label): \(Int($0.value).formatted()) plays, nothing in the library · click for the artist page" }
        notOwned.onClick = { [weak self] b in self?.onArtist?(b.id) }
        let never = BarListChart()
        never.bars = Array(s.neverPlayed.prefix(10))
        never.format = { "\(Int($0))" }
        never.tip = { "\($0.label): \(Int($0.value).formatted()) tracks, never played on last.fm · click for the artist page" }
        never.onClick = { [weak self] in self?.onArtist?($0.id) }
        rows.append(dashGrid([(panel("Played a lot, not in your library", notOwned, note: "plays"), 1),
                              (panel("In your library, never played", never, note: "tracks"), 1),
                              (onThisDayCard(), 1)]))
        finish(rows)
    }

    // MARK: Most played, by period

    private static func periodTitle(_ p: Period) -> String {
        switch p {
        case .days(7): "the last 7 days"
        case .days(30): "the last month"
        case .days(182): "the last 6 months"
        case .days(365): "the last year"
        case .days(let n): "the last \(n) days"
        case .year(let y): String(y)
        case .all: "all time"
        }
    }

    private func mostPlayedCard() -> NSView {
        periodPills = [("7 days", Period.days(7)), ("Month", .days(30)), ("6 months", .days(182)), ("Year", .days(365)), ("All time", .all)]
            .map { label, p in (Pill(label, target: self, action: #selector(periodClicked(_:))), p) }
        yearMenu.removeAllItems()
        yearMenu.addItem(withTitle: "Year…")
        yearMenu.addItems(withTitles: playYears.map(String.init))
        yearMenu.font = Dash.font(12)
        yearMenu.target = self
        yearMenu.action = #selector(yearChosen)
        yearMenu.toolTip = "Your most played artists of one year"
        let controls = NSStackView(views: periodPills.map(\.0) + [yearMenu])
        controls.spacing = 6
        topChart.tip = { b in "\(b.label): \(Int(b.value).formatted()) plays · "
            + (b.count.map { "\($0.formatted()) tracks in the library" } ?? "not in the library") + " · click for the artist page" }
        topChart.onClick = { [weak self] b in self?.onArtist?(b.id) }
        periodNote.font = Dash.font(11)
        periodNote.textColor = Dash.text3
        let body = NSStackView(views: [controls, periodNote, topChart])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        topChart.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        updatePeriodControls()
        loadTop()
        return StatsPanel("Most played artists", body, note: "plays (tracks you own)")
    }

    private func updatePeriodControls() {
        for (pill, p) in periodPills { pill.isOn = p == period }
        if case .year(let y) = period { yearMenu.selectItem(withTitle: String(y)) } else { yearMenu.selectItem(at: 0) }
    }

    @objc private func periodClicked(_ sender: Pill) {
        guard let p = periodPills.first(where: { $0.0 === sender })?.1 else { return }
        period = p
        updatePeriodControls()
        loadTop()
    }

    /// A year from the chart: the "Most played" card at that year, scrolled into view.
    private func showYear(_ y: Int) {
        period = .year(y)
        updatePeriodControls()
        loadTop()
        topChart.scrollToVisible(topChart.bounds.insetBy(dx: 0, dy: -60))
    }

    @objc private func yearChosen() {
        // "Year…" is a heading, not a choice: the period stays.
        guard let y = Int(yearMenu.titleOfSelectedItem ?? "") else { updatePeriodControls(); return }
        period = .year(y)
        updatePeriodControls()
        loadTop()
    }

    /// The chosen period's top artists, read off the main thread; the card keeps its place.
    private func loadTop() {
        let p = period
        let (from, year): (Int?, Int?) = {
            switch p {
            case .days(let n): return (Int(Date().timeIntervalSince1970) - n * 86400, nil)
            case .year(let y): return (nil, y)
            case .all: return (nil, nil)
            }
        }()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let bars = (try? CollectionDB().topArtists(from: from, to: nil, year: year)) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.period == p else { return }
                let total = bars.reduce(0) { $0 + Int($1.value) }
                self.periodNote.stringValue = bars.isEmpty ? "No plays in \(Self.periodTitle(p))."
                    : "Top \(bars.count) of \(Self.periodTitle(p)) · \(total.formatted()) plays between them"
                self.topChart.bars = bars
            }
        }
    }

    // MARK: On this day

    private func onThisDayCard() -> NSView {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMMM")
        let dateName = Calendar.current.date(from: DateComponents(year: 2000, month: today.month, day: today.day)).map(f.string) ?? ""
        let shows = RowListChart()
        shows.empty = "No show you own was recorded on this date."
        shows.rows = today.shows.prefix(5).map { a in
            let year = a.showDate.map { String($0.prefix(4)) } ?? ""
            return .init(lead: year, main: a.artist, detail: a.venue ?? a.title, color: Theme.kind(.show),
                         tip: "\(a.artist) · \(a.showDate ?? "") \(a.venue ?? "") · click to play",
                         action: { [weak self] in self?.onPlayRelease?(a) })
        }
        let days = RowListChart()
        days.empty = "No plays on this date in other years."
        days.rows = today.days.prefix(6).map { d in
            .init(lead: String(d.year), main: d.artist, detail: d.plays > 1 ? "\(d.plays) plays" : d.title,
                  tip: "\(d.year): \(d.plays) plays that day, most of them \(d.artist) (\(d.title)) · click for the artist page",
                  action: { [weak self] in self?.onArtist?(d.artistKey) })
        }
        let body = NSStackView(views: [Dash.label("Shows recorded then", Dash.font(12, .medium), Dash.text2), shows,
                                       Dash.label("What you played", Dash.font(12, .medium), Dash.text2), days])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.setCustomSpacing(14, after: shows)
        for v in [shows, days] { v.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        return StatsPanel("On \(dateName)", body, note: "in other years")
    }

    /// A long name, short enough for a tile.

    private func note(_ text: String) -> NSView {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = Dash.font(13)
        l.textColor = Dash.text2
        return l
    }

    private func panel(_ title: String, _ content: NSView, note: String? = nil) -> NSView { StatsPanel(title, content, note: note) }

    private func finish(_ rows: [NSView]) {
        for r in rows {
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            r.setContentHuggingPriority(.required, for: .vertical)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(spacer)
        Dash.relaxWidth(stack)
        MainActor.assumeIsolated { updateStatus() }
        if let y = ProcessInfo.processInfo.environment["OMNIAMP_STATS_SCROLL"].flatMap(Double.init) {   // test hook: lower charts
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.documentView?.scroll(NSPoint(x: 0, y: y)) }
        }
    }
}
