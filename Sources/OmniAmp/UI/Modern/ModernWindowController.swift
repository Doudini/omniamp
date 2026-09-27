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
    /// The search field only shows while jumping (J / ⌘F); hidden, it takes no room and the status gets it.
    private var filterMinWidth: NSLayoutConstraint!
    private var filterHiddenWidth: NSLayoutConstraint!
    private let statusLabel = NSTextField(labelWithString: "")
    private var clock: DisplayClock!
    private var addBtn: ModernButton!
    private var radioBtn: ModernButton!
    private var podcastBtn: ModernButton!
    /// Opens the Internet Radio window (set by the app delegate).
    var onRadio: (() -> Void)?
    var onPodcasts: (() -> Void)?
    /// ADD opens a small menu: files, folder, URL.
    var addMenuProvider: (() -> NSMenu)?
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
        infoView.onContentChange = { [weak self] in self?.fitInfoDrawer() }
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
        table.rowHeight = PlaylistStyle.rowHeight
        NotificationCenter.default.addObserver(forName: PlaylistStyle.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.table.rowHeight = PlaylistStyle.rowHeight
            self.table.reloadData()
            self.fitColumns()
        }
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
        radioBtn = ModernButton(glyph: Fonts.Icon.radio, label: "RADIO", target: self, action: #selector(radioTapped))
        radioBtn.toolTip = "Internet radio (⌘⌥R)"
        podcastBtn = ModernButton(glyph: Fonts.Icon.podcast, label: "PODCASTS", target: self, action: #selector(podcastsTapped))
        podcastBtn.toolTip = "Podcasts (⌘⌥P)"
        addBtn.glyphSize = 10; radioBtn.glyphSize = 11; podcastBtn.glyphSize = 11
        for b in [addBtn!, radioBtn!, podcastBtn!] {
            b.keyStyle = true
            b.housing = false
            b.keyBase = Theme.background.blended(withFraction: 0.35, of: Theme.panelTop)!   // matches the darker bottom bar
            b.setContentHuggingPriority(.required, for: .horizontal)   // keys keep their size; the status takes spare room
        }
        root.addSubview(podcastBtn)
        root.addSubview(addBtn)
        root.addSubview(radioBtn)

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

            addBtn.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            addBtn.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            addBtn.heightAnchor.constraint(equalToConstant: 22),
            radioBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: KeyHousing.seam),
            radioBtn.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            radioBtn.heightAnchor.constraint(equalToConstant: 22),
            podcastBtn.leadingAnchor.constraint(equalTo: radioBtn.trailingAnchor, constant: KeyHousing.seam),
            podcastBtn.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            podcastBtn.heightAnchor.constraint(equalToConstant: 22),
            filterField.leadingAnchor.constraint(equalTo: podcastBtn.trailingAnchor, constant: 12),
            filterField.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),


            statusLabel.leadingAnchor.constraint(equalTo: filterField.trailingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
        ])
        KeyHousing.wrap([addBtn, radioBtn, podcastBtn], in: root)
        filterMinWidth = filterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 90)
        filterHiddenWidth = filterField.widthAnchor.constraint(equalToConstant: 0)
        setSearchVisible(false)
        // Push the panel's content below the transparent titlebar.
        panel.topInset = titlebarHeight
    }

    /// The title column takes whatever width is left, so the number and time columns always stay visible.
    /// Bottom bar: icon-only ADD/RADIO in narrow windows.
    func windowDidResize(_ notification: Notification) {
        // Also fires while the saved frame is restored in init, before the UI exists.
        let narrow = (window?.frame.width ?? 600) < 520
        addBtn?.compact = narrow
        // Icon-only keys are square.
        for b in [addBtn, radioBtn, podcastBtn] { b?.iconWidth = narrow ? 22 : 34 }
        radioBtn?.compact = narrow
        podcastBtn?.compact = narrow
        infoView.compact = narrow
        fitInfoDrawer()
    }

    /// Number column: sized once for the longest number (so titles don't stagger), or hidden.
    /// Time column: fits "12:34" (or "1:02:34"), plus room for "[2] " only while something is queued.
    private func sizeFixedColumns() {
        guard table.tableColumns.count == 3 else { return }
        let pad: CGFloat = 6
        func width(_ s: String, _ f: NSFont) -> CGFloat {
            ceil((s as NSString).size(withAttributes: [.font: f, .kern: PlaylistStyle.kern]).width) + pad
        }
        let bold = PlaylistStyle.textFont(bold: true)
        let numCol = table.tableColumns[0]
        numCol.isHidden = !PlaylistStyle.showNumbers
        if PlaylistStyle.showNumbers {
            let digits = String(repeating: "8", count: String(max(controller.tracks.count, 9)).count) + "."
            numCol.width = max(width(digits, bold), width(PlaylistStyle.playMarker, bold))
        }
        let long = controller.tracks.contains { ($0.duration ?? 0) >= 3600 }
        var sample = long ? "8:88:88" : "88:88"
        if !controller.playQueue.isEmpty { sample = "[\(String(repeating: "8", count: String(controller.playQueue.count).count))] " + sample }
        table.tableColumns[2].width = width(sample, PlaylistStyle.timeFont(bold: true))
    }

    private func fitColumns() {
        guard table.tableColumns.count == 3 else { return }
        sizeFixedColumns()
        let numW = table.tableColumns[0].isHidden ? 0 : table.tableColumns[0].width + table.intercellSpacing.width
        let fixed = numW + table.tableColumns[2].width + table.intercellSpacing.width * 2
        let w = max(table.tableColumns[1].minWidth, scroll.contentSize.width - fixed)
        if abs(table.tableColumns[1].width - w) > 0.5 { table.tableColumns[1].width = w }
    }

    // MARK: PlayerUI

    func playlistDidReload() {
        table.reloadData()
        fitColumns()
        updateStatus()
    }

    func playlistRowsDidUpdate(_ trackIndices: IndexSet) {
        if controller.visible == nil {
            table.reloadData(forRowIndexes: trackIndices.filteredIndexSet { $0 < table.numberOfRows },
                             columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        } else {
            table.reloadData() // filtered view is small; keep it simple
        }
        if let c = controller.currentIndex, trackIndices.contains(c) {
            panel.refreshTrackInfo()
            if pinnedInfoID == nil { refreshInfo() }   // e.g. radio: format and song title arrive after start
        }
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
        drawerHeight.constant = d == .none ? 0 : (d == .info ? infoHeight() : 150)
        drawerGap.constant = d == .none ? 0 : 8
        panel.eqButton.isOn = d == .eq
        panel.infoButton.isOn = d == .info
        if d == .info { refreshInfo() }
        if d == .eq { eqView.refresh() }   // not kept current while hidden
    }

    /// INFO takes the height its text needs (cover-high at least, 300 pt at most).
    private func infoHeight() -> CGFloat {
        let w = drawerHost.bounds.width > 0 ? drawerHost.bounds.width : (window?.contentView?.bounds.width ?? 540) - 20
        return min(300, infoView.preferredHeight(forWidth: w))
    }

    private func fitInfoDrawer() {
        guard drawer == .info, drawerHeight != nil else { return }
        let h = infoHeight()
        if abs(drawerHeight.constant - h) > 0.5 { drawerHeight.constant = h }
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

    func mixDidChange() {
        if drawer == .eq { eqView.refresh() }   // hidden: refreshed when it opens
        panel.refreshVolume()
    }

    func optionsDidChange() {
        fitColumns()
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
        setSearchVisible(true)
        window?.makeFirstResponder(filterField)
    }

    private func setSearchVisible(_ on: Bool) {
        filterField.isHidden = !on
        // Deactivate before activating: both at once conflict (0 wide vs. a minimum width).
        if on { filterHiddenWidth.isActive = false; filterMinWidth.isActive = true }
        else { filterMinWidth.isActive = false; filterHiddenWidth.isActive = true }
    }

    /// Hide the search field again once it's empty and no longer being typed in.
    private func hideSearchIfIdle() {
        guard filterField.stringValue.isEmpty, window?.firstResponder !== filterField.currentEditor() else { return }
        setSearchVisible(false)
    }

    // MARK: Actions

    @objc private func radioTapped() { onRadio?() }
    @objc private func podcastsTapped() { onPodcasts?() }
    @objc private func addTapped() {
        guard let menu = addMenuProvider?() else { controller.showOpenPanel(for: window); return }
        // Opens upwards from the button, like Winamp's ADD pop-out.
        let y = addBtn.isFlipped ? -menu.size.height - 2 : addBtn.bounds.height + menu.size.height + 2
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: addBtn)
    }

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
        statusLabel.setIfChanged(controller.statusText)
    }

    // MARK: Timer

    private func uiTick() {
        tick += 1
        panel.refresh(tick: tick)
        if tick % 30 == 0, controller.store.isLoadingTags || controller.sleepAt != nil { updateStatus() }
    }

    func playbackStateDidChange() {
        clock.update()
        panel.refresh(tick: tick)   // show the new state even when the clock is off
    }

    /// Tear down without quitting (used when switching looks).
    func dismantle() {
        clock.stop()
        panel.dismissHoverCard()
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
        cell.font = id == Self.colTime ? PlaylistStyle.timeFont(bold: isCurrent) : PlaylistStyle.textFont(bold: isCurrent)
        cell.textColor = isCurrent ? Theme.current : Theme.playlistText
        if isCurrent {
            let glow = NSShadow()
            glow.shadowColor = NSColor.white.withAlphaComponent(0.6)
            glow.shadowBlurRadius = 4
            cell.shadow = glow
        } else {
            cell.shadow = nil
        }
        let text: String
        switch id {
        // The playing row shows ▶ in its number slot (its number is in the marquee), so no row needs extra room.
        case Self.colNum: text = isCurrent ? PlaylistStyle.playMarker : "\(i + 1)."
        case Self.colTitle: text = (isCurrent && !PlaylistStyle.showNumbers ? PlaylistStyle.playMarker + " " : "") + t.displayTitle
        default:
            // Queue position in Winamp style: "[2] 3:45".
            let q = controller.queuePosition(of: i).map { "[\($0)] " } ?? ""
            text = q + TimeFormat.mmss(t.duration)
        }
        if PlaylistStyle.kern != 0 {
            cell.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: cell.font!, .foregroundColor: cell.textColor!, .kern: PlaylistStyle.kern,
                .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = cell.alignment; p.lineBreakMode = .byTruncatingTail; return p }(),
            ])
        } else {
            cell.stringValue = text
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
    /// Clear the filter and land on the playing track in the full playlist.
    private func clearFilterShowingCurrent() {
        filterField.stringValue = ""
        controller.setFilter("")
        if let c = controller.currentIndex, let r = controller.row(forTrackIndex: c) {
            table.selectRowIndexes([r], byExtendingSelection: false)
            // Center it: after a jump the surrounding tracks are what you want to see.
            let visible = table.rows(in: table.visibleRect).length
            table.scrollRowToVisible(min(controller.rowCount - 1, r + visible / 2))
            table.scrollRowToVisible(max(0, r - visible / 2))
        }
        window?.makeFirstResponder(table)
        setSearchVisible(false)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === filterField else { return }
        DispatchQueue.main.async { [weak self] in self?.hideSearchIfIdle() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        // Enter: play the highlighted match and go back to the full playlist.
        // Shift+Enter: play it but keep the results (e.g. to try the next version of a song).
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let keep = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            playSelected()
            if keep { return true }   // stay in the field, results intact
            clearFilterShowingCurrent()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            clearFilterShowingCurrent()
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
