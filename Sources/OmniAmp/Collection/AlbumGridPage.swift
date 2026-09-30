import AppKit

/// The Albums section: the library as a wall of covers, grouped by artist, year, decade, kind or when it was
/// added, in three sizes. A click opens the album in a panel under its row (its tracks, Play, Add, the artist);
/// a double-click plays it. A show without a cover gets a ticket stub with its date and venue, any other release
/// a printed sleeve with its title: a bootleg collection is mostly without art.
///
/// Keys: arrows move (an open panel follows), ⌘↓ opens, ⌘↑ or Esc closes, Return plays, ⌥Return adds,
/// ⌘+ / ⌘− change the size. The rest go to the window (`onKey`).
final class AlbumGridPage: NSView, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    var onPlay: (([LibraryTrack], Int) -> Void)?   // the tracks, and the one to start at
    var onAdd: (([LibraryTrack]) -> Void)?
    var onArtist: ((String) -> Void)?
    /// Right-click on a cover (selected first): the window's menu for the selected album.
    var onMenu: (() -> NSMenu?)?
    var onKey: ((NSEvent) -> Bool)?
    /// "Search for …" under a search that found nothing: the search spelled like the library.
    var onSuggestion: ((String) -> Void)?

    let collection = GridCollectionView()
    private let scroll = NSScrollView()
    private let flow = NSCollectionViewFlowLayout()
    private let empty = EmptyNotice()
    private var groupPills: [Pill] = []
    private var sizePills: [Pill] = []

    private var db: CollectionDB?
    private var sections: [AlbumGrid.Section] = []
    private var selected: AlbumGrid.Position?
    private var open: AlbumGrid.Position?
    private var openTracks: [LibraryTrack] = []
    /// What was loaded last: a reload of the same (new files, a finished scan) keeps the scroll position.
    private var loaded = ""

    /// A–Z by default: one wall of covers (most artists in a loose collection have a release or two, so a title
    /// per artist leaves a lot of rows with one cover).
    private var grouping = AlbumGrouping(rawValue: UserDefaults.standard.string(forKey: Pref.libraryGridGroup) ?? "") ?? .none
    private var size = min(2, max(0, UserDefaults.standard.object(forKey: Pref.libraryGridSize) as? Int ?? 1))
    private static let tileSizes: [CGFloat] = [118, 158, 208]
    private static let spacing: CGFloat = 16, inset: CGFloat = 16
    private var columns = 1
    private var tileWidth: CGFloat = 158
    private var laidOutWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        groupPills = AlbumGrouping.allCases.map { g in
            let p = Pill(g.title, target: self, action: #selector(groupClicked(_:)))
            p.tag = AlbumGrouping.allCases.firstIndex(of: g)!
            return p
        }
        sizePills = ["S", "M", "L"].enumerated().map { i, t in
            let p = Pill(t, target: self, action: #selector(sizeClicked(_:)))
            p.tag = i
            p.toolTip = ["Small covers (⌘−)", "Medium covers", "Large covers (⌘+)"][i]
            return p
        }
        let caption = Dash.label("GROUP", Dash.mono(9.5, bold: true), Dash.text3)
        let sizeCaption = Dash.label("SIZE", Dash.mono(9.5, bold: true), Dash.text3)
        let bar = NSStackView(views: [caption] + groupPills + [NSView(), sizeCaption] + sizePills)
        bar.spacing = 6
        bar.setCustomSpacing(10, after: caption)
        bar.setCustomSpacing(10, after: sizeCaption)
        updatePills()

        flow.minimumInteritemSpacing = Self.spacing
        flow.minimumLineSpacing = 22
        flow.sectionInset = NSEdgeInsets(top: 6, left: Self.inset, bottom: 18, right: Self.inset)
        flow.sectionHeadersPinToVisibleBounds = true
        collection.collectionViewLayout = flow
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColors = [.clear]
        collection.isSelectable = false   // selection is the page's own (a click also opens, the panel isn't one)
        collection.register(AlbumTileItem.self, forItemWithIdentifier: AlbumTileItem.id)
        collection.register(AlbumPanelItem.self, forItemWithIdentifier: AlbumPanelItem.id)
        collection.register(GridHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: GridHeader.id)
        collection.onKey = { [weak self] e in self?.key(e) ?? false }
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false

        empty.onSuggestion = { [weak self] s in self?.onSuggestion?(s) }
        for v in [bar, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Loading

    /// The albums the filter and search let through. `keep`: an album to select (else the selection stays).
    func reload(db: CollectionDB?, filter: LibraryFilter, query: String, keep: String? = nil, emptyText: String? = nil) {
        self.db = db
        let q = query.trimmingCharacters(in: .whitespaces)
        var list: [LibraryAlbum] = []
        do {
            if let db { list = q.isEmpty ? try db.albumsWhere(filter.sql, [], order: "a.artist") : try db.albums(matching: q, filter) }
        } catch {
            NSLog("OmniAmp: library query failed: %@", "\(error)")
        }
        let keepSelected = keep ?? selectedAlbum?.key, keepOpen = open.map { album($0).key }
        let what = "\(filter)\u{1}\(q)\u{1}\(grouping)"
        let same = what == loaded
        loaded = what
        let origin = scroll.contentView.bounds.origin
        sections = AlbumGrid.sections(list, by: grouping)
        selected = keepSelected.flatMap(position)
        open = keepOpen.flatMap(position)
        openTracks = open.map { (try? db?.tracks(album: album($0).key)) ?? [] } ?? []
        collection.reloadData()
        if same {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if let s = selected, keep != nil {
            reveal(s)
        } else {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        empty.text = sections.isEmpty ? (emptyText ?? (q.isEmpty ? "No albums with these filters." : "Nothing matches “\(q)”.")) : ""
        empty.suggestion = nil
    }

    var isEmpty: Bool { sections.isEmpty }

    /// Offers a better spelling of the search under "Nothing matches" (nil: none).
    func suggest(_ spelled: String?) { empty.suggestion = spelled }

    private func position(of key: String) -> AlbumGrid.Position? {
        for (s, sec) in sections.enumerated() {
            if let i = sec.albums.firstIndex(where: { $0.key == key }) { return AlbumGrid.Position(section: s, index: i) }
        }
        return nil
    }

    private func album(_ p: AlbumGrid.Position) -> LibraryAlbum { sections[p.section].albums[p.index] }

    var selectedAlbum: LibraryAlbum? {
        guard let s = selected, s.section < sections.count, s.index < sections[s.section].albums.count else { return nil }
        return album(s)
    }

    /// The keyboard to the grid, with an album selected.
    func focus() {
        if selected == nil, !sections.isEmpty { select(AlbumGrid.Position(section: 0, index: 0)) }
        window?.makeFirstResponder(collection)
    }

    /// Test hook (OMNIAMP_LIBRARY=albums:…): a grouping by name ("year"), else the album with that title, opened.
    func applyHook(_ s: String) {
        if let g = AlbumGrouping(rawValue: s), let pill = groupPills.first(where: { AlbumGrouping.allCases[$0.tag] == g }) {
            groupClicked(pill)
        } else {
            openAlbum(titled: s)
        }
    }

    /// Opens an album's panel by title.
    func openAlbum(titled title: String) {
        guard let key = sections.lazy.flatMap(\.albums).first(where: { $0.title.localizedCaseInsensitiveContains(title) })?.key,
              let p = position(of: key) else { return }
        select(p)
        setOpen(p)
    }

    // MARK: Group and size

    private func updatePills() {
        for p in groupPills { p.isOn = AlbumGrouping.allCases[p.tag] == grouping }
        for p in sizePills { p.isOn = p.tag == size }
    }

    @objc private func groupClicked(_ sender: Pill) {
        grouping = AlbumGrouping.allCases[sender.tag]
        UserDefaults.standard.set(grouping.rawValue, forKey: Pref.libraryGridGroup)
        updatePills()
        let keep = selectedAlbum?.key
        let list = sections.flatMap(\.albums)
        sections = AlbumGrid.sections(list, by: grouping)
        loaded = loaded.components(separatedBy: "\u{1}").dropLast().joined(separator: "\u{1}") + "\u{1}\(grouping)"
        selected = keep.flatMap(position)
        open = nil
        openTracks = []
        collection.reloadData()
        if let s = selected { reveal(s) } else { scroll.contentView.scroll(to: .zero) }
    }

    @objc private func sizeClicked(_ sender: Pill) { setSize(sender.tag) }

    private func setSize(_ s: Int) {
        guard (0...2).contains(s), s != size else { return }
        size = s
        UserDefaults.standard.set(size, forKey: Pref.libraryGridSize)
        updatePills()
        laidOutWidth = 0
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let s = selected { reveal(s) }
    }

    // MARK: Layout

    private var available: CGFloat { scroll.contentView.bounds.width - 2 * Self.inset }

    override func layout() {
        super.layout()
        let width = available
        guard width > 0, abs(width - laidOutWidth) > 0.5 else { return }
        laidOutWidth = width
        let base = Self.tileSizes[size]
        let cols = max(1, Int((width + Self.spacing) / (base + Self.spacing)))
        // The row fills the width: the covers grow a little rather than leave a ragged gap on the right.
        tileWidth = floor((width - CGFloat(cols - 1) * Self.spacing) / CGFloat(cols))
        let moved = cols != columns && open != nil
        columns = cols
        if moved { collection.reloadData() } else { flow.invalidateLayout() }
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        if indexPath.item == panelSlot(indexPath.section) {
            return NSSize(width: available, height: AlbumPanelView.height(tracks: openTracks.count, width: available))
        }
        return NSSize(width: tileWidth, height: tileWidth + AlbumTileView.labels)
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> NSSize {
        grouping == .none ? .zero : NSSize(width: collectionView.bounds.width, height: 36)
    }

    // MARK: Data

    /// The item the open album's panel is in this section, if it's here.
    private func panelSlot(_ section: Int) -> Int? {
        guard let o = open, o.section == section else { return nil }
        return AlbumGrid.panelSlot(index: o.index, count: sections[section].albums.count, columns: columns)
    }

    private func indexPath(_ p: AlbumGrid.Position) -> IndexPath {
        let slot = panelSlot(p.section)
        return IndexPath(item: slot.map { p.index >= $0 ? p.index + 1 : p.index } ?? p.index, section: p.section)
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].albums.count + (panelSlot(section) == nil ? 0 : 1)
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let slot = panelSlot(indexPath.section)
        if indexPath.item == slot, let o = open {
            let item = collectionView.makeItem(withIdentifier: AlbumPanelItem.id, for: indexPath) as! AlbumPanelItem
            let panel = item.view as! AlbumPanelView
            panel.pointerX = Self.inset + CGFloat(o.index % columns) * (tileWidth + Self.spacing) + tileWidth / 2 - Self.inset
            panel.show(album(o), tracks: openTracks)
            panel.onPlay = { [weak self] list, start in self?.onPlay?(list, start) }
            panel.onAdd = { [weak self] list in self?.onAdd?(list) }
            panel.onArtist = { [weak self] key in self?.onArtist?(key) }
            return item
        }
        let p = AlbumGrid.Position(section: indexPath.section, index: slot.map { indexPath.item > $0 ? indexPath.item - 1 : indexPath.item } ?? indexPath.item)
        let item = collectionView.makeItem(withIdentifier: AlbumTileItem.id, for: indexPath) as! AlbumTileItem
        let tile = item.view as! AlbumTileView
        tile.show(album(p), withArtist: grouping != .artist)
        tile.isSelected = p == selected
        tile.isOpen = p == open
        tile.onClick = { [weak self, weak tile] clicks in
            guard let self, let key = tile?.album?.key, let at = self.position(of: key) else { return }
            self.clicked(at, clicks: clicks)
        }
        tile.onPlay = { [weak self, weak tile] in
            guard let self, let key = tile?.album?.key, let at = self.position(of: key) else { return }
            self.select(at)
            self.play(at)
        }
        tile.onMenu = { [weak self, weak tile] in
            guard let self, let key = tile?.album?.key, let at = self.position(of: key) else { return nil }
            self.select(at)
            self.window?.makeFirstResponder(self.collection)
            return self.onMenu?()
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let h = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GridHeader.id, for: indexPath) as! GridHeader
        let s = sections[indexPath.section]
        h.show(s.title, count: s.albums.count, kind: s.kind)
        return h
    }

    // MARK: Selection and the panel

    private func clicked(_ p: AlbumGrid.Position, clicks: Int) {
        window?.makeFirstResponder(collection)
        if clicks >= 2 {
            select(p)
            play(p)
            return
        }
        let wasOpen = open == p
        select(p)
        setOpen(wasOpen ? nil : p)
    }

    private func select(_ p: AlbumGrid.Position) {
        selected = p
        let key = album(p).key
        for case let item as AlbumTileItem in collection.visibleItems() {
            let tile = item.view as! AlbumTileView
            tile.isSelected = tile.album?.key == key
        }
    }

    private func setOpen(_ p: AlbumGrid.Position?) {
        guard p != open else { return }
        open = p
        openTracks = p.map { (try? db?.tracks(album: album($0).key)) ?? [] } ?? []
        collection.reloadData()
        if let p { reveal(p) }
    }

    /// Scrolls an album into view, with its panel when it's open (under the pinned group title).
    private func reveal(_ p: AlbumGrid.Position) {
        collection.layoutSubtreeIfNeeded()
        guard let tile = collection.layoutAttributesForItem(at: indexPath(p))?.frame else { return }
        var rect = tile
        if let slot = panelSlot(p.section), let panel = collection.layoutAttributesForItem(at: IndexPath(item: slot, section: p.section))?.frame {
            rect = rect.union(panel)
        }
        let header: CGFloat = grouping == .none ? 8 : 44
        collection.scrollToVisible(NSRect(x: rect.minX, y: rect.minY - header, width: rect.width, height: rect.height + header + 8))
    }

    private func tracks(_ p: AlbumGrid.Position) -> [LibraryTrack] { (try? db?.tracks(album: album(p).key)) ?? [] }

    private func play(_ p: AlbumGrid.Position) { onPlay?(tracks(p), 0) }

    // MARK: Keys

    private func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let arrows: [UInt16: AlbumGrid.Direction] = [123: .left, 124: .right, 125: .down, 126: .up]
        if mods == .command, e.keyCode == 125 { if let s = selected { setOpen(s) }; return true }
        if mods == .command, e.keyCode == 126 { setOpen(nil); return true }
        if mods == .command || mods == [.command, .shift] {
            if e.keyCode == 24 { setSize(size + 1); return true }   // ⌘+ (⌘=)
            if e.keyCode == 27 { setSize(size - 1); return true }   // ⌘−
        }
        if mods.isEmpty, let d = arrows[e.keyCode] {
            let counts = sections.map(\.albums.count)
            guard let from = selected else {
                if !sections.isEmpty { select(AlbumGrid.Position(section: 0, index: 0)) }
                return true
            }
            guard let to = AlbumGrid.move(from, d, counts: counts, columns: columns) else {
                return d == .left ? (onKey?(e) ?? false) : true   // off the left edge: the sidebar
            }
            select(to)
            if open != nil { setOpen(to) } else { reveal(to) }
            return true
        }
        if e.keyCode == 36 || e.keyCode == 76, mods.isEmpty || mods == .option {
            if let s = selected { mods.isEmpty ? play(s) : onAdd?(tracks(s)) }
            return true
        }
        if e.keyCode == 53, mods.isEmpty, open != nil {
            setOpen(nil)
            return true
        }
        return onKey?(e) ?? false
    }
}

/// The grid's collection view: keys to the page first.
final class GridCollectionView: NSCollectionView {
    var onKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - Tiles

final class AlbumTileItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("albumTile")
    override func loadView() { view = AlbumTileView() }
    override func prepareForReuse() {
        super.prepareForReuse()
        view.prepareForReuse()   // its cover read is cancelled
    }
}

/// A cover with its title and artist under it. The cover is the large one, the small one standing in while it's
/// read; none at all: a printed sleeve or ticket stub (GridCovers).
final class AlbumTileView: NSView, NSDraggingSource {
    static let labels: CGFloat = 40

    private(set) var album: LibraryAlbum?
    private var withArtist = true
    private var image: NSImage?
    private var noCover = false
    private var token = -1
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var isOpen = false { didSet { if isOpen != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    var onClick: ((Int) -> Void)?
    var onPlay: (() -> Void)?
    var onMenu: (() -> NSMenu?)?

    override var isFlipped: Bool { true }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let a = album {
            LibraryArt.shared.cancel(a, token: token, large: true)
            LibraryArt.shared.cancel(a, token: token)
        }
        album = nil
        token = -1
        image = nil
        hovering = false
    }

    func show(_ a: LibraryAlbum, withArtist: Bool) {
        if let old = album, old.key != a.key {
            LibraryArt.shared.cancel(old, token: token, large: true)
            LibraryArt.shared.cancel(old, token: token)
        }
        album = a
        self.withArtist = withArtist
        noCover = false
        needsDisplay = true
        switch LibraryArt.shared.cached(a, large: true) {
        case .some(let img?):
            set(img)
            token = -1
        case .some(nil):
            smallCover(a)   // no large one (or the share was away when it was read)
        case nil:
            // The small cover while the large one is read (it's often in memory from the lists).
            if case let .some(small?) = LibraryArt.shared.cached(a) { image = NSImage(cgImage: small, size: .zero) } else { image = nil }
            token = LibraryArt.shared.load(a, large: true) { [weak self] img in
                guard let self, self.album?.key == a.key else { return }
                if let img { self.set(img) } else { self.smallCover(a) }
            }
        }
    }

    /// The small cover when there's one (kept from earlier, when the share was there), else the printed sleeve.
    private func smallCover(_ a: LibraryAlbum) {
        token = LibraryArt.shared.load(a) { [weak self] small in
            guard let self, self.album?.key == a.key else { return }
            self.set(small)
        }
    }

    private func set(_ img: CGImage?) {
        image = img.map { NSImage(cgImage: $0, size: .zero) }
        noCover = img == nil
        needsDisplay = true
    }

    private var cover: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: bounds.width) }
    private var playButton: NSRect {
        let d = min(40, bounds.width * 0.26)
        return NSRect(x: cover.maxX - d - 8, y: cover.maxY - d - 8, width: d, height: d)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let a = album else { return }
        let r = cover
        let shape = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let image {
            // Fill the square: a cover that isn't one is cropped in the middle.
            let s = image.size, side = min(s.width, s.height)
            image.draw(in: r, from: NSRect(x: (s.width - side) / 2, y: (s.height - side) / 2, width: side, height: side),
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else if noCover {
            GridCovers.draw(a, in: r)
        } else {
            Dash.cardRaised.setFill()
            r.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        Dash.border.setStroke()
        edge.stroke()
        if isSelected || isOpen {
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: 5, yRadius: 5)
            ring.lineWidth = 3
            Dash.accent.setStroke()
            ring.stroke()
        }
        if hovering {
            let b = playButton
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: b).fill()
            let g = NSAttributedString(string: Fonts.Icon.play, attributes: [.font: Fonts.hack(b.width * 0.38), .foregroundColor: NSColor.white])
            let gs = g.size()
            g.draw(at: NSPoint(x: b.midX - gs.width / 2 + b.width * 0.04, y: b.midY - gs.height / 2))
        }
        // Unofficial recordings say what they are, in their kind's color (a ticket stub already does).
        if !a.kind.isOfficial, !(noCover && a.kind == .show) {
            let tag = NSAttributedString(string: a.kind == .show ? "LIVE" : "DEMO", attributes: [.font: Dash.mono(8.5, bold: true), .foregroundColor: NSColor.white])
            let ts = tag.size()
            let pill = NSRect(x: r.minX + 7, y: r.minY + 7, width: ts.width + 10, height: ts.height + 3)
            Theme.kind(a.kind).withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            tag.draw(at: NSPoint(x: pill.minX + 5, y: pill.minY + 1.5))
        }
        let isShow = a.kind == .show && a.showDate != nil
        let title = isShow ? [a.showDate, a.venue].compactMap { $0 }.joined(separator: " · ") : a.title
        var sub: [String] = []
        if withArtist { sub.append(a.artist) }
        if !isShow, let y = a.year { sub.append(String(y)) }
        if !withArtist { sub.append(a.tracks == 1 ? "1 track" : "\(a.tracks) tracks") }
        GridCovers.text(title, Dash.font(12.5, .semibold), isSelected ? Dash.accent : Dash.text, x: 1, y: r.maxY + 6, width: bounds.width - 2, lines: 1)
        GridCovers.text(sub.joined(separator: " · "), Dash.font(11.5), Dash.text2, x: 1, y: r.maxY + 23, width: bounds.width - 2, lines: 1)
    }

    // Mouse: a click opens, a double-click plays, the round button plays, a drag carries the album's folder.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        if hovering, playButton.contains(at) { onPlay?(); return }
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if e.type == .leftMouseUp { onClick?(event.clickCount); return }
            let p = convert(e.locationInWindow, from: nil)
            if hypot(p.x - at.x, p.y - at.y) > 4 { drag(event); return }
        }
    }

    private func drag(_ event: NSEvent) {
        guard let a = album else { return }
        let item = NSDraggingItem(pasteboardWriter: URL(exactPath: a.folder, isDirectory: true) as NSURL)
        let snapshot = NSImage(size: cover.size)
        if let rep = bitmapImageRepForCachingDisplay(in: cover) {
            cacheDisplay(in: cover, to: rep)
            snapshot.addRepresentation(rep)
        }
        item.setDraggingFrame(cover, contents: snapshot)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { album.map { "\($0.title), \($0.artist)" } }
    override func accessibilityPerformPress() -> Bool { onClick?(1); return true }
}

/// Covers for releases that have none: a ticket stub for a show (date, venue, artist), a printed sleeve for the
/// rest (title and artist), in the theme's colors with the kind's color as the accent.
enum GridCovers {
    @MainActor static func draw(_ a: LibraryAlbum, in r: NSRect) {
        let w = r.width, pad = max(8, w * 0.07), tint = Theme.kind(a.kind)
        Dash.cardRaised.setFill()
        r.fill()
        if a.kind == .show {
            let stub = w * 0.2
            tint.withAlphaComponent(0.28).setFill()
            NSRect(x: r.minX, y: r.minY, width: stub, height: r.height).fill()
            let perforation = NSBezierPath()
            perforation.move(to: NSPoint(x: r.minX + stub, y: r.minY + 9))
            perforation.line(to: NSPoint(x: r.minX + stub, y: r.maxY - 9))
            perforation.setLineDash([2, 3], count: 2, phase: 0)
            perforation.lineWidth = 1
            Dash.text3.setStroke()
            perforation.stroke()
            Dash.page.setFill()
            for y in [r.minY, r.maxY] { NSBezierPath(ovalIn: NSRect(x: r.minX + stub - 6, y: y - 6, width: 12, height: 12)).fill() }
            // ADMIT ONE up the stub.
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.translateBy(x: r.minX + stub / 2, y: r.midY)
                ctx.rotate(by: -.pi / 2)
                let admit = NSAttributedString(string: "ADMIT ONE", attributes: [.font: Dash.mono(max(6.5, w * 0.05), bold: true), .foregroundColor: tint])
                let s = admit.size()
                admit.draw(at: NSPoint(x: -s.width / 2, y: -s.height / 2))
                ctx.restoreGState()
            }
            let x = r.minX + stub + pad * 0.8, width = r.maxX - pad - x
            var y = r.minY + pad
            y += text(a.artist.uppercased(), Dash.mono(max(7.5, w * 0.055), bold: true), Dash.text2, x: x, y: y, width: width, lines: 2) + w * 0.04
            y += text(a.showDate ?? a.year.map(String.init) ?? "", Dash.mono(max(10, w * 0.095), bold: true), Dash.text, x: x, y: y, width: width, lines: 1)
                + w * 0.03
            // The venue; else the title, unless it's only the date again ("94-02-27").
            let place = a.venue ?? (a.title.contains { $0.isLetter } ? a.title : "")
            text(place, Dash.font(max(9.5, w * 0.075), .medium), Dash.text2, x: x, y: y, width: width, lines: 4)
        } else {
            tint.setFill()
            NSRect(x: r.minX, y: r.minY, width: r.width, height: max(3, w * 0.025)).fill()
            let x = r.minX + pad, width = r.width - 2 * pad
            var y = r.minY + pad + w * 0.03
            y += text(a.title, Dash.font(max(11, w * 0.1), .semibold), Dash.text, x: x, y: y, width: width, lines: 4) + w * 0.03
            text(a.artist, Dash.font(max(9.5, w * 0.07)), Dash.text2, x: x, y: y, width: width, lines: 2)
            if let year = a.year {
                let f = Dash.mono(max(8.5, w * 0.06))
                text(String(year), f, Dash.text3, x: x, y: r.maxY - pad - (f.ascender - f.descender), width: width, lines: 1)
            }
        }
    }

    /// Text in a flipped view, at most `lines` lines (truncated). Returns the height it took.
    @discardableResult
    @MainActor static func text(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat, lines: Int) -> CGFloat {
        guard !s.isEmpty, width > 0 else { return 0 }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        let line = ceil(font.ascender - font.descender + font.leading)
        let most = line * CGFloat(lines)
        let fits = str.boundingRect(with: NSSize(width: width, height: most), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let h = min(most, ceil(fits.height))
        str.draw(with: NSRect(x: x, y: y, width: width, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return h
    }
}

/// A group's title over its covers, pinned while its covers scroll by.
final class GridHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("gridHeader")
    private var title = "", count = 0, kind: ReleaseKind?
    override var isFlipped: Bool { true }

    func show(_ title: String, count: Int, kind: ReleaseKind?) {
        self.title = title
        self.count = count
        self.kind = kind
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Dash.page.setFill()
        bounds.fill()
        var x: CGFloat = 16
        if let kind {
            Theme.kind(kind).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 15, width: 9, height: 9), xRadius: 2, yRadius: 2).fill()
            x += 16
        }
        let name = NSAttributedString(string: title, attributes: [.font: Dash.font(15, .semibold), .foregroundColor: Dash.text])
        let n = NSAttributedString(string: "  \(count)", attributes: [.font: Dash.mono(10.5), .foregroundColor: Dash.text3])
        let s = NSMutableAttributedString(attributedString: name)
        s.append(n)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
        s.draw(with: NSRect(x: x, y: 9, width: bounds.width - x - 16, height: 22), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        Dash.border.setFill()
        NSRect(x: 16, y: bounds.height - 1, width: bounds.width - 32, height: 1).fill()
    }
}

// MARK: - The open album

final class AlbumPanelItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("albumPanel")
    override func loadView() { view = AlbumPanelView() }
}

/// An opened album under its row: the cover, what it is, Play / Add / Artist, and its tracks in columns
/// (double-click one to play from there). A notch points at the album's cover.
final class AlbumPanelView: NSView {
    var onPlay: (([LibraryTrack], Int) -> Void)?
    var onAdd: (([LibraryTrack]) -> Void)?
    var onArtist: ((String) -> Void)?
    /// Where the notch points (the opened cover's middle).
    var pointerX: CGFloat = 60 { didSet { needsDisplay = true } }

    static let notch: CGFloat = 10, pad: CGFloat = 20, cover: CGFloat = 200, header: CGFloat = 116, row: CGFloat = 22

    private let art = ArtView()
    private let title = Dash.label("", Dash.font(20, .semibold), Dash.text)
    private let artist = Dash.label("", Dash.font(14), Dash.text2)
    private let meta = Dash.label("", Dash.mono(10.5), Dash.text3)
    private let list = TrackColumnsView()
    private var buttons: NSStackView!
    private var album: LibraryAlbum?
    private var tracks: [LibraryTrack] = []

    override var isFlipped: Bool { true }

    static func columns(_ n: Int, width: CGFloat) -> Int {
        let room = width - 3 * pad - cover
        if n > 24, room >= 900 { return 3 }
        if n > 8, room >= 520 { return 2 }
        return 1
    }

    static func height(tracks n: Int, width: CGFloat) -> CGFloat {
        let cols = columns(n, width: width), rows = (n + cols - 1) / cols
        return notch + pad + max(cover, header + CGFloat(rows) * row) + pad
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        art.cornerRadius = 6
        art.placeholder = Fonts.Icon.music
        art.surface = Dash.cardRaised
        art.iconColor = Dash.text3
        art.translatesAutoresizingMaskIntoConstraints = true
        let play = Pill("Play", glyph: Fonts.Icon.play, target: self, action: #selector(playAll))
        play.prominent = true
        let add = Pill("Add", glyph: Fonts.Icon.plus, target: self, action: #selector(addAll))
        let artistPage = Pill("Artist", target: self, action: #selector(showArtist))
        play.toolTip = "Add to the playlist and play (Return, double-click)"
        add.toolTip = "Add to the playlist (⌥Return)"
        artistPage.toolTip = "The artist's page"
        buttons = NSStackView(views: [play, add, artistPage])
        buttons.spacing = 6
        list.onPlay = { [weak self] i in guard let self else { return }; self.onPlay?(self.tracks, i) }
        for v in [art, title, artist, meta, buttons!, list] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ a: LibraryAlbum, tracks: [LibraryTrack]) {
        album = a
        self.tracks = tracks
        let isShow = a.kind == .show && a.showDate != nil
        title.stringValue = isShow ? [a.showDate, a.venue].compactMap { $0 }.joined(separator: "  ") : a.title
        artist.stringValue = a.artist
        var parts = [Self.kindName(a.kind)]
        if !isShow, let y = a.year { parts.append(String(y)) }
        parts.append(tracks.count == 1 ? "1 track" : "\(tracks.count) tracks")
        if a.duration > 0 { parts.append(AlbumCell.length(a.duration)) }
        if let f = tracks.first?.format, !f.isEmpty { parts.append(f) }
        meta.stringValue = parts.joined(separator: " · ").uppercased()
        art.image = nil
        if case let .some(img?) = LibraryArt.shared.cached(a, large: true) {
            art.image = img
        } else {
            LibraryArt.shared.load(a, large: true) { [weak self] img in
                guard self?.album?.key == a.key else { return }
                if let img { self?.art.image = img; return }
                LibraryArt.shared.load(a) { [weak self] small in if self?.album?.key == a.key { self?.art.image = small } }
            }
        }
        list.tracks = tracks
        needsLayout = true
        needsDisplay = true
    }

    private static func kindName(_ k: ReleaseKind) -> String {
        switch k {
        case .album: "Album"
        case .single: "EP / Single"
        case .compilation: "Compilation"
        case .live: "Live album"
        case .show: "Show"
        case .unreleased: "Demo / unreleased"
        }
    }

    override func layout() {
        super.layout()
        let top = Self.notch + Self.pad, x = Self.pad * 2 + Self.cover, width = bounds.width - x - Self.pad
        art.frame = NSRect(x: Self.pad, y: top, width: Self.cover, height: Self.cover)
        title.frame = NSRect(x: x, y: top - 2, width: width, height: 26)
        artist.frame = NSRect(x: x, y: top + 26, width: width, height: 19)
        meta.frame = NSRect(x: x, y: top + 49, width: width, height: 15)
        buttons.frame = NSRect(x: x, y: top + 72, width: buttons.fittingSize.width, height: 26)
        list.columns = Self.columns(tracks.count, width: bounds.width)
        list.frame = NSRect(x: x, y: top + Self.header, width: width, height: bounds.height - top - Self.header - Self.pad)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 0, y: Self.notch, width: bounds.width, height: bounds.height - Self.notch).insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: body, xRadius: 10, yRadius: 10)
        let px = min(max(pointerX, 24), bounds.width - 24)
        let notch = NSBezierPath()
        notch.move(to: NSPoint(x: px - Self.notch - 1, y: body.minY + 0.5))
        notch.line(to: NSPoint(x: px, y: 0.5))
        notch.line(to: NSPoint(x: px + Self.notch + 1, y: body.minY + 0.5))
        notch.close()
        Dash.card.setFill()
        shape.fill()
        notch.fill()
        Dash.border.setStroke()
        shape.stroke()
        let edge = NSBezierPath()
        edge.move(to: NSPoint(x: px - Self.notch, y: body.minY))
        edge.line(to: NSPoint(x: px, y: 0.5))
        edge.line(to: NSPoint(x: px + Self.notch, y: body.minY))
        edge.stroke()
        Dash.card.setFill()   // the card's top edge under the notch goes
        NSRect(x: px - Self.notch + 1.5, y: body.minY - 0.5, width: 2 * Self.notch - 3, height: 1.5).fill()
    }

    @objc private func playAll() { onPlay?(tracks, 0) }
    @objc private func addAll() { onAdd?(tracks) }
    @objc private func showArtist() { if let a = album { onArtist?(a.artistKey) } }
}

/// An album's tracks in one to three columns, numbered in play order. Double-click plays from that track.
final class TrackColumnsView: NSView {
    var tracks: [LibraryTrack] = [] { didSet { hovered = nil; needsDisplay = true } }
    var columns = 1 { didSet { if columns != oldValue { needsDisplay = true } } }
    var onPlay: ((Int) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    private var perColumn: Int { max(1, (tracks.count + columns - 1) / columns) }
    private var columnWidth: CGFloat { (bounds.width - CGFloat(columns - 1) * 24) / CGFloat(columns) }

    private func rect(_ i: Int) -> NSRect {
        let c = i / perColumn, r = i % perColumn
        return NSRect(x: CGFloat(c) * (columnWidth + 24), y: CGFloat(r) * AlbumPanelView.row, width: columnWidth, height: AlbumPanelView.row)
    }

    private func index(at p: NSPoint) -> Int? { tracks.indices.first { rect($0).contains(p) } }

    override func draw(_ dirtyRect: NSRect) {
        let discs = Set(tracks.compactMap(\.disc)).count > 1
        for (i, t) in tracks.enumerated() {
            let r = rect(i)
            guard r.intersects(dirtyRect) else { continue }
            if i == hovered {
                Dash.selection.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: -4, dy: 1), xRadius: 4, yRadius: 4).fill()
            }
            let n = t.number.map { n in discs ? "\(t.disc ?? 1)-" + String(format: "%02d", n) : String(format: "%02d", n) } ?? "·"
            let num = NSAttributedString(string: n, attributes: [.font: Dash.mono(10.5), .foregroundColor: Dash.text3])
            let ns = num.size()
            num.draw(at: NSPoint(x: r.minX + 30 - ns.width, y: r.midY - ns.height / 2))
            let time = NSAttributedString(string: t.duration.map(AlbumCell.length) ?? "", attributes: [.font: Dash.mono(10.5), .foregroundColor: Dash.text3])
            let tw = time.size().width
            time.draw(at: NSPoint(x: r.maxX - tw, y: r.midY - time.size().height / 2))
            GridCovers.text(t.title, Dash.font(13), t.playable ? Dash.text : Dash.text3, x: r.minX + 38, y: r.midY - 8,
                            width: r.width - 38 - tw - 10, lines: 1)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onPlay?(i)
    }
}
