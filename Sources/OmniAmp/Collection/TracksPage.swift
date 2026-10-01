import AppKit

/// Tracks: the whole library as one sortable list, like Winamp's, with each song's plays and when it last played
/// (Last.fm's history and OmniAmp's own, by song: every recording of it). Columns can be sorted (click a header, again to
/// reverse), resized, moved and hidden (right-click the header); the layout and the sort are remembered. Filters and
/// the search narrow the list. Return or a double-click plays (one track: its album from there; several: those),
/// ⌥Return adds, rows drag to the playlist.
///
/// Everything is read and sorted off the main thread (a connection of its own), so a 100,000-track library opens and
/// re-sorts without a stall; the table only draws the rows on screen. The library is read once (again when it
/// changes): a filter or a search narrows what's in memory (a search asks the index for its file ids).

/// A track as the list shows it, with its sort keys worked out once (folding strings for every comparison would be
/// most of a sort's cost).
/// A song's plays and the last one (UNIX time; 0: never).
struct PlayCount: Sendable, Equatable {
    var plays = 0
    var last = 0
}

struct TrackRow: Sendable {
    let track: LibraryTrack
    let genre: String
    let year: Int?
    let added: Double
    let artistKey: String
    /// The song's key (Keys.title).
    let titleKey: String
    /// Its plays are kept under who performs it (the track's artist, not the album's: a compilation's tracks are
    /// "Various Artists" in the library but their own artist on last.fm) and the song. Worked out once (sorting by
    /// plays looks it up in every comparison).
    let countKey: String
    /// Its release: official (album, single, live album) or not, lossless (what the filters look at).
    var official = true
    var lossless = false
    /// Its album has more than one disc: the track number shows the disc ("2-05").
    var multiDisc = false
    let artistSort: String, albumSort: String, titleSort: String, genreSort: String

    /// `keys`: sort keys already worked out for this artist, album and genre (they repeat: each is folded once).
    /// `performerKey`: Keys.artist of the track's own artist (worked out once per artist by the caller).
    init(track: LibraryTrack, genre: String, year: Int?, added: Double, artistKey: String, titleKey: String? = nil,
         performerKey: String? = nil, keys: (artist: String, album: String, genre: String)? = nil) {
        self.track = track
        self.genre = genre
        self.year = year
        self.added = added
        self.artistKey = artistKey
        self.titleKey = titleKey ?? Keys.title(track.title)
        countKey = (performerKey ?? Keys.artist(track.artist)) + "\u{1}" + self.titleKey
        artistSort = keys?.artist ?? Self.sortKey(Keys.sortName(track.artist))
        albumSort = keys?.album ?? Self.sortKey(track.album)
        titleSort = Self.sortKey(track.title)
        genreSort = keys?.genre ?? Self.sortKey(genre)
    }

    /// Case and accents don't count ("Björk" by "bjork"). Cheaper than `Keys.fold` (it runs for every track).
    static func sortKey(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// What the filters let through; `ids`: a search's files (nil: no search).
    static func visible(_ rows: [TrackRow], filter: LibraryFilter, ids: Set<Int64>?) -> [TrackRow] {
        if filter == LibraryFilter(), ids == nil { return rows }
        return rows.filter { r in
            switch filter.scope {
            case .all: break
            case .official: if !r.official { return false }
            case .unofficial: if r.official { return false }
            }
            if filter.losslessOnly, !r.lossless { return false }
            return ids?.contains(r.track.id) ?? true
        }
    }

    var trackNumber: String {
        guard let n = track.number else { return "" }
        return multiDisc ? "\(track.disc ?? 1)-" + String(format: "%02d", n) : String(n)
    }
}

/// The list's columns. The ids are kept in the user's defaults (the table's saved layout): never rename one.
enum TrackColumn: String, CaseIterable, Sendable {
    case length, title, artist, album, track, genre, year, format, added, plays, lastPlayed

    var title: String {
        switch self {
        case .length: "Length"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .track: "Track"
        case .genre: "Genre"
        case .year: "Year"
        case .format: "Format"
        case .added: "Added"
        case .plays: "Plays"
        case .lastPlayed: "Last Played"
        }
    }
    var width: CGFloat {
        switch self {
        case .length: 52
        case .title: 250
        case .artist: 170
        case .album: 200
        case .track: 44
        case .genre: 130
        case .year: 44
        case .format: 82
        case .added: 84
        case .plays: 46
        case .lastPlayed: 96
        }
    }
    /// Numbers read best right-aligned.
    var rightAligned: Bool { [.length, .track, .year, .plays].contains(self) }
    /// The text columns share the width the list has (so it fits without scrolling sideways); the rest keep theirs.
    var stretches: Bool { [.title, .artist, .album, .genre].contains(self) }
}

/// How the list is sorted: a column, either way. Ties (and the Artist column itself) fall back to artist, album,
/// disc, track, as Winamp does; empty values go last whichever way.
struct TrackSort: Equatable, Sendable {
    var column: TrackColumn = .artist
    var ascending = true

    /// "artist:asc" (the pref's form).
    init(column: TrackColumn = .artist, ascending: Bool = true) { self.column = column; self.ascending = ascending }
    init?(pref: String?) {
        guard let parts = pref?.split(separator: ":"), parts.count == 2, let c = TrackColumn(rawValue: String(parts[0])) else { return nil }
        self.init(column: c, ascending: parts[1] != "desc")
    }
    var pref: String { column.rawValue + (ascending ? ":asc" : ":desc") }

    /// `counts`: plays per song (TrackRow.countKey), for the Plays and Last Played columns.
    func sorted(_ rows: [TrackRow], counts: [String: PlayCount] = [:]) -> [TrackRow] {
        rows.sorted { a, b in
            let c = primary(a, b, counts)
            if c != 0 { return ascending ? c < 0 : c > 0 }
            return Self.natural(a, b)
        }
    }

    /// -1, 0 or 1 by the column; a missing value after a present one either way (so it's flipped back for descending).
    private func primary(_ a: TrackRow, _ b: TrackRow, _ counts: [String: PlayCount]) -> Int {
        func str(_ x: String, _ y: String) -> Int {
            if x.isEmpty != y.isEmpty { return (x.isEmpty ? 1 : -1) * (ascending ? 1 : -1) }
            return x < y ? -1 : x > y ? 1 : 0
        }
        func num<T: Comparable>(_ x: T?, _ y: T?) -> Int {
            switch (x, y) {
            case (nil, nil): return 0
            case (nil, _): return ascending ? 1 : -1
            case (_, nil): return ascending ? -1 : 1
            case let (x?, y?): return x < y ? -1 : x > y ? 1 : 0
            }
        }
        switch column {
        case .artist: return str(a.artistSort, b.artistSort)
        case .title: return str(a.titleSort, b.titleSort)
        case .album: return str(a.albumSort, b.albumSort)
        case .genre: return str(a.genreSort, b.genreSort)
        case .format: return str(a.track.format, b.track.format)
        case .length: return num(a.track.duration, b.track.duration)
        case .year: return num(a.year, b.year)
        case .added: return num(a.added > 0 ? a.added : nil, b.added > 0 ? b.added : nil)
        case .track:
            let d = num(a.track.disc ?? 1, b.track.disc ?? 1)
            return d != 0 ? d : num(a.track.number, b.track.number)
        case .plays: return num(counts[a.countKey]?.plays ?? 0, counts[b.countKey]?.plays ?? 0)
        case .lastPlayed:
            // Never played: last, either way.
            let x = counts[a.countKey]?.last ?? 0, y = counts[b.countKey]?.last ?? 0
            return num(x > 0 ? x : nil, y > 0 ? y : nil)
        }
    }

    /// Artist, album (two albums of one name kept apart), disc, track, then the file name.
    static func natural(_ a: TrackRow, _ b: TrackRow) -> Bool {
        if a.artistSort != b.artistSort { return a.artistSort.isEmpty != b.artistSort.isEmpty ? b.artistSort.isEmpty : a.artistSort < b.artistSort }
        if a.albumSort != b.albumSort { return a.albumSort < b.albumSort }
        if a.track.albumKey != b.track.albumKey { return a.track.albumKey < b.track.albumKey }
        let da = a.track.disc ?? 1, db = b.track.disc ?? 1
        if da != db { return da < db }
        let na = a.track.number ?? .max, nb = b.track.number ?? .max
        if na != nb { return na < nb }
        return a.track.path < b.track.path
    }
}

@MainActor
final class TracksPage: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// Tracks to play and the one to start at (several selected: those).
    var onPlay: (([LibraryTrack], Int) -> Void)?
    /// One track: its album, from that track.
    var onPlayAlbum: ((TrackRow) -> Void)?
    var onAdd: (([LibraryTrack]) -> Void)?
    var onReplace: (([LibraryTrack]) -> Void)?
    var onShowAlbum: ((TrackRow) -> Void)?
    var onArtist: ((String) -> Void)?
    /// All recordings of a song: artist key, title key.
    var onVersions: ((String, String) -> Void)?
    /// Keys the page leaves to the window (Space, Esc, typing, ← to the sidebar).
    var onKey: ((NSEvent) -> Bool)?
    /// The status line changed (what's listed or selected).
    var onSummary: (() -> Void)?

    private let table = KeyTableView()
    private let scroll = NSScrollView()
    private let empty = EmptyNotice()
    /// Every track, sorted by `allSort`; `rows` is what the filters and the search let through of it.
    private var all: [TrackRow] = []
    private var allSort: TrackSort?
    private var rows: [TrackRow] = []
    /// How long `rows` play, worked out when they're set (the status line asks on every selection change).
    private var rowsSeconds: Double = 0
    /// Bumped by every library change; `all` was read at `readVersion` (stale while they differ).
    private var libraryVersion = 0
    private var readVersion = -1
    private var sort = TrackSort(pref: UserDefaults.standard.string(forKey: Pref.libraryTracksSort)) ?? TrackSort()
    private var filter = LibraryFilter()
    private var query = ""
    private var generation = 0
    private var loaded = false
    private var emptyText = ""
    /// Plays per song, read after the list is on screen (never holding it up), again when the history changes.
    private var counts: [String: PlayCount] = [:]
    /// Counts to read the next time the list is shown: never read yet, or the history changed while it was hidden.
    private var countsDirty = true
    private let observers = Observers()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for c in TrackColumn.allCases {
            let col = ListLook.column(c.rawValue, c.width)
            col.title = c.title
            col.headerCell = DashHeaderCell(textCell: c.title)
            col.headerCell.alignment = c.rightAligned ? .right : .left
            col.minWidth = 36
            col.resizingMask = c.stretches ? [.userResizingMask, .autoresizingMask] : [.userResizingMask]
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.onKey = { [weak self] e in self?.key(e) ?? false }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        Dash.applyList(table, in: scroll, rowHeight: 24)
        table.intercellSpacing = NSSize(width: 10, height: 0)
        table.headerView = DashHeaderView()
        table.cornerView = nil
        scroll.hasHorizontalScroller = true
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        // Widths, order and hidden columns, as the user left them (after the columns exist).
        table.autosaveName = "OmniAmpLibraryTracks"
        table.autosaveTableColumns = true
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(TrackColumn.title.rawValue))?.isHidden = false   // never hidden
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        table.menu = rowMenu
        observers.add(NotificationCenter.default.addObserver(forName: ListeningHistory.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Hidden (another section, the window closed): read when it's shown again, not on every import page.
                if self.loaded, !self.isHidden, self.window?.isVisible == true { self.readCounts() } else { self.countsDirty = true }
            }
        })
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        table.headerView?.menu = headerMenu
        showSortIndicator()
        empty.isHidden = true
        for v in [scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Loading

    /// The library has new, changed or removed files: read it again the next time the list is shown.
    func libraryChanged() { libraryVersion += 1 }

    /// The list for this filter and search, the selection kept by track.
    func reload(filter: LibraryFilter, query: String, emptyText: String) {
        self.emptyText = emptyText
        self.filter = filter
        self.query = query.trimmingCharacters(in: .whitespaces)
        refresh()
    }

    /// The one way the list changes (filter, search, sort, new files, new counts): worked out in the background from
    /// what's known (the library read again only when it changed, sorted again only when the order did), then shown.
    /// A newer refresh replaces one still running and starts from the same state, so nothing asked for is lost.
    private func refresh(revealSelection: Bool = false) {
        generation += 1
        let gen = generation, sort = sort, q = query, filter = filter, counts = counts, version = libraryVersion
        let known = readVersion == libraryVersion ? all : nil
        let inOrder = known != nil && allSort == sort
        if !loaded { showEmpty("Loading…") }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let db = known == nil || !q.isEmpty ? try? CollectionDB() : nil
            let everything: [TrackRow]
            if let known {
                everything = inOrder ? known : sort.sorted(known, counts: counts)
            } else {
                everything = sort.sorted((try? db?.trackRows()) ?? [], counts: counts)
            }
            let ids = q.isEmpty ? nil : ((try? db?.fileIDs(matching: q)) ?? [])
            let list = TrackRow.visible(everything, filter: filter, ids: ids)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.all = everything
                self.allSort = sort
                if known == nil { self.readVersion = version }   // a change during the read: read again next time
                self.show(list)
                if revealSelection, let first = self.table.selectedRowIndexes.first { self.table.scrollRowToVisible(first) }
                if self.countsDirty { self.readCounts() }
            }
        }
    }

    /// Plays per song, in the background. Sorted by plays: sorted again; else just those columns redrawn.
    private func readCounts() {
        countsDirty = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let c = (try? CollectionDB().playCounts()) ?? [:]
            DispatchQueue.main.async { [weak self] in
                guard let self, c != self.counts else { return }
                self.counts = c
                if self.sort.column == .plays || self.sort.column == .lastPlayed {
                    self.allSort = nil
                    self.refresh()
                } else {
                    let cols = [TrackColumn.plays, .lastPlayed].map { self.table.column(withIdentifier: NSUserInterfaceItemIdentifier($0.rawValue)) }
                    self.table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<self.rows.count), columnIndexes: IndexSet(cols.filter { $0 >= 0 }))
                }
            }
        }
    }

    private func show(_ list: [TrackRow]) {
        let keep = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].track.id : nil })
        let first = !loaded
        rows = list
        rowsSeconds = list.reduce(0) { $0 + ($1.track.duration ?? 0) }
        loaded = true
        table.reloadData()
        if first {
            // Fitted to the width, from the left (the header sits over the content: only x is reset).
            table.sizeToFit()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let again = IndexSet(rows.indices.filter { keep.contains(rows[$0].track.id) })
        table.selectRowIndexes(again, byExtendingSelection: false)
        showEmpty(rows.isEmpty ? emptyText : nil)
        onSummary?()
    }

    private func showEmpty(_ text: String?) {
        empty.text = text ?? ""
        empty.isHidden = text == nil || text!.isEmpty
    }

    /// Sorted another way (in the refresh, with the filter and search as they are), the first selected row in view.
    private func resort(_ s: TrackSort) {
        sort = s
        UserDefaults.standard.set(s.pref, forKey: Pref.libraryTracksSort)
        showSortIndicator()
        refresh(revealSelection: true)
    }

    private func showSortIndicator() {
        for col in table.tableColumns {
            guard let cell = col.headerCell as? DashHeaderCell else { continue }
            cell.sortedAscending = col.identifier.rawValue == sort.column.rawValue ? sort.ascending : nil
        }
        table.headerView?.needsDisplay = true
    }

    // MARK: What's listed

    var isEmpty: Bool { rows.isEmpty }

    /// "8,945 tracks · 25.8 days", or what's selected of them.
    var summary: String? {
        guard loaded else { return nil }
        let sel = table.selectedRowIndexes.filter { $0 < rows.count }
        let seconds = sel.count > 1 ? sel.reduce(0) { $0 + (rows[$1].track.duration ?? 0) } : rowsSeconds
        let time = seconds >= 86400 ? String(format: "%.1f days", seconds / 86400)
            : seconds >= 3600 ? String(format: "%.1f hours", seconds / 3600) : AlbumCell.length(seconds)
        let n = rows.count == 1 ? "1 track" : "\(rows.count.formatted()) tracks"
        return sel.count > 1 ? "\(sel.count.formatted()) of \(n) selected · \(time)" : "\(n) · \(time)"
    }

    /// What Play and Add act on: the selected tracks, in the list's order.
    var selectedTracks: [LibraryTrack] { table.selectedRowIndexes.filter { $0 < rows.count }.map { rows[$0].track } }

    func focus() {
        window?.makeFirstResponder(table)
        if table.selectedRow < 0, !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func restyle() {
        table.reloadData()
        table.headerView?.needsDisplay = true
    }

    // MARK: Playing

    /// One track: its album from there; several: those.
    private func play() {
        let sel = table.selectedRowIndexes.filter { $0 < rows.count }
        if sel.count == 1 { onPlayAlbum?(rows[sel[0]]) } else if !sel.isEmpty { onPlay?(sel.map { rows[$0].track }, 0) }
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        play()
    }

    private func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        switch e.keyCode {
        case 36, 76:
            if mods == .option { onAdd?(selectedTracks); return true }
            guard mods.isEmpty else { return false }
            play()
            return true
        default:
            return onKey?(e) ?? false
        }
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === table.headerView?.menu {
            // Show or hide columns (not Title: a list needs something to read).
            for c in TrackColumn.allCases where c != .title {
                let item = menu.addItem(withTitle: c.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = c.rawValue
                item.state = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(c.rawValue))?.isHidden == false ? .on : .off
            }
            return
        }
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        window?.makeFirstResponder(table)
        func add(_ title: String, _ action: Selector) { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        add("Play", #selector(playSelected))
        add("Add to Playlist", #selector(addSelected))
        add("Replace Playlist and Play", #selector(replaceSelected))
        menu.addItem(.separator())
        if table.selectedRowIndexes.count == 1 {
            add("Show Album", #selector(showAlbum))
            add("Artist Page", #selector(artistPage))
            add("Show All Versions", #selector(versions))
        }
        add("Show in Finder", #selector(showInFinder))
    }

    private var clicked: TrackRow? {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return r >= 0 && r < rows.count ? rows[r] : nil
    }

    @objc private func playSelected() { play() }
    @objc private func addSelected() { onAdd?(selectedTracks) }
    @objc private func replaceSelected() { onReplace?(selectedTracks) }
    @objc private func showAlbum() { if let r = clicked { onShowAlbum?(r) } }
    @objc private func artistPage() { if let r = clicked { onArtist?(r.artistKey) } }
    @objc private func versions() { if let r = clicked { onVersions?(r.artistKey, Keys.title(r.track.title)) } }
    @objc private func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting(selectedTracks.map { URL(exactPath: $0.path) }) }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let col = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return }
        col.isHidden.toggle()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CardRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let id = tableColumn?.identifier.rawValue, let c = TrackColumn(rawValue: id) else { return nil }
        let r = rows[row], t = r.track
        let cell = libraryCell(tableView, "tracks." + id), f = cell.field
        f.font = Dash.font(12)
        f.textColor = Dash.text2
        f.alignment = c.rightAligned ? .right : .left
        f.toolTip = nil
        switch c {
        case .length:
            f.stringValue = t.duration.map(AlbumCell.length) ?? ""
            f.font = Dash.mono(11)
        case .title:
            f.stringValue = t.title
            f.font = Dash.font(13)
            f.textColor = t.playable ? Dash.text : Dash.text3
            if !t.playable { f.toolTip = "OmniAmp can't play this format. Convert it to FLAC to play it." }
        case .artist: f.stringValue = t.artist
        case .album: f.stringValue = t.album
        case .track:
            f.stringValue = r.trackNumber
            f.font = Dash.mono(11)
            f.textColor = Dash.text3
        case .genre: f.stringValue = r.genre
        case .year:
            f.stringValue = r.year.map(String.init) ?? ""
            f.font = Dash.mono(11)
            f.textColor = Dash.text3
        case .format:
            f.stringValue = t.format
            f.font = Dash.mono(9.5)
            f.textColor = t.playable ? Dash.text3 : Theme.warning
        case .added:
            f.stringValue = r.added > 0 ? Self.day.string(from: Date(timeIntervalSince1970: r.added)) : ""
            f.font = Dash.mono(11)
            f.textColor = Dash.text3
        case .plays:
            let n = counts[r.countKey]?.plays ?? 0
            f.stringValue = n > 0 ? n.formatted() : ""
            f.font = Dash.mono(11)
            // Counted by song: a live recording shows the studio one's plays too.
            if n > 0 { f.toolTip = "\(n.formatted()) play\(n == 1 ? "" : "s") of this song (every recording)" }
        case .lastPlayed:
            let last = counts[r.countKey]?.last ?? 0
            let when = Date(timeIntervalSince1970: TimeInterval(last))
            f.stringValue = last > 0 ? Self.ago.localizedString(for: when, relativeTo: Date()) : ""
            f.toolTip = last > 0 ? when.formatted(date: .long, time: .shortened) : nil
            f.textColor = Dash.text3
        }
        return cell
    }

    private static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// A header click sorts by that column; again, the other way.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let c = TrackColumn(rawValue: tableColumn.identifier.rawValue) else { return }
        resort(c == sort.column ? TrackSort(column: c, ascending: !sort.ascending) : TrackSort(column: c))
    }

    func tableViewSelectionDidChange(_ notification: Notification) { onSummary?() }

    /// Dragging tracks out (to the playlist, or Finder): their files.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        row < rows.count ? URL(exactPath: rows[row].track.path) as NSURL : nil
    }
}

// MARK: - Header

/// The list's column header in the library's colors (the system one is a light bar): the card color, a hairline
/// under it, the sorted column's arrow.
final class DashHeaderView: NSTableHeaderView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        self.frame.size.height = 24
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Dash.card.setFill()
        bounds.fill()
        super.draw(dirtyRect)
        Dash.border.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

final class DashHeaderCell: NSTableHeaderCell {
    /// Sorted by this column: which way; nil when it isn't.
    var sortedAscending: Bool?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Dash.card.setFill()
        cellFrame.fill()
        // A faint divider between columns.
        Dash.border.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 6, width: 1, height: cellFrame.height - 12).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let arrow = sortedAscending.map { $0 ? "▲" : "▼" }
        let font = Dash.font(11, sortedAscending == nil ? .medium : .semibold)
        let color = sortedAscending == nil ? Dash.text3 : Dash.text2
        let title = NSAttributedString(string: stringValue, attributes: [.font: font, .foregroundColor: color])
        let mark = arrow.map { NSAttributedString(string: $0, attributes: [.font: Dash.font(7), .foregroundColor: Dash.text2]) }
        let markW = mark.map { $0.size().width + 4 } ?? 0
        let room = cellFrame.insetBy(dx: 5, dy: 0)
        let size = title.size()
        let textW = min(size.width, room.width - markW)
        let x = alignment == .right ? room.maxX - textW - markW : room.minX
        let y = cellFrame.midY - size.height / 2
        title.draw(with: NSRect(x: x, y: y, width: textW, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let mark {
            let ms = mark.size()
            mark.draw(at: NSPoint(x: x + textW + 4, y: cellFrame.midY - ms.height / 2))
        }
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {}
}
