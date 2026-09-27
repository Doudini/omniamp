import AppKit

/// The resizable, native "modern" look.
final class ModernWindowController: NSWindowController, NSWindowDelegate, PlayerUI {
    private let controller: PlayerController
    private let panel = ModernPanelView()
    private let eqView = ModernEQView()
    private let infoView = ModernInfoView()
    /// One drawer slot under the panel, shared by EQ and INFO (only one is open at a time).
    private let drawerHost = NSView()
    private var drawerHeight: NSLayoutConstraint!
    private var drawerGap: NSLayoutConstraint!
    private enum Drawer: String { case none, eq, info }
    private var drawer: Drawer {
        get {
            if let s = UserDefaults.standard.string(forKey: "modernDrawer"), let d = Drawer(rawValue: s) { return d }
            return UserDefaults.standard.bool(forKey: "modernEQVisible") ? .eq : .none
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "modernDrawer") }
    }
    /// Track shown in INFO when the user picked one in the playlist (stable ID); nil = follow playback.
    private var pinnedInfoID: Int?
    private let table = PlaylistTableView()
    private let scroll = NSScrollView()
    private let filterField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private var clock: DisplayClock!
    private var addBtn: ModernButton!
    private var clrBtn: ModernButton!
    private var tick = 0
    var onClose: (() -> Void)?
    /// Right-click menu for the playlist (built by the app delegate).
    var playlistMenu: (() -> NSMenu)?
    private static let rowType = NSPasteboard.PasteboardType("com.omniamp.rows")

    private static let colNum = NSUserInterfaceItemIdentifier("num")
    private static let colTitle = NSUserInterfaceItemIdentifier("title")
    private static let colTime = NSUserInterfaceItemIdentifier("time")

    init(controller: PlayerController) {
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "OmniAmp"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.background
        window.minSize = NSSize(width: 360, height: 340)
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("OmniAmpMain") { window.center() }
        window.setFrameAutosaveName("OmniAmpMain")
        buildUI()
        panel.controller = controller
        eqView.controller = controller
        infoView.controller = controller
        infoView.onReveal = { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) }
        panel.onToggleEQ = { [weak self] in self?.toggle(.eq) }
        panel.onToggleInfo = { [weak self] in self?.pinnedInfoID = nil; self?.toggle(.info) }
        panel.onArtClick = { [weak self] in self?.artClicked() }
        windowDidResize(Notification(name: NSWindow.didResizeNotification))
        applyDrawer()
        eqView.refresh()
        controller.ui = self
        playlistDidReload()
        panel.refreshTrackInfo()
        panel.refreshOptions()
        if let c = controller.currentIndex, let r = controller.row(forTrackIndex: c) {
            table.selectRowIndexes([r], byExtendingSelection: false)
            DispatchQueue.main.async { self.table.scrollRowToVisible(r) }
        }
        clock = DisplayClock(player: controller.player) { [weak self] in self?.uiTick() }
        clock.track([window])
        panel.refresh(tick: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        let root = DropView()
        root.onDrop = { [weak self] urls in self?.controller.add(urls) }
        window?.contentView = root

        // Window title drawn by us inside the panel area (the titlebar is transparent).
        let titleLabel = NSTextField(labelWithString: "OMNIAMP")
        titleLabel.font = Fonts.hack(10, bold: true)
        titleLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        panel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(panel)
        root.addSubview(titleLabel)

        table.headerView = nil
        table.backgroundColor = .black
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.allowsMultipleSelection = true
        table.style = .plain
        table.gridStyleMask = []
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClick)
        table.onActivate = { [weak self] in self?.playSelected() }
        table.onDelete = { [weak self] in self?.removeSelected() }
        table.onMove = { [weak self] d in self?.moveSelection(by: d) }
        table.contextMenu = { [weak self] in self?.playlistMenu?() }
        table.registerForDraggedTypes([.fileURL, Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap

        // Only the title column stretches with the window.
        let cNum = NSTableColumn(identifier: Self.colNum); cNum.width = 52; cNum.resizingMask = []
        let cTitle = NSTableColumn(identifier: Self.colTitle); cTitle.width = 300; cTitle.resizingMask = .autoresizingMask
        let cTime = NSTableColumn(identifier: Self.colTime); cTime.width = 84; cTime.resizingMask = []
        [cNum, cTitle, cTime].forEach(table.addTableColumn)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        cTitle.minWidth = 60
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
            self?.fitColumns()
        }
        scroll.postsFrameChangedNotifications = true

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 4
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.black.cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        drawerHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(drawerHost)
        for v in [eqView, infoView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            drawerHost.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: drawerHost.topAnchor), v.bottomAnchor.constraint(equalTo: drawerHost.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: drawerHost.leadingAnchor), v.trailingAnchor.constraint(equalTo: drawerHost.trailingAnchor),
            ])
        }

        filterField.placeholderString = "Jump to…  (J)"
        filterField.font = Fonts.hack(11)
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.sendsSearchStringImmediately = true
        filterField.delegate = self
        filterField.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(filterField)

        statusLabel.font = Fonts.hack(10)
        statusLabel.textColor = Theme.playlistText
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.lineBreakMode = .byTruncatingHead
        root.addSubview(statusLabel)

        addBtn = ModernButton(glyph: Fonts.Icon.plus, label: "ADD", target: self, action: #selector(addTapped))
        clrBtn = ModernButton(glyph: Fonts.Icon.trash, label: "CLEAR", target: self, action: #selector(clearTapped))
        addBtn.glyphSize = 10; clrBtn.glyphSize = 10
        root.addSubview(addBtn)
        root.addSubview(clrBtn)

        let titlebarHeight: CGFloat = 28
        drawerHeight = drawerHost.heightAnchor.constraint(equalToConstant: 0)
        drawerGap = scroll.topAnchor.constraint(equalTo: drawerHost.bottomAnchor, constant: 0)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),

            panel.topAnchor.constraint(equalTo: root.topAnchor, constant: 0),
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            drawerHost.topAnchor.constraint(equalTo: panel.bottomAnchor, constant: 8),
            drawerHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            drawerHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            drawerHeight,
            drawerGap,
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: filterField.topAnchor, constant: -8),

            addBtn.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            addBtn.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            addBtn.heightAnchor.constraint(equalToConstant: 22),
            clrBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: 4),
            clrBtn.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            clrBtn.heightAnchor.constraint(equalToConstant: 22),

            filterField.leadingAnchor.constraint(equalTo: clrBtn.trailingAnchor, constant: 10),
            filterField.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            filterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

            statusLabel.leadingAnchor.constraint(equalTo: filterField.trailingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
        ])
        // Push the panel's content below the transparent titlebar.
        panel.topInset = titlebarHeight
    }

    /// The title column takes whatever width is left, so the number and time columns always stay visible.
    /// Bottom bar: icon-only ADD/CLEAR in narrow windows.
    func windowDidResize(_ notification: Notification) {
        // Also fires while the saved frame is restored in init, before the UI exists.
        let narrow = (window?.frame.width ?? 600) < 520
        addBtn?.compact = narrow
        clrBtn?.compact = narrow
        infoView.compact = narrow
    }

    private func fitColumns() {
        guard table.tableColumns.count == 3 else { return }
        let fixed = table.tableColumns[0].width + table.tableColumns[2].width + table.intercellSpacing.width * 3
        let w = max(table.tableColumns[1].minWidth, scroll.contentSize.width - fixed)
        if abs(table.tableColumns[1].width - w) > 0.5 { table.tableColumns[1].width = w }
    }

    // MARK: PlayerUI

    func playlistDidReload() {
        table.reloadData()
        updateStatus()
    }

    func playlistRowsDidUpdate(_ trackIndices: IndexSet) {
        if controller.visible == nil {
            table.reloadData(forRowIndexes: trackIndices.filteredIndexSet { $0 < table.numberOfRows },
                             columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        } else {
            table.reloadData() // filtered view is small; keep it simple
        }
        if let c = controller.currentIndex, trackIndices.contains(c) { panel.refreshTrackInfo() }
    }

    func currentTrackDidChange(old: Int?, new: Int?) {
        panel.refreshTrackInfo()
        pinnedInfoID = nil
        refreshInfo()
        var rows = IndexSet()
        for i in [old, new].compactMap({ $0 }) {
            if let r = controller.row(forTrackIndex: i), r < table.numberOfRows { rows.insert(r) }
        }
        if !rows.isEmpty { table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
        if let n = new, let r = controller.row(forTrackIndex: n) { table.scrollRowToVisible(r) }
    }

    private func toggle(_ d: Drawer) {
        drawer = drawer == d ? .none : d
        applyDrawer()
    }

    /// Cover click: open INFO on the playing track; if INFO shows a selected row, switch back to the playing
    /// track; if it already shows the playing track, close it.
    private func artClicked() {
        if drawer == .info && pinnedInfoID == nil {
            toggle(.info)
        } else {
            pinnedInfoID = nil
            if drawer != .info { drawer = .info; applyDrawer() } else { refreshInfo() }
        }
    }

    private func applyDrawer() {
        let d = drawer
        eqView.isHidden = d != .eq
        infoView.isHidden = d != .info
        drawerHost.isHidden = d == .none
        drawerHeight.constant = d == .none ? 0 : (d == .info ? 168 : 150)
        drawerGap.constant = d == .none ? 0 : 8
        panel.eqButton.isOn = d == .eq
        panel.infoButton.isOn = d == .info
        if d == .info { refreshInfo() }
    }

    private func refreshInfo() {
        guard drawer == .info else { return }
        if let id = pinnedInfoID, let i = controller.store.index(ofID: id) {
            infoView.show(index: i, pinned: true)
        } else {
            pinnedInfoID = nil
            infoView.show(index: controller.currentIndex, pinned: false)
        }
    }

    func optionsDidChange() {
        eqView.refresh()
        panel.refreshOptions()
        updateStatus()
    }

    var selectedTrackIndices: IndexSet {
        IndexSet(table.selectedRowIndexes.filter { $0 < controller.rowCount }.map { controller.trackIndex(forRow: $0) })
    }

    var selectedTrackIndex: Int? {
        let r = table.selectedRow
        return r >= 0 && r < controller.rowCount ? controller.trackIndex(forRow: r) : nil
    }

    func focusFilter() {
        window?.makeFirstResponder(filterField)
    }

    // MARK: Actions

    @objc private func addTapped() { controller.showOpenPanel(for: window) }
    @objc private func clearTapped() { filterField.stringValue = ""; controller.clear() }

    @objc private func tableDoubleClick() {
        guard table.clickedRow >= 0 else { return }
        controller.play(index: controller.trackIndex(forRow: table.clickedRow))
    }

    private func playSelected() {
        let r = table.selectedRow >= 0 ? table.selectedRow : 0
        guard r < controller.rowCount else { return }
        controller.play(index: controller.trackIndex(forRow: r))
    }

    private func removeSelected() {
        let rows = table.selectedRowIndexes
        guard let firstRow = rows.first else { return }
        var idx = IndexSet()
        for r in rows { idx.insert(controller.trackIndex(forRow: r)) }
        controller.remove(trackIndices: idx)
        let n = controller.rowCount
        if n > 0 { table.selectRowIndexes([min(firstRow, n - 1)], byExtendingSelection: false) }
    }

    private func moveSelection(by delta: Int) {
        guard controller.visible == nil else { NSSound.beep(); return }
        let moved = controller.shift(trackIndices: table.selectedRowIndexes, by: delta)
        table.selectRowIndexes(moved, byExtendingSelection: false)
        if let f = moved.first { table.scrollRowToVisible(delta < 0 ? f : moved.last!) }
    }

    @objc private func filterChanged() {
        controller.setFilter(filterField.stringValue)
        if controller.rowCount > 0 {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    private func updateStatus() {
        statusLabel.stringValue = controller.statusText
    }

    // MARK: Timer

    private func uiTick() {
        tick += 1
        panel.refresh(tick: tick)
        if tick % 30 == 0, controller.store.isLoadingTags { updateStatus() }
    }

    func playbackStateDidChange() {
        clock.update()
        panel.refresh(tick: tick)   // show the new state even when the clock is off
    }

    /// Tear down without quitting (used when switching looks).
    func dismantle() {
        clock.stop()
        window?.delegate = nil
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        clock.stop()
        onClose?()
    }
}

// MARK: - Table

extension ModernWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { controller.rowCount }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PlaylistRowView() }

    /// Clicking a row shows it in INFO; the playing track takes over again when playback moves on.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard drawer == .info, let type = NSApp.currentEvent?.type,
              [.leftMouseDown, .leftMouseUp, .keyDown].contains(type) else { return }
        let rows = table.selectedRowIndexes
        if rows.count == 1, let r = rows.first, r < controller.rowCount {
            let i = controller.trackIndex(forRow: r)
            pinnedInfoID = i == controller.currentIndex ? nil : controller.store.id(at: i)
        } else {
            pinnedInfoID = nil
        }
        refreshInfo()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = id
            cell.lineBreakMode = .byTruncatingTail
            cell.cell?.truncatesLastVisibleLine = true
            cell.alignment = id == Self.colTitle ? .left : .right
        }
        let i = controller.trackIndex(forRow: row)
        let t = controller.tracks[i]
        let isCurrent = i == controller.currentIndex
        cell.font = Fonts.hack(11.5, bold: isCurrent)
        cell.textColor = isCurrent ? Theme.current : Theme.playlistText
        if isCurrent {
            let glow = NSShadow()
            glow.shadowColor = NSColor.white.withAlphaComponent(0.6)
            glow.shadowBlurRadius = 4
            cell.shadow = glow
        } else {
            cell.shadow = nil
        }
        switch id {
        case Self.colNum: cell.stringValue = isCurrent ? "\(Fonts.Icon.play) \(i + 1)." : "\(i + 1)."
        case Self.colTitle: cell.stringValue = t.displayTitle
        default:
            // Queue position in Winamp style: "[2] 3:45".
            let q = controller.queuePosition(of: i).map { "[\($0)] " } ?? ""
            cell.stringValue = q + TimeFormat.mmss(t.duration)
        }
        return cell
    }

    // Drag source: rows carry their row number (reordering within the table).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard controller.visible == nil else { return nil } // no reordering while filtered
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let fromSelf = (info.draggingSource as? NSTableView) === tableView
        if fromSelf {
            guard controller.visible == nil else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }
        // Files: insert where dropped; while filtered, just append.
        if controller.visible != nil { tableView.setDropRow(-1, dropOperation: .on) }
        else if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let pb = info.draggingPasteboard
        if (info.draggingSource as? NSTableView) === tableView {
            let rows = IndexSet((pb.pasteboardItems ?? []).compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) })
            guard !rows.isEmpty else { return false }
            let moved = controller.move(trackIndices: rows, to: row)
            tableView.selectRowIndexes(moved, byExtendingSelection: false)
            return true
        }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        controller.add(urls, at: row >= 0 && controller.visible == nil ? row : nil)
        return true
    }
}

// MARK: - Filter field keys

extension ModernWindowController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            playSelected()
            window?.makeFirstResponder(table)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            filterField.stringValue = ""
            controller.setFilter("")
            if let c = controller.currentIndex, let r = controller.row(forTrackIndex: c) {
                table.selectRowIndexes([r], byExtendingSelection: false)
                table.scrollRowToVisible(r)
            }
            window?.makeFirstResponder(table)
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let n = controller.rowCount
            guard n > 0 else { return true }
            let d = sel == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let r = max(0, min(n - 1, table.selectedRow + d))
            table.selectRowIndexes([r], byExtendingSelection: false)
            table.scrollRowToVisible(r)
            return true
        default:
            return false
        }
    }
}
