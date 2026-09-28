import AppKit

/// "Find Missing Info…" for one release: looks it up online (MusicBrainz, iTunes, Deezer, and archive.org
/// for shows), lets you pick a match and adjust artist, album, year and genre, then writes those into the
/// files (MP3, FLAC) and saves the cover as cover.jpg in the album's folder.
final class FindInfoSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let album: LibraryAlbum
    private let tracks: [LibraryTrack]
    private let currentGenre: String?
    private var candidates: [InfoCandidate] = []
    private var thumbs: [URL: CGImage] = [:]
    private var searchTask: Task<Void, Never>?

    private let queryArtist = NSTextField()
    private let queryAlbum = NSTextField()
    private let table = KeyTableView()
    private let scroll = NSScrollView()
    private let cover = ArtView()
    private let artist = NSTextField(), albumField = NSTextField(), year = NSTextField(), genre = NSTextField()
    private let writeTags = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let saveCover = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var applyButton: NSButton!
    private var coverData: Data?
    private var coverTask: Task<Void, Never>?
    /// The folder's own cover file, if it has one.
    private let existingCover: String?

    /// Called on the main thread when done (with a line for the status bar), or with nil when cancelled.
    var onDone: ((String?) -> Void)?

    init(album: LibraryAlbum, tracks: [LibraryTrack], genre: String?) {
        self.album = album
        self.tracks = tracks
        self.currentGenre = genre
        existingCover = DetailsReader.folderArtName(in: album.folder)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        super.init(window: w)
        build()
        search()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func label(_ s: String, size: CGFloat = 10, bold: Bool = true) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Fonts.hack(size, bold: bold)
        l.textColor = LibraryStyle.header
        return l
    }

    private func build() {
        window?.backgroundColor = Theme.background
        let title = label("FIND MISSING INFO", size: 11)
        title.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        let what = label(album.kind == .show ? "\(album.artist) · \(album.title)" : "\(album.artist) — \(album.title)", size: 11, bold: false)
        what.textColor = Theme.playlistText
        what.lineBreakMode = .byTruncatingTail

        for (f, v, ph) in [(queryArtist, album.artist, "Artist"), (queryAlbum, album.kind == .show ? "" : album.title, "Album")] {
            f.stringValue = v
            f.placeholderString = ph
            f.font = Fonts.hack(11)
        }
        let searchButton = ModernButton(glyph: Fonts.Icon.search, label: "SEARCH", target: self, action: #selector(searchClicked))
        searchButton.glyphSize = 10
        searchButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let queryRow = NSStackView(views: [queryArtist, queryAlbum, searchButton])
        queryRow.spacing = 6
        queryArtist.widthAnchor.constraint(equalTo: queryAlbum.widthAnchor, multiplier: 0.7).isActive = true

        table.addTableColumn(ListLook.column("candidate", 400, flexible: true))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(apply)
        ListLook.apply(table, in: scroll, rowHeight: 50)

        cover.cornerRadius = 3
        cover.widthAnchor.constraint(equalToConstant: 150).isActive = true
        cover.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let form = NSGridView(numberOfColumns: 2, rows: 0)
        form.rowSpacing = 5
        form.columnSpacing = 8
        for (name, field, now) in [("ARTIST", artist, album.artist), ("ALBUM", albumField, album.title),
                                   ("YEAR", year, album.year.map(String.init) ?? ""), ("GENRE", genre, currentGenre ?? "")] {
            field.stringValue = now
            field.font = Fonts.hack(11)
            field.placeholderString = "(leave as it is)"
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
            form.addRow(with: [label(name, size: 9), field])
            let was = NSTextField(labelWithString: now.isEmpty ? "now: nothing" : "now: \(now)")
            was.font = Fonts.hack(8.5)
            was.textColor = Theme.phosphorDim
            was.lineBreakMode = .byTruncatingTail
            form.addRow(with: [NSGridCell.emptyContentView, was])
        }
        form.column(at: 0).xPlacement = .trailing

        let writable = tracks.filter { ["mp3", "flac"].contains(($0.path as NSString).pathExtension.lowercased()) }
        let files = Set(writable.map(\.path)).count
        writeTags.title = files == 0 ? "No MP3 or FLAC files to write tags into" : "Write into the \(files) MP3/FLAC file\(files == 1 ? "" : "s")"
        writeTags.state = files > 0 ? .on : .off
        writeTags.isEnabled = files > 0
        saveCover.title = existingCover.map { "Replace \($0) with this cover" } ?? "Save the cover as cover.jpg in the folder"
        saveCover.state = existingCover == nil ? .on : .off
        for b in [writeTags, saveCover] {
            b.font = Fonts.hack(10)
            b.contentTintColor = Theme.phosphor
        }

        status.font = Fonts.hack(10)
        status.textColor = LibraryStyle.dim
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        applyButton = NSButton(title: "Apply", target: self, action: #selector(apply))
        applyButton.keyEquivalent = "\r"
        let bottom = NSStackView(views: [status, NSView(), cancel, applyButton])

        let right = NSStackView(views: [cover, form, writeTags, saveCover])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        right.setCustomSpacing(14, after: cover)

        let root = NSView()
        for v in [title, what, queryRow, scroll, right, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            what.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            what.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 12),
            what.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            queryRow.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            queryRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            queryRow.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: queryRow.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            right.topAnchor.constraint(equalTo: queryRow.topAnchor),
            right.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 16),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            right.widthAnchor.constraint(equalToConstant: 320),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        window?.contentView = root
    }

    // MARK: Searching

    @objc private func searchClicked() { search() }

    private func search() {
        searchTask?.cancel()
        candidates = []
        table.reloadData()
        status.stringValue = "Searching MusicBrainz, iTunes, Deezer" + (album.showDate != nil ? " and archive.org…" : "…")
        let a = queryArtist.stringValue, b = queryAlbum.stringValue, date = album.showDate
        searchTask = Task { @MainActor [weak self] in
            // An empty album field (a show): the date is what's searched for.
            let found = await MetadataLookup.shared.candidates(artist: a, album: b.isEmpty ? (date ?? "") : b, showDate: date)
            guard let self, !Task.isCancelled else { return }
            self.candidates = found
            self.table.reloadData()
            self.status.stringValue = found.isEmpty ? "Nothing found. Try other words above, or fill in the fields yourself."
                : "\(found.count) match\(found.count == 1 ? "" : "es"). Pick one, check the fields, then Apply."
            if !found.isEmpty, found[0].score >= 0.8 { self.table.selectRowIndexes([0], byExtendingSelection: false) }
            for c in found { if let u = c.thumbURL { self.loadThumb(u) } }
        }
    }

    private func loadThumb(_ url: URL) {
        Task { @MainActor [weak self] in
            guard let data = await MetadataLookup.shared.image(url), let img = ArtworkStore.image(data, maxPixels: 120) else { return }
            self?.thumbs[url] = img
            if let self, let row = self.candidates.firstIndex(where: { $0.thumbURL == url }) {
                self.table.reloadData(forRowIndexes: [row], columnIndexes: [0])
                if self.table.selectedRow == row, self.cover.image == nil { self.cover.image = img }
            }
        }
    }

    // MARK: Picking

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        guard r >= 0, r < candidates.count else { return }
        let c = candidates[r]
        artist.stringValue = c.artist
        albumField.stringValue = c.album
        if let y = c.year { year.stringValue = String(y) }
        if let g = c.genre { genre.stringValue = g }
        cover.image = c.thumbURL.flatMap { thumbs[$0] }
        coverData = nil
        coverTask?.cancel()
        guard let url = c.coverURL else { return }
        // The large cover, fetched now so Apply saves right away.
        coverTask = Task { @MainActor [weak self] in
            let data = await MetadataLookup.shared.image(url)
            guard let self, !Task.isCancelled, self.table.selectedRow == r else { return }
            self.coverData = data
            if let data, let img = ArtworkStore.image(data, maxPixels: 300) { self.cover.image = img }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PlaylistRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = candidates[row]
        let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cand"), owner: nil) as? CandidateCell) ?? CandidateCell()
        cell.show(c, thumb: c.thumbURL.flatMap { thumbs[$0] })
        return cell
    }

    // MARK: Applying

    @objc private func cancel() {
        searchTask?.cancel()
        coverTask?.cancel()
        onDone?(nil)
    }

    @objc private func apply() {
        func value(_ f: NSTextField) -> String? {
            let v = f.stringValue.trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        let tags = BasicTags(artist: value(artist), album: value(albumField), year: value(year), genre: value(genre))
        let paths = writeTags.state == .on
            ? Array(Set(tracks.map(\.path).filter { ["mp3", "flac"].contains(($0 as NSString).pathExtension.lowercased()) })).sorted() : []
        let folder = album.folder
        let wantCover = saveCover.state == .on
        let pendingCover = coverTask
        let chosenURL = table.selectedRow >= 0 && table.selectedRow < candidates.count ? candidates[table.selectedRow].coverURL : nil
        applyButton.isEnabled = false
        status.stringValue = "Writing…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            var data = self.coverData
            if wantCover, data == nil, let url = chosenURL {
                await pendingCover?.value
                data = self.coverData
                if data == nil { data = await MetadataLookup.shared.image(url) }
            }
            let coverBytes = wantCover ? data : nil
            let result = await Task.detached { FindInfoSheet.write(tags, paths: paths, cover: coverBytes, folder: folder) }.value
            if coverBytes != nil { LibraryArt.shared.forget(folder: folder) }
            MusicCollection.shared.rescan(folder: folder)
            self.onDone?(result)
        }
    }

    /// Off the main thread: tags into the files, the cover into the folder. Returns a line for the status bar.
    nonisolated static func write(_ tags: BasicTags, paths: [String], cover: Data?, folder: String) -> String {
        var written = 0, failed: [String] = [], skipped: [String] = []
        if !tags.isEmpty {
            for p in paths {
                switch TagWriter.write(tags, to: p) {
                case .written: written += 1
                case .unchanged: break
                case .unsupported(let why): skipped.append(why)
                case .failed(let why): failed.append("\((p as NSString).lastPathComponent): \(why)")
                }
            }
        }
        var parts: [String] = []
        if written > 0 { parts.append("tags written into \(written) file\(written == 1 ? "" : "s")") }
        if let cover {
            let ext = cover.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
            if (try? cover.write(to: URL(exactPath: folder + "/cover." + ext), options: .atomic)) != nil {
                parts.append("saved cover.\(ext)")
            } else {
                failed.append("couldn't save the cover in the folder")
            }
        }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped (\(Set(skipped).sorted().joined(separator: ", ")))") }
        if !failed.isEmpty { parts.append("\(failed.count) failed: \(failed[0])") }
        return parts.isEmpty ? "Nothing changed." : parts.joined(separator: " · ").prefix(1).uppercased() + parts.joined(separator: " · ").dropFirst() + "."
    }
}

/// A match in the list: cover, "Album — Artist", source and details.
final class CandidateCell: NSTableCellView {
    private let art = ArtView()
    private let title = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("cand")
        art.cornerRadius = 2
        for f in [title, sub] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.lineBreakMode = .byTruncatingTail
            addSubview(f)
        }
        addSubview(art)
        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            art.centerYAnchor.constraint(equalTo: centerYAnchor),
            art.widthAnchor.constraint(equalToConstant: 40), art.heightAnchor.constraint(equalToConstant: 40),
            title.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ c: InfoCandidate, thumb: CGImage?) {
        art.placeholder = c.source == .archive ? LibraryWindowController.Section.shows.glyph : Fonts.Icon.music
        art.image = thumb
        title.stringValue = "\(c.album) — \(c.artist)"
        title.font = Fonts.hack(11.5, bold: true)
        title.textColor = Theme.playlistText
        sub.stringValue = ([c.source.rawValue.uppercased()] + [c.year.map(String.init), c.genre, c.detail].compactMap { $0 }.filter { !$0.isEmpty })
            .joined(separator: " · ")
        sub.font = Fonts.hack(9.5)
        sub.textColor = LibraryStyle.dim
    }
}
