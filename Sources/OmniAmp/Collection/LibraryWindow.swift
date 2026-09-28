import AppKit

/// The music library browser in the modern look. Four panes: a sidebar (Artists, Shows, Years, Genres,
/// Recently Added), a list for the section (artists A–Z, years, genres…), that entry's releases (with a
/// timeline for an artist) grouped by kind, and the selected release's tracks.
///
/// ALL / OFFICIAL / UNOFFICIAL and LOSSLESS filter every pane; typing searches titles, artists, albums and
/// venues. Return or double-click plays (adds to the playlist and starts), ⌥Return adds without playing.
final class LibraryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                                     NSMenuDelegate, NSSearchFieldDelegate {
    enum Section: Int, CaseIterable {
        case artists, shows, years, genres, added, stats, listening

        var title: String {
            switch self {
            case .artists: "Artists"
            case .shows: "Shows"
            case .years: "Years"
            case .genres: "Genres"
            case .added: "Recently Added"
            case .stats: "Stats"
            case .listening: "Listening"
            }
        }
        var glyph: String {
            switch self {
            case .artists: "\u{F0849}"   // nf-md-account_music
            case .shows: "\u{F0403}"     // nf-md-microphone_variant
            case .years: "\u{F00ED}"     // nf-md-calendar_blank
            case .genres: "\u{F0770}"    // nf-md-tag_multiple
            case .added: "\u{F0150}"     // nf-md-clock_outline
            case .stats: "\u{F0128}"     // nf-md-chart_bar
            case .listening: "\u{F01E7}"   // nf-md-earth
            }
        }
    }

    /// A row in the albums pane.
    private enum Item: Equatable {
        case header(String, ReleaseKind?)
        case album(LibraryAlbum)
    }

    /// A row in the middle list.
    private struct Entry: Equatable {
        let id: String
        let title: String
        let count: Int
        var letter: String?
    }

    private let controller: PlayerController
    private let library = MusicCollection.shared
    private var section: Section = .artists
    private var filter = LibraryFilter()
    private var query = ""

    private var entries: [Entry] = []
    private var items: [Item] = []
    private var tracks: [LibraryTrack] = []
    private var maxCount = 1

    private let sidebar = KeyTableView()
    private let middle = KeyTableView()
    private let albumTable = KeyTableView()
    private let trackTable = KeyTableView()
    private let scrolls = (0..<4).map { _ in NSScrollView() }
    private let letters = LetterStrip()
    private let timeline = LibraryTimeline()
    private var timelineHeight: NSLayoutConstraint!
    private var lettersWidth: NSLayoutConstraint!
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private var scopeButtons: [Pill] = []
    private var losslessButton: Pill!
    private var observers: [NSObjectProtocol] = []
    private var refreshPending = false
    private let statsPage = StatsPage()
    private let listeningPage = ListeningPage()
    private let songPage = SongPage()
    private let artistPage = ArtistPage()
    /// Pages over the lists, the one shown last: Back goes down the stack, then to the lists.
    private enum Page { case song(artist: String, title: String), artist(String) }
    private var pages: [Page] = []
    private var statsGeneration = 0

    init(controller: PlayerController) {
        self.controller = controller
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Music Library"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.minSize = NSSize(width: 880, height: 460)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        if !w.setFrameUsingName("OmniAmpLibrary") { w.center() }
        w.setFrameAutosaveName("OmniAmpLibrary")
        if let st = Self.lastState {
            section = st.section; filter = st.filter; query = st.query
        }
        build()
        search.stringValue = query
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: Theme.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        })
        observers.append(nc.addObserver(forName: MusicCollection.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        })
        observers.append(nc.addObserver(forName: MusicCollection.progressChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        })
        library.start()
        // Test hook: OMNIAMP_LIBRARY=section[:entry] opens on a section and entry ("shows:Grateful Dead", "years:1997").
        var entry = Self.lastState?.entry
        if let hook = ProcessInfo.processInfo.environment["OMNIAMP_LIBRARY"], let name = hook.split(separator: ":").first,
           let s = Section.allCases.first(where: { String(describing: $0) == name }) {
            section = s
            entry = hook.split(separator: ":", maxSplits: 1).dropFirst().first.map { e in s == .artists || s == .shows ? Keys.artist(String(e)) : String(e) }
        }
        reloadAll(keepEntry: entry, keepAlbum: Self.lastState?.album)
        // Test hook: OMNIAMP_LIBRARY_SONG="Artist|Title" opens that song's page.
        if let name = ProcessInfo.processInfo.environment["OMNIAMP_LIBRARY_ARTIST"] {   // test hook: that artist's page
            DispatchQueue.main.async { [weak self] in self?.push(.artist(Keys.artist(name))) }
        }
        if let hook = ProcessInfo.processInfo.environment["OMNIAMP_LIBRARY_SONG"]?.components(separatedBy: "|"), hook.count == 2 {
            DispatchQueue.main.async { [weak self] in self?.showSong(artist: Keys.artist(hook[0]), titleKey: Keys.title(hook[1])) }
        }
        // Test hook: OMNIAMP_DEBUG logs how small the window's content can get (pages must not force a large minimum).
        if ProcessInfo.processInfo.environment["OMNIAMP_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let v = self?.window?.contentView else { return }
                let probe = v.widthAnchor.constraint(equalToConstant: 100)
                probe.priority = .init(499)
                probe.isActive = true
                v.layoutSubtreeIfNeeded()
                NSLog("OmniAmp: DEBUG library minimum content %@", NSStringFromSize(v.fittingSize))
                probe.isActive = false
            }
        }
        // Test hook: OMNIAMP_LIBRARY_FIND=1 opens Find Missing Info for the selected release.
        if ProcessInfo.processInfo.environment["OMNIAMP_LIBRARY_FIND"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.findInfo() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private static var lastState: (section: Section, filter: LibraryFilter, query: String, entry: String?, album: String?)?
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        Self.lastState = (section, filter, query, selectedEntry?.id, selectedAlbum?.key)
        onClose?()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: Layout

    private func build() {
        window?.backgroundColor = Dash.page
        let title = Dash.label("Music Library", Dash.font(12, .semibold), Dash.text2)

        search.placeholderString = "Search artists, albums, songs, venues…"
        search.font = Dash.font(13)
        search.target = self
        search.action = #selector(searchChanged)
        search.delegate = self
        search.sendsSearchStringImmediately = false
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)

        scopeButtons = [("All", LibraryFilter.Scope.all), ("Official", .official), ("Unofficial", .unofficial)].map { label, scope in
            let b = Pill(label, target: self, action: #selector(scopeClicked(_:)))
            b.tag = scope.rawValue
            return b
        }
        scopeButtons[1].toolTip = "Albums, EPs, compilations and live albums"
        scopeButtons[2].toolTip = "Shows, bootlegs, demos, outtakes and other unreleased recordings"
        losslessButton = Pill("Lossless", target: self, action: #selector(losslessClicked))
        losslessButton.toolTip = "Only lossless releases (FLAC, ALAC, WAV, AIFF)"
        let folders = Pill("Folders", glyph: Fonts.Icon.folder, target: self, action: #selector(showFolders(_:)))
        folders.toolTip = "Add or remove library folders, rescan"
        updateFilterButtons()
        let top = NSStackView(views: [search] + scopeButtons + [losslessButton, folders])
        top.spacing = 6
        top.setCustomSpacing(14, after: search)
        top.setCustomSpacing(14, after: scopeButtons[2])

        configure(sidebar, scrolls[0], columns: [ListLook.column("section", 150, flexible: true)], rowHeight: 32)
        configure(middle, scrolls[1], columns: [ListLook.column("entry", 220, flexible: true)], rowHeight: 26)
        configure(albumTable, scrolls[2], columns: [ListLook.column("album", 400, flexible: true)], rowHeight: 54)
        configure(trackTable, scrolls[3], columns: [ListLook.column("no", 38), ListLook.column("title", 260, flexible: true),
                                                    ListLook.column("artist", 150), ListLook.column("time", 56),
                                                    ListLook.column("format", 86)], rowHeight: 24)
        albumTable.allowsMultipleSelection = true
        trackTable.allowsMultipleSelection = true
        for t in [albumTable, trackTable] {
            t.setDraggingSourceOperationMask(.copy, forLocal: false)
            let menu = NSMenu()
            menu.delegate = self
            t.menu = menu
        }
        let artistMenu = NSMenu()
        artistMenu.delegate = self
        middle.menu = artistMenu

        letters.onLetter = { [weak self] l in self?.jump(to: l) }
        letters.translatesAutoresizingMaskIntoConstraints = false
        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.onSelect = { [weak self] a in self?.selectAlbum(a.key) }
        Dash.styleCard(timeline)

        empty.font = Dash.font(13)
        empty.textColor = LibraryStyle.dim
        empty.alignment = .center
        empty.isHidden = true

        status.font = Dash.font(11)
        status.textColor = Dash.text2
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let add = Pill("Add", glyph: Fonts.Icon.plus, target: self, action: #selector(addSelection))
        let play = Pill("Play", glyph: Fonts.Icon.play, target: self, action: #selector(playSelection))
        play.prominent = true
        add.toolTip = "Add to the playlist (⌥Return)"
        play.toolTip = "Add to the playlist and play (Return, double-click)"
        let bottom = NSStackView(views: [status, NSView(), add, play])
        bottom.spacing = 6

        let root = NSView()
        statsPage.onGenre = { [weak self] g in self?.open(.genres, g) }
        statsPage.onYear = { [weak self] y in self?.open(.years, String(y)) }
        statsPage.onArtist = { [weak self] a in self?.push(.artist(a)) }
        statsPage.onSearch = { [weak self] q in
            guard let self else { return }
            self.search.stringValue = q
            self.searchChanged()
        }
        listeningPage.onArtist = { [weak self] a in self?.push(.artist(a)) }
        listeningPage.onPlayRelease = { [weak self] album in
            guard let self, let db = self.db else { return }
            self.play((try? db.tracks(album: album.key)) ?? [])
        }
        statsPage.onSong = { [weak self] a, t in self?.showSong(artist: a, titleKey: t) }
        songPage.onBack = { [weak self] in self?.back() }
        songPage.onArtist = { [weak self] a in self?.push(.artist(a)) }
        songPage.onPlay = { [weak self] list in self?.play(list) }
        songPage.onAdd = { [weak self] list in self?.enqueue(list) }
        artistPage.onBack = { [weak self] in self?.back() }
        artistPage.onSong = { [weak self] a, t in self?.push(.song(artist: a, title: t)) }
        artistPage.onRelease = { [weak self] a in self?.openRelease(artist: a.artistKey, album: a.key) }
        artistPage.onBrowse = { [weak self] a in self?.openRelease(artist: a, album: nil) }
        artistPage.onPlay = { [weak self] list in self?.play(list) }
        for v in [title, top, scrolls[0], letters, scrolls[1], timeline, scrolls[2], scrolls[3], empty, bottom, statsPage, listeningPage, songPage, artistPage]
            as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let (side, mid, alb, trk) = (scrolls[0], scrolls[1], scrolls[2], scrolls[3])
        timelineHeight = timeline.heightAnchor.constraint(equalToConstant: 0)
        lettersWidth = letters.widthAnchor.constraint(equalToConstant: 16)
        let gap: CGFloat = 8
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            title.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 32),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            side.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            side.widthAnchor.constraint(equalToConstant: 150),
            side.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),

            letters.topAnchor.constraint(equalTo: side.topAnchor),
            letters.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            letters.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: gap),
            lettersWidth,
            mid.topAnchor.constraint(equalTo: side.topAnchor),
            mid.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            mid.leadingAnchor.constraint(equalTo: letters.trailingAnchor, constant: 2),
            mid.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.22),

            timeline.topAnchor.constraint(equalTo: side.topAnchor),
            timeline.leadingAnchor.constraint(equalTo: mid.trailingAnchor, constant: gap),
            timeline.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            timelineHeight,
            alb.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 0),
            alb.leadingAnchor.constraint(equalTo: timeline.leadingAnchor),
            alb.trailingAnchor.constraint(equalTo: timeline.trailingAnchor),
            alb.heightAnchor.constraint(equalTo: trk.heightAnchor, multiplier: 1.1),
            trk.topAnchor.constraint(equalTo: alb.bottomAnchor, constant: gap),
            trk.leadingAnchor.constraint(equalTo: timeline.leadingAnchor),
            trk.trailingAnchor.constraint(equalTo: timeline.trailingAnchor),
            trk.bottomAnchor.constraint(equalTo: side.bottomAnchor),

            empty.centerXAnchor.constraint(equalTo: alb.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: alb.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: alb.widthAnchor, constant: -40),

            statsPage.topAnchor.constraint(equalTo: side.topAnchor),
            statsPage.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            statsPage.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: gap),
            statsPage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            artistPage.topAnchor.constraint(equalTo: side.topAnchor),
            artistPage.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            artistPage.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: gap),
            artistPage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            songPage.topAnchor.constraint(equalTo: side.topAnchor),
            songPage.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            songPage.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: gap),
            songPage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            listeningPage.topAnchor.constraint(equalTo: side.topAnchor),
            listeningPage.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            listeningPage.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: gap),
            listeningPage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root
    }

    private func configure(_ t: KeyTableView, _ scroll: NSScrollView, columns: [NSTableColumn], rowHeight: CGFloat) {
        columns.forEach(t.addTableColumn)
        t.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        t.dataSource = self
        t.delegate = self
        t.target = self
        t.doubleAction = #selector(doubleClicked(_:))
        t.onKey = { [weak self, weak t] e in t.map { self?.tableKey(e, in: $0) ?? false } ?? false }
        Dash.applyList(t, in: scroll, rowHeight: rowHeight)
        // A single-column list is exactly as wide as its card (wider, the selection's right side was cut off).
        if columns.count == 1 {
            t.intercellSpacing = NSSize(width: 0, height: 0)
            columns[0].resizingMask = .autoresizingMask
            t.sizeLastColumnToFit()
        }
        // Only the title column stretches.
        if columns.count > 1 { t.columnAutoresizingStyle = .uniformColumnAutoresizingStyle; columns.dropFirst(2).forEach { $0.resizingMask = [] } }
    }

    private func applyTheme() {
        window?.backgroundColor = Dash.page
        for (t, s) in zip([sidebar, middle, albumTable, trackTable], scrolls) { Dash.applyList(t, in: s, rowHeight: t.rowHeight) }
        [sidebar, middle, albumTable, trackTable].forEach { $0.reloadData() }
        status.textColor = LibraryStyle.dim
        empty.textColor = LibraryStyle.dim
        letters.needsDisplay = true
        timeline.needsDisplay = true
    }

    // MARK: Loading

    private var db: CollectionDB? { library.reader }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Everything again, keeping the selections where they still exist.
    private func reloadAll(keepEntry: String? = nil, keepAlbum: String? = nil) {
        sidebar.reloadData()
        sidebar.selectRowIndexes([searching ? Section.artists.rawValue : section.rawValue], byExtendingSelection: false)
        loadEntries(keep: keepEntry ?? selectedEntry?.id, keepAlbum: keepAlbum ?? selectedAlbum?.key)
        updateStatus()
    }

    /// Stats and Listening replace the lists; everything else shows them.
    private var showingStats: Bool { section == .stats && !searching }
    private var showingListening: Bool { section == .listening && !searching }
    private var showingPage: Bool { showingStats || showingListening }

    private func showStatsPage() {
        for v in [letters, scrolls[1], timeline, scrolls[2], scrolls[3], empty] as [NSView] { v.isHidden = true }
        statsPage.isHidden = false
        if statsPage.documentView?.subviews.first.map({ ($0 as? NSStackView)?.arrangedSubviews.isEmpty ?? true }) ?? true {
            statsPage.showLoading()
        }
        // Counted on a connection of its own, off the main thread (a 100k-track library takes a moment).
        statsGeneration += 1
        let gen = statsGeneration, filter = self.filter
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = try? CollectionDB().stats(filter)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.statsGeneration, self.showingStats, let stats else { return }
                self.statsPage.show(stats)
            }
        }
    }

    // MARK: Pages (song, artist)

    private func showSong(artist: String, titleKey: String) { push(.song(artist: artist, title: titleKey)) }

    private func push(_ p: Page) {
        pages.append(p)
        showTopPage()
    }

    private func showTopPage() {
        guard let p = pages.last else { return }
        for v in [letters, scrolls[1], timeline, scrolls[2], scrolls[3], empty, statsPage, listeningPage, songPage, artistPage] as [NSView] {
            v.isHidden = true
        }
        switch p {
        case .song(let artist, let title):
            songPage.isHidden = false
            songPage.show(artist: artist, titleKey: title)
            window?.makeFirstResponder(songPage)
        case .artist(let key):
            artistPage.isHidden = false
            artistPage.show(artist: key)
            window?.makeFirstResponder(artistPage)
        }
    }

    /// Back: the page before, or the lists.
    private func back() {
        pages.removeLast()
        if pages.isEmpty { closePages() } else { showTopPage() }
    }

    private func closePages() {
        pages = []
        songPage.isHidden = true
        artistPage.isHidden = true
        reloadAll()
    }

    /// A release (or just the artist) in the library's lists.
    private func openRelease(artist: String, album: String?) {
        pages = []
        songPage.isHidden = true
        artistPage.isHidden = true
        section = .artists
        reloadAll(keepEntry: artist, keepAlbum: album)
        window?.makeFirstResponder(album == nil ? middle : albumTable)
    }

    /// The artist selected in the list: their page.
    @objc private func openArtistPage() {
        guard let e = selectedEntry, section == .artists || section == .shows || searching else { return }
        push(.artist(e.id))
    }

    /// Right-click on a track: all recordings of that song by that artist.
    @objc private func showVersions() {
        let r = trackTable.clickedRow >= 0 ? trackTable.clickedRow : trackTable.selectedRow
        guard r >= 0, r < tracks.count else { return }
        let t = tracks[r]
        let artist = t.albumKey.components(separatedBy: "\u{1}").first ?? Keys.artist(t.artist)
        showSong(artist: artist, titleKey: Keys.title(t.title))
    }

    /// From a chart: the library at that genre, year or artist.
    private func open(_ s: Section, _ entry: String) {
        section = s
        reloadAll(keepEntry: entry)
        window?.makeFirstResponder(middle)
    }

    private func loadEntries(keep: String?, keepAlbum: String? = nil) {
        if !pages.isEmpty, !searching { return }   // a page stays until Back
        songPage.isHidden = true
        artistPage.isHidden = true
        pages = []
        statsPage.isHidden = !showingStats
        listeningPage.isHidden = !showingListening
        for v in [scrolls[1], scrolls[2], scrolls[3]] as [NSView] { v.isHidden = showingPage }
        if showingStats { showStatsPage(); return }
        if showingListening {
            for v in [letters, timeline, empty] as [NSView] { v.isHidden = true }
            listeningPage.appear()
            return
        }
        guard let db else { entries = []; middle.reloadData(); showEmpty(); return }
        do {
            switch searching ? .artists : section {
            case .artists:
                let list = searching ? try db.artists(matching: query, filter) : try db.artists(filter)
                entries = list.map { Entry(id: $0.key, title: $0.name, count: $0.albums, letter: $0.letter) }
            case .shows:
                entries = try db.artists(filter, onlyKind: .show).map { Entry(id: $0.key, title: $0.name, count: $0.albums, letter: $0.letter) }
            case .years:
                entries = try db.years(filter).map { Entry(id: $0.id, title: $0.title, count: $0.count) }
            case .genres:
                entries = try db.genres(filter).map { Entry(id: $0.id, title: $0.title, count: $0.count) }
            case .added:
                entries = try db.addedMonths(filter).map { Entry(id: $0.id, title: $0.title, count: $0.count) }
            case .stats, .listening:
                entries = []
            }
        } catch {
            NSLog("OmniAmp: library query failed: %@", "\(error)")
            entries = []
        }
        maxCount = max(1, entries.map(\.count).max() ?? 1)
        let showLetters = (searching || section == .artists || section == .shows) && entries.count > 30
        lettersWidth.constant = showLetters ? 16 : 0
        letters.isHidden = !showLetters
        letters.present = Set(entries.compactMap(\.letter))
        middle.reloadData()
        let row = keep.flatMap { id in entries.firstIndex { $0.id == id } } ?? (entries.isEmpty ? nil : 0)
        if let row {
            middle.selectRowIndexes([row], byExtendingSelection: false)
            middle.scrollRowToVisible(row)
        } else {
            middle.deselectAll(nil)
        }
        loadAlbums(keep: keepAlbum)
    }

    private var selectedEntry: Entry? {
        let r = middle.selectedRow
        return r >= 0 && r < entries.count ? entries[r] : nil
    }

    private func loadAlbums(keep: String? = nil) {
        var list: [LibraryAlbum] = []
        var grouping: (LibraryAlbum) -> String = { $0.kind.title }
        if let db, let e = selectedEntry {
            do {
                switch searching ? .artists : section {
                case .artists:
                    let all = try db.albums(artist: e.id, filter)
                    timeline.albums = all
                    if searching {
                        let hits = Set(try db.albums(matching: query, filter).map(\.key))
                        list = all.filter { hits.contains($0.key) }
                    } else {
                        list = all
                    }
                case .shows:
                    let all = try db.albums(artist: e.id, filter)
                    timeline.albums = all.filter { $0.kind == .show }
                    list = all.filter { $0.kind == .show }.sorted { ($0.showDate ?? "", $0.title) < ($1.showDate ?? "", $1.title) }
                    grouping = { a in a.year.map(String.init) ?? "Undated" }
                case .years:
                    list = try db.albums(year: Int(e.id), filter)
                case .genres:
                    list = try db.albums(genre: e.id, filter)
                case .added:
                    list = try db.albums(addedIn: e.id, filter)
                    grouping = { _ in "" }
                case .stats, .listening:
                    break
                }
            } catch {
                NSLog("OmniAmp: library query failed: %@", "\(error)")
            }
        }
        let withTimeline = (searching || section == .artists || section == .shows) && selectedEntry != nil
        if !withTimeline { timeline.albums = [] }
        timelineHeight.constant = withTimeline ? min(timeline.preferredHeight, 100) : 0
        timeline.isHidden = timelineHeight.constant == 0

        // Group titles with counts ("Shows & Bootlegs · 42", "1977 · 23").
        items = []
        var i = 0
        while i < list.count {
            let g = grouping(list[i])
            var j = i
            while j < list.count, grouping(list[j]) == g { j += 1 }
            // Groups by kind carry its color; year groups (shows) are all one kind: the same.
            if !g.isEmpty { items.append(.header("\(g) · \(j - i)", list[i].kind)) }
            items += list[i..<j].map { .album($0) }
            i = j
        }
        albumTable.reloadData()
        let row = keep.flatMap { k in items.firstIndex { if case .album(let a) = $0 { a.key == k } else { false } } }
            ?? items.firstIndex { if case .album = $0 { true } else { false } }
        if let row {
            albumTable.selectRowIndexes([row], byExtendingSelection: false)
            albumTable.scrollRowToVisible(row == 1 ? 0 : row)   // the first release: its group title stays in view
        } else {
            albumTable.deselectAll(nil)
        }
        loadTracks()
        showEmpty()
    }

    private var selectedAlbums: [LibraryAlbum] {
        albumTable.selectedRowIndexes.compactMap { r in
            guard r < items.count, case .album(let a) = items[r] else { return nil }
            return a
        }
    }
    private var selectedAlbum: LibraryAlbum? { selectedAlbums.first }

    private func loadTracks() {
        let albums = selectedAlbums
        tracks = []
        if let db {
            for a in albums {
                tracks += (try? db.tracks(album: a.key, matching: searching ? query : nil)) ?? []
            }
            // A search found the album by its title or artist, not a song: show all its tracks.
            if searching, tracks.isEmpty { for a in albums { tracks += (try? db.tracks(album: a.key)) ?? [] } }
        }
        trackTable.reloadData()
        timeline.selectedKey = selectedAlbum?.key
    }

    private func selectAlbum(_ key: String) {
        guard let row = items.firstIndex(where: { if case .album(let a) = $0 { a.key == key } else { false } }) else { return }
        albumTable.selectRowIndexes([row], byExtendingSelection: false)
        albumTable.scrollRowToVisible(row)
    }

    private func showEmpty() {
        if showingPage { empty.isHidden = true; return }
        if let err = library.openError {
            empty.stringValue = "The library database couldn't be opened:\n\(err)"
        } else if library.roots.isEmpty, entries.isEmpty {
            empty.stringValue = "Point OmniAmp at your music.\n\nFOLDERS → Add Folder… (a NAS share is fine). The library keeps itself up to date and sorts out albums, live recordings, shows and unreleased tracks from the tags and folder names."
        } else if entries.isEmpty {
            empty.stringValue = library.progress.running ? "Reading your music…" : (searching ? "Nothing matches “\(query)”." : "Nothing here with these filters.")
        } else {
            empty.stringValue = ""
        }
        empty.isHidden = empty.stringValue.isEmpty
    }

    /// Written during a scan: refresh at most every two seconds (the lists stay put under the mouse).
    private func libraryChanged() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            let entry = self.selectedEntry?.id, album = self.selectedAlbum?.key
            let topRow = self.middle.rows(in: self.middle.visibleRect).location
            self.loadEntries(keep: entry, keepAlbum: album)
            if entry == nil, topRow > 0 { self.middle.scrollRowToVisible(topRow) }
            self.updateStatus()
        }
    }

    private func updateStatus() {
        let p = library.progress
        if p.running {
            var s = "Scanning… \(p.found.formatted()) files"
            if p.toRead > 0 { s += " · reading tags \(p.read.formatted()) of \(p.toRead.formatted())" }
            status.stringValue = s
        } else if let sum = try? db?.summary(), sum.tracks > 0 {
            let days = sum.duration / 86400
            status.stringValue = "\(sum.artists.formatted()) artists · \(sum.albums.formatted()) releases · \(sum.tracks.formatted()) tracks · "
                + (days >= 1 ? String(format: "%.1f days", days) : String(format: "%.1f hours", sum.duration / 3600))
        } else {
            status.stringValue = ""
        }
        showEmpty()
    }

    // MARK: Filters and search

    private func updateFilterButtons() {
        for b in scopeButtons { b.isOn = b.tag == filter.scope.rawValue }
        losslessButton.isOn = filter.losslessOnly
    }

    @objc private func scopeClicked(_ sender: ModernButton) {
        filter.scope = LibraryFilter.Scope(rawValue: sender.tag) ?? .all
        updateFilterButtons()
        loadEntries(keep: selectedEntry?.id, keepAlbum: selectedAlbum?.key)
    }

    @objc private func losslessClicked() {
        filter.losslessOnly.toggle()
        updateFilterButtons()
        loadEntries(keep: selectedEntry?.id, keepAlbum: selectedAlbum?.key)
    }

    @objc private func searchChanged() {
        guard search.stringValue != query else { return }
        query = search.stringValue
        reloadAll(keepEntry: nil)
    }

    /// Typing searches as you go (after a short pause).
    func controlTextDidChange(_ obj: Notification) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(searchChanged), object: nil)
        perform(#selector(searchChanged), with: nil, afterDelay: 0.25)
    }

    /// In the search field: Return and ↓ go to the results; Esc clears, and in an empty field goes back to the list.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === search else { return false }
        switch sel {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            searchChanged()
            window?.makeFirstResponder(middle)
        case #selector(NSResponder.cancelOperation(_:)):
            if !search.stringValue.isEmpty { search.stringValue = ""; searchChanged() } else { window?.makeFirstResponder(middle) }
        default:
            return false
        }
        return true
    }

    func focusSearch() {
        window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    func focusList() {
        window?.makeFirstResponder(middle)
    }

    /// First artist at or after the letter.
    private func jump(to letter: String) {
        letters.current = letter
        guard let row = entries.firstIndex(where: { ($0.letter ?? "#") >= letter && ($0.letter != "#" || letter == "#") }) else { return }
        middle.selectRowIndexes([row], byExtendingSelection: false)
        // The letter's first artist at the top of the list.
        middle.scrollRowToVisible(min(entries.count - 1, row + max(0, middle.rows(in: middle.visibleRect).length - 1)))
        middle.scrollRowToVisible(row)
        window?.makeFirstResponder(middle)
    }

    // MARK: Folders

    @objc private func showFolders(_ sender: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Add Folder…", action: #selector(addFolder), keyEquivalent: "").target = self
        let rescan = menu.addItem(withTitle: "Rescan All", action: #selector(rescanAll), keyEquivalent: "")
        rescan.target = self
        rescan.isEnabled = !library.roots.isEmpty
        if !library.roots.isEmpty {
            menu.addItem(.separator())
            let head = menu.addItem(withTitle: "Library folders (choose one to remove it):", action: nil, keyEquivalent: "")
            head.isEnabled = false
            for r in library.roots {
                let it = menu.addItem(withTitle: r, action: #selector(removeFolder(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = r
                it.image = NSWorkspace.shared.icon(forFile: r)
                it.image?.size = NSSize(width: 16, height: 16)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = "Add to Library"
        p.message = "Choose the folders that hold your music. OmniAmp reads them and keeps the library up to date."
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK else { return }
            MainActor.assumeIsolated {
                for u in p.urls { self?.library.add(u) }
                self?.updateStatus()
            }
        }
    }

    @objc private func rescanAll() { library.rescanAll() }

    @objc private func removeFolder(_ sender: NSMenuItem) {
        guard let root = sender.representedObject as? String else { return }
        let a = NSAlert()
        a.messageText = "Remove “\((root as NSString).lastPathComponent)” from the library?"
        a.informativeText = "Its music disappears from the library. Nothing is deleted from the disk, and the playlist isn't changed."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard let w = window else { return }
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.library.remove(root) }
        }
    }

    // MARK: Playing

    /// What Return, PLAY and ADD act on: the tracks selected in the track list when it has focus,
    /// else all tracks of the selected releases.
    private func chosenTracks() -> [LibraryTrack] {
        if window?.firstResponder === trackTable, !trackTable.selectedRowIndexes.isEmpty {
            return trackTable.selectedRowIndexes.filter { $0 < tracks.count }.map { tracks[$0] }
        }
        if window?.firstResponder === middle, let db, section == .artists || section == .shows || searching {
            // An artist: every release in the list, in order.
            return items.compactMap { if case .album(let a) = $0 { a } else { nil } }.flatMap { (try? db.tracks(album: $0.key)) ?? [] }
        }
        guard let db else { return [] }
        return selectedAlbums.flatMap { (try? db.tracks(album: $0.key)) ?? [] }
    }

    @objc private func playSelection() { play(chosenTracks()) }
    @objc private func addSelection() { enqueue(chosenTracks()) }

    /// Only what OmniAmp can play; says what was left out (WMA, SHN, protected M4P…). nil when nothing's left.
    private func playable(_ list: [LibraryTrack]) -> [LibraryTrack]? {
        let ok = list.filter(\.playable)
        let skipped = list.count - ok.count
        if skipped > 0 {
            let formats = Set(list.filter { !$0.playable }.map { ($0.path as NSString).pathExtension.uppercased() }).sorted()
            let names = formats.joined(separator: "/")
            status.stringValue = ok.isEmpty
                ? "OmniAmp can't play \(names) files. Convert them to FLAC to play them (see scripts/convert-unplayable.sh)."
                : "Skipped \(skipped) \(names) track\(skipped == 1 ? "" : "s") OmniAmp can't play."
        }
        if ok.isEmpty { NSSound.beep(); return nil }
        return ok
    }

    /// Plays: already at the end of the playlist in this order → play from there; else add them and play the first.
    private func play(_ all: [LibraryTrack]) {
        guard let list = playable(all), let first = list.first else { return }
        let keys = list.map(\.key)
        let current = controller.tracks.map(\.key)
        if let i = current.firstIndex(of: first.key), i + keys.count <= current.count, Array(current[i..<(i + keys.count)]) == keys {
            controller.play(index: i)
            return
        }
        let at = controller.tracks.count
        controller.insertScanned(list.map(\.track), at: at)
        controller.play(index: at)
        if list.count == all.count { status.stringValue = "Playing \(list.count == 1 ? "“\(first.title)”" : "\(list.count) tracks")." }
    }

    private func enqueue(_ all: [LibraryTrack]) {
        guard let list = playable(all) else { return }
        controller.insertScanned(list.map(\.track), at: controller.tracks.count)
        if list.count == all.count { status.stringValue = "Added \(list.count == 1 ? "“\(list[0].title)”" : "\(list.count) tracks") to the playlist." }
    }

    @objc private func replaceAndPlay() {
        guard let list = playable(chosenTracks()) else { return }
        controller.clear()
        controller.insertScanned(list.map(\.track), at: 0)
        controller.play(index: 0)
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        guard sender.clickedRow >= 0 else { return }
        switch sender {
        case middle where section == .artists || section == .shows || searching: openArtistPage()
        case sidebar, middle: window?.makeFirstResponder(albumTable)
        case trackTable: play(trackTable.selectedRowIndexes.filter { $0 < tracks.count }.map { tracks[$0] })
        default:
            guard let db else { return }
            play(selectedAlbums.flatMap { (try? db.tracks(album: $0.key)) ?? [] })
        }
    }

    private var infoSheet: FindInfoSheet?

    /// Look the selected release up online; write what's chosen into its files and folder.
    @objc private func findInfo() {
        guard let a = selectedAlbum, let db, let w = window, infoSheet == nil else { return }
        let sheet = FindInfoSheet(album: a, tracks: (try? db.tracks(album: a.key)) ?? [], genre: try? db.genre(album: a.key))
        sheet.onDone = { [weak self, weak sheet] message in
            guard let self, let sw = sheet?.window else { return }
            w.endSheet(sw)
            self.infoSheet = nil
            if let message { self.status.stringValue = "“\(a.title)”: \(message)" }
        }
        infoSheet = sheet
        w.beginSheet(sheet.window!)
    }

    @objc private func showInFinder() {
        let urls: [URL]
        if window?.firstResponder === trackTable {
            urls = trackTable.selectedRowIndexes.filter { $0 < tracks.count }.map { URL(exactPath: tracks[$0].path) }
        } else {
            urls = selectedAlbums.map { URL(exactPath: $0.firstPath) }
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: Keyboard

    /// Return plays, ⌥Return adds, Space pauses, ←/→ and Tab move between the lists, typing searches, Esc
    /// clears the search or closes.
    private func tableKey(_ e: NSEvent, in t: KeyTableView) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let order: [NSTableView] = [sidebar, middle, albumTable, trackTable]
        let idx = order.firstIndex { $0 === t } ?? 0
        func focus(_ i: Int) {
            let target = order[max(0, min(order.count - 1, i))]
            window?.makeFirstResponder(target)
            if target.selectedRow < 0, target.numberOfRows > 0 {
                let first = (0..<target.numberOfRows).first { target.delegate?.tableView?(target, shouldSelectRow: $0) ?? true } ?? 0
                target.selectRowIndexes([first], byExtendingSelection: false)
            }
        }
        switch e.keyCode {
        case 36, 76:
            if mods == .option { addSelection(); return true }
            guard mods.isEmpty else { return false }
            if t === sidebar { focus(1) } else if t === middle && !(section == .artists || section == .shows || searching) { focus(2) }
            else { playSelection() }
            return true
        case 49 where mods.isEmpty: controller.togglePlayPause(); return true
        case 53 where mods.isEmpty:
            if searching { search.stringValue = ""; searchChanged() } else { window?.performClose(nil) }
            return true
        case 124 where mods.isEmpty: focus(idx + 1); return true
        case 123 where mods.isEmpty: focus(idx - 1); return true
        case 48: focus(mods == .shift ? idx - 1 : idx + 1); return true
        default:
            guard mods.isEmpty || mods == .shift, let c = ListLook.typedText(e) else { return false }
            window?.makeFirstResponder(search)
            search.currentEditor()?.insertText(c)
            return true
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === middle.menu {
            // An artist in the list: their page, or everything they made.
            guard section == .artists || section == .shows || searching, middle.clickedRow >= 0 else { return }
            if middle.selectedRow != middle.clickedRow { middle.selectRowIndexes([middle.clickedRow], byExtendingSelection: false) }
            window?.makeFirstResponder(middle)
            menu.addItem(withTitle: "Artist Page", action: #selector(openArtistPage), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Play All", action: #selector(playSelection), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Add All to Playlist", action: #selector(addSelection), keyEquivalent: "").target = self
            return
        }
        let t = menu === albumTable.menu ? albumTable : trackTable
        let row = t.clickedRow
        guard row >= 0 else { return }
        if !t.selectedRowIndexes.contains(row) { t.selectRowIndexes([row], byExtendingSelection: false) }
        window?.makeFirstResponder(t)
        func add(_ title: String, _ action: Selector) { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        add("Play", #selector(playSelection))
        add("Add to Playlist", #selector(addSelection))
        add("Replace Playlist and Play", #selector(replaceAndPlay))
        menu.addItem(.separator())
        if t === albumTable, selectedAlbums.count == 1 { add("Find Missing Info…", #selector(findInfo)) }
        if t === trackTable, trackTable.selectedRowIndexes.count == 1 { add("Show All Versions", #selector(showVersions)) }
        add("Show in Finder", #selector(showInFinder))
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case sidebar: Section.allCases.count
        case middle: entries.count
        case albumTable: items.count
        default: tracks.count
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if tableView === albumTable, row < items.count, case .header = items[row] { return HeaderRowView() }
        return CardRowView()
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === albumTable, row < items.count, case .header = items[row] { return 24 }
        return tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === albumTable, row < items.count, case .header = items[row] { return false }
        if tableView === sidebar, searching { return false }
        return true
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard let t = n.object as? NSTableView else { return }
        switch t {
        case sidebar:
            sidebar.reloadData(forRowIndexes: IndexSet(0..<Section.allCases.count), columnIndexes: [0])   // the selected one's look
            guard !searching, let s = Section(rawValue: sidebar.selectedRow) else { return }
            if !pages.isEmpty {   // leaving the pages
                pages = []
                songPage.isHidden = true
                artistPage.isHidden = true
                section = s
                loadEntries(keep: nil)
                return
            }
            guard s != section else { return }
            section = s
            loadEntries(keep: nil)
        case middle:
            letters.current = selectedEntry?.letter
            loadAlbums()
        case albumTable:
            loadTracks()
        default: break
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch tableView {
        case sidebar:
            let s = Section(rawValue: row)!
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("sidebar"), owner: nil) as? SidebarCell) ?? SidebarCell()
            cell.show(glyph: s.glyph, title: s.title, selected: sidebar.selectedRow == row, enabled: !searching || s == .artists)
            return cell
        case middle:
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("bucket"), owner: nil) as? BucketCell) ?? BucketCell()
            guard row < entries.count else { return cell }
            let e = entries[row]
            cell.show(e.title, e.count)
            cell.fraction = section == .years && !searching ? CGFloat(e.count) / CGFloat(maxCount) : nil
            return cell
        case albumTable:
            guard row < items.count else { return nil }
            switch items[row] {
            case .header(let text, let kind):
                let h = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("header"), owner: nil) as? HeaderCell) ?? HeaderCell()
                h.show(text, kind: kind)
                return h
            case .album(let a):
                let c = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("album"), owner: nil) as? AlbumCell) ?? AlbumCell()
                c.show(a, withArtist: !searching && !(section == .artists || section == .shows))
                return c
            }
        default:
            guard row < tracks.count, let id = tableColumn?.identifier.rawValue else { return nil }
            let t = tracks[row]
            let f = libraryLabel(tableView, id)
            f.font = Dash.font(12.5)
            f.textColor = Dash.text2
            f.alignment = .left
            switch id {
            case "no":
                f.stringValue = t.number.map { n in t.disc.map { "\($0)-" + String(format: "%02d", n) } ?? String(format: "%02d", n) } ?? ""
                f.font = Dash.mono(10.5)
                f.textColor = Dash.text3
                f.alignment = .right
            case "title":
                f.stringValue = t.title
                f.font = Dash.font(13)
                f.textColor = t.playable ? Dash.text : Dash.text3
            case "artist":
                f.stringValue = t.artist
            case "time":
                f.stringValue = t.duration.map(AlbumCell.length) ?? ""
                f.font = Dash.mono(11)
                f.alignment = .right
            default:
                f.stringValue = t.format
                f.font = Dash.mono(9.5)
                f.textColor = Dash.text3
                if !t.playable { f.textColor = Theme.warning }
            }
            f.toolTip = t.playable ? nil : "OmniAmp can't play this format. Convert it to FLAC to play it."
            return f
        }
    }

    /// Dragging releases or tracks out (to the playlist, or Finder): their files.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if tableView === trackTable, row < tracks.count { return URL(exactPath: tracks[row].path) as NSURL }
        if tableView === albumTable, row < items.count, case .album(let a) = items[row] { return URL(exactPath: a.folder, isDirectory: true) as NSURL }
        return nil
    }
}
