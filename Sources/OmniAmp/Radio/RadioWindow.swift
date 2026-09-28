import AppKit

/// Internet radio browser in the modern look: popular stations, search, genre/country filters, favorites
/// and station logos. Follows the selected color theme.
final class RadioWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                                  NSSearchFieldDelegate {
    private let controller: PlayerController
    private var popularButton: Pill!
    private var favoritesButton: Pill!
    private let search = NSSearchField()
    private let genre = NSPopUpButton()
    private let country = NSPopUpButton()
    private let table = KeyTableView()
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private var stations: [RadioStation] = []
    private var loadTask: Task<Void, Never>?
    private var showingFavorites = false
    private var themeObserver: NSObjectProtocol?

    private static let genres = ["All genres", "pop", "rock", "jazz", "classical", "electronic", "ambient", "chillout", "lounge",
                                 "dance", "house", "techno", "trance", "hiphop", "rnb", "soul", "funk", "blues", "reggae", "metal",
                                 "indie", "alternative", "country", "folk", "80s", "90s", "oldies", "latin", "world", "news", "talk"]
    static let countries: [(String, String)] = [("All countries", ""), ("United States", "US"), ("United Kingdom", "GB"),
        ("Germany", "DE"), ("France", "FR"), ("Netherlands", "NL"), ("Belgium", "BE"), ("Switzerland", "CH"), ("Austria", "AT"),
        ("Italy", "IT"), ("Spain", "ES"), ("Portugal", "PT"), ("Sweden", "SE"), ("Norway", "NO"), ("Denmark", "DK"),
        ("Finland", "FI"), ("Poland", "PL"), ("Czechia", "CZ"), ("Greece", "GR"), ("Canada", "CA"), ("Mexico", "MX"),
        ("Brazil", "BR"), ("Argentina", "AR"), ("Australia", "AU"), ("New Zealand", "NZ"), ("Japan", "JP"), ("South Korea", "KR"),
        ("India", "IN"), ("Turkey", "TR"), ("Russia", "RU"), ("Ukraine", "UA"), ("South Africa", "ZA")]

    init(controller: PlayerController) {
        self.controller = controller
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Internet Radio"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.minSize = NSSize(width: 560, height: 320)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        if !w.setFrameUsingName("OmniAmpRadio") { w.center() }
        w.setFrameAutosaveName("OmniAmpRadio")
        build()
        themeObserver = NotificationCenter.default.addObserver(forName: Theme.changed, object: nil, queue: .main) { [weak self] _ in
            self?.build()
            self?.table.reloadData()
        }
        if let st = Self.lastState {
            // Reopened after being closed (the window is freed when closed): same view and filters.
            showingFavorites = st.favorites
            search.stringValue = st.query
            genre.selectItem(at: st.genre)
            country.selectItem(at: st.country)
        }
        load()
    }
    required init?(coder: NSCoder) { fatalError() }

    private static var lastState: (favorites: Bool, query: String, genre: Int, country: Int)?
    /// Closed: the app drops this controller (its lists and logos go with it).
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        Self.lastState = (showingFavorites, search.stringValue, max(0, genre.indexOfSelectedItem), max(0, country.indexOfSelectedItem))
        loadTask?.cancel()
        onClose?()
    }

    deinit { themeObserver.map(NotificationCenter.default.removeObserver) }

    // MARK: Layout

    private func build() {
        window?.backgroundColor = Dash.page
        let title = Dash.label("Internet Radio", Dash.font(12, .semibold), Dash.text2)

        popularButton = Pill("Popular", glyph: Fonts.Icon.radio, target: self, action: #selector(showPopular))
        favoritesButton = Pill("Favorites", glyph: Fonts.Icon.starFilled, target: self, action: #selector(showFavorites))
        popularButton.isOn = !showingFavorites
        favoritesButton.isOn = showingFavorites

        search.placeholderString = "Search stations…"
        search.font = Dash.font(13)
        search.target = self
        search.action = #selector(searchChanged)
        search.delegate = self   // Esc in an empty field closes the window
        search.sendsWholeSearchString = true
        if genre.numberOfItems == 0 {
            genre.addItems(withTitles: Self.genres)
            country.addItems(withTitles: Self.countries.map(\.0))
        }
        for p in [genre, country] { p.target = self; p.action = #selector(filterChanged); p.font = Dash.font(12) }

        if table.tableColumns.isEmpty {
            for c in [ListLook.column("logo", 32), ListLook.column("fav", 22), ListLook.column("name", 260, flexible: true),
                      ListLook.column("genre", 160), ListLook.column("country", 110), ListLook.column("format", 70)] { table.addTableColumn(c) }
            table.headerView = nil
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.dataSource = self
            table.delegate = self
            table.target = self
            table.doubleAction = #selector(playSelected)
            table.action = #selector(tableClicked)
            table.onKey = { [weak self] e in self?.tableKey(e) ?? false }
            let menu = NSMenu()
            menu.delegate = self   // filled for the clicked row
            table.menu = menu
        }
        Dash.applyList(table, in: scroll, rowHeight: 34)   // again on a theme change: the colors

        status.font = Dash.font(11.5)
        status.textColor = Dash.text2
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let credit = NSButton(title: "radio-browser.info", target: self, action: #selector(openCredit))
        credit.isBordered = false
        credit.attributedTitle = NSAttributedString(string: "directory: radio-browser.info",
                                                    attributes: [.font: Dash.font(11), .foregroundColor: Dash.text3])
        let fav = Pill("Favorite", glyph: Fonts.Icon.starFilled, target: self, action: #selector(toggleFavorite))
        let add = Pill("Add", glyph: Fonts.Icon.plus, target: self, action: #selector(addSelected))
        let play = Pill("Play", glyph: Fonts.Icon.play, target: self, action: #selector(playSelected))
        play.prominent = true
        fav.toolTip = "Add or remove from favorites"
        add.toolTip = "Add to the playlist"
        play.toolTip = "Play now (double-click)"

        let urlButton = Pill("URL", glyph: Fonts.Icon.plus, target: self, action: #selector(addCustom))
        urlButton.toolTip = "Add a station by its stream or playlist URL (saved in Favorites)"
        let top = NSStackView(views: [popularButton, favoritesButton, search, genre, country, urlButton])
        top.spacing = 6
        let bottom = NSStackView(views: [status, NSView(), credit, fav, add, play])
        bottom.spacing = 6
        let root = NSView()
        for v in [title, top, scroll, bottom] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            title.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 32),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root
    }

    // MARK: Loading

    private func load() {
        loadTask?.cancel()
        popularButton.isOn = !showingFavorites
        favoritesButton.isOn = showingFavorites
        if showingFavorites {
            let q = search.stringValue.lowercased()
            stations = RadioFavorites.all.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.tags.lowercased().contains(q) }
            table.reloadData()
            selectTopResult()
            status.stringValue = stations.isEmpty ? "No favorites yet: select a station and press FAV." : "\(stations.count) favorites"
            return
        }
        status.stringValue = "Loading…"
        let filtered = genre.indexOfSelectedItem > 0 || country.indexOfSelectedItem > 0 || !search.stringValue.isEmpty
        let name = search.stringValue
        let tag = genre.indexOfSelectedItem > 0 ? genre.titleOfSelectedItem ?? "" : ""
        let cc = Self.countries[max(0, country.indexOfSelectedItem)].1
        loadTask = Task { @MainActor in
            do {
                let list = try await RadioBrowser.shared.stations(name: name, tag: tag, country: cc)
                guard !Task.isCancelled else { return }
                stations = list
                table.reloadData()
                selectTopResult()
                table.scrollRowToVisible(0)
                status.stringValue = list.isEmpty ? "No stations found." : "\(list.count) stations" + (filtered ? "" : " · most popular")
            } catch {
                guard !Task.isCancelled else { return }
                status.stringValue = "Couldn't reach the radio directory: \(error.localizedDescription)"
            }
        }
    }

    @objc private func showPopular() { showingFavorites = false; load() }
    @objc private func showFavorites() { showingFavorites = true; load() }
    @objc private func searchChanged() { load() }
    @objc private func filterChanged() { load() }
    @objc private func openCredit() { NSWorkspace.shared.open(URL(string: "https://www.radio-browser.info")!) }

    // MARK: Keyboard

    /// Return plays, Space pauses, ⌘D favorite, Esc closes, typing searches.
    private func tableKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        switch e.keyCode {
        case 36, 76: playSelected(); return true
        case 49: controller.togglePlayPause(); return true
        case 53: window?.performClose(nil); return true
        case 48: focusSearch(); return true   // Tab / ⇧Tab: list ⇄ search
        default:
            guard let c = ListLook.typedText(e) else { return false }
            window?.makeFirstResponder(search)
            search.currentEditor()?.insertText(c)
            return true
        }
    }

    /// The search field: Return searches and goes to the results, ↓ goes to them; Esc clears the text, and in an
    /// empty field goes back to the list (field → list → window closed).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === search else { return false }
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            searchChanged()
            focusList()
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            focusList()
        case #selector(NSResponder.cancelOperation(_:)):
            if !search.stringValue.isEmpty { search.stringValue = ""; searchChanged() } else { focusList() }
        default:
            return false
        }
        return true
    }

    /// ⌃Tab: POPULAR ⇄ FAVORITES.
    func toggleView() {
        showingFavorites.toggle()
        load()
        focusList()
    }

    /// Opened from the menu or ⌘2: start in the station list, so arrows, Return and Esc work right away.
    func focusList() {
        window?.makeFirstResponder(table)
        if table.selectedRow < 0, table.numberOfRows > 0 { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    /// A new list: the top row is selected (the old row number would point at another station, and on first
    /// open nothing was selected, so Return did nothing).
    private func selectTopResult() {
        if stations.isEmpty { table.deselectAll(nil) } else {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    /// ⌘F while this window is in front.
    func focusSearch() {
        window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < stations.count else { return }
        if table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
        let s = stations[row]
        func add(_ title: String, _ action: Selector) { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        add("Play", #selector(playSelected))
        add("Add to Playlist", #selector(addSelected))
        menu.addItem(.separator())
        add(RadioFavorites.contains(s) ? "Remove from Favorites  (⌘D)" : "Add to Favorites  (⌘D)", #selector(toggleFavorite))
        add("Copy Stream URL", #selector(copyStreamURL))
    }

    @objc private func copyStreamURL() {
        guard let s = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.url, forType: .string)
        status.stringValue = "Copied the stream address of “\(s.name)”."
    }

    // MARK: Actions

    private var selected: RadioStation? {
        let r = table.selectedRow
        return r >= 0 && r < stations.count ? stations[r] : nil
    }

    @objc private func playSelected() {
        guard let s = selected else { return }
        let i = controller.addStation(url: s.url, name: s.name, logo: s.favicon, tags: s.summary)
        controller.play(index: i)
        if !s.uuid.hasPrefix("custom:") { RadioBrowser.shared.countClick(s.uuid) }
    }

    @objc private func addSelected() {
        guard let s = selected else { return }
        controller.addStation(url: s.url, name: s.name, logo: s.favicon, tags: s.summary)
        status.stringValue = "Added “\(s.name)” to the playlist."
    }

    /// A station that isn't in the directory: probe the link, then keep it in Favorites.
    @objc private func addCustom() {
        AddURL.ask(title: "Add a Station by URL", message: "Paste a stream address, or a .pls / .m3u link from the station's website.",
                   in: window) { [weak self] text in
            self?.status.stringValue = "Checking the link…"
            Task { @MainActor in
                guard let self else { return }
                do {
                    let found: [URLProbe.Station]
                    switch try await URLProbe.probe(text) {
                    case .station(let url, let name): found = [URLProbe.Station(url: url, name: name)]
                    case .stations(let list): found = list
                    case .podcast:
                        self.status.stringValue = "That's a podcast feed: add it with + FEED in Podcasts."
                        return
                    case .file(let url, let title):
                        self.controller.addEpisode(.webFile(url, title: title))
                        self.status.stringValue = "That's an audio file, not a live station: added “\(title)” to the playlist."
                        return
                    }
                    for s in found {
                        let st = RadioStation.custom(url: s.url, name: s.name ?? AddURL.fallbackName(s.url))
                        if !RadioFavorites.contains(st) { RadioFavorites.toggle(st) }
                    }
                    self.showingFavorites = true
                    self.search.stringValue = ""
                    self.load()
                    self.status.stringValue = found.count == 1 ? "Added “\(found[0].name ?? AddURL.fallbackName(found[0].url))” to Favorites."
                                                               : "Added \(found.count) stations to Favorites."
                } catch {
                    self.status.stringValue = ""
                    AddURL.show(error, in: self.window)
                }
            }
        }
    }

    /// ⌘D (File → Favorite Station): from the list or while typing in the search.
    var canToggleFavorite: Bool { selected != nil }
    func toggleFavoriteFromMenu() { toggleFavorite() }

    @objc private func toggleFavorite() {
        guard let s = selected else { return }
        RadioFavorites.toggle(s)
        if showingFavorites { load() } else { table.reloadData(forRowIndexes: [table.selectedRow], columnIndexes: [1]) }
    }

    /// Clicking the ★ column toggles the favorite.
    @objc private func tableClicked() {
        guard table.clickedColumn == 1, table.clickedRow >= 0, table.clickedRow < stations.count else { return }
        RadioFavorites.toggle(stations[table.clickedRow])
        if showingFavorites { load() } else { table.reloadData(forRowIndexes: [table.clickedRow], columnIndexes: [1]) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { stations.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CardRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, row < stations.count else { return nil }
        let s = stations[row]
        if id == "logo" {
            let v = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("logo"), owner: nil) as? LogoCell) ?? LogoCell()
            v.identifier = NSUserInterfaceItemIdentifier("logo")
            v.show(s.favicon)
            return v
        }
        let textCell = libraryCell(tableView, id), cell = textCell.field   // centred on the row
        cell.alignment = .left
        switch id {
        case "fav":
            let on = RadioFavorites.contains(s)
            cell.stringValue = on ? Fonts.Icon.starFilled : Fonts.Icon.starEmpty
            cell.font = Theme.icon(12)
            cell.textColor = on ? Dash.accent : Dash.text3
            cell.alignment = .center
        case "name":
            cell.stringValue = s.name
            cell.font = Dash.font(13, .medium)
            cell.textColor = Dash.text
        case "genre":
            cell.stringValue = s.genreLabel
            cell.font = Dash.font(12)
            cell.textColor = Dash.text2
        case "country":
            cell.stringValue = s.countryCode.isEmpty ? s.country : (Locale.current.localizedString(forRegionCode: s.countryCode) ?? s.country)
            cell.font = Dash.font(12)
            cell.textColor = Dash.text2
        default:
            cell.stringValue = s.formatLabel
            cell.font = Dash.mono(10)
            cell.textColor = Dash.text3
            cell.alignment = .right
        }
        return textCell
    }
}

/// Station logo in a list row (loads asynchronously; dim radio glyph until then or when there is none).
final class LogoCell: NSView {
    private let art = ArtView()
    private var url: String?

    init() {
        super.init(frame: .zero)
        art.cornerRadius = 4
        art.placeholder = Fonts.Icon.radio
        art.surface = Dash.cardRaised
        art.iconColor = Dash.text3
        addSubview(art)
        NSLayoutConstraint.activate([
            art.centerXAnchor.constraint(equalTo: centerXAnchor), art.centerYAnchor.constraint(equalTo: centerYAnchor),
            art.widthAnchor.constraint(equalToConstant: 24), art.heightAnchor.constraint(equalToConstant: 24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ logo: String?) {
        url = logo
        art.image = LogoStore.shared.cached(logo)
        guard art.image == nil else { return }
        LogoStore.shared.load(logo) { [weak self] img in
            guard let self, self.url == logo else { return }
            self.art.image = img
        }
    }
}
