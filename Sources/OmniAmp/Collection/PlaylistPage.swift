import AppKit

/// A saved playlist in the library: its songs in the playlist's own order (no sorting: the order is the point),
/// edited in place. Drag songs in from anywhere, drag rows to reorder, ⌫ removes, ⌥↑/⌥↓ move; every change is
/// written to the .m3u8 at once and can be undone.
@MainActor
final class PlaylistPage: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// Songs to play and the one to start at.
    var onPlay: (([Track], Int) -> Void)?
    var onAdd: (([Track]) -> Void)?
    /// Replace the player's playlist with this one and play it.
    var onLoad: ((URL) -> Void)?
    var onShowAlbum: ((LibraryTrack) -> Void)?
    var onRename: (() -> Void)?
    var onTrash: (() -> Void)?
    /// "Add to Playlist ▸ New Playlist…" on rows: the window makes it.
    var onNewPlaylist: (([Track]) -> Void)?
    var onAddToSaved: (([Track], URL) -> Void)?
    /// Keys the page leaves to the window (Space, Esc, typing, ← to the sidebar).
    var onKey: ((NSEvent) -> Bool)?
    /// The status line changed (what's listed or selected).
    var onSummary: (() -> Void)?

    private(set) var url: URL?
    private var doc = PlaylistDocument()
    private var rows: [PlaylistRow] = []
    private var generation = 0

    private let titleLabel = Dash.label("", Dash.font(22, .semibold), Dash.text)
    private let subtitle = Dash.label("", Dash.font(12), Dash.text2)
    private let table = KeyTableView()
    private let scroll = NSScrollView()
    private let empty = EmptyNotice()
    private let observers = Observers()
    private static let rowType = NSPasteboard.PasteboardType("com.microbot.omniamp.playlistRow")

    private enum Column: String, CaseIterable {
        case number, title, artist, album, length, format
        var title: String {
            switch self {
            case .number: "#"
            case .title: "Title"
            case .artist: "Artist"
            case .album: "Album"
            case .length: "Length"
            case .format: "Format"
            }
        }
        var width: CGFloat {
            switch self {
            case .number: 36
            case .title: 300
            case .artist: 170
            case .album: 190
            case .length: 60
            case .format: 90
            }
        }
        var rightAligned: Bool { self == .number || self == .length }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for c in Column.allCases {
            let col = ListLook.column(c.rawValue, c.width)
            col.title = c.title
            col.headerCell = DashHeaderCell(textCell: c.title)
            col.headerCell.alignment = c.rightAligned ? .right : .left
            col.minWidth = 30
            col.resizingMask = c == .title ? [.userResizingMask, .autoresizingMask] : [.userResizingMask]
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.allowsMultipleSelection = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.onKey = { [weak self] e in self?.key(e) ?? false }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.registerForDraggedTypes([.fileURL, LibraryDrag.pathsType, LibraryDrag.tracksType, Self.rowType])
        table.draggingDestinationFeedbackStyle = .gap
        Dash.applyList(table, in: scroll, rowHeight: 24)
        table.intercellSpacing = NSSize(width: 10, height: 0)
        table.headerView = DashHeaderView()
        table.cornerView = DashHeaderCorner()
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        table.autosaveName = "OmniAmpLibraryPlaylist"
        table.autosaveTableColumns = true
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        table.menu = rowMenu

        let play = Pill("Play", glyph: Fonts.Icon.play, target: self, action: #selector(playAll))
        play.prominent = true
        play.toolTip = "Add to the player's playlist and play"
        let add = Pill("Add", glyph: Fonts.Icon.plus, target: self, action: #selector(addAll))
        add.toolTip = "Add to the player's playlist"
        let load = Pill("Load", target: self, action: #selector(loadIntoPlayer))
        load.toolTip = "Replace the player's playlist with this one"
        let more = Pill("•••", target: self, action: #selector(showMore(_:)))
        more.toolTip = "Rename, Show in Finder, Move to Trash"
        let buttons = NSStackView(views: [play, add, load, more])
        buttons.spacing = 6
        // The names give way to the buttons when it's narrow (they truncate).
        for l in [titleLabel, subtitle] { l.setContentCompressionResistancePriority(.init(200), for: .horizontal) }
        empty.text = "Drag songs, albums or folders here, or onto the playlist's name in the sidebar.\n\n"
            + "Or right-click songs anywhere: Add to Playlist."
        for v in [titleLabel, subtitle, buttons, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
            subtitle.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.centerYAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -60),
        ])
        observers.add(NotificationCenter.default.addObserver(forName: SavedPlaylists.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playlistsChanged() }
        })
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Loading

    /// Shows a playlist (again: a refresh keeps the selection and scroll).
    func show(_ url: URL) {
        let same = self.url.map { SavedPlaylists.same($0, url) } ?? false
        self.url = url
        titleLabel.stringValue = SavedPlaylists.name(url)
        titleLabel.toolTip = url.path
        let selected = same ? table.selectedRowIndexes : []
        let topRow = same ? table.rows(in: table.visibleRect).location : 0
        apply(SavedPlaylists.shared.document(url), resolve: true)
        if !selected.isEmpty { table.selectRowIndexes(selected.filteredIndexSet { $0 < rows.count }, byExtendingSelection: false) }
        if !same { table.deselectAll(nil) }
        table.scrollRowToVisible(min(topRow, max(0, rows.count - 1)))
    }

    /// The library changed (tags, files found or gone): read the rows again.
    func libraryChanged() {
        if url != nil, !isHidden { resolveRows() }
    }

    /// A new document: rows it had already keep what was looked up for them, new ones show the playlist's own
    /// text until the lookup (library tags, files that are gone) is back.
    private func apply(_ newDoc: PlaylistDocument, resolve: Bool) {
        let base = url?.deletingLastPathComponent() ?? URL(exactPath: "/")
        let known = Dictionary(rows.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        let quick = PlaylistRow.resolve(newDoc, base: base, db: nil, checkFiles: false)
        let isNew = quick.contains { known[$0.itemID] == nil }
        doc = newDoc
        rows = quick.map { known[$0.itemID] ?? $0 }
        table.reloadData()
        updateHeader()
        if resolve || isNew { resolveRows() }
    }

    /// The library's tags and the files' presence, looked up off the main thread (a NAS answers slowly).
    private func resolveRows() {
        guard let url else { return }
        generation += 1
        let gen = generation, doc = self.doc, base = url.deletingLastPathComponent(), library = MusicCollection.hasFolders
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let db = library ? try? CollectionDB() : nil
            let resolved = PlaylistRow.resolve(doc, base: base, db: db, checkFiles: true)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    let byID = Dictionary(resolved.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
                    self.rows = self.rows.map { byID[$0.itemID] ?? $0 }
                    self.table.reloadData()
                    self.updateHeader()
                }
            }
        }
    }

    /// The folder changed: another playlist, a rename, or this one edited elsewhere (Finder, another app).
    private func playlistsChanged() {
        guard let url, SavedPlaylists.shared.urls.contains(where: { SavedPlaylists.same($0, url) }) else { return }
        let onDisk = SavedPlaylists.shared.document(url)
        if onDisk.text() != doc.text() { show(url) }
    }

    private func updateHeader() {
        let seconds = rows.compactMap(\.duration).reduce(0, +)
        let missing = rows.count { $0.missing }
        var parts = [rows.count == 1 ? "1 song" : "\(rows.count.formatted()) songs"]
        if seconds > 0 { parts.append(Self.span(seconds)) }
        if missing > 0 { parts.append("\(missing.formatted()) missing") }
        if doc.readOnly { parts.append(".pls: read only (Load it, then save it as a new playlist to edit it)") }
        subtitle.stringValue = parts.joined(separator: " · ")
        empty.isHidden = !rows.isEmpty
        onSummary?()
    }

    private static func span(_ s: Double) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(1, m)) min"
    }

    /// The status line: what's selected.
    var summary: String? {
        let sel = table.selectedRowIndexes.filter { $0 < rows.count }
        guard sel.count > 1 else { return nil }
        let secs = sel.compactMap { rows[$0].duration }.reduce(0, +)
        return "\(sel.count.formatted()) of \(rows.count.formatted()) songs selected · \(Self.span(secs))"
    }

    func focus() {
        window?.makeFirstResponder(table)
        if table.selectedRow < 0, !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func restyle() {
        table.reloadData()
        table.headerView?.needsDisplay = true
    }

    // MARK: Editing

    /// Writes the playlist and makes the change undoable (Edit → Undo, ⌘Z).
    private func commit(_ newDoc: PlaylistDocument, _ actionName: String) {
        guard let url, !doc.readOnly else { NSSound.beep(); return }
        let old = doc
        apply(newDoc, resolve: false)
        do { try SavedPlaylists.shared.write(newDoc, to: url) } catch {
            apply(old, resolve: false)
            NSAlert(error: error).runModal()
            return
        }
        guard let undo = window?.undoManager else { return }
        let written = newDoc.text()
        undo.registerUndo(withTarget: self) { page in
            MainActor.assumeIsolated {
                guard page.url.map({ SavedPlaylists.same($0, url) }) ?? false else { return }
                // Undo writes back a whole copy, so only while the file is still what this edit wrote: songs added
                // since from Tracks, the sidebar or another app would be lost, and a trashed playlist would come back.
                guard SavedPlaylists.shared.urls.contains(where: { SavedPlaylists.same($0, url) }),
                      SavedPlaylists.shared.document(url).text() == written else { NSSound.beep(); return }
                page.commit(old, actionName)
            }
        }
        undo.setActionName(actionName)
    }

    /// Songs added at a row (nil: the end).
    func insert(_ tracks: [Track], at row: Int? = nil) {
        guard !tracks.isEmpty else { return }
        var d = doc
        d.insert(tracks, at: row)
        commit(d, "Add to Playlist")
        let start = row ?? (rows.count - tracks.count)
        table.selectRowIndexes(IndexSet(start..<min(rows.count, start + tracks.count)), byExtendingSelection: false)
        table.scrollRowToVisible(start)
    }

    private func move(_ selection: IndexSet, to row: Int) {
        var d = doc
        let moved = d.move(selection, to: row)
        commit(d, "Move")
        table.selectRowIndexes(moved, byExtendingSelection: false)
        if let first = moved.first { table.scrollRowToVisible(first) }
    }

    @objc private func removeSelected() {
        let sel = table.selectedRowIndexes.filteredIndexSet { $0 < rows.count }
        guard !sel.isEmpty else { return }
        var d = doc
        d.remove(sel)
        commit(d, "Remove from Playlist")
        let next = min(sel.first ?? 0, rows.count - 1)
        if next >= 0 { table.selectRowIndexes([next], byExtendingSelection: false) }
    }

    // MARK: Playing

    private var selectedRows: [PlaylistRow] { table.selectedRowIndexes.filter { $0 < rows.count }.map { rows[$0] } }
    var selectedTracks: [Track] { selectedRows.compactMap(\.track) }

    /// One song: the playlist from there; several: those.
    private func playSelection() {
        let sel = table.selectedRowIndexes.filter { $0 < rows.count }
        if sel.count > 1 { onPlay?(sel.compactMap { rows[$0].track }, 0); return }
        play(from: sel.first ?? 0)
    }

    private func play(from row: Int) {
        let playable = rows.indices.filter { rows[$0].track != nil }
        guard !playable.isEmpty else { NSSound.beep(); return }
        let start = playable.firstIndex { $0 >= row } ?? 0
        onPlay?(playable.map { rows[$0].track! }, start)
    }

    @objc private func playAll() { play(from: 0) }

    /// The window's Play and Add buttons: the selected songs, or the whole playlist when none are.
    func playChosen() { if table.selectedRowIndexes.isEmpty { playAll() } else { playSelection() } }
    func addChosen() { onAdd?(table.selectedRowIndexes.isEmpty ? rows.compactMap(\.track) : selectedTracks) }
    @objc private func addAll() { onAdd?(rows.compactMap(\.track)) }
    @objc private func loadIntoPlayer() { if let url { onLoad?(url) } }
    @objc private func doubleClicked() { if table.clickedRow >= 0 { play(from: table.clickedRow) } }

    private func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        switch e.keyCode {
        case 36, 76:
            if mods == .option { onAdd?(selectedTracks); return true }
            guard mods.isEmpty else { return false }
            playSelection()
            return true
        case 51 where mods.isEmpty, 117 where mods.isEmpty:
            removeSelected()
            return true
        case 125 where mods == .option, 126 where mods == .option:
            let sel = table.selectedRowIndexes
            guard let first = sel.first, let last = sel.last else { return true }
            if e.keyCode == 126 { if first > 0 { move(sel, to: first - 1) } } else if last < rows.count - 1 { move(sel, to: last + 2) }
            return true
        default:
            return onKey?(e) ?? false
        }
    }

    // MARK: Menus

    @objc private func showMore(_ sender: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Rename…", action: #selector(rename), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(revealPlaylist), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to Trash", action: #selector(trash), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func rename() { onRename?() }
    @objc private func trash() { onTrash?() }
    @objc private func revealPlaylist() { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        window?.makeFirstResponder(table)
        func add(_ title: String, _ action: Selector) { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        add("Play", #selector(playSelected))
        menu.addItem(SavedPlaylists.shared.addMenuItem(target: self, current: #selector(addSelected), saved: #selector(addToSaved(_:)),
                                                       new: #selector(newPlaylist)))
        if !doc.readOnly { add("Remove from Playlist", #selector(removeSelected)) }
        menu.addItem(.separator())
        if table.selectedRowIndexes.count == 1, rows[row].library != nil { add("Show Album", #selector(showAlbum)) }
        add("Show in Finder", #selector(showInFinder))
    }

    @objc private func playSelected() { playSelection() }
    @objc private func addSelected() { onAdd?(selectedTracks) }
    @objc private func newPlaylist() { onNewPlaylist?(selectedTracks) }
    @objc private func addToSaved(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { onAddToSaved?(selectedTracks, u) }
    }
    @objc private func showAlbum() {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        if r >= 0, r < rows.count, let t = rows[r].library { onShowAlbum?(t) }
    }
    @objc private func showInFinder() {
        let urls = selectedTracks.filter { !$0.isRemote }.map { URL(exactPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { tableView.reusableRowView("cardRow", CardRowView.init) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let id = tableColumn?.identifier.rawValue, let c = Column(rawValue: id) else { return nil }
        let r = rows[row]
        let cell = libraryCell(tableView, "playlist." + id), f = cell.field
        f.font = Dash.font(12)
        f.textColor = r.missing ? Dash.text3 : Dash.text2
        f.alignment = c.rightAligned ? .right : .left
        f.toolTip = nil
        switch c {
        case .number:
            f.stringValue = String(row + 1)
            f.font = Dash.mono(10.5)
            f.textColor = Dash.text3
        case .title:
            f.stringValue = r.title
            f.font = Dash.font(13)
            f.textColor = r.missing || r.track == nil ? Dash.text3 : Dash.text
            if r.missing { f.toolTip = "Not found: \(doc.items.indices.contains(row) ? doc.items[row].ref : "")" }
            else if r.track == nil { f.toolTip = "OmniAmp can't play this format." }
        case .artist: f.stringValue = r.artist
        case .album: f.stringValue = r.album
        case .length:
            f.stringValue = r.duration.map(AlbumCell.length) ?? ""
            f.font = Dash.mono(11)
        case .format:
            f.stringValue = r.missing ? "Missing" : r.format
            f.font = Dash.mono(9.5)
            f.textColor = r.missing || r.track == nil ? Theme.warning : Dash.text3
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { onSummary?() }

    /// Dragging rows: within the list they move; out of it they're their files (the player, Finder, another playlist).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < rows.count else { return nil }
        let item = rows[row].track.map(LibraryDrag.item(for:)) ?? NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard !doc.readOnly else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return (info.draggingSource as? NSTableView) === tableView ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let pb = info.draggingPasteboard
        if (info.draggingSource as? NSTableView) === tableView {
            let moving = IndexSet((pb.pasteboardItems ?? []).compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) })
            guard !moving.isEmpty else { return false }
            move(moving, to: row)
            return true
        }
        let target = url
        LibraryDrag.droppedTracks(pb) { [weak self] tracks in
            guard let self, self.url == target else { return }
            self.insert(tracks, at: min(row, self.rows.count))
        }
        return true
    }
}
