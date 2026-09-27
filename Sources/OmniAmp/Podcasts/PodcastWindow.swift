import AppKit

/// Podcast browser in the modern look: top shows per country, search, subscriptions (with new-episode
/// counts), and the selected show's episodes. Episodes play like any track and remember their position.
final class PodcastWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let controller: PlayerController
    private let library = PodcastLibrary.shared
    private var topButton: ModernButton!
    private var subscribedButton: ModernButton!
    private var subscribeButton: ModernButton!
    private let search = NSSearchField()
    private let country = NSPopUpButton()
    private let showsTable = NSTableView()
    private let showsScroll = NSScrollView()
    private let episodesTable = NSTableView()
    private let episodesScroll = NSScrollView()
    private let showTitle = NSTextField(labelWithString: "")
    private let showInfo = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var shows: [PodcastShow] = []
    private var episodes: [PodcastEpisode] = []
    private var currentShow: PodcastShow?
    private var loadTask: Task<Void, Never>?
    private var episodesTask: Task<Void, Never>?
    private var showingSubscriptions: Bool
    private var themeObserver: NSObjectProtocol?

    private static let countries = RadioWindowController.countries.filter { !$0.1.isEmpty }

    init(controller: PlayerController) {
        self.controller = controller
        showingSubscriptions = !PodcastLibrary.shared.subscriptions.isEmpty
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
        themeObserver = NotificationCenter.default.addObserver(forName: Theme.changed, object: nil, queue: .main) { [weak self] _ in
            self?.build()
            self?.showsTable.reloadData()
            self?.episodesTable.reloadData()
        }
        load()
        refreshSubscriptions()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { themeObserver.map(NotificationCenter.default.removeObserver) }

    /// Opening the window again checks subscribed shows for new episodes.
    func windowDidBecomeKey(_ notification: Notification) { refreshSubscriptions() }

    // MARK: Layout

    private func column(_ id: String, _ width: CGFloat, flexible: Bool = false) -> NSTableColumn {
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        c.width = width
        c.resizingMask = flexible ? .autoresizingMask : []
        return c
    }

    private func style(_ table: NSTableView, _ scroll: NSScrollView, rowHeight: CGFloat) {
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.style = .plain
        table.gridStyleMask = []
        table.backgroundColor = Theme.lcd
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.lcd
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 4
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.black.cgColor
    }

    private func build() {
        window?.backgroundColor = Theme.background
        let title = NSTextField(labelWithString: "PODCASTS")
        title.font = Fonts.hack(10, bold: true)
        title.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)

        topButton = ModernButton(glyph: Fonts.Icon.podcast, label: "TOP", target: self, action: #selector(showTop))
        subscribedButton = ModernButton(glyph: Fonts.Icon.rss, label: "SUBSCRIBED", target: self, action: #selector(showSubscribed))
        for b in [topButton!, subscribedButton!] { b.glyphSize = 10 }
        topButton.isOn = !showingSubscriptions
        subscribedButton.isOn = showingSubscriptions

        search.placeholderString = "Search podcasts…"
        search.font = Fonts.hack(11)
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsWholeSearchString = true
        if country.numberOfItems == 0 {
            country.addItems(withTitles: Self.countries.map(\.0))
            let here = Locale.current.region?.identifier ?? "US"
            country.selectItem(at: Self.countries.firstIndex { $0.1 == here } ?? 0)
        }
        country.target = self
        country.action = #selector(countryChanged)
        country.font = Fonts.hack(11)

        if showsTable.tableColumns.isEmpty {
            showsTable.addTableColumn(column("show", 300, flexible: true))
            style(showsTable, showsScroll, rowHeight: 46)
            showsTable.action = #selector(showClicked)
            episodesTable.addTableColumn(column("mark", 16))
            episodesTable.addTableColumn(column("title", 300, flexible: true))
            episodesTable.addTableColumn(column("date", 92))
            episodesTable.addTableColumn(column("length", 62))
            style(episodesTable, episodesScroll, rowHeight: 26)
            episodesTable.allowsMultipleSelection = true
            episodesTable.doubleAction = #selector(playSelected)
        } else {
            for (t, s) in [(showsTable, showsScroll), (episodesTable, episodesScroll)] {
                t.backgroundColor = Theme.lcd
                s.backgroundColor = Theme.lcd
            }
        }

        showTitle.font = Fonts.hack(13, bold: true)
        showTitle.textColor = Theme.playlistText
        showTitle.lineBreakMode = .byTruncatingTail
        showTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        showInfo.font = Fonts.hack(10.5)
        showInfo.textColor = Theme.phosphorDim.blended(withFraction: 0.35, of: Theme.phosphor)
        showInfo.lineBreakMode = .byTruncatingTail
        showInfo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subscribeButton = ModernButton(glyph: Fonts.Icon.rss, label: "SUBSCRIBE", target: self, action: #selector(toggleSubscription))
        subscribeButton.glyphSize = 10
        subscribeButton.toolTip = "Subscribe: new episodes show up under SUBSCRIBED"

        status.font = Fonts.hack(10)
        status.textColor = Theme.phosphorDim.blended(withFraction: 0.4, of: Theme.phosphor)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let credit = NSButton(title: "Apple Podcasts", target: self, action: #selector(openCredit))
        credit.isBordered = false
        credit.attributedTitle = NSAttributedString(string: "directory: Apple Podcasts",
                                                    attributes: [.font: Fonts.hack(9), .foregroundColor: Theme.phosphorDim])
        let playedButton = ModernButton(glyph: Fonts.Icon.check, label: "PLAYED", target: self, action: #selector(togglePlayed))
        let add = ModernButton(glyph: Fonts.Icon.plus, label: "ADD", target: self, action: #selector(addSelected))
        let play = ModernButton(glyph: Fonts.Icon.play, label: "PLAY", target: self, action: #selector(playSelected))
        for b in [playedButton, add, play] { b.glyphSize = 10 }
        playedButton.toolTip = "Mark the selected episodes as played / unplayed"
        add.toolTip = "Add the selected episodes to the playlist"
        play.toolTip = "Play now (double-click)"

        let top = NSStackView(views: [topButton, subscribedButton, search, country])
        top.spacing = 6
        let header = NSStackView(views: [showTitle, NSView(), subscribeButton])
        header.spacing = 8
        let bottom = NSStackView(views: [status, NSView(), credit, playedButton, add, play])
        bottom.spacing = 6
        let root = NSView()
        for v in [title, top, showsScroll, header, showInfo, episodesScroll, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        for b in [topButton!, subscribedButton!, subscribeButton!, playedButton, add, play] { b.heightAnchor.constraint(equalToConstant: 22).isActive = true }
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let showsWidth = showsScroll.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.36)
        showsWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            title.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 34),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            showsScroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            showsScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            showsScroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),
            showsWidth,
            showsScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),

            header.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: showsScroll.trailingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            showInfo.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            showInfo.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            showInfo.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            episodesScroll.topAnchor.constraint(equalTo: showInfo.bottomAnchor, constant: 8),
            episodesScroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            episodesScroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            episodesScroll.bottomAnchor.constraint(equalTo: showsScroll.bottomAnchor),

            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window?.contentView = root
        updateHeader()
    }

    // MARK: Loading shows

    private var countryCode: String { Self.countries[max(0, country.indexOfSelectedItem)].1 }

    private func load() {
        loadTask?.cancel()
        topButton.isOn = !showingSubscriptions
        subscribedButton.isOn = showingSubscriptions
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        if showingSubscriptions {
            let lq = q.lowercased()
            shows = library.subscriptions.filter { lq.isEmpty || $0.title.lowercased().contains(lq) || $0.author.lowercased().contains(lq) }
            showsTable.reloadData()
            scrollToTop(showsScroll)
            status.stringValue = shows.isEmpty ? "No subscriptions yet: pick a show and press SUBSCRIBE." : "\(shows.count) subscriptions"
            selectFirstShowIfNeeded()
            return
        }
        status.stringValue = "Loading…"
        let cc = countryCode
        loadTask = Task { @MainActor in
            do {
                let list = q.isEmpty ? try await PodcastDirectory.shared.top(country: cc)
                                     : try await PodcastDirectory.shared.search(q, country: cc)
                guard !Task.isCancelled else { return }
                shows = list
                showsTable.reloadData()
                scrollToTop(showsScroll)
                status.stringValue = list.isEmpty ? "No podcasts found." : "\(list.count) podcasts" + (q.isEmpty ? " · top chart" : "")
                selectFirstShowIfNeeded()
            } catch {
                guard !Task.isCancelled else { return }
                status.stringValue = "Couldn't reach the podcast directory: \(error.localizedDescription)"
            }
        }
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
            if showingSubscriptions { showsTable.reloadData() }
            if let s = currentShow { episodes = library.cachedEpisodes(s); episodesTable.reloadData() }
        }
    }

    @objc private func showTop() { showingSubscriptions = false; load() }
    @objc private func showSubscribed() { showingSubscriptions = true; load() }
    @objc private func searchChanged() { load() }
    @objc private func countryChanged() { if !showingSubscriptions { load() } }
    @objc private func openCredit() { NSWorkspace.shared.open(URL(string: "https://podcasts.apple.com")!) }

    // MARK: Episodes

    @objc private func showClicked() {
        let r = showsTable.selectedRow
        guard r >= 0, r < shows.count, shows[r] != currentShow else { return }
        open(shows[r])
    }

    private func open(_ show: PodcastShow) {
        currentShow = show
        episodes = library.cachedEpisodes(show)
        episodesTable.reloadData()
        scrollToTop(episodesScroll)
        updateHeader()
        episodesTask?.cancel()
        if episodes.isEmpty { status.stringValue = "Loading episodes…" }
        episodesTask = Task { @MainActor in
            do {
                let eps = try await library.episodes(show)
                guard !Task.isCancelled, currentShow == show else { return }
                episodes = eps
                episodesTable.reloadData()
                updateHeader()
                status.stringValue = eps.isEmpty ? "This feed has no audio episodes." : "\(eps.count) episodes"
                // Seen: the new-episode marks stay until the next visit.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.library.markSeen(show)
                    self?.showsTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<(self?.shows.count ?? 0)), columnIndexes: [0])
                }
            } catch {
                guard !Task.isCancelled, currentShow == show else { return }
                status.stringValue = (episodes.isEmpty ? "Couldn't load this feed: " : "Showing saved episodes (offline): ") + error.localizedDescription
            }
        }
    }

    private func updateHeader() {
        guard let s = currentShow else {
            showTitle.stringValue = "Pick a podcast"
            showInfo.stringValue = ""
            subscribeButton.isHidden = true
            return
        }
        showTitle.stringValue = s.title
        showInfo.stringValue = [s.author, s.genre ?? "", episodes.isEmpty ? "" : "\(episodes.count) episodes"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        subscribeButton.isHidden = false
        subscribeButton.isOn = library.isSubscribed(s)
        subscribeButton.label = library.isSubscribed(s) ? "SUBSCRIBED" : "SUBSCRIBE"
    }

    @objc private func toggleSubscription() {
        guard let s = currentShow else { return }
        library.toggleSubscription(s)
        updateHeader()
        if showingSubscriptions { load() } else { showsTable.reloadData() }
        status.stringValue = library.isSubscribed(s) ? "Subscribed to “\(s.title)”." : "Unsubscribed from “\(s.title)”."
    }

    private var selectedEpisodes: [PodcastEpisode] {
        episodesTable.selectedRowIndexes.filter { $0 < episodes.count }.map { episodes[$0] }
    }

    @objc private func playSelected() {
        guard let s = currentShow else { return }
        let row = episodesTable.clickedRow >= 0 ? episodesTable.clickedRow : episodesTable.selectedRow
        guard row >= 0, row < episodes.count else { return }
        let i = controller.addEpisode(episodes[row].track(show: s))
        controller.play(index: i)
        status.stringValue = "Playing “\(episodes[row].title)”."
    }

    @objc private func addSelected() {
        guard let s = currentShow else { return }
        let eps = selectedEpisodes
        guard !eps.isEmpty else { return }
        // Oldest first, so a show plays in order.
        for e in eps.reversed() { controller.addEpisode(e.track(show: s)) }
        status.stringValue = eps.count == 1 ? "Added “\(eps[0].title)” to the playlist." : "Added \(eps.count) episodes to the playlist."
    }

    @objc private func togglePlayed() {
        let eps = selectedEpisodes
        guard !eps.isEmpty else { return }
        let makePlayed = !eps.allSatisfy { library.isPlayed($0.url) }
        for e in eps { library.markPlayed(e.url, makePlayed) }
        episodesTable.reloadData(forRowIndexes: episodesTable.selectedRowIndexes, columnIndexes: IndexSet(integersIn: 0..<4))
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === showsTable ? shows.count : episodes.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PlaylistRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        if tableView === showsTable {
            guard row < shows.count else { return nil }
            let v = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("show"), owner: nil) as? ShowCell) ?? ShowCell()
            v.identifier = NSUserInterfaceItemIdentifier("show")
            v.show(shows[row], newCount: library.newCount(shows[row]), subscribed: !showingSubscriptions && library.isSubscribed(shows[row]))
            return v
        }
        guard row < episodes.count else { return nil }
        let e = episodes[row]
        let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: nil) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = NSUserInterfaceItemIdentifier(id)
            f.lineBreakMode = .byTruncatingTail
            return f
        }()
        let played = library.isPlayed(e.url)
        let dim = Theme.phosphorDim.blended(withFraction: 0.35, of: Theme.phosphor)!
        cell.alignment = .left
        switch id {
        case "mark":
            cell.stringValue = played ? Fonts.Icon.check : ""
            cell.font = Theme.icon(10)
            cell.textColor = Theme.phosphorDim
            cell.alignment = .center
        case "title":
            cell.stringValue = e.title
            cell.font = Fonts.hack(12, bold: !played)
            cell.textColor = played ? dim : Theme.playlistText
            cell.toolTip = e.summary
        case "date":
            cell.stringValue = e.published.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? ""
            cell.font = Fonts.hack(10.5)
            cell.textColor = dim
        default:
            cell.stringValue = TimeFormat.mmss(e.duration)
            cell.font = Fonts.hack(10.5)
            cell.textColor = dim
            cell.alignment = .right
        }
        return cell
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
        art.cornerRadius = 3
        for l in [title, author, badge] {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(l)
        }
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(art)
        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            art.centerYAnchor.constraint(equalTo: centerYAnchor),
            art.widthAnchor.constraint(equalToConstant: 36), art.heightAnchor.constraint(equalToConstant: 36),
            title.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            author.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            author.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            author.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            badge.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ s: PodcastShow, newCount: Int, subscribed: Bool) {
        title.stringValue = s.title
        title.font = Fonts.hack(12, bold: true)
        title.textColor = Theme.playlistText
        author.stringValue = s.author
        author.font = Fonts.hack(10)
        author.textColor = Theme.phosphorDim.blended(withFraction: 0.35, of: Theme.phosphor)
        badge.font = Fonts.hack(10, bold: true)
        badge.textColor = Theme.phosphor
        badge.stringValue = newCount > 0 ? "● \(newCount) new" : (subscribed ? Fonts.Icon.rss : "")
        if subscribed, newCount == 0 { badge.font = Theme.icon(10); badge.textColor = Theme.phosphorDim }
        artwork = s.artwork
        art.image = LogoStore.shared.cached(s.artwork)
        guard art.image == nil else { return }
        let want = s.artwork
        LogoStore.shared.load(want) { [weak self] img in
            guard let self, self.artwork == want else { return }
            self.art.image = img
        }
    }
}
