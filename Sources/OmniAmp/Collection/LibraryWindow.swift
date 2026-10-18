import AppKit

/// The music library browser in the modern look. Four panes: a sidebar (Artists, Shows, Years, Genres,
/// Recently Added), a list for the section (artists A–Z, years, genres…), that entry's releases (with a
/// timeline for an artist) grouped by kind, and the selected release's tracks. Albums shows the covers in a
/// grid instead (AlbumGridPage), Tracks every track in one sortable list (TracksPage).
///
/// ALL / OFFICIAL / UNOFFICIAL and LOSSLESS filter every pane; typing searches titles, artists, albums and
/// venues. Return or double-click plays (adds to the playlist and starts), ⌥Return adds without playing.
final class LibraryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, PageBack,
                                     NSMenuDelegate, NSSearchFieldDelegate {
    enum Section: Int, CaseIterable {
        // Only kept in memory (never in prefs): the numbers may change.
        case tracks, artists, albums, shows, years, genres, added, stats, listening, attention

        var title: String {
            switch self {
            case .tracks: "Tracks"
            case .artists: "Artists"
            case .albums: "Albums"
            case .shows: "Shows"
            case .years: "Years"
            case .genres: "Genres"
            case .added: "Recently Added"
            case .stats: "Stats"
            case .listening: "Listening"
            case .attention: "Needs Attention"
            }
        }
        var glyph: String {
            switch self {
            case .tracks: Fonts.Icon.music
            case .artists: "\u{F0849}"   // nf-md-account_music
            case .albums: "\u{F0025}"    // nf-md-album
            case .shows: "\u{F0403}"     // nf-md-microphone_variant
            case .years: "\u{F00ED}"     // nf-md-calendar_blank
            case .genres: "\u{F0770}"    // nf-md-tag_multiple
            case .added: "\u{F0150}"     // nf-md-clock_outline
            case .stats: "\u{F0128}"     // nf-md-chart_bar
            case .listening: "\u{F01E7}"   // nf-md-earth
            case .attention: Fonts.Icon.warning
            }
        }
    }

    /// A row in the sidebar: the sections, then the saved playlists under their title.
    private enum SideRow: Equatable { case section(Section), divider, header, group(URL), playlist(URL) }

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
    /// Needs Attention is on screen already (a refresh), and a group the test hook asked for.
    private var attentionOpen = false
    private var attentionHookGroup: String?
    /// The gap under the release shelf (none when it's hidden).
    private var timelineGap: NSLayoutConstraint!
    private var lettersWidth: NSLayoutConstraint!
    private let search = DashSearchField()
    private let status = NSTextField(labelWithString: "")
    /// Shown while Live Music Archive downloads are paused (after a quit): carries on with all of them.
    private lazy var resumeButton = Pill("Resume", glyph: "⤓", target: self, action: #selector(resumeDownloads))
    private let empty = EmptyNotice()
    /// A search that found nothing, spelled like the library ("nirvna" → nirvana), for the query it was worked out for.
    private var suggestion: (query: String, spelled: String?)?
    private var scopeButtons: [Pill] = []
    private var losslessButton: Pill!
    private let observers = Observers()
    private var refreshPending = false
    private let statsPage = StatsPage()
    private let listeningPage = ListeningPage()
    private let songPage = SongPage()
    private let artistPage = ArtistPage()
    private let attentionPage = AttentionPage()
    private let gridPage = AlbumGridPage()
    private let tracksPage = TracksPage()
    private let playlistPage = PlaylistPage()
    private let playlists = SavedPlaylists.shared
    private var sideRows: [SideRow] = []
    /// The saved playlist shown (its sidebar row selected); nil: a section.
    private var openPlaylist: URL?
    private var playlistsCollapsed = UserDefaults.standard.bool(forKey: Pref.libraryPlaylistsCollapsed)
    /// A rename in progress: the folder's change notice mustn't close the playlist under its old name.
    private var renaming = false
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
            openPlaylist = st.playlist
        }
        if let q = ProcessInfo.processInfo.environment["OMNIAMP_LIBRARY_SEARCH"] { query = q }   // test hook
        // Test hook: OMNIAMP_LIBRARY_TYPING=1 puts the cursor in the search field (how it looks while typing).
        if ProcessInfo.processInfo.environment["OMNIAMP_LIBRARY_TYPING"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.focusSearch() }
        }
        build()
        search.stringValue = query
        let nc = NotificationCenter.default
        observers.add(nc.addObserver(forName: Theme.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        })
        observers.add(nc.addObserver(forName: MusicCollection.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        })
        observers.add(nc.addObserver(forName: SavedPlaylists.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playlistsChanged() }
        })
        observers.add(nc.addObserver(forName: MusicCollection.progressChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        })
        observers.add(nc.addObserver(forName: LiveArchiveDownloads.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        })
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didMiniaturizeNotification] {
            observers.add(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            })
        }
        library.start()
        // Test hook: OMNIAMP_LIBRARY=section[:entry] opens on a section and entry ("shows:Grateful Dead", "years:1997").
        var entry = Self.lastState?.entry
        // "playlists:Road Trip" opens that saved playlist ("playlists": the first one).
        if let hook = ProcessInfo.processInfo.environment["OMNIAMP_LIBRARY"], hook == "playlists" || hook.hasPrefix("playlists:") {
            let name = hook.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)
            openPlaylist = playlists.urls.first { name == nil || SavedPlaylists.name($0) == name }
            query = ""
            search.stringValue = ""
        } else if let hook = ProcessInfo.processInfo.environment["OMNIAMP_LIBRARY"], let name = hook.split(separator: ":").first,
           let s = Section.allCases.first(where: { String(describing: $0) == name }) {
            section = s
            entry = hook.split(separator: ":", maxSplits: 1).dropFirst().first.map { e in s == .artists || s == .shows ? Keys.artist(String(e)) : String(e) }
            if s == .attention { attentionHookGroup = entry }
            // "albums:year" groups the grid by year; "albums:Homogenic" opens that album.
            if s == .albums, let e = entry { DispatchQueue.main.async { [weak self] in self?.gridPage.applyHook(e) } }
            openPlaylist = nil
        }
        if let u = openPlaylist, !playlists.urls.contains(where: { SavedPlaylists.same($0, u) }) { openPlaylist = nil }
        if let u = openPlaylist { reveal(u) }
        if searching { openPlaylist = nil }
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
        // Test hook: OMNIAMP_LIBRARY_FIND=1 opens Find Missing Info for the selected release, "Artist|Album" for that one.
        if let hook = ProcessInfo.processInfo.environment["OMNIAMP_LIBRARY_FIND"] {
            let parts = hook.components(separatedBy: "|")
            if parts.count == 2, let a = try? db?.albums(artist: Keys.artist(parts[0]), LibraryFilter()).first(where: { $0.title == parts[1] }) {
                openRelease(artist: a.artistKey, album: a.key)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.findInfo() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private static var lastState: (section: Section, filter: LibraryFilter, query: String, entry: String?, album: String?, playlist: URL?)?
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        Self.lastState = (section, filter, query, selectedEntry?.id, selectedAlbum?.key, openPlaylist)
        // Only the player stays open: the covers and tickets in memory go (on disk, or drawn again, when it opens).
        LibraryArt.shared.releaseMemory()
        Tickets.shared.releaseMemory()
        onClose?()
    }


    // MARK: Layout

    private func build() {
        window?.backgroundColor = Dash.page
        let title = Dash.label("Music Library", Dash.font(12, .semibold), Dash.text2)

        search.placeholderString = "Search artists, albums, songs, venues, dates, folders…"
        search.toolTip = "Every word counts (as the start of a word). \"Quotes\" for exact words; dates in any spelling: 1977-05-08, 8.5.77, 5/8/1977"
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
        sidebar.action = #selector(sidebarClicked)
        // Songs, albums, folders and files dropped on a playlist go into it; on the title, into a new one.
        sidebar.registerForDraggedTypes([.fileURL, LibraryDrag.pathsType, LibraryDrag.tracksType, Self.sidebarPlaylistType])
        sidebar.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        sidebar.setDraggingSourceOperationMask(.copy, forLocal: false)
        sidebar.draggingDestinationFeedbackStyle = .regular
        let sideMenu = NSMenu()
        sideMenu.delegate = self
        sidebar.menu = sideMenu
        let artistMenu = NSMenu()
        artistMenu.delegate = self
        middle.menu = artistMenu

        letters.onLetter = { [weak self] l in self?.jump(to: l) }
        // Scrolling the list (by hand: not a jump or a selection brought into view) lights the letter it's at.
        observers.add(NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scrolls[1],
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followScroll() }
        })
        letters.translatesAutoresizingMaskIntoConstraints = false
        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.onSelect = { [weak self] a in self?.selectAlbum(a.key) }
        Dash.styleCard(timeline)

        empty.onSuggestion = { [weak self] q in self?.search(for: q) }

        status.font = Dash.font(11)
        status.textColor = Dash.text2
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let add = Pill("Add", glyph: Fonts.Icon.plus, target: self, action: #selector(addSelection))
        let play = Pill("Play", glyph: Fonts.Icon.play, target: self, action: #selector(playSelection))
        play.prominent = true
        add.toolTip = "Add to the playlist (⌥Return)"
        play.toolTip = "Add to the playlist and play (Return, double-click)"
        resumeButton.toolTip = "Carry on with the paused Live Music Archive downloads (only the missing files)"
        resumeButton.isHidden = true
        let bottom = NSStackView(views: [status, resumeButton, NSView(), add, play])
        bottom.spacing = 6

        let root = NSView()
        statsPage.onGenre = { [weak self] g in self?.open(.genres, g) }
        statsPage.onYear = { [weak self] y in self?.open(.years, String(y)) }
        statsPage.onArtist = { [weak self] a in self?.push(.artist(a)) }
        statsPage.onAlbum = { [weak self] a in self?.openRelease(artist: a.artistKey, album: a.key) }
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
        attentionPage.onFix = { [weak self] fix in
            guard let self else { return }
            switch fix {
            case .artist(let a): self.push(.artist(a))
            case .open(let a, let album): self.openRelease(artist: a, album: album)
            case .folder(let f): NSWorkspace.shared.activateFileViewerSelecting([URL(exactPath: f, isDirectory: true)])
            case .findInfo(let a, let album):
                self.openRelease(artist: a, album: album)
                if self.selectedAlbum?.key == album { self.findInfo() }
            }
        }
        artistPage.onBack = { [weak self] in self?.back() }
        artistPage.onSong = { [weak self] a, t in self?.push(.song(artist: a, title: t)) }
        artistPage.onRelease = { [weak self] a in self?.openRelease(artist: a.artistKey, album: a.key) }
        artistPage.onBrowse = { [weak self] a in self?.openRelease(artist: a, album: nil) }
        artistPage.onPlay = { [weak self] list in self?.play(list) }
        artistPage.onShows = { [weak self] a in self?.dropPages(); self?.open(.shows, a) }
        gridPage.onPlay = { [weak self] list, start in self?.play(list, from: start) }
        gridPage.onAdd = { [weak self] list in self?.enqueue(list) }
        gridPage.onArtist = { [weak self] a in self?.push(.artist(a)) }
        gridPage.onMenu = { [weak self] in self?.gridMenu() }
        gridPage.onKey = { [weak self] e in self?.gridKey(e) ?? false }
        gridPage.onSuggestion = { [weak self] q in self?.search(for: q) }
        tracksPage.onPlay = { [weak self] list, start in self?.play(list, from: start) }
        tracksPage.onPlayAlbum = { [weak self] r in
            guard let self, let db = self.db else { return }
            let album = (try? db.tracks(album: r.track.albumKey)) ?? []
            if let i = album.firstIndex(where: { $0.id == r.track.id }) { self.play(album, from: i) } else { self.play([r.track]) }
        }
        tracksPage.onAdd = { [weak self] list in self?.enqueue(list) }
        tracksPage.onReplace = { [weak self] list in self?.replace(with: list) }
        tracksPage.onEditTags = { [weak self] in self?.editTags(of: $0) }
        tracksPage.onShowAlbum = { [weak self] r in self?.openRelease(artist: r.artistKey, album: r.track.albumKey) }
        tracksPage.onArtist = { [weak self] a in self?.push(.artist(a)) }
        tracksPage.onVersions = { [weak self] a, t in self?.showSong(artist: a, titleKey: t) }
        tracksPage.onKey = { [weak self] e in self?.gridKey(e) ?? false }
        tracksPage.onSummary = { [weak self] in self?.updateStatus() }
        tracksPage.onAddToSaved = { [weak self] list, url in self?.addToSaved(list, url) }
        tracksPage.onNewPlaylist = { [weak self] list in self?.newPlaylist(with: list) }
        playlistPage.onPlay = { [weak self] list, start in self?.play(tracks: list, from: start) }
        playlistPage.onAdd = { [weak self] list in self?.enqueue(tracks: list) }
        playlistPage.onLoad = { [weak self] url in
            guard let self else { return }
            self.controller.loadPlaylist(url)
            self.status.stringValue = "Loaded “\(SavedPlaylists.name(url))” into the player."
        }
        playlistPage.onEditTags = { [weak self] in self?.editTags(of: $0) }
        playlistPage.onShowAlbum = { [weak self] t in
            self?.openRelease(artist: t.albumKey.components(separatedBy: "\u{1}").first ?? Keys.artist(t.artist), album: t.albumKey)
        }
        playlistPage.onRename = { [weak self] in if let u = self?.openPlaylist { self?.beginRename(u) } }
        playlistPage.onTrash = { [weak self] in if let u = self?.openPlaylist { self?.trashPlaylist(u) } }
        playlistPage.onAddToSaved = { [weak self] list, url in self?.addTracks(list, to: url) }
        playlistPage.onNewPlaylist = { [weak self] list in self?.newPlaylist(tracks: list) }
        playlistPage.onKey = { [weak self] e in self?.gridKey(e) ?? false }
        playlistPage.onSummary = { [weak self] in self?.updateStatus() }
        // Filter words typed into the search became chips: they leave the field (no new search for that).
        tracksPage.onSearchText = { [weak self] text in
            guard let self else { return }
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.searchChanged), object: nil)
            self.search.stringValue = text
            self.query = text
        }
        for v in [title, top, scrolls[0], letters, scrolls[1], timeline, scrolls[2], scrolls[3], empty, bottom, statsPage, listeningPage,
                  songPage, artistPage, attentionPage, gridPage, tracksPage, playlistPage] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let (side, mid, alb, trk) = (scrolls[0], scrolls[1], scrolls[2], scrolls[3])
        timelineHeight = timeline.heightAnchor.constraint(equalToConstant: 0)
        timelineGap = alb.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 0)
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
            timelineGap,
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
            attentionPage.topAnchor.constraint(equalTo: side.topAnchor),
            attentionPage.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            attentionPage.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: gap),
            attentionPage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
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
            gridPage.topAnchor.constraint(equalTo: side.topAnchor),
            gridPage.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            gridPage.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: gap - 12),
            gridPage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: 0),
            tracksPage.topAnchor.constraint(equalTo: side.topAnchor),
            tracksPage.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            tracksPage.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: gap),
            tracksPage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            playlistPage.topAnchor.constraint(equalTo: side.topAnchor),
            playlistPage.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            playlistPage.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: gap + 4),
            playlistPage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

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
        // Dash's colors follow the theme by themselves: cards painted again and a redraw are enough, so every
        // page (hidden ones too) keeps its scroll and lists.
        window?.backgroundColor = Dash.page
        if let v = window?.contentView { Dash.restyle(v) }
        [sidebar, middle, albumTable, trackTable].forEach { $0.reloadData() }
        tracksPage.restyle()
        playlistPage.restyle()
    }

    // MARK: Loading

    private var db: CollectionDB? { library.reader }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Everything again, keeping the selections where they still exist.
    private func reloadAll(keepEntry: String? = nil, keepAlbum: String? = nil) {
        rebuildSidebar()
        loadEntries(keep: keepEntry ?? selectedEntry?.id, keepAlbum: keepAlbum ?? selectedAlbum?.key)
        updateStatus()
    }

    /// Stats and Listening replace the lists; everything else shows them.
    private var showingStats: Bool { section == .stats && !searching && openPlaylist == nil }
    private var showingListening: Bool { section == .listening && !searching && openPlaylist == nil }
    private var showingAttention: Bool { section == .attention && !searching && openPlaylist == nil }
    /// The album grid and the track list: searches show in them too.
    private var showingAlbums: Bool { section == .albums && openPlaylist == nil }
    private var showingTracks: Bool { section == .tracks && openPlaylist == nil }
    /// A saved playlist (a search closes it).
    private var showingPlaylist: Bool { openPlaylist != nil && !searching }
    private var showingPage: Bool { showingStats || showingListening || showingAttention || showingAlbums || showingTracks || showingPlaylist }
    /// Where a search shows its results (highlighted in the sidebar): the grid or the track list when one is open,
    /// else the artists.
    private var searchSection: Section { section == .albums || section == .tracks ? section : .artists }

    private func showStatsPage() {
        for v in [letters, scrolls[1], timeline, scrolls[2], scrolls[3], empty] as [NSView] { v.isHidden = true }
        statsPage.isHidden = false
        if statsPage.documentView?.subviews.first.map({ ($0 as? NSStackView)?.arrangedSubviews.isEmpty ?? true }) ?? true {
            statsPage.showLoading()
        }
        // Counted on a connection of its own, off the main thread (a 100k-track library takes a moment).
        statsGeneration += 1
        let gen = statsGeneration, filter = self.filter
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
        for v in [letters, scrolls[1], timeline, scrolls[2], scrolls[3], empty, statsPage, listeningPage, songPage, artistPage, attentionPage,
                  gridPage, tracksPage, playlistPage] as [NSView] {
            v.isHidden = true
        }
        switch p {
        case .song(let artist, let title):
            songPage.isHidden = false
            if shownSong != artist + "\u{1}" + title {
                shownSong = artist + "\u{1}" + title
                songPage.show(artist: artist, titleKey: title)
            }
            window?.makeFirstResponder(songPage.documentView)
        case .artist(let key):
            artistPage.isHidden = false
            if shownArtist != key {
                shownArtist = key
                artistPage.show(artist: key)
            }
            window?.makeFirstResponder(artistPage.documentView)
        }
    }

    /// A page's Back keys (Esc, ⌘[, ⌫): the page before, the lists, or in Needs Attention its overview.
    @objc func pageBack(_ sender: Any?) {
        if !pages.isEmpty { back(); return }
        if showingAttention { _ = attentionPage.showOverview() }
    }

    /// Back: the page before, or the lists.
    private func back() {
        guard !pages.isEmpty else { return }
        pages.removeLast()
        if pages.isEmpty { closePages() } else { showTopPage() }
    }

    private func closePages() {
        dropPages()
        reloadAll()
        focusList()   // the list the page was opened from (keys keep working)
    }

    /// Out of the pages: the lists again. The artist page's lookups stop, and the next page opened loads fresh.
    private func dropPages() {
        pages = []
        songPage.isHidden = true
        artistPage.isHidden = true
        artistPage.stopLookups()
        shownArtist = nil
        shownSong = nil
    }

    /// What the two pages show now: Back to one of them just shows it again, scrolled as it was.
    private var shownArtist: String?
    private var shownSong: String?

    /// A release (or just the artist) in the library's lists.
    private func openRelease(artist: String, album: String?) {
        dropPages()
        section = .artists
        openPlaylist = nil
        // A search or a filter could hide the release (the first search hit would be opened instead).
        if searching {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(searchChanged), object: nil)
            search.stringValue = ""
            query = ""
        }
        reloadAll(keepEntry: artist, keepAlbum: album)
        if filter != LibraryFilter(), selectedEntry?.id != artist || (album != nil && selectedAlbum?.key != album) {
            filter = LibraryFilter()
            updateFilterButtons()
            reloadAll(keepEntry: artist, keepAlbum: album)
        }
        window?.makeFirstResponder(album == nil ? middle : albumTable)
    }

    // MARK: Opened from elsewhere (the playlist's "Show in Music Library")

    func revealArtist(_ key: String) {
        pages = []
        push(.artist(key))
    }

    func revealSong(artist: String, titleKey: String) {
        pages = []
        push(.song(artist: artist, title: titleKey))
    }

    func revealAlbum(artist: String, album: String) {
        if searching { search.stringValue = ""; query = "" }
        openRelease(artist: artist, album: album)
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

    /// A click on the section already highlighted (Artists while searching, or the one under an open page):
    /// no selection change, so it's handled here. It ends the search or closes the pages.
    @objc private func sidebarClicked() {
        let row = sidebar.clickedRow
        guard row >= 0 else { return }
        switch sideRow(at: row) {
        case .header:
            if NSApp.currentEvent?.clickCount ?? 1 <= 1 { togglePlaylists() }   // a double click isn't two
            return
        case .group(let g):
            if NSApp.currentEvent?.clickCount ?? 1 <= 1 { toggleGroup(g) }
            return
        case .playlist where row == sidebar.selectedRow && !pages.isEmpty:   // back from a page opened over it
            dropPages()
            loadEntries(keep: nil)
            return
        default: break
        }
        guard row == sidebar.selectedRow, case .section(let s) = sideRow(at: row), searching || !pages.isEmpty else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(searchChanged), object: nil)
        search.stringValue = ""
        query = ""
        dropPages()
        section = s
        reloadAll(keepEntry: nil)
    }

    /// From a chart: the library at that genre, year or artist.
    private func open(_ s: Section, _ entry: String) {
        section = s
        openPlaylist = nil
        reloadAll(keepEntry: entry)
        window?.makeFirstResponder(middle)
    }

    private func loadEntries(keep: String?, keepAlbum: String? = nil) {
        // An open page stays until Back or a click elsewhere: refreshes (new files, a finished download) only
        // update the lists under it. A new search closes it in searchChanged.
        if !pages.isEmpty { return }
        dropPages()
        statsPage.isHidden = !showingStats
        listeningPage.isHidden = !showingListening
        attentionPage.isHidden = !showingAttention
        gridPage.isHidden = !showingAlbums
        tracksPage.isHidden = !showingTracks
        playlistPage.isHidden = !showingPlaylist
        for v in [scrolls[1], scrolls[2], scrolls[3]] as [NSView] { v.isHidden = showingPage }
        if showingPlaylist, let url = openPlaylist {
            for v in [letters, timeline, empty] as [NSView] { v.isHidden = true }
            // Refreshes (a scan, a filter) leave it as it is: it follows its file and the library by itself.
            if !(playlistPage.url.map { SavedPlaylists.same($0, url) } ?? false) { playlistPage.show(url) }
            return
        }
        if !showingAttention { attentionOpen = false }
        if showingAttention {
            for v in [letters, timeline, empty] as [NSView] { v.isHidden = true }
            // A refresh keeps the view it's on (a group's full list); coming from another section, the overview.
            // A group by name only from the test hook ("attention:genre").
            attentionPage.reload(group: attentionHookGroup ?? (attentionOpen ? attentionPage.group : nil))
            attentionHookGroup = nil
            attentionOpen = true
            return
        }
        if showingStats { showStatsPage(); return }
        if showingAlbums {
            for v in [letters, timeline, empty] as [NSView] { v.isHidden = true }
            gridPage.reload(db: db, filter: filter, query: query, keep: keepAlbum, emptyText: gridEmptyText)
            gridPage.suggest(gridPage.isEmpty ? spelledLikeLibrary() : nil)
            return
        }
        if showingListening {
            for v in [letters, timeline, empty] as [NSView] { v.isHidden = true }
            listeningPage.appear()
            return
        }
        if showingTracks {
            for v in [letters, timeline, empty] as [NSView] { v.isHidden = true }
            let text = gridEmptyText ?? (searching ? "Nothing matches “\(query)”." : "Nothing here with these filters.")
            tracksPage.reload(filter: filter, query: query, emptyText: text)
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
            case .tracks, .albums, .stats, .listening, .attention:
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
                        let hits = Set(try db.albums(matching: query, filter, artist: e.id).map(\.key))
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
                case .tracks, .albums, .stats, .listening, .attention:
                    break
                }
            } catch {
                NSLog("OmniAmp: library query failed: %@", "\(error)")
            }
        }
        let withTimeline = (searching || section == .artists || section == .shows) && selectedEntry != nil
        if !withTimeline { timeline.albums = [] }
        timelineHeight.constant = withTimeline ? min(timeline.preferredHeight, 140) : 0
        timeline.isHidden = timelineHeight.constant == 0
        timelineGap.constant = timeline.isHidden ? 0 : 10

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
        if showingAlbums, pages.isEmpty { return gridPage.selectedAlbum.map { [$0] } ?? [] }
        return albumTable.selectedRowIndexes.compactMap { r in
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

    /// The grid's empty text when there's no library to show yet (else it says what the filters or search hid).
    private var gridEmptyText: String? {
        if let err = library.openError { return "The library database couldn't be opened:\n\(err)" }
        if library.roots.isEmpty { return "Point OmniAmp at your music.\n\nFOLDERS → Add Folder… (a NAS share is fine)." }
        return library.progress.running ? "Reading your music…" : nil
    }

    /// A search that found nothing, spelled like the library (worked out once per search).
    private func spelledLikeLibrary() -> String? {
        guard searching, !library.progress.running else { return nil }
        if let s = suggestion, s.query == query { return s.spelled }
        let spelled = (try? db?.suggestion(for: query)) ?? nil
        suggestion = (query, spelled)
        return spelled
    }

    private func search(for q: String) {
        search.stringValue = q
        searchChanged()
    }

    private func showEmpty() {
        var suggestion: String?
        let text: String
        if showingPage || !pages.isEmpty {
            text = ""
        } else if let err = library.openError {
            text = "The library database couldn't be opened:\n\(err)"
        } else if library.roots.isEmpty, entries.isEmpty {
            text = "Point OmniAmp at your music.\n\nFOLDERS → Add Folder… (a NAS share is fine). The library keeps itself up to date and sorts out albums, live recordings, shows and unreleased tracks from the tags and folder names."
        } else if entries.isEmpty {
            text = library.progress.running ? "Reading your music…" : (searching ? "Nothing matches “\(query)”." : "Nothing here with these filters.")
            suggestion = spelledLikeLibrary()
        } else {
            text = ""
        }
        empty.text = text
        empty.suggestion = suggestion
    }

    @objc private func resumeDownloads() { LiveArchiveDownloads.shared.resumeAll() }

    /// The window can be seen: open, not in the Dock, not covered by other windows.
    private var onScreen: Bool {
        guard let w = window else { return false }
        return w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
    }

    /// Library changes while the window couldn't be seen: one refresh when it's seen again.
    private var refreshWhenSeen = false

    /// Unseen for this long (in the Dock, behind other windows), the covers and tickets in memory are let go.
    private static let releaseAfter: TimeInterval = 5 * 60
    private var releaseWork: DispatchWorkItem?

    private func visibilityChanged() {
        releaseWork?.cancel()
        releaseWork = nil
        guard onScreen else {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.onScreen else { return }
                    LibraryArt.shared.releaseMemory()
                    Tickets.shared.releaseMemory()
                    MemoryTrim.soon()
                }
            }
            releaseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseAfter, execute: work)
            return
        }
        becameVisible()
    }

    /// Seen again (uncovered, back from the Dock): what changed meanwhile, now.
    private func becameVisible() {
        guard onScreen else { return }
        if refreshWhenSeen {
            refreshWhenSeen = false
            libraryChanged()
        }
        tracksPage.becameVisible()
    }

    /// Written during a scan: refresh at most every two seconds (the lists stay put under the mouse).
    private func libraryChanged() {
        tracksPage.libraryChanged()
        // Behind other windows or in the Dock, nothing is re-read or redrawn (a background scan, hours of playing):
        // the lists catch up once when the window is seen again.
        guard onScreen else { refreshWhenSeen = true; return }
        // Genres, Stats, Needs Attention and Tracks go over the whole library: once the scan is done, not every 2 s of it.
        if library.progress.running, pages.isEmpty, [.genres, .stats, .attention, .tracks].contains(section), !searching || section == .tracks {
            refreshAfterScan = true
            return
        }
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.suggestion = nil   // the library's words may have changed
            let entry = self.selectedEntry?.id, album = self.selectedAlbum?.key
            let topRow = self.middle.rows(in: self.middle.visibleRect).location
            self.loadEntries(keep: entry, keepAlbum: album)
            self.playlistPage.libraryChanged()   // its songs' tags, files found or gone (at most every 2 s, like the lists)
            if entry == nil, topRow > 0 { self.middle.scrollRowToVisible(topRow) }
            self.updateStatus()
        }
    }

    /// A heavy section's refresh held back until the running scan ends.
    private var refreshAfterScan = false

    private func updateStatus() {
        let p = library.progress
        if !p.running, refreshAfterScan {
            refreshAfterScan = false
            libraryChanged()
        }
        if p.running {
            var s = "Scanning… \(p.found.formatted()) files"
            if p.toRead > 0 { s += " · reading tags \(p.read.formatted()) of \(p.toRead.formatted())" }
            status.stringValue = s
        } else if showingTracks, pages.isEmpty, let summary = tracksPage.summary {
            status.stringValue = summary
        } else if showingPlaylist, pages.isEmpty, let summary = playlistPage.summary {
            status.stringValue = summary
        } else if let sum = try? db?.summary(), sum.tracks > 0 {
            let days = sum.duration / 86400
            status.stringValue = "\(sum.artists.formatted()) artists · \(sum.albums.formatted()) releases · \(sum.tracks.formatted()) tracks · "
                + (days >= 1 ? String(format: "%.1f days", days) : String(format: "%.1f hours", sum.duration / 3600))
        } else {
            status.stringValue = ""
        }
        // Downloads from the Live Music Archive keep going wherever you are: shown first.
        if let d = LiveArchiveDownloads.shared.summary {
            status.stringValue = d + (status.stringValue.isEmpty ? "" : "   ·   " + status.stringValue)
        }
        resumeButton.isHidden = LiveArchiveDownloads.shared.paused.isEmpty
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
        // Typing a search: its results replace an open page (and an open playlist).
        dropPages()
        if searching { openPlaylist = nil }
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
            if showingTracks, sel == #selector(NSResponder.insertNewline(_:)) { tracksPage.finishTyping(search.stringValue) }
            focusList()
        case #selector(NSResponder.cancelOperation(_:)):
            if !search.stringValue.isEmpty { search.stringValue = ""; searchChanged() } else { focusList() }
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
        if showingAlbums, pages.isEmpty { gridPage.focus() } else if showingTracks, pages.isEmpty { tracksPage.focus() }
        else if showingPlaylist, pages.isEmpty { playlistPage.focus() }
        else { window?.makeFirstResponder(middle) }
    }

    /// The letter of the first artist in view.
    private func followScroll() {
        guard !letters.isHidden, !entries.isEmpty else { return }
        let top = middle.visibleRect.minY + scrolls[1].contentInsets.top + 1
        let row = middle.row(at: NSPoint(x: middle.visibleRect.midX, y: top))
        guard row >= 0, row < entries.count else { return }
        letters.current = entries[row].letter ?? "#"
    }

    /// First artist at or after the letter.
    private func jump(to letter: String) {
        letters.current = letter
        // That letter's first artist; none: the next letter that has one (by letter, not by place in the list).
        let later = Set(entries.compactMap(\.letter)).filter { $0 >= letter }.sorted()
        guard let target = later.first, let row = entries.firstIndex(where: { ($0.letter ?? "#") == target }) else { return }
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
        if showingTracks, pages.isEmpty { return tracksPage.selectedTracks }
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

    @objc private func playSelection() {
        if showingPlaylist, pages.isEmpty { playlistPage.playChosen(); return }
        play(chosenTracks())
    }
    @objc private func addSelection() {
        if showingPlaylist, pages.isEmpty { playlistPage.addChosen(); return }
        enqueue(chosenTracks())
    }

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

    /// Plays: already at the end of the playlist in this order → play from there; else add them and play the first
    /// (`from`: the one at that index instead, the ones before it added too).
    private func play(_ all: [LibraryTrack], from start: Int = 0) {
        guard let list = playable(all), let first = list.first else { return }
        let startKey = all.indices.contains(start) ? all[start].key : first.key
        play(tracks: list.map(\.track), from: list.firstIndex { $0.key == startKey } ?? 0, announce: list.count == all.count)
    }

    private func play(tracks list: [Track], from offset: Int = 0, announce: Bool = true) {
        guard let first = list.first else { NSSound.beep(); return }
        let keys = list.map(\.key)
        let current = controller.tracks.map(\.key)
        if let i = current.firstIndex(of: first.key), i + keys.count <= current.count, Array(current[i..<(i + keys.count)]) == keys {
            controller.play(index: i + offset)
            return
        }
        let at = controller.tracks.count
        controller.insertScanned(list, at: at)
        controller.play(index: at + offset)
        if announce { status.stringValue = "Playing \(list.count == 1 ? "“\(first.title ?? first.fileStem)”" : "\(list.count) tracks")." }
    }

    private func enqueue(_ all: [LibraryTrack]) {
        guard let list = playable(all) else { return }
        enqueue(tracks: list.map(\.track), announce: list.count == all.count)
    }

    private func enqueue(tracks list: [Track], announce: Bool = true) {
        guard let first = list.first else { NSSound.beep(); return }
        controller.insertScanned(list, at: controller.tracks.count)
        if announce { status.stringValue = "Added \(list.count == 1 ? "“\(first.title ?? first.fileStem)”" : "\(list.count) tracks") to the playlist." }
    }

    @objc private func replaceAndPlay() { replace(with: chosenTracks()) }

    private func replace(with tracks: [LibraryTrack]) {
        guard let list = playable(tracks) else { return }
        controller.clear()
        controller.insertScanned(list.map(\.track), at: 0)
        controller.play(index: 0)
    }

    // MARK: Saved playlists

    /// "Add to Playlist ▸ <a saved playlist>" on what's chosen.
    @objc private func addSelectionToSaved(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { addToSaved(chosenTracks(), url) }
    }

    @objc private func newPlaylistFromSelection() { newPlaylist(with: chosenTracks()) }

    private func addToSaved(_ all: [LibraryTrack], _ url: URL) {
        guard let list = playable(all) else { return }
        addTracks(list.map(\.track), to: url, announce: list.count == all.count)
    }

    private func newPlaylist(with all: [LibraryTrack]) {
        guard let list = playable(all) else { return }
        newPlaylist(tracks: list.map(\.track))
    }

    private func addTracks(_ list: [Track], to url: URL, announce: Bool = true) {
        guard !list.isEmpty else { NSSound.beep(); return }
        do { try playlists.append(list, to: url) } catch { showError(error); return }
        if announce { status.stringValue = "Added \(Self.songs(list)) to “\(SavedPlaylists.name(url))”." }
    }

    /// From a menu: asks for a name (the songs' album or artist suggested), and stays where it is.
    private func newPlaylist(tracks list: [Track]) {
        guard let url = playlists.promptNew(tracks: list) else { return }
        status.stringValue = "Made “\(SavedPlaylists.name(url))” with \(Self.songs(list))."
    }

    private static func songs(_ list: [Track]) -> String {
        list.count == 1 ? "“\(list[0].title ?? list[0].fileStem)”" : "\(list.count.formatted()) songs"
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        guard sender.clickedRow >= 0 else { return }
        switch sender {
        case middle where section == .artists || section == .shows || searching: openArtistPage()
        case sidebar where showingPlaylist: playlistPage.focus()
        case sidebar, middle: window?.makeFirstResponder(albumTable)
        case trackTable: play(trackTable.selectedRowIndexes.filter { $0 < tracks.count }.map { tracks[$0] })
        default:
            guard let db else { return }
            play(selectedAlbums.flatMap { (try? db.tracks(album: $0.key)) ?? [] })
        }
    }

    private var infoSheet: FindInfoSheet?

    /// The selected album's Wikipedia article (found through MusicBrainz), else Wikipedia's search for it.
    @objc private func albumWikipedia() {
        guard let a = selectedAlbum else { return }
        Task { NSWorkspace.shared.open(await MetadataLookup.shared.albumWikipedia(releaseGroup: nil, artist: a.artist, title: a.title)) }
    }

    private var tagSheet: TagEditorSheet?

    /// Edit the selected release's tags and cover by hand.
    @objc private func editAlbumTags() {
        guard let a = selectedAlbum, let db else { return }
        editTags(a, tracks: (try? db.tracks(album: a.key)) ?? [], genre: try? db.genre(album: a.key))
    }

    @objc private func editTrackTags() {
        editTags(of: trackTable.selectedRowIndexes.filter { $0 < tracks.count }.map { tracks[$0] })
    }

    /// Some tracks' tags: those of the first one's release (the editor is for one release at a time).
    func editTags(of picked: [LibraryTrack]) {
        guard let first = picked.first, let db,
              let a = try? db.albumsWhere("a.key = ?", [first.albumKey], order: "a.key").first else { return }
        editTags(a, tracks: picked.filter { $0.albumKey == first.albumKey }, genre: try? db.genre(album: a.key))
    }

    private func editTags(_ a: LibraryAlbum, tracks: [LibraryTrack], genre: String?) {
        guard let w = window, tagSheet == nil, !tracks.isEmpty else { return }
        let sheet = TagEditorSheet(album: a, tracks: tracks, genre: genre)
        sheet.onDone = { [weak self, weak sheet] message in
            guard let self, let sw = sheet?.window else { return }
            w.endSheet(sw)
            self.tagSheet = nil
            if let message { self.status.stringValue = "“\(a.title)”: \(message)" }
        }
        tagSheet = sheet
        w.beginSheet(sheet.window!)
    }

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
        // From the sidebar into the album grid (the lists are hidden).
        if t === sidebar, showingAlbums || showingTracks || showingPlaylist, pages.isEmpty, mods.isEmpty, [124, 48, 36, 76].contains(e.keyCode) {
            if showingAlbums { gridPage.focus() } else if showingTracks { tracksPage.focus() } else { playlistPage.focus() }
            return true
        }
        // ↑/↓ in the sidebar step over the playlists' title and the line above it.
        if t === sidebar, mods.isEmpty, e.keyCode == 125 || e.keyCode == 126 {
            let step = e.keyCode == 125 ? 1 : -1
            var r = sidebar.selectedRow + step
            while r >= 0, r < sideRows.count, !selectable(sideRows[r]) { r += step }
            if r >= 0, r < sideRows.count {
                sidebar.selectRowIndexes([r], byExtendingSelection: false)
                sidebar.scrollRowToVisible(r)
            }
            return true
        }
        if t === sidebar, mods.isEmpty, e.keyCode == 51 || e.keyCode == 117, case .playlist(let u) = sideRow(at: sidebar.selectedRow) {
            trashPlaylist(u)
            return true
        }
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

    // MARK: Album grid

    /// Right-click on a cover (it's selected): what the album lists offer, plus its artist and its place in them.
    private func gridMenu() -> NSMenu? {
        guard gridPage.selectedAlbum != nil else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        add("Play", #selector(playSelection))
        menu.addItem(addToPlaylistItem())
        add("Replace Playlist and Play", #selector(replaceAndPlay))
        menu.addItem(.separator())
        add("Artist Page", #selector(gridArtistPage))
        add("Show in Artists", #selector(gridShowInArtists))
        add("Find Missing Info…", #selector(findInfo))
        add("Show in Finder", #selector(showInFinder))
        return menu
    }

    @objc private func gridArtistPage() {
        if let a = gridPage.selectedAlbum { push(.artist(a.artistKey)) }
    }

    @objc private func gridShowInArtists() {
        if let a = gridPage.selectedAlbum { openRelease(artist: a.artistKey, album: a.key) }
    }

    /// Keys the grid leaves to the window: Space pauses, Esc clears the search or closes, ⇧Tab or ← off the first
    /// cover goes to the sidebar, typing searches.
    private func gridKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        switch e.keyCode {
        case 49 where mods.isEmpty: controller.togglePlayPause(); return true
        case 53 where mods.isEmpty:
            if searching { search.stringValue = ""; searchChanged() } else { window?.performClose(nil) }
            return true
        case 123 where mods.isEmpty: window?.makeFirstResponder(sidebar); return true
        case 48 where mods == .shift: window?.makeFirstResponder(sidebar); return true
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
            let addAll = addToPlaylistItem()
            addAll.title = "Add All to Playlist"
            menu.addItem(addAll)
            return
        }
        if menu === sidebar.menu { fillSidebarMenu(menu); return }
        let t = menu === albumTable.menu ? albumTable : trackTable
        let row = t.clickedRow
        guard row >= 0 else { return }
        if !t.selectedRowIndexes.contains(row) { t.selectRowIndexes([row], byExtendingSelection: false) }
        window?.makeFirstResponder(t)
        func add(_ title: String, _ action: Selector) { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        add("Play", #selector(playSelection))
        menu.addItem(addToPlaylistItem())
        add("Replace Playlist and Play", #selector(replaceAndPlay))
        menu.addItem(.separator())
        if t === albumTable, selectedAlbums.count == 1 {
            add("Find Missing Info…", #selector(findInfo))
            add("Edit Tags…", #selector(editAlbumTags))
            if selectedAlbum?.kind != .show { add("Wikipedia ↗", #selector(albumWikipedia)) }
        }
        if t === trackTable, trackTable.selectedRowIndexes.count == 1 { add("Show All Versions", #selector(showVersions)) }
        if t === trackTable { add("Edit Tags…", #selector(editTrackTags)) }
        add("Show in Finder", #selector(showInFinder))
    }

    /// "Add to Playlist ▸": the player's, a saved one, or a new one.
    private func addToPlaylistItem() -> NSMenuItem {
        playlists.addMenuItem(target: self, current: #selector(addSelection), saved: #selector(addSelectionToSaved(_:)),
                              new: #selector(newPlaylistFromSelection))
    }

    // MARK: Sidebar playlists

    private func sideRow(at row: Int) -> SideRow? { row >= 0 && row < sideRows.count ? sideRows[row] : nil }

    private func selectable(_ r: SideRow) -> Bool {
        switch r {
        case .section, .playlist: true
        case .divider, .header, .group: false
        }
    }

    /// The row of a playlist or group (by path: a folder's URL may or may not end in "/").
    private func rowIndex(of r: SideRow) -> Int? {
        switch r {
        case .playlist(let u): sideRows.firstIndex { if case .playlist(let x) = $0 { SavedPlaylists.same(x, u) } else { false } }
        case .group(let u): sideRows.firstIndex { if case .group(let x) = $0 { SavedPlaylists.same(x, u) } else { false } }
        default: sideRows.firstIndex(of: r)
        }
    }

    /// What the sidebar highlights: the open playlist, the section, or where a search shows its results.
    private var currentSideRow: SideRow {
        if searching { return .section(searchSection) }
        return openPlaylist.map(SideRow.playlist) ?? .section(section)
    }

    /// The sections, the playlists' title, then (unless folded away) each group with its playlists (unless that group
    /// is folded) and the playlists in no group; the current one highlighted.
    private func rebuildSidebar() {
        var rows = Section.allCases.map(SideRow.section) + [.divider, .header]
        if !playlistsCollapsed {
            for g in playlists.groups {
                rows.append(.group(g.url))
                if !collapsedGroups.contains(g.name) { rows += g.playlists.map(SideRow.playlist) }
            }
            rows += playlists.ungrouped.map(SideRow.playlist)
        }
        sideRows = rows
        sidebar.reloadData()
        if let r = rowIndex(of: currentSideRow) {
            sidebar.selectRowIndexes([r], byExtendingSelection: false)
        } else {
            sidebar.deselectAll(nil)
        }
    }

    /// The groups folded away (by folder name), as the user left them.
    private var collapsedGroups = Set(UserDefaults.standard.stringArray(forKey: Pref.libraryPlaylistGroupsCollapsed) ?? [])

    private func setGroup(_ name: String, folded: Bool) {
        if folded { collapsedGroups.insert(name) } else { collapsedGroups.remove(name) }
        UserDefaults.standard.set(collapsedGroups.sorted(), forKey: Pref.libraryPlaylistGroupsCollapsed)
    }

    private func toggleGroup(_ url: URL) {
        let name = url.lastPathComponent
        setGroup(name, folded: !collapsedGroups.contains(name))
        rebuildSidebar()
    }

    /// The playlists folder changed: the list again; the open playlist gone (deleted or renamed outside), its section.
    private func playlistsChanged() {
        guard !renaming else { return }
        if let u = openPlaylist, !playlists.urls.contains(where: { SavedPlaylists.same($0, u) }) {
            openPlaylist = nil
            dropPages()
            rebuildSidebar()
            loadEntries(keep: nil)
            return
        }
        rebuildSidebar()
    }

    private func togglePlaylists() {
        playlistsCollapsed.toggle()
        UserDefaults.standard.set(playlistsCollapsed, forKey: Pref.libraryPlaylistsCollapsed)
        rebuildSidebar()
    }

    /// Unfolds what hides a playlist: the Playlists title and its group.
    private func reveal(_ url: URL) {
        if playlistsCollapsed { playlistsCollapsed = false; UserDefaults.standard.set(false, forKey: Pref.libraryPlaylistsCollapsed) }
        if let g = playlists.group(of: url) { setGroup(g.name, folded: false) }
    }

    /// Shows a saved playlist (from the sidebar, or one just made).
    private func openSaved(_ url: URL) {
        if searching {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(searchChanged), object: nil)
            search.stringValue = ""
            query = ""
        }
        dropPages()
        openPlaylist = url
        reveal(url)
        rebuildSidebar()
        if let r = rowIndex(of: .playlist(url)) { sidebar.scrollRowToVisible(r) }
        loadEntries(keep: nil)
        updateStatus()
    }

    /// The + on the Playlists title: a playlist or a group.
    @objc private func showNewMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Playlist", action: #selector(newEmptyPlaylist), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Group", action: #selector(newGroup), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func newEmptyPlaylist() { createAndRename([]) }

    /// A new playlist (empty, or the songs dropped on a title), in a group or in none, opened with its name ready to
    /// type over.
    private func createAndRename(_ tracks: [Track], in group: URL? = nil) {
        let name = playlists.uniqueName(tracks.isEmpty ? "New Playlist" : SavedPlaylists.suggestedName(for: tracks), in: group)
        let url: URL
        do { url = try playlists.create(named: name, tracks: tracks, in: group) } catch { showError(error); return }
        openSaved(url)
        if !tracks.isEmpty { status.stringValue = "Made “\(name)” with \(Self.songs(tracks))." }
        beginRename(url)
    }

    @objc private func newGroup() {
        let url: URL
        do { url = try playlists.createGroup(named: "New Group") } catch { showError(error); return }
        if playlistsCollapsed { togglePlaylists() } else { rebuildSidebar() }
        beginRename(group: url)
    }

    /// A row's name in the sidebar becomes editable; `commit` gets what was typed (changed and not empty).
    private func beginRename(row: SideRow, current: String, commit: @escaping (String) -> Void) {
        guard let r = rowIndex(of: row) else { return }
        sidebar.scrollRowToVisible(r)
        guard let cell = sidebar.view(atColumn: 0, row: r, makeIfNecessary: true) as? SidebarCell else { return }
        cell.beginRename { [weak self] name in
            guard let self else { return }
            defer { self.window?.makeFirstResponder(self.sidebar) }
            guard let name, let clean = SavedPlaylists.cleanName(name), clean != current else {
                self.rebuildSidebar()
                return
            }
            self.renaming = true
            commit(name)
            self.renaming = false
            self.rebuildSidebar()
        }
    }

    private func beginRename(_ url: URL) {
        reveal(url)
        rebuildSidebar()
        beginRename(row: .playlist(url), current: SavedPlaylists.name(url)) { [weak self] name in
            guard let self else { return }
            do { self.playlistMoved(url, to: try self.playlists.rename(url, to: name)) } catch { self.showError(error) }
        }
    }

    private func beginRename(group url: URL) {
        beginRename(row: .group(url), current: url.lastPathComponent) { [weak self] name in
            guard let self else { return }
            do {
                let new = try self.playlists.renameGroup(url, to: name)
                if self.collapsedGroups.contains(url.lastPathComponent) {
                    self.setGroup(url.lastPathComponent, folded: false)
                    self.setGroup(new.lastPathComponent, folded: true)
                }
                // The open playlist was in it: same file name, new folder.
                if let open = self.openPlaylist, SavedPlaylists.same(open.deletingLastPathComponent(), url) {
                    self.playlistMoved(open, to: new.appendingExact(open.lastPathComponent))
                }
            } catch {
                self.showError(error)
            }
        }
    }

    /// A playlist renamed or moved to another group: the page follows it.
    private func playlistMoved(_ old: URL, to new: URL) {
        guard let open = openPlaylist, SavedPlaylists.same(open, old) else { return }
        openPlaylist = new
        playlistPage.show(new)
    }

    /// Moves playlists in or out of a group (nil: out of any).
    private func movePlaylist(_ url: URL, toGroup group: URL?) {
        renaming = true
        defer { renaming = false; rebuildSidebar() }
        do {
            let new = try playlists.move(url, toGroup: group)
            playlistMoved(url, to: new)
            if let group { setGroup(group.lastPathComponent, folded: false) }
        } catch {
            showError(error)
        }
    }

    private func trashPlaylist(_ url: URL) {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = "Move “\(SavedPlaylists.name(url))” to the Trash?"
        a.informativeText = "Only the playlist goes; its songs stay where they are."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                do { try self.playlists.trash(url) } catch { self.showError(error) }
            }
        }
    }

    private func deleteGroup(_ url: URL) {
        guard let w = window else { return }
        let n = playlists.groups.first { SavedPlaylists.same($0.url, url) }?.playlists.count ?? 0
        let a = NSAlert()
        a.messageText = "Delete the group “\(url.lastPathComponent)”?"
        a.informativeText = n == 0 ? "It's empty." : "Its \(n == 1 ? "playlist stays" : "\(n) playlists stay"), outside any group."
        a.addButton(withTitle: "Delete Group")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.renaming = true
                defer { self.renaming = false; self.rebuildSidebar() }
                do {
                    for (old, new) in try self.playlists.deleteGroup(url) { self.playlistMoved(old, to: new) }
                    self.setGroup(url.lastPathComponent, folded: false)
                } catch {
                    self.showError(error)
                }
            }
        }
    }

    private func showError(_ error: Error) {
        guard let w = window else { NSAlert(error: error).runModal(); return }
        NSAlert(error: error).beginSheetModal(for: w)
    }

    /// The playlist or group a sidebar menu was opened on.
    private var menuPlaylist: URL?
    private var menuGroup: URL?

    private func fillSidebarMenu(_ menu: NSMenu) {
        func add(_ title: String, _ action: Selector, to m: NSMenu? = nil) -> NSMenuItem {
            let it = (m ?? menu).addItem(withTitle: title, action: action, keyEquivalent: "")
            it.target = self
            return it
        }
        switch sideRow(at: sidebar.clickedRow) {
        case .header, .divider:
            _ = add("New Playlist", #selector(newEmptyPlaylist))
            _ = add("New Group", #selector(newGroup))
            menu.addItem(.separator())
            _ = add(playlistsCollapsed ? "Show Playlists" : "Hide Playlists", #selector(togglePlaylistsMenu))
        case .group(let g):
            menuGroup = g
            _ = add("New Playlist in Group", #selector(menuNewInGroup))
            menu.addItem(.separator())
            _ = add("Rename", #selector(menuRenameGroup))
            let colors = NSMenu()
            let current = playlists.groups.first { SavedPlaylists.same($0.url, g) }?.color
            let none = add("None", #selector(menuColorGroup(_:)), to: colors)
            none.tag = 0
            none.state = current == nil ? .on : .off
            colors.addItem(.separator())
            for c in PlaylistColor.allCases {
                let it = add(c.name, #selector(menuColorGroup(_:)), to: colors)
                it.tag = c.rawValue
                it.image = c.swatch
                it.state = current == c ? .on : .off
            }
            let colorItem = menu.addItem(withTitle: "Color", action: nil, keyEquivalent: "")
            colorItem.submenu = colors
            _ = add("Show in Finder", #selector(menuRevealGroup))
            menu.addItem(.separator())
            _ = add("Delete Group…", #selector(menuDeleteGroup))
        case .playlist(let u):
            menuPlaylist = u
            _ = add("Play", #selector(menuPlayPlaylist))
            _ = add("Add to Current Playlist", #selector(menuAddPlaylist))
            _ = add("Load into Player", #selector(menuLoadPlaylist))
            menu.addItem(.separator())
            if !SavedPlaylists.isReadOnly(u) { _ = add("Rename", #selector(menuRenamePlaylist)) }
            if !playlists.groups.isEmpty {
                // Into a group, or out of the one it's in.
                let groups = NSMenu()
                let inGroup = playlists.group(of: u)
                let out = add("No Group", #selector(menuMovePlaylist(_:)), to: groups)
                out.state = inGroup == nil ? .on : .off
                groups.addItem(.separator())
                for g in playlists.groups {
                    let it = add(g.name, #selector(menuMovePlaylist(_:)), to: groups)
                    it.representedObject = g.url
                    it.image = g.color?.swatch
                    it.state = inGroup?.url == g.url ? .on : .off
                }
                let moveItem = menu.addItem(withTitle: "Move to Group", action: nil, keyEquivalent: "")
                moveItem.submenu = groups
            }
            _ = add("Show in Finder", #selector(menuRevealPlaylist))
            menu.addItem(.separator())
            _ = add("Move to Trash", #selector(menuTrashPlaylist))
        default: break
        }
    }

    @objc private func togglePlaylistsMenu() { togglePlaylists() }

    /// The songs in a saved playlist that can be played, read as playing it would (the library's tags where it has them).
    private func savedTracks(_ url: URL) -> [Track] {
        let doc = playlists.document(url)
        return PlaylistRow.resolve(doc, base: url.deletingLastPathComponent(), db: db, checkFiles: false).compactMap(\.track)
    }

    @objc private func menuPlayPlaylist() { if let u = menuPlaylist { play(tracks: savedTracks(u)) } }
    @objc private func menuAddPlaylist() { if let u = menuPlaylist { enqueue(tracks: savedTracks(u)) } }
    @objc private func menuLoadPlaylist() { if let u = menuPlaylist { playlistPage.onLoad?(u) } }
    @objc private func menuRenamePlaylist() { if let u = menuPlaylist { beginRename(u) } }
    @objc private func menuRevealPlaylist() { if let u = menuPlaylist { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    @objc private func menuTrashPlaylist() { if let u = menuPlaylist { trashPlaylist(u) } }
    @objc private func menuMovePlaylist(_ sender: NSMenuItem) { if let u = menuPlaylist { movePlaylist(u, toGroup: sender.representedObject as? URL) } }
    @objc private func menuNewInGroup() {
        guard let g = menuGroup else { return }
        setGroup(g.lastPathComponent, folded: false)
        createAndRename([], in: g)
    }
    @objc private func menuRenameGroup() { if let g = menuGroup { beginRename(group: g) } }
    @objc private func menuRevealGroup() { if let g = menuGroup { NSWorkspace.shared.activateFileViewerSelecting([g]) } }
    @objc private func menuDeleteGroup() { if let g = menuGroup { deleteGroup(g) } }
    @objc private func menuColorGroup(_ sender: NSMenuItem) {
        guard let g = menuGroup else { return }
        do { try playlists.setColor(PlaylistColor(rawValue: sender.tag), of: g) } catch { showError(error) }
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case sidebar: sideRows.count
        case middle: entries.count
        case albumTable: items.count
        default: tracks.count
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if tableView === sidebar {
            if case .divider = sideRow(at: row) { return tableView.reusableRowView("dividerRow", SidebarDividerRowView.init) }
            return tableView.reusableRowView("sideRow", SidebarRowView.init)
        }
        if tableView === albumTable, row < items.count, case .header = items[row] { return tableView.reusableRowView("headerRow", HeaderRowView.init) }
        return tableView.reusableRowView("cardRow", CardRowView.init)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === sidebar {
            switch sideRow(at: row) {
            case .divider: return 11
            case .header: return 26
            case .group: return 28
            case .playlist: return 28
            default: return tableView.rowHeight
            }
        }
        if tableView === albumTable, row < items.count, case .header = items[row] { return 24 }
        return tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === sidebar { return sideRow(at: row).map(selectable) ?? false }
        if tableView === albumTable, row < items.count, case .header = items[row] { return false }
        return true
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard let t = n.object as? NSTableView else { return }
        switch t {
        case sidebar:
            sidebar.reloadData(forRowIndexes: IndexSet(0..<sideRows.count), columnIndexes: [0])   // the selected one's look
            if case .playlist(let u) = sideRow(at: sidebar.selectedRow) {
                guard !(openPlaylist.map { SavedPlaylists.same($0, u) } ?? false) || searching else { return }
                openSaved(u)
                return
            }
            guard case .section(let s) = sideRow(at: sidebar.selectedRow) else { return }
            // From a playlist to a section (the same one it was in too).
            if openPlaylist != nil {
                openPlaylist = nil
                dropPages()
                section = s
                loadEntries(keep: nil)
                updateStatus()
                return
            }
            // Searching highlights Artists (or Albums) itself (not a choice); a click on it ends the search in sidebarClicked.
            // Artists, Albums and Tracks all show search results: going from one to another keeps the search.
            if searching, s != searchSection, s == .artists || s == .albums || s == .tracks {
                dropPages()
                section = s
                reloadAll(keepEntry: nil)
                return
            }
            if searching, s != searchSection {
                // A section chosen while searching: the search ends, the section opens.
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(searchChanged), object: nil)
                search.stringValue = ""
                query = ""
                dropPages()
                section = s
                reloadAll(keepEntry: nil)
                return
            }
            // While searching, the Artists highlight is the search's own (set by reloadAll): not a choice.
            if searching { return }
            if !pages.isEmpty {   // leaving the pages
                dropPages()
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
            switch sideRow(at: row) {
            case .section(let s):
                let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("sidebar"), owner: nil) as? SidebarCell) ?? SidebarCell()
                cell.show(glyph: s.glyph, title: s.title, selected: sidebar.selectedRow == row)
                return cell
            case .playlist(let u):
                let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("sidebar"), owner: nil) as? SidebarCell) ?? SidebarCell()
                // nf-md-playlist_music; a group's playlists sit under its name.
                cell.show(glyph: "\u{F0CB8}", title: SavedPlaylists.name(u), selected: sidebar.selectedRow == row, small: true,
                          indent: playlists.group(of: u) == nil ? 10 : 26)
                return cell
            case .group(let g):
                let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("sidebar"), owner: nil) as? SidebarCell) ?? SidebarCell()
                let color = playlists.groups.first { SavedPlaylists.same($0.url, g) }?.color
                // A dot in the group's color; a ring for a group without one.
                cell.show(glyph: color == nil ? "\u{25CB}" : "\u{25CF}", title: g.lastPathComponent, selected: false, small: true, indent: 24,
                          folded: collapsedGroups.contains(g.lastPathComponent), glyphColor: color?.color ?? Dash.text3)
                return cell
            case .header:
                let h = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("playlistsHeader"), owner: nil) as? PlaylistsHeaderCell)
                    ?? PlaylistsHeaderCell()
                h.show(collapsed: playlistsCollapsed, count: playlists.urls.count)
                h.add.target = self
                h.add.action = #selector(showNewMenu(_:))
                return h
            case .divider, nil:
                return nil
            }
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
            let textCell = libraryCell(tableView, id), f = textCell.field
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
            return textCell
        }
    }

    /// A playlist dragged in the sidebar (its path), to move it into or out of a group.
    private static let sidebarPlaylistType = NSPasteboard.PasteboardType("com.microbot.omniamp.savedPlaylist")

    /// A folded group the drag has been resting on, and since when: after a moment it unfolds.
    private var dragHover: (group: URL, since: Date)?

    /// Over the sidebar: songs go into a playlist, or into a new one on the Playlists title (or the space under the
    /// last playlist) or on a group's name; a playlist moves into the group it's dropped on (or out of any, on the
    /// title). Sections don't take drops.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === sidebar, let header = sideRows.firstIndex(of: .header) else { return [] }
        // The row under the mouse (the proposed one is between rows as often as on one).
        let r = sidebar.row(at: sidebar.convert(info.draggingLocation, from: nil))
        let target = sideRow(at: r)
        if case .group(let g) = target, collapsedGroups.contains(g.lastPathComponent) {
            if let h = dragHover, SavedPlaylists.same(h.group, g) {
                if Date().timeIntervalSince(h.since) > 0.7 {
                    dragHover = nil
                    toggleGroup(g)
                }
            } else {
                dragHover = (g, Date())
            }
        } else {
            dragHover = nil
        }
        if let moving = info.draggingPasteboard.string(forType: Self.sidebarPlaylistType).map({ URL(exactPath: $0) }) {
            // Onto a group, or a playlist in one: that group; anywhere else in the playlists: out of any group.
            let group: URL?
            switch target {
            case .section: return []
            case .group(let g): group = g
            case .playlist(let u): group = playlists.group(of: u)?.url
            default: group = nil
            }
            if let group, let gr = rowIndex(of: .group(group)) { sidebar.setDropRow(gr, dropOperation: .on) } else { sidebar.setDropRow(header, dropOperation: .on) }
            // Already there: nothing to do.
            let from = playlists.group(of: moving)?.url
            let same = switch (from, group) {
            case (nil, nil): true
            case (let a?, let b?): SavedPlaylists.same(a, b)
            default: false
            }
            return same ? [] : .move
        }
        switch target {
        case .playlist(let u):
            // A playlist's own rows dropped on it would only add them again.
            if SavedPlaylists.isReadOnly(u) || (openPlaylist.map { SavedPlaylists.same($0, u) } ?? false && (info.draggingSource as? NSView)?.isDescendant(of: playlistPage) == true) {
                return []
            }
            sidebar.setDropRow(r, dropOperation: .on)
        case .group: sidebar.setDropRow(r, dropOperation: .on)
        case .section: return []
        default: sidebar.setDropRow(header, dropOperation: .on)   // the title, the line, or below the last playlist
        }
        return .copy
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        dragHover = nil
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard tableView === sidebar else { return false }
        dragHover = nil
        let target = sideRow(at: row)
        let pb = info.draggingPasteboard
        if let moving = pb.string(forType: Self.sidebarPlaylistType).map({ URL(exactPath: $0) }) {
            if case .group(let g) = target { movePlaylist(moving, toGroup: g) } else { movePlaylist(moving, toGroup: nil) }
            return true
        }
        if case .playlist(let u) = target {
            LibraryDrag.droppedTracks(pb) { [weak self] tracks in self?.addTracks(tracks, to: u) }
            return true
        }
        let group: URL?
        switch target {
        case .group(let g): group = g
        case .header: group = nil
        default: return false
        }
        status.stringValue = "Reading what was dropped…"
        LibraryDrag.droppedTracks(pb) { [weak self] tracks in
            guard let self else { return }
            guard !tracks.isEmpty else { self.updateStatus(); NSSound.beep(); return }
            if let group { self.setGroup(group.lastPathComponent, folded: false) }
            self.createAndRename(tracks, in: group)
        }
        return true
    }

    /// Dragging releases or tracks out (to the playlist, a saved playlist, or Finder): their files (and, inside OmniAmp,
    /// the songs with their tags).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if tableView === sidebar {
            // A playlist: moved between groups here; its file elsewhere (Finder copies it, the player plays it).
            guard case .playlist(let u) = sideRow(at: row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(u.absoluteString, forType: .fileURL)
            item.setString(u.path, forType: Self.sidebarPlaylistType)
            return item
        }
        if tableView === trackTable, row < tracks.count { return tracks[row].playable ? LibraryDrag.item(for: tracks[row].track) : URL(exactPath: tracks[row].path) as NSURL }
        if tableView === albumTable, row < items.count, case .album(let a) = items[row] { return LibraryDrag.writer(for: a, db: db) }
        return nil
    }
}
