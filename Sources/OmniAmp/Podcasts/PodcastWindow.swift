import AppKit
import UniformTypeIdentifiers

/// Podcast browser in the modern look: top shows per country, search, subscriptions (with new-episode
/// counts), and the selected show's episodes. Episodes play like any track and remember their position.
final class PodcastWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                                    NSSplitViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    private let controller: PlayerController
    private let library = PodcastLibrary.shared
    private var topButton: Pill!
    private var subscribedButton: Pill!
    private var subscribeButton: Pill!
    private let search = DashSearchField()
    private let country = DashPopUp()
    private let showsTable = KeyTableView()
    private let showsScroll = NSScrollView()
    private let episodesTable = KeyTableView()
    /// Right-click menu of the show list; the show it was opened on.
    private let showsMenu = NSMenu()
    private var menuShow: PodcastShow?
    /// Arrowing through the show list opens a show after a short pause (not every feed on the way).
    private var showSelectionWork: DispatchWorkItem?
    private let episodesScroll = NSScrollView()
    private let showTitle = NSTextField(labelWithString: "")
    private let showInfo = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var shows: [PodcastShow] = []
    /// The open show's episodes, and the ones shown after the title filter and UNPLAYED.
    private var allEpisodes: [PodcastEpisode] = []
    private var episodes: [PodcastEpisode] = []
    private let episodeFilter = DashSearchField()
    private var unplayedButton: Pill!
    private static let unplayedKey = "podcastUnplayedOnly"
    private var unplayedOnly: Bool { UserDefaults.standard.bool(forKey: Self.unplayedKey) }
    private var currentShow: PodcastShow?
    /// In the Continue listening / Downloads lists, each episode's own show (they mix shows).
    private var episodeShows: [String: PodcastShow] = [:]
    private let downloads = PodcastDownloads.shared
    private var downloadButton: Pill!
    private var folderButton: Pill!

    /// Pinned at the top of SUBSCRIBED when they have something.
    private static let continueShow = PodcastShow(feedURL: "omniamp:continue", title: "Continue listening", author: "")
    private static let downloadsShow = PodcastShow(feedURL: "omniamp:downloads", title: "Downloads", author: "")
    private static func isPinned(_ s: PodcastShow?) -> Bool { s?.feedURL.hasPrefix("omniamp:") == true }
    private var loadTask: Task<Void, Never>?
    private var episodesTask: Task<Void, Never>?
    private var showingSubscriptions: Bool
    private let observers = Observers()
    /// Episodes released after this are marked new (nil: the show isn't subscribed). Taken when the show
    /// opens, so the marks stay while you look, though opening it counts as having seen them.
    private var newSince: Double?
    /// Episode list above, show notes below (collapsible).
    private let split = NotesSplitView()
    /// Shows on the left, the selected show on the right; the gap between them is a draggable divider.
    private let panes = PaneSplitView()
    private let rightPane = NSView()
    private static let showsWidthKey = "podcastShowsWidth"
    private let notes = EpisodeNotesView()
    private var notesButton: Pill!
    private var progressTimer: Timer?
    private static let notesOpenKey = "podcastNotesOpen", notesHeightKey = "podcastNotesHeight"

    private static let countries = RadioWindowController.countries.filter { !$0.1.isEmpty }

    init(controller: PlayerController) {
        self.controller = controller
        showingSubscriptions = Self.lastState?.subscriptions ?? !PodcastLibrary.shared.subscriptions.isEmpty
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Podcasts"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.minSize = NSSize(width: 700, height: 360)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        if !w.setFrameUsingName("OmniAmpPodcasts") { w.center() }
        w.setFrameAutosaveName("OmniAmpPodcasts")
        build()
        // All three on the main queue.
        observers.add(NotificationCenter.default.addObserver(forName: Theme.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.build()
                self?.showsTable.reloadData()
                self?.episodesTable.reloadData()
            }
        })
        observers.add(NotificationCenter.default.addObserver(forName: PodcastLibrary.progressChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.countedAsStarted = nil   // finished or reset: counts again past 30 s when replayed
                self?.refreshMarks()
                self?.refreshPinned(PodcastWindowController.continueShow)
            }
        })
        observers.add(NotificationCenter.default.addObserver(forName: PodcastDownloads.changed, object: nil, queue: .main) { [weak self] n in
            let path = n.object as? String
            MainActor.assumeIsolated { self?.downloadChanged(path) }
        })
        if let st = Self.lastState {
            // Reopened after being closed (the window is freed when closed): same view, search and show.
            search.stringValue = st.query
            if let s = st.show { open(s) }
        }
        load()
        refreshSubscriptions()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// What to restore when the window is opened again (it is freed on close to give its memory back).
    private static var lastState: (subscriptions: Bool, query: String, show: PodcastShow?)?
    /// Closed: the app drops this controller.
    var onClose: (() -> Void)?


    /// Opening the window again checks subscribed shows for new episodes.
    func windowDidBecomeKey(_ notification: Notification) {
        refreshSubscriptions()
        refreshMarks()
        startProgressTimer()
    }

    func windowWillClose(_ notification: Notification) {
        progressTimer?.invalidate()
        progressTimer = nil
        Self.lastState = (showingSubscriptions, search.stringValue, currentShow)
        loadTask?.cancel()
        episodesTask?.cancel()
        onClose?()
    }

    /// The playing episode that has been added to Continue listening (once it's past 30 s).
    private var countedAsStarted: String?   // reset when an episode finishes or is marked (the progress observer)

    /// While an episode plays, its pie keeps up, and past 30 s it joins Continue listening (every few seconds;
    /// nothing runs when the window is closed).
    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self, self.window?.occlusionState.contains(.visible) == true,
                  self.controller.player.isPlayingEpisode, self.controller.player.state == .playing,
                  let url = self.controller.currentTrack?.path else { return }
            if self.controller.player.currentTime > 30, self.countedAsStarted != url {
                self.countedAsStarted = url
                self.refreshPinned(Self.continueShow)
            }
            guard let row = self.episodes.firstIndex(where: { $0.url == url }) else { return }
            self.episodesTable.reloadData(forRowIndexes: [row], columnIndexes: [0])
            if self.episodesTable.selectedRow == row { self.updateNotes() }
        } }
        t.tolerance = 1   // lets macOS batch its wake-ups with others
        RunLoop.main.add(t, forMode: .common)
        progressTimer = t
    }

    // MARK: Layout

    private func column(_ id: String, _ width: CGFloat, flexible: Bool = false) -> NSTableColumn {
        ListLook.column(id, width, flexible: flexible)
    }

    private func style(_ table: NSTableView, _ scroll: NSScrollView, rowHeight: CGFloat) {
        table.columnAutoresizingStyle = .noColumnAutoresizing   // fitColumns() sizes the flexible one
        table.dataSource = self
        table.delegate = self
        table.target = self
        Dash.applyList(table, in: scroll, rowHeight: rowHeight)
    }

    private func build() {
        window?.backgroundColor = Dash.page
        let title = Dash.label("Podcasts", Dash.font(12, .semibold), Dash.text2)

        topButton = Pill("Top", glyph: Fonts.Icon.podcast, target: self, action: #selector(showTop))
        subscribedButton = Pill("Subscribed", glyph: Fonts.Icon.rss, target: self, action: #selector(showSubscribed))
        topButton.isOn = !showingSubscriptions
        subscribedButton.isOn = showingSubscriptions

        search.placeholderString = "Search podcasts…"
        search.font = Dash.font(13)
        search.target = self
        search.action = #selector(searchChanged)
        search.delegate = self   // Esc in an empty field closes the window
        search.sendsWholeSearchString = false   // search as you type (the field waits for a pause)
        search.sendsSearchStringImmediately = false
        if country.numberOfItems == 0 {
            country.addItems(withTitles: Self.countries.map(\.0))
            let here = Locale.current.region?.identifier ?? "US"
            country.selectItem(at: Self.countries.firstIndex { $0.1 == here } ?? 0)
        }
        country.highlightsChoice = false   // which directory, not a filter: never lit
        country.target = self
        country.action = #selector(countryChanged)
        country.font = Dash.font(12)

        if showsTable.tableColumns.isEmpty {
            showsTable.addTableColumn(column("show", 300, flexible: true))
            style(showsTable, showsScroll, rowHeight: 54)
            showsTable.action = #selector(showClicked)
            showsMenu.delegate = self
            showsTable.menu = showsMenu
            showsTable.onKey = { [weak self] e in self?.showsKey(e) ?? false }
            episodesTable.onKey = { [weak self] e in self?.episodesKey(e) ?? false }
            episodesTable.addTableColumn(column("mark", 14))
            episodesTable.addTableColumn(column("art", 26))
            episodesTable.addTableColumn(column("title", 300, flexible: true))
            episodesTable.addTableColumn(column("dl", 16))
            episodesTable.action = #selector(episodeClicked)
            let menu = NSMenu()
            menu.delegate = self   // filled for the clicked row
            episodesTable.menu = menu
            episodesTable.addTableColumn(column("date", 92))
            episodesTable.addTableColumn(column("length", 62))
            style(episodesTable, episodesScroll, rowHeight: 32)
            episodesTable.allowsMultipleSelection = true
            episodesTable.doubleAction = #selector(playSelected)
        } else {
            for (t, s) in [(showsTable, showsScroll), (episodesTable, episodesScroll)] {
                t.backgroundColor = Dash.card
                s.backgroundColor = Dash.card
            }
        }
        notes.applyTheme()
        if split.subviews.isEmpty {
            split.isVertical = false
            split.dividerStyle = .thin
            split.delegate = self
            split.addArrangedSubview(episodesScroll)
            split.addArrangedSubview(notes)
            notes.isHidden = !UserDefaults.standard.bool(forKey: Self.notesOpenKey)
        }

        showTitle.font = Dash.font(17, .semibold)
        showTitle.textColor = Dash.text
        showTitle.lineBreakMode = .byTruncatingTail
        showTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        showInfo.font = Dash.font(12)
        showInfo.textColor = Dash.text2
        showInfo.lineBreakMode = .byTruncatingTail
        showInfo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subscribeButton = Pill("Subscribe", glyph: Fonts.Icon.rss, target: self, action: #selector(subscribeTapped))
        subscribeButton.toolTip = "Subscribe: new episodes show up under SUBSCRIBED"

        status.font = Dash.font(11.5)
        status.textColor = Dash.text2
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        notesButton = Pill("Notes", glyph: Fonts.Icon.info, target: self, action: #selector(toggleNotes))
        notesButton.isOn = !notes.isHidden
        notesButton.toolTip = "Show notes of the selected episode"
        downloadButton = Pill("Download", glyph: Fonts.Icon.download, target: self, action: #selector(downloadSelected))
        downloadButton.toolTip = "Save the selected episodes for offline listening (or remove them)"
        let playedButton = Pill("Played", glyph: Fonts.Icon.check, target: self, action: #selector(togglePlayed))
        let add = Pill("Add", glyph: Fonts.Icon.plus, target: self, action: #selector(addSelected))
        let play = Pill("Play", glyph: Fonts.Icon.play, target: self, action: #selector(playSelected))
        play.prominent = true
        playedButton.toolTip = "Mark the selected episodes as played / unplayed"
        add.toolTip = "Add the selected episodes to the playlist"
        play.toolTip = "Play now (double-click)"

        let feedButton = Pill("Feed", glyph: Fonts.Icon.plus, target: self, action: #selector(feedMenu(_:)))
        feedButton.toolTip = "Add a podcast by its feed URL, or import / export your subscriptions (OPML)"
        let top = NSStackView(views: [topButton, subscribedButton, search, country, feedButton])
        top.spacing = 6
        folderButton = Pill("Folder", glyph: Fonts.Icon.folder, target: self, action: #selector(showDownloadFolder))
        folderButton.toolTip = "Open the downloads folder in Finder (change it in Settings)"
        episodeFilter.placeholderString = "Filter episodes"
        episodeFilter.font = Dash.font(12)
        episodeFilter.controlSize = .small
        episodeFilter.sendsSearchStringImmediately = true   // it's local: filter on every key
        episodeFilter.target = self
        episodeFilter.action = #selector(episodeFilterChanged)
        episodeFilter.delegate = self
        episodeFilter.toolTip = "Show only episodes whose title has all these words (⇧⌘F)"
        episodeFilter.setContentHuggingPriority(.defaultLow, for: .horizontal)   // stretches across its row
        unplayedButton = Pill("Unplayed", target: self, action: #selector(toggleUnplayed))
        unplayedButton.isOn = unplayedOnly
        unplayedButton.toolTip = "Hide episodes you've played"
        let header = NSStackView(views: [showTitle, NSView(), folderButton, subscribeButton])
        // The list's own toolbar: filter + UNPLAYED, above the episodes (the title line keeps its room).
        let listBar = NSStackView(views: [episodeFilter, unplayedButton])
        listBar.spacing = 8
        header.spacing = 8
        let bottom = NSStackView(views: [status, NSView(), notesButton, downloadButton, playedButton, add, play])
        bottom.spacing = 6
        let root = NSView()
        for v in [title, top, panes, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        // Right side: rebuilt with the theme (a new header each time), the episode/notes split moves over.
        rightPane.subviews.forEach { $0.removeFromSuperview() }
        for v in [header, showInfo, listBar, split] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            rightPane.addSubview(v)
        }
        if panes.subviews.isEmpty {
            panes.isVertical = true
            panes.delegate = self
            panes.addArrangedSubview(showsScroll)
            panes.addArrangedSubview(rightPane)
        }
        for b in [topButton!, subscribedButton!, subscribeButton!, notesButton!, downloadButton!, playedButton, add, play] { b.heightAnchor.constraint(equalToConstant: 22).isActive = true }
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            title.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 34),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            panes.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            panes.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            panes.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            panes.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),

            header.topAnchor.constraint(equalTo: rightPane.topAnchor),
            header.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            showInfo.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            showInfo.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            showInfo.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            listBar.topAnchor.constraint(equalTo: showInfo.bottomAnchor, constant: 8),
            listBar.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            listBar.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            split.topAnchor.constraint(equalTo: listBar.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),

            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root
        updateHeader()
        DispatchQueue.main.async {
            self.restoreShowsWidth()
            if !self.notes.isHidden { self.restoreNotesHeight() }
            self.fitColumns()
        }
    }

    private func restoreShowsWidth() {
        panes.layoutSubtreeIfNeeded()
        let saved = UserDefaults.standard.double(forKey: Self.showsWidthKey)
        let w = saved > 0 ? saved : (panes.bounds.width * 0.36).rounded()
        panes.setPosition(min(max(w, Self.minShows), max(Self.minShows, panes.bounds.width - Self.minEpisodes)), ofDividerAt: 0)
    }

    private static let minShows: CGFloat = 200, minEpisodes: CGFloat = 380

    // MARK: Columns

    /// The flexible column (show name, episode title) takes exactly the room left, so dates and lengths
    /// always end at the right edge instead of running past it.
    private func fitColumns() {
        for (table, flexible) in [(showsTable, "show"), (episodesTable, "title")] {
            guard let col = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(flexible)),
                  let clip = table.enclosingScrollView?.contentView else { continue }
            let others = table.tableColumns.filter { $0 !== col }.reduce(0) { $0 + $1.width }
            let spacing = table.intercellSpacing.width * CGFloat(table.tableColumns.count)
            let w = max(col.minWidth, (clip.bounds.width - others - spacing).rounded(.down))
            if abs(col.width - w) > 0.5 { col.width = w }
        }
    }

    // MARK: Show notes pane

    @objc private func toggleNotes() {
        notes.isHidden.toggle()
        UserDefaults.standard.set(!notes.isHidden, forKey: Self.notesOpenKey)
        notesButton.isOn = !notes.isHidden
        split.adjustSubviews()
        split.needsDisplay = true   // or the old divider line stays behind
        if !notes.isHidden { restoreNotesHeight(); updateNotes() }
        episodesTable.reloadData()   // the title tooltips are only there while the pane is closed
    }

    private func restoreNotesHeight() {
        split.layoutSubtreeIfNeeded()
        let saved = UserDefaults.standard.double(forKey: Self.notesHeightKey)
        let h = min(max(saved > 0 ? saved : 170, 90), max(90, split.bounds.height - 90))
        split.setPosition(split.bounds.height - h - split.dividerThickness, ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { splitView === split && notes.isHidden }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        splitView === panes ? max(proposed, Self.minShows) : max(proposed, 80)   // keep a few episode rows
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if splitView === panes { return min(proposed, splitView.bounds.width - Self.minEpisodes - splitView.dividerThickness) }
        return min(proposed, splitView.bounds.height - 90 - splitView.dividerThickness)   // notes: cover and a line or two
    }

    /// Window resizes go to the episode list: the notes keep their height, the show list its width.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== notes && view !== showsScroll
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        fitColumns()
        if (notification.object as? NSSplitView) === panes {
            if showsScroll.frame.width >= Self.minShows { UserDefaults.standard.set(showsScroll.frame.width, forKey: Self.showsWidthKey) }
            return
        }
        guard !notes.isHidden, notes.frame.height >= 90 else { return }
        UserDefaults.standard.set(notes.frame.height, forKey: Self.notesHeightKey)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let table = notification.object as? NSTableView
        if table === episodesTable { updateNotes(); updateDownloadButton() }
        if table === showsTable {
            showSelectionWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.showClicked() }
            showSelectionWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
        }
    }

    // MARK: Keyboard

    private enum Key {
        static let left: UInt16 = 123, right: UInt16 = 124, returnKey: UInt16 = 36, enter: UInt16 = 76, space: UInt16 = 49, escape: UInt16 = 53, tab: UInt16 = 48
    }

    private static func plain(_ e: NSEvent) -> Bool { e.modifierFlags.intersection([.command, .control, .option]).isEmpty }

    /// Show list: → or Return goes to the episodes.
    private func showsKey(_ e: NSEvent) -> Bool {
        guard Self.plain(e) else { return false }
        switch e.keyCode {
        case Key.tab: focus(e.modifierFlags.contains(.shift) ? -1 : 1, from: .shows); return true
        case Key.escape: window?.performClose(nil); return true
        case Key.space: controller.togglePlayPause(); return true
        case Key.right, Key.returnKey, Key.enter:
            showSelectionWork?.perform()   // open the highlighted show now
            focusEpisodes()
            return true
        default:
            // Letters and digits start a directory search (or filter the subscriptions).
            guard let c = ListLook.typedText(e) else { return false }
            window?.makeFirstResponder(search)
            search.currentEditor()?.insertText(c)
            return true
        }
    }

    /// Opened from the menu or ⌘3: start in the show list, so arrows, Return and Esc work right away.
    func focusList() { window?.makeFirstResponder(showsTable) }

    /// Episode list: ← back to the shows, Return plays, Space pauses / resumes.
    private func episodesKey(_ e: NSEvent) -> Bool {
        guard Self.plain(e) else { return false }
        switch e.keyCode {
        case Key.tab: focus(e.modifierFlags.contains(.shift) ? -1 : 1, from: .episodes); return true
        case Key.escape, Key.left: focusShows(); return true   // one step back (Esc again in the shows closes)
        case Key.returnKey, Key.enter: playSelected(); return true
        case Key.space: controller.togglePlayPause(); return true
        default:
            // Letters and digits start the episode filter.
            guard let c = ListLook.typedText(e) else { return false }
            focusEpisodeFilter(typing: c)
            return true
        }
    }

    private func focusEpisodes() {
        window?.makeFirstResponder(episodesTable)
        if episodesTable.selectedRow < 0, !episodes.isEmpty {
            episodesTable.selectRowIndexes([0], byExtendingSelection: false)
            episodesTable.scrollRowToVisible(0)
        }
    }

    // Menu shortcuts that act here (AppDelegate routes them when this window is in front).
    var canDownloadSelection: Bool { !selectedEpisodes.isEmpty }
    func downloadFromMenu() { downloadSelected() }
    func toggleNotesFromMenu() { toggleNotes() }
    func toggleUnplayedFromMenu() { toggleUnplayed() }

    /// ⌘F while this window is in front.
    func focusSearch() {
        window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    private func updateNotes() {
        guard !notes.isHidden else { return }
        let row = episodesTable.selectedRow
        guard row >= 0, row < episodes.count, let s = show(for: episodes[row]) else { notes.show(nil, show: nil, status: nil); return }
        let e = episodes[row]
        let status: String?
        switch mark(for: e) {
        case .played: status = "Played"
        case .new: status = "New"
        case .progress:
            let p = controller.episodeProgress(e.url)
            let d = p?.duration ?? e.duration
            status = d.flatMap { d in p.map { "\(max(1, Int((d - $0.position) / 60))) min left" } } ?? "Started"
        case .none: status = nil
        }
        var extra = [status].compactMap { $0 }
        if Self.isPinned(currentShow) { extra.insert(s.title, at: 0) }   // mixed shows: say which
        switch downloads.state(e.url) {
        case .done: extra.append("Downloaded" + (downloads.entries[e.url].map { " · " + ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file) } ?? ""))
        case .downloading(let p): extra.append("Downloading \(Int(p * 100))%")
        case .queued: extra.append("Waiting to download")
        case .none: if let f = downloads.failure(e.url) { extra.append("Download failed: " + f) }
        }
        notes.show(e, show: s, status: extra.isEmpty ? nil : extra.joined(separator: " · "))
    }

    // MARK: Markers

    private func mark(for e: PodcastEpisode) -> EpisodeMarkView.State {
        if library.isPlayed(e.url) { return .played }
        if let p = controller.episodeProgress(e.url) {
            let d = p.duration ?? e.duration
            return .progress(d.flatMap { $0 > 0 ? min(1, max(0, p.position / $0)) : nil })
        }
        if let since = newSince, let pub = e.published, pub > since { return .new }
        return .none
    }

    /// Played / started changed somewhere: markers and titles (played ones are dimmed).
    private func refreshMarks() {
        if unplayedOnly { applyEpisodeFilter(); return }   // something played now hides
        guard !episodes.isEmpty else { return }
        episodesTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<episodes.count), columnIndexes: [0, 2])
        updateNotes()
    }

    // MARK: Loading shows

    private var countryCode: String { Self.countries[max(0, country.indexOfSelectedItem)].1 }

    /// `keepPlace`: refresh the subscriptions where you are (after an import), not back at the top.
    private func load(keepPlace: Bool = false) {
        loadTask?.cancel()
        topButton.isOn = !showingSubscriptions
        subscribedButton.isOn = showingSubscriptions
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        if showingSubscriptions {
            let lq = q.lowercased()
            let subs = library.subscriptions.filter { lq.isEmpty || $0.title.lowercased().contains(lq) || $0.author.lowercased().contains(lq) }
            shows = (lq.isEmpty ? pinnedShows : []) + subs
            showsTable.reloadData()
            syncShowSelection()
            if !keepPlace { scrollToTop(showsScroll) }
            status.stringValue = library.subscriptions.isEmpty ? "No subscriptions yet: pick a show and press SUBSCRIBE."
                : (subs.isEmpty ? "No subscriptions match “\(q)”." : "\(subs.count) subscriptions")
            selectFirstShowIfNeeded()
            return
        }
        let cc = countryCode
        let dir = PodcastDirectory.shared
        // The last chart shows at once (a fresh one replaces it if it's old).
        let showingCached = q.isEmpty && dir.cachedTop(country: cc) != nil
        if q.isEmpty, let cached = dir.cachedTop(country: cc) {
            setShows(cached.shows, status: "\(cached.shows.count) podcasts · top chart")
            if cached.fresh { return }
        } else {
            status.stringValue = q.isEmpty ? "Loading the top chart…" : "Searching…"
        }
        loadTask = Task { @MainActor in
            do {
                if q.isEmpty {
                    let list = try await dir.top(country: cc)
                    guard !Task.isCancelled else { return }
                    setShows(list, status: list.isEmpty ? "No podcasts found." : "\(list.count) podcasts · top chart",
                             keepSelection: showingCached)   // a background refresh: don't jump
                    return
                }
                // Apple answers in a blink; fyyd can take 10 s: show Apple's, then add fyyd's.
                var appleFailed: Error?
                do {
                    let list = try await dir.searchApple(q, country: cc)
                    guard !Task.isCancelled else { return }
                    setShows(list, status: list.isEmpty ? "Searching more directories…" : "\(list.count) podcasts · searching more…")
                } catch {
                    appleFailed = error
                }
                let extra = (try? await dir.searchFyyd(q)) ?? []
                guard !Task.isCancelled else { return }
                if let appleFailed, extra.isEmpty { throw appleFailed }
                let merged = PodcastDirectory.merge(appleFailed == nil ? shows : [], extra)
                if merged.count != shows.count || appleFailed != nil { setShows(merged, status: "", keepSelection: true) }
                status.stringValue = shows.isEmpty ? "No podcasts found." : "\(shows.count) podcasts"
            } catch {
                guard !Task.isCancelled else { return }
                status.stringValue = "Couldn't reach the podcast directory: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Episode filter

    /// The one way the episode list changes: keep the full list, show the filtered part, keep the selection.
    private func setEpisodes(_ list: [PodcastEpisode]) {
        allEpisodes = list
        applyEpisodeFilter()
    }

    private func applyEpisodeFilter() {
        let selected = Set(selectedEpisodes.map(\.url))
        let words = episodeFilter.stringValue.lowercased().split(separator: " ").map(String.init)
        let hidePlayed = unplayedOnly
        episodes = allEpisodes.filter { e in
            if hidePlayed, library.isPlayed(e.url) { return false }
            guard !words.isEmpty else { return true }
            let t = e.title.lowercased()
            return words.allSatisfy { t.contains($0) }
        }
        episodesTable.reloadData()
        let keep = IndexSet(episodes.indices.filter { selected.contains(episodes[$0].url) })
        // By identity: the old row numbers now point at other episodes (PLAY / DOWNLOAD would act on them).
        if keep.isEmpty { episodesTable.deselectAll(nil) } else { episodesTable.selectRowIndexes(keep, byExtendingSelection: false) }
        updateHeader()
        updateNotes()
        updateDownloadButton()
    }

    private var isFiltering: Bool { unplayedOnly || !episodeFilter.stringValue.isEmpty }

    @objc private func episodeFilterChanged() {
        applyEpisodeFilter()
        if !episodes.isEmpty { episodesTable.scrollRowToVisible(0) }
    }

    @objc private func toggleUnplayed() {
        UserDefaults.standard.set(!unplayedOnly, forKey: Self.unplayedKey)
        unplayedButton.isOn = unplayedOnly
        applyEpisodeFilter()
    }

    /// In the filter: ↓ or Return moves into the (filtered) list.
    /// Both search fields: Return or ↓ go to the results; Esc clears the text, and in an empty field goes
    /// back to the list (Esc steps back one level: field → list → window closed).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let isFilter = control === episodeFilter
        guard isFilter || control === search else { return false }
        func toList() { if isFilter { focusEpisodes() } else { focusShows() } }
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if isFilter { episodeFilterChanged() } else { searchChanged() }   // don't wait for the typing pause
            toList()
        case #selector(NSResponder.moveDown(_:)):
            toList()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            focus(sel == #selector(NSResponder.insertTab(_:)) ? 1 : -1, from: isFilter ? .filter : .search)
        case #selector(NSResponder.cancelOperation(_:)):
            if search === control, !search.stringValue.isEmpty { search.stringValue = ""; searchChanged() }
            else if isFilter, !episodeFilter.stringValue.isEmpty { episodeFilter.stringValue = ""; episodeFilterChanged() }
            else { toList() }
        default:
            return false
        }
        return true
    }

    /// Tab / ⇧Tab go around a fixed ring: search → shows → episode filter → episodes (AppKit's own key view
    /// loop gets recalculated by the split and stack views, so it's done here).
    private enum Stop: Int, CaseIterable { case search, shows, filter, episodes }

    private func focus(_ step: Int, from: Stop) {
        let all = Stop.allCases
        let next = all[(from.rawValue + step + all.count) % all.count]
        switch next {
        case .search: window?.makeFirstResponder(search)
        case .shows: focusShows()
        case .filter: window?.makeFirstResponder(episodeFilter)
        case .episodes: focusEpisodes()
        }
    }

    private func focusShows() {
        window?.makeFirstResponder(showsTable)
        if showsTable.selectedRow < 0, !shows.isEmpty { showsTable.selectRowIndexes([0], byExtendingSelection: false) }
    }

    /// ⌃Tab: TOP ⇄ SUBSCRIBED.
    func toggleView() {
        showingSubscriptions.toggle()
        load()
        focusShows()
    }

    /// ⇧⌘F, or typing in the episode list.
    func focusEpisodeFilter(typing text: String? = nil) {
        window?.makeFirstResponder(episodeFilter)
        if let text { episodeFilter.currentEditor()?.insertText(text) }
    }

    /// Highlight the open show in the list (or nothing, if it isn't in this list): the row index alone would
    /// point at another show after the list changed.
    private func syncShowSelection() {
        // By feed: the list's copy and the open one can differ in details filled in later (cover, author).
        if let cur = currentShow, let r = shows.firstIndex(where: { $0.feedURL == cur.feedURL }) {
            if showsTable.selectedRow != r { showsTable.selectRowIndexes([r], byExtendingSelection: false) }
        } else if showsTable.selectedRow >= 0 {
            showsTable.deselectAll(nil)
        }
    }

    /// Show a list of podcasts on the left; `keepSelection` when only adding to it (late search results).
    private func setShows(_ list: [PodcastShow], status text: String, keepSelection: Bool = false) {
        shows = list
        showsTable.reloadData()
        syncShowSelection()
        if !keepSelection { scrollToTop(showsScroll) }
        status.stringValue = text
        selectFirstShowIfNeeded()
    }

    /// After a reload, show the first rows (the clip view otherwise keeps its old offset).
    private func scrollToTop(_ scroll: NSScrollView) {
        DispatchQueue.main.async {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func selectFirstShowIfNeeded() {
        guard currentShow == nil, let first = shows.first else { return }
        showsTable.selectRowIndexes([0], byExtendingSelection: false)
        open(first)
    }

    /// Re-read subscribed feeds (at most every 10 minutes each) so new-episode counts are current.
    private func refreshSubscriptions() {
        let subs = library.subscriptions
        guard !subs.isEmpty else { return }
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for s in subs { group.addTask { _ = try? await PodcastLibrary.shared.episodes(s) } }
            }
            if showingSubscriptions {
                // Feeds may have filled in covers and authors (imported shows): take the updated entries.
                let byFeed = Dictionary(library.subscriptions.map { ($0.feedURL, $0) }, uniquingKeysWith: { a, _ in a })
                shows = shows.map { byFeed[$0.feedURL] ?? $0 }
                if let c = currentShow, let updated = byFeed[c.feedURL] { currentShow = updated }
                showsTable.reloadData()
                syncShowSelection()
            }
            if let s = currentShow, !Self.isPinned(s) { setEpisodes(library.cachedEpisodes(s)) }
        }
    }

    // MARK: Continue listening / Downloads

    private var pinnedShows: [PodcastShow] {
        [(Self.continueShow, !startedEpisodes().isEmpty), (Self.downloadsShow, !downloads.entries.isEmpty || downloads.isBusy)]
            .filter(\.1).map(\.0)
    }

    /// Started, unfinished episodes, most recently heard first, each with its show.
    private func startedEpisodes() -> [(episode: PodcastEpisode, show: PodcastShow)] {
        var out: [(PodcastEpisode, PodcastShow, Double)] = []
        for url in controller.startedEpisodeURLs where !library.isPlayed(url) {
            guard let (e, show) = resolve(url) else { continue }
            out.append((e, show, library.lastListened(url) ?? e.published ?? 0))
        }
        return out.sorted { $0.2 > $1.2 }.map { ($0.0, $0.1) }
    }

    /// An episode wherever we know it from: a download, a feed read before, or the playlist.
    private func resolve(_ url: String) -> (PodcastEpisode, PodcastShow)? {
        if let d = downloads.entries[url] { return (d.episode, d.show) }
        if let found = library.lookup(url) { return found }
        guard let t = controller.tracks.first(where: { $0.path == url && $0.isEpisode }) else { return nil }
        return (PodcastEpisode(title: t.title ?? "Episode", url: url, published: t.published, duration: t.duration, summary: t.summary),
                PodcastShow(feedURL: "", title: t.podcast.flatMap { $0.isEmpty ? nil : $0 } ?? "Web audio", author: "", artwork: t.logo))
    }

    private func pinnedEpisodes(_ s: PodcastShow) -> [(episode: PodcastEpisode, show: PodcastShow)] {
        if s == Self.continueShow { return startedEpisodes() }
        let pending = downloads.pending
        return pending + downloads.all.filter { e in !pending.contains { $0.episode.url == e.episode.url } }.map { ($0.episode, $0.show) }
    }

    private func openPinned(_ s: PodcastShow) {
        let list = pinnedEpisodes(s)
        episodeShows = Dictionary(list.map { ($0.episode.url, $0.show) }, uniquingKeysWith: { a, _ in a })
        setEpisodes(list.map(\.episode))
        status.stringValue = s == Self.continueShow
            ? (episodes.isEmpty ? "Nothing started yet." : "Pick up where you left off.")
            : (episodes.isEmpty ? "No downloads: select episodes and press DOWNLOAD." : "Downloaded episodes play offline and are deleted once you finish them.")
    }

    /// A pinned list changed (a download finished, an episode was started or finished): refresh it and the row.
    private func refreshPinned(_ s: PodcastShow) {
        if showingSubscriptions, search.stringValue.isEmpty {
            let pinned = pinnedShows
            if pinned != Array(shows.prefix(while: Self.isPinned)) {
                shows = pinned + shows.drop(while: Self.isPinned)
                showsTable.reloadData()
                syncShowSelection()
            } else {
                showsTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<pinned.count), columnIndexes: [0])
            }
        }
        guard currentShow == s else { return }
        let list = pinnedEpisodes(s)
        guard list.map(\.episode.url) != allEpisodes.map(\.url) else { return }
        episodeShows = Dictionary(list.map { ($0.episode.url, $0.show) }, uniquingKeysWith: { a, _ in a })
        setEpisodes(list.map(\.episode))
    }

    /// The show an episode row belongs to.
    private func show(for e: PodcastEpisode) -> PodcastShow? {
        episodeShows[e.url] ?? (Self.isPinned(currentShow) ? nil : currentShow)
    }

    // MARK: Downloading

    private func downloadChanged(_ url: String?) {
        if let url, let row = episodes.firstIndex(where: { $0.url == url }) {
            episodesTable.reloadData(forRowIndexes: [row], columnIndexes: [3])
            if episodesTable.selectedRow == row { updateNotes() }
        }
        updateDownloadButton()
        if currentShow == Self.downloadsShow { updateHeader() }   // count, size, folder
        // Finished, removed or failed: the Downloads list and its row count change.
        if url.map({ downloads.state($0) }).map({ if case .downloading = $0 { return false } else { return true } }) ?? true {
            refreshPinned(Self.downloadsShow)
        }
    }

    static func shortPath(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    @objc private func showDownloadFolder() {
        try? FileManager.default.createDirectory(at: downloads.dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(downloads.dir)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === showsMenu { fillShowMenu(menu); return }
        let row = episodesTable.clickedRow >= 0 ? episodesTable.clickedRow : episodesTable.selectedRow
        guard row >= 0, row < episodes.count else { return }
        // Right-click on a row outside the selection works on that row (like Finder).
        if !episodesTable.selectedRowIndexes.contains(row) { episodesTable.selectRowIndexes([row], byExtendingSelection: false) }
        let eps = selectedEpisodes
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let it = menu.addItem(withTitle: title, action: enabled ? action : nil, keyEquivalent: "")
            it.target = self
        }
        add("Play", #selector(playSelected))
        add(eps.count == 1 ? "Add to Playlist" : "Add \(eps.count) to Playlist", #selector(addSelected))
        menu.addItem(.separator())
        let states = eps.map { downloads.state($0.url) }
        if states.contains(.none) { add(eps.count == 1 ? "Download" : "Download \(states.filter { $0 == .none }.count)", #selector(menuDownload)) }
        if states.contains(where: { $0 != .none && $0 != .done }) { add("Cancel Download", #selector(menuCancel)) }
        if states.contains(.done) { add("Remove Download", #selector(menuRemove)) }
        add("Show in Finder…", #selector(menuReveal), enabled: states.contains(.done))
        menu.addItem(.separator())
        add(eps.allSatisfy { library.isPlayed($0.url) } ? "Mark as Unplayed" : "Mark as Played", #selector(togglePlayed))
    }

    /// Right-click on a show: subscription, refresh, mark all played, copy its feed.
    private func fillShowMenu(_ menu: NSMenu) {
        let row = showsTable.clickedRow >= 0 ? showsTable.clickedRow : showsTable.selectedRow
        guard row >= 0, row < shows.count else { return }
        let s = shows[row]
        menuShow = s
        func add(_ title: String, _ action: Selector) { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        if s == Self.downloadsShow { add("Open Downloads Folder", #selector(showDownloadFolder)); return }
        if Self.isPinned(s) { return }
        add(library.isSubscribed(s) ? "Unsubscribe" : "Subscribe", #selector(menuToggleSubscription))
        add("Refresh Episodes", #selector(menuRefresh))
        add("Mark All as Played", #selector(menuMarkAllPlayed))
        menu.addItem(.separator())
        add("Copy Feed URL", #selector(menuCopyFeed))
    }

    @objc private func menuToggleSubscription() { if let s = menuShow { toggleSubscription(s) } }

    @objc private func menuRefresh() {
        guard let s = menuShow else { return }
        status.stringValue = "Refreshing “\(s.title)”…"
        Task { @MainActor in
            do {
                let eps = try await library.episodes(s, maxAge: 0)
                if currentShow?.feedURL == s.feedURL { setEpisodes(eps) }
                if let r = shows.firstIndex(of: s) { showsTable.reloadData(forRowIndexes: [r], columnIndexes: [0]) }
                status.stringValue = "“\(s.title)”: \(eps.count) episodes."
            } catch {
                status.stringValue = "Couldn't refresh “\(s.title)”: \(error.localizedDescription)"
            }
        }
    }

    @objc private func menuMarkAllPlayed() {
        guard let s = menuShow else { return }
        Task { @MainActor in
            // A show never opened has no episodes cached yet: read its feed first.
            var eps = library.cachedEpisodes(s)
            if eps.isEmpty { eps = (try? await library.episodes(s)) ?? [] }
            let urls = eps.map(\.url).filter { !library.isPlayed($0) }
            library.markPlayed(urls)
            library.markSeen(s)
            if let r = shows.firstIndex(of: s) { showsTable.reloadData(forRowIndexes: [r], columnIndexes: [0]) }
            status.stringValue = urls.isEmpty ? "Everything in “\(s.title)” was already played." : "Marked \(urls.count) episodes of “\(s.title)” as played."
        }
    }

    @objc private func menuCopyFeed() {
        guard let s = menuShow else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.feedURL, forType: .string)
        status.stringValue = "Copied the feed address of “\(s.title)”."
    }

    @objc private func menuDownload() {
        var n = 0
        for e in selectedEpisodes where downloads.state(e.url) == .none { if let s = show(for: e) { downloads.download(e, show: s); n += 1 } }
        if n > 0 { status.stringValue = "Downloading \(n == 1 ? "1 episode" : "\(n) episodes") to " + Self.shortPath(downloads.dir) + "…" }
    }

    @objc private func menuCancel() { for e in selectedEpisodes { if downloads.state(e.url) != .done { downloads.cancel(e.url) } } }

    @objc private func menuRemove() {
        let done = selectedEpisodes.filter { downloads.state($0.url) == .done }
        for e in done { downloads.remove(e.url) }
        status.stringValue = done.count == 1 ? "Removed the download of “\(done[0].title)”." : "Removed \(done.count) downloads."
    }

    @objc private func menuReveal() {
        let files = selectedEpisodes.compactMap { downloads.localFile($0.url) }
        if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
    }

    /// The key follows the selection: DOWNLOAD, REMOVE (all downloaded) or CANCEL (all coming in).
    private func updateDownloadButton() {
        guard downloadButton != nil else { return }
        let states = selectedEpisodes.map { downloads.state($0.url) }
        let label: String, glyph: String
        if !states.isEmpty, states.allSatisfy({ $0 == .done }) { (label, glyph) = ("Remove", Fonts.Icon.trash) }
        else if !states.isEmpty, states.allSatisfy({ $0 != .none && $0 != .done }) { (label, glyph) = ("Cancel", Fonts.Icon.download) }
        else { (label, glyph) = ("Download", Fonts.Icon.download) }
        downloadButton.label = label
        downloadButton.glyph = glyph
    }

    @objc private func downloadSelected() {
        let eps = selectedEpisodes
        guard !eps.isEmpty else { status.stringValue = "Select the episodes to download."; return }
        switch downloadButton.label {
        case "REMOVE":
            for e in eps { downloads.remove(e.url) }
            status.stringValue = eps.count == 1 ? "Removed the download of “\(eps[0].title)”." : "Removed \(eps.count) downloads."
        case "CANCEL":
            for e in eps { downloads.cancel(e.url) }
            status.stringValue = "Stopped downloading."
        default:
            var n = 0
            for e in eps where downloads.state(e.url) == .none { if let s = show(for: e) { downloads.download(e, show: s); n += 1 } }
            status.stringValue = n == 0 ? "Already downloaded." : (n == 1 ? "Downloading 1 episode" : "Downloading \(n) episodes") + " to " + Self.shortPath(downloads.dir) + "…"
        }
        updateDownloadButton()
    }

    /// A click on a row's download icon starts, stops or (when done) does nothing but select.
    @objc private func episodeClicked() {
        let row = episodesTable.clickedRow, col = episodesTable.clickedColumn
        guard row >= 0, row < episodes.count, col == 3 else { return }
        let e = episodes[row]
        switch downloads.state(e.url) {
        case .none: if let s = show(for: e) { downloads.download(e, show: s); status.stringValue = "Downloading to " + Self.shortPath(downloads.dir) + "…" }
        case .queued, .downloading: downloads.cancel(e.url); status.stringValue = "Stopped downloading “\(e.title)”."
        case .done: if let f = downloads.localFile(e.url) { NSWorkspace.shared.activateFileViewerSelecting([f]) }
        }
    }

    @objc private func showTop() { showingSubscriptions = false; load() }
    @objc private func showSubscribed() { showingSubscriptions = true; load() }
    @objc private func searchChanged() { load() }
    @objc private func countryChanged() { if !showingSubscriptions { load() } }

    // MARK: Episodes

    @objc private func showClicked() {
        let r = showsTable.selectedRow
        guard r >= 0, r < shows.count, shows[r].feedURL != currentShow?.feedURL else { return }
        open(shows[r])
    }

    /// Show a podcast found by URL (Add URL or + FEED), subscribing to it if asked.
    func present(_ show: PodcastShow, subscribe: Bool) {
        if subscribe, !library.isSubscribed(show) { library.toggleSubscription(show) }
        if library.isSubscribed(show) {
            showingSubscriptions = true
            search.stringValue = ""
            load()
            if let r = shows.firstIndex(where: { $0.feedURL == show.feedURL }) {
                showsTable.selectRowIndexes([r], byExtendingSelection: false)
                showsTable.scrollRowToVisible(r)
            }
        } else {
            showsTable.deselectAll(nil)
        }
        open(show)
        status.stringValue = library.isSubscribed(show) ? "Subscribed to “\(show.title)”." : "Found “\(show.title)”: press SUBSCRIBE to keep it."
    }

    @objc private func feedMenu(_ sender: NSView) {
        let m = NSMenu()
        m.addItem(withTitle: "Add by Feed URL…", action: #selector(addFeed), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Import Subscriptions (OPML)…", action: #selector(chooseOPML), keyEquivalent: "").target = self
        let exp = m.addItem(withTitle: "Export Subscriptions (OPML)…", action: library.subscriptions.isEmpty ? nil : #selector(exportOPML),
                            keyEquivalent: "")
        exp.target = self
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // MARK: OPML

    @objc private func chooseOPML() {
        guard let w = window else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.init(filenameExtension: "opml") ?? .xml, .xml]
        p.allowsOtherFileTypes = true
        p.message = "Choose an OPML file exported from another podcast app."
        p.prompt = "Import"
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let u = p.url else { return }
            self?.importOPML(u)
        }
    }

    /// Subscribe to every show in an OPML file (also when one is opened from Finder).
    func importOPML(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { status.stringValue = "Couldn't read \(url.lastPathComponent)."; return }
        let (list, complete) = PodcastOPML.parse(data)
        guard !list.isEmpty else {
            status.stringValue = complete ? "No podcasts found in \(url.lastPathComponent)." : "\(url.lastPathComponent) isn't a readable OPML file."
            return
        }
        let added = library.subscribe(list)
        showingSubscriptions = true
        search.stringValue = ""
        load()
        let already = list.count - added
        status.stringValue = "Imported \(added) show\(added == 1 ? "" : "s")" + (already > 0 ? " (\(already) already subscribed)" : "") + ". Loading their episodes…"
        // Covers, authors and episodes come with each feed.
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for s in list { group.addTask { _ = try? await PodcastLibrary.shared.episodes(s) } }
            }
            if showingSubscriptions { load(keepPlace: true) }
            status.stringValue = "Imported \(added) show\(added == 1 ? "" : "s")" + (already > 0 ? " (\(already) already subscribed)" : "")
                + (complete ? "." : ". The file is damaged part-way: some shows may be missing.")
        }
    }

    @objc private func exportOPML() {
        guard let w = window else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.init(filenameExtension: "opml") ?? .xml]
        p.nameFieldStringValue = "OmniAmp Podcasts.opml"
        p.message = "Your \(library.subscriptions.count) subscriptions, for another podcast app or as a backup."
        p.beginSheetModal(for: w) { [weak self] r in
            guard let self, r == .OK, let u = p.url else { return }
            do {
                try PodcastOPML.write(self.library.subscriptions).write(to: u, options: .atomic)
                self.status.stringValue = "Exported \(self.library.subscriptions.count) subscriptions to \(u.lastPathComponent)."
            } catch {
                self.status.stringValue = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    @objc private func addFeed() {
        AddURL.ask(title: "Add a Podcast by URL", message: "Paste the show's RSS feed (also private or paid feeds with a personal link) or an Apple Podcasts link.",
                   button: "Subscribe", in: window) { [weak self] text in
            self?.status.stringValue = "Checking the link…"
            Task { @MainActor in
                guard let self else { return }
                do {
                    switch try await URLProbe.probe(text) {
                    case .podcast(let show): self.present(show, subscribe: true)
                    case .station, .stations:
                        self.status.stringValue = "That's a radio stream: add it with + URL in Internet Radio."
                    case .file(let url, let title):
                        self.controller.addEpisode(.webFile(url, title: title))
                        self.status.stringValue = "That's a single audio file: added “\(title)” to the playlist."
                    }
                } catch {
                    self.status.stringValue = ""
                    AddURL.show(error, in: self.window)
                }
            }
        }
    }

    private func open(_ show: PodcastShow) {
        currentShow = show
        episodesTask?.cancel()
        if Self.isPinned(show) {
            newSince = nil
            episodeFilter.stringValue = ""
            episodesTable.deselectAll(nil)
            scrollToTop(episodesScroll)
            openPinned(show)
            return
        }
        episodeShows = [:]
        newSince = library.seenMark(show)
        episodeFilter.stringValue = ""   // a filter typed for another show would only confuse
        episodesTable.deselectAll(nil)
        setEpisodes(library.cachedEpisodes(show))
        scrollToTop(episodesScroll)
        episodesTask?.cancel()
        if allEpisodes.isEmpty { status.stringValue = "Loading episodes…" }
        episodesTask = Task { @MainActor in
            do {
                let eps = try await library.episodes(show)
                guard !Task.isCancelled, currentShow?.feedURL == show.feedURL else { return }
                setEpisodes(eps)
                status.stringValue = eps.isEmpty ? "This feed has no audio episodes." : "\(eps.count) episodes"
                // Seen: the new-episode marks stay until the next visit. Only a show looked at for a second: arrowing
                // past it (which cancels this) leaves its marks.
                guard (try? await Task.sleep(for: .seconds(1))) != nil, !Task.isCancelled else { return }
                library.markSeen(show)
                showsTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<shows.count), columnIndexes: [0])
            } catch {
                guard !Task.isCancelled, currentShow?.feedURL == show.feedURL else { return }
                status.stringValue = (allEpisodes.isEmpty ? "Couldn't load this feed: " : "Showing saved episodes (offline): ") + error.localizedDescription
            }
        }
    }

    /// "494 episodes", or "12 of 494 episodes" while filtered.
    private func countText(singular: String) -> String {
        let n = allEpisodes.count
        let noun = n == 1 ? singular : singular + "s"
        return isFiltering && episodes.count != n ? "\(episodes.count) of \(n) \(noun)" : "\(n) \(noun)"
    }

    private func updateHeader() {
        guard let s = currentShow else {
            showTitle.stringValue = "Pick a podcast"
            showInfo.stringValue = ""
            subscribeButton.isHidden = true
            folderButton.isHidden = true
            return
        }
        showTitle.stringValue = s.title
        if Self.isPinned(s) {
            showInfo.stringValue = s == Self.continueShow
                ? countText(singular: "started episode")
                : "\(downloads.entries.count) episode\(downloads.entries.count == 1 ? "" : "s") · "
                  + ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file)
                  + (downloads.isBusy ? " · \(downloads.pending.count) coming in" : "")
            subscribeButton.isHidden = true
            folderButton.isHidden = s != Self.downloadsShow
            if s == Self.downloadsShow { showInfo.stringValue += " · in " + Self.shortPath(downloads.dir) }
            return
        }
        folderButton.isHidden = true
        showInfo.stringValue = [s.author, s.genre ?? "", allEpisodes.isEmpty ? "" : countText(singular: "episode")]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        subscribeButton.isHidden = false
        subscribeButton.isOn = library.isSubscribed(s)
        subscribeButton.label = library.isSubscribed(s) ? "Subscribed" : "Subscribe"
    }

    @objc private func subscribeTapped() {
        if let s = currentShow { toggleSubscription(s) }
    }

    private func toggleSubscription(_ s: PodcastShow) {
        guard !Self.isPinned(s) else { return }
        library.toggleSubscription(s)
        if currentShow?.feedURL == s.feedURL { updateHeader() }
        if showingSubscriptions {
            load()   // the list changes; setShows keeps the open show highlighted if it's still there
        } else {
            showsTable.reloadData()
        }
        status.stringValue = library.isSubscribed(s) ? "Subscribed to “\(s.title)”." : "Unsubscribed from “\(s.title)”."
    }

    private var selectedEpisodes: [PodcastEpisode] {
        episodesTable.selectedRowIndexes.filter { $0 < episodes.count }.map { episodes[$0] }
    }

    @objc private func playSelected() {
        let row = episodesTable.clickedRow >= 0 ? episodesTable.clickedRow : episodesTable.selectedRow
        guard row >= 0, row < episodes.count, let s = show(for: episodes[row]) else { return }
        let i = controller.addEpisode(episodes[row].track(show: s))
        controller.play(index: i)
        status.stringValue = "Playing “\(episodes[row].title)”."
    }

    @objc private func addSelected() {
        let eps = selectedEpisodes
        guard !eps.isEmpty else { return }
        // Oldest first, so a show plays in order.
        for e in eps.reversed() { if let s = show(for: e) { controller.addEpisode(e.track(show: s)) } }
        status.stringValue = eps.count == 1 ? "Added “\(eps[0].title)” to the playlist." : "Added \(eps.count) episodes to the playlist."
    }

    @objc private func togglePlayed() {
        let eps = selectedEpisodes
        guard !eps.isEmpty else { return }
        let makePlayed = !eps.allSatisfy { library.isPlayed($0.url) }
        library.markPlayed(eps.map(\.url), makePlayed)   // one save and one refresh for 500 episodes too
        if unplayedOnly { applyEpisodeFilter() } else {
            episodesTable.reloadData(forRowIndexes: episodesTable.selectedRowIndexes, columnIndexes: IndexSet(integersIn: 0..<6))
            updateNotes()
        }
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === showsTable ? shows.count : episodes.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CardRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        if tableView === showsTable {
            guard row < shows.count else { return nil }
            let v = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("show"), owner: nil) as? ShowCell) ?? ShowCell()
            v.identifier = NSUserInterfaceItemIdentifier("show")
            let s = shows[row]
            if s == Self.continueShow {
                let n = startedEpisodes().count
                v.showPinned(s, glyph: Fonts.Icon.play, subtitle: "\(n) started episode\(n == 1 ? "" : "s")")
            } else if s == Self.downloadsShow {
                let n = downloads.entries.count, busy = downloads.pending.count
                v.showPinned(s, glyph: Fonts.Icon.download, subtitle: "\(n) episode\(n == 1 ? "" : "s") · "
                             + ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file)
                             + (busy > 0 ? " · \(busy) coming in" : ""))
            } else {
                // Subscriptions also say how fresh the show is.
                let latest = showingSubscriptions ? library.cachedEpisodes(s).first?.published : nil
                v.show(s, newCount: library.newCount(s), subscribed: !showingSubscriptions && library.isSubscribed(s),
                       updated: latest.map { Self.relative($0) })
            }
            return v
        }
        guard row < episodes.count else { return nil }
        let e = episodes[row]
        if id == "mark" {
            let v = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: nil) as? EpisodeMarkView) ?? EpisodeMarkView()
            v.identifier = NSUserInterfaceItemIdentifier(id)
            v.state = mark(for: e)
            return v
        }
        if id == "art" {
            let v = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: nil) as? EpisodeArtCell) ?? EpisodeArtCell()
            v.identifier = NSUserInterfaceItemIdentifier(id)
            v.show(show(for: e).flatMap { e.artwork(show: $0) })
            return v
        }
        if id == "dl" {
            let v = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: nil) as? DownloadMarkView) ?? DownloadMarkView()
            v.identifier = NSUserInterfaceItemIdentifier(id)
            v.set(downloads.state(e.url), failure: downloads.failure(e.url))
            return v
        }
        // Text centered in the row, level with the thumbnail and marker.
        let host = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            v.identifier = NSUserInterfaceItemIdentifier(id)
            let f = NSTextField(labelWithString: "")
            f.lineBreakMode = .byTruncatingTail
            f.translatesAutoresizingMaskIntoConstraints = false
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.addSubview(f)
            v.textField = f
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: v.leadingAnchor), f.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                f.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            return v
        }()
        let cell = host.textField!
        let played = library.isPlayed(e.url)
        cell.alignment = .left
        switch id {
        case "title":
            cell.stringValue = e.title
            cell.font = Dash.font(13, played ? .regular : .medium)
            cell.textColor = played ? Dash.text3 : Dash.text
            cell.toolTip = notes.isHidden ? e.summary : nil   // the notes pane shows them when open
        case "date":
            cell.stringValue = e.published.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? ""
            cell.font = Dash.font(12)
            cell.textColor = Dash.text2
        default:
            cell.stringValue = TimeFormat.mmss(e.duration)
            cell.font = Dash.mono(11)
            cell.textColor = Dash.text2
            cell.alignment = .right
        }
        return host
    }
}

extension PodcastWindowController {
    /// "today", "yesterday", "3 days ago", "2 weeks ago"…
    static func relative(_ t: Double) -> String {
        let d = Date(timeIntervalSince1970: t)
        if Calendar.current.isDateInToday(d) { return "today" }
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        f.unitsStyle = .full
        return f.localizedString(for: Calendar.current.startOfDay(for: d), relativeTo: Calendar.current.startOfDay(for: Date()))
    }
}

/// A show in the list: cover, title, author, and a new-episode count for subscriptions.
final class ShowCell: NSView {
    private let art = ArtView()
    private let title = NSTextField(labelWithString: "")
    private let author = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var artwork: String?

    init() {
        super.init(frame: .zero)
        art.cornerRadius = 4
        art.placeholder = Fonts.Icon.podcast
        art.surface = Dash.cardRaised
        art.iconColor = Dash.text3
        for l in [title, author, badge] {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(l)
        }
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(art)
        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            art.centerYAnchor.constraint(equalTo: centerYAnchor),
            art.widthAnchor.constraint(equalToConstant: 40), art.heightAnchor.constraint(equalToConstant: 40),
            title.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            author.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            author.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            author.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Continue listening / Downloads: a glyph instead of a cover, a summary instead of the author.
    func showPinned(_ s: PodcastShow, glyph: String, subtitle: String) {
        show(s, newCount: 0, subscribed: false, updated: nil)
        art.placeholder = glyph
        author.stringValue = subtitle
    }

    func show(_ s: PodcastShow, newCount: Int, subscribed: Bool, updated: String? = nil) {
        art.placeholder = Fonts.Icon.podcast
        title.stringValue = s.title
        title.font = Dash.font(13, .semibold)
        title.textColor = Dash.text
        author.stringValue = [s.author, updated.map { "updated " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        author.font = Dash.font(11.5)
        author.textColor = Dash.text2
        badge.font = Dash.mono(10, bold: true)
        badge.textColor = Dash.accent
        badge.stringValue = newCount > 0 ? "● \(newCount) new" : (subscribed ? Fonts.Icon.rss : "")
        if subscribed, newCount == 0 { badge.font = Theme.icon(10); badge.textColor = Dash.text3 }
        let want = LogoStore.thumbnail(s.artwork)   // small file, small decode: the list shows 36 pt covers
        artwork = want
        art.image = LogoStore.shared.cached(want, size: .small)
        guard art.image == nil else { return }
        LogoStore.shared.load(want, size: .small) { [weak self] img in
            guard let self, self.artwork == want else { return }
            self.art.image = img
        }
    }
}
