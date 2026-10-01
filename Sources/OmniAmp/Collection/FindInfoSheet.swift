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

    private let queryArtist = DashField()
    private let queryAlbum = DashField()
    private let table = KeyTableView()
    private let scroll = NSScrollView()
    private let cover = ArtView()
    private let artist = DashField(), albumField = DashField(), year = DashField(), genre = DashField()
    private let writeTags = DashCheck(checkboxWithTitle: "", target: nil, action: nil)
    private let saveCover = DashCheck(checkboxWithTitle: "", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var applyButton: Pill!
    private var cancelButton: Pill?
    /// Writing: a second Apply (double-click on a match) or Cancel must wait for it.
    private var busy = false
    private var coverData: Data?
    private var coverTask: Task<Void, Never>?
    /// The folder's own cover file, if it has one.
    private let existingCover: String?
    /// No artist in the tags: guesses from the names, and the track titles to search for.
    private let unknownArtist: Bool
    private let guesses: [ReleaseGuess.Guess]

    /// Called on the main thread when done (with a line for the status bar), or with nil when cancelled.
    var onDone: ((String?) -> Void)?

    init(album: LibraryAlbum, tracks: [LibraryTrack], genre: String?) {
        self.album = album
        self.tracks = tracks
        self.currentGenre = genre
        existingCover = DetailsReader.folderArtName(in: album.folder)
        unknownArtist = ["unknown artist", ""].contains(album.artistKey)
        guesses = unknownArtist ? ReleaseGuess.guesses(folder: album.folder, albumTitle: album.title,
                                                       fileNames: tracks.map { ($0.path as NSString).lastPathComponent },
                                                       titles: tracks.map(\.title)) : []
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
        l.font = Dash.mono(size, bold: bold)
        l.textColor = Dash.text2
        return l
    }

    private func build() {
        window?.backgroundColor = Dash.page
        let title = NSTextField(labelWithAttributedString: Dash.title("Find missing info"))
        let what = Dash.label(album.kind == .show ? "\(album.artist) · \(album.title)" : "\(album.artist) — \(album.title)", Dash.font(13, .medium), Dash.text)
        what.lineBreakMode = .byTruncatingTail

        let first = guesses.first
        for (f, v, ph) in [(queryArtist, first?.artist ?? album.artist, "Artist"),
                           (queryAlbum, first?.album ?? (album.kind == .show ? "" : album.title), "Album")] {
            f.stringValue = v
            f.placeholderString = ph
            f.font = Dash.font(13)
        }
        let searchButton = Pill("Search", glyph: Fonts.Icon.search, target: self, action: #selector(searchClicked))
        let queryRow = NSStackView(views: [queryArtist, queryAlbum, searchButton])
        queryRow.spacing = 6
        queryArtist.widthAnchor.constraint(equalTo: queryAlbum.widthAnchor, multiplier: 0.7).isActive = true

        table.addTableColumn(ListLook.column("candidate", 400, flexible: true))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(apply)
        Dash.applyList(table, in: scroll, rowHeight: 56)

        cover.cornerRadius = 3
        cover.widthAnchor.constraint(equalToConstant: 150).isActive = true
        cover.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let form = NSGridView(numberOfColumns: 2, rows: 0)
        form.rowSpacing = 5
        form.columnSpacing = 8
        // Placeholders ("Unknown Artist") aren't values: those fields start empty, so they're left alone unless filled.
        let knownArtist = ["unknown artist", ""].contains(album.artistKey) ? "" : album.artist
        let knownTitle = Keys.fold(album.title) == "unknown album" ? "" : album.title
        for (name, field, now) in [("ARTIST", artist, knownArtist), ("ALBUM", albumField, knownTitle),
                                   ("YEAR", year, album.year.map(String.init) ?? ""), ("GENRE", genre, currentGenre ?? "")] {
            field.stringValue = now
            field.font = Dash.font(13)
            field.placeholderString = "(leave as it is)"
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
            form.addRow(with: [label(name, size: 9), field])
            let was = NSTextField(labelWithString: now.isEmpty ? "now: nothing" : "now: \(now)")
            was.font = Dash.font(10.5)
            was.textColor = Dash.text3
            was.lineBreakMode = .byTruncatingTail
            form.addRow(with: [NSGridCell.emptyContentView, was])
        }
        form.column(at: 0).xPlacement = .trailing

        let writable = tracks.filter { ["mp3", "flac"].contains(($0.path as NSString).pathExtension.lowercased()) }
        let files = Set(writable.map(\.path)).count
        writeTags.title = files == 0 ? "No MP3 or FLAC files to write tags into" : "Write into the \(files) MP3/FLAC file\(files == 1 ? "" : "s")"
        writeTags.state = files > 0 ? .on : .off
        writeTags.isEnabled = files > 0
        if album.sharedFolder {
            // A cover.jpg would be every release's in that folder: this one's is kept in OmniAmp instead.
            saveCover.title = "Use this cover for this release (its folder holds others, so no cover.jpg)"
            saveCover.state = .on
        } else {
            saveCover.title = existingCover.map { "Replace \($0) with this cover" } ?? "Save the cover as cover.jpg in the folder"
            saveCover.state = existingCover == nil ? .on : .off
        }
        for b in [writeTags, saveCover] {
            b.font = Dash.font(12)
        }

        status.font = Dash.font(11.5)
        status.textColor = Dash.text2
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = Pill("Cancel", target: self, action: #selector(cancel))
        cancelButton = cancel
        cancel.keyEquivalent = "\u{1b}"
        applyButton = Pill("Apply", target: self, action: #selector(apply))
        applyButton.prominent = true
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
        // No artist in the tags: also the songs themselves (MusicBrainz knows which releases have them), and the guess.
        let songs = unknownArtist ? ReleaseGuess.searchTitles(tracks.map { ($0.title, $0.duration) }, artist: a.isEmpty ? nil : a) : []
        if !songs.isEmpty { status.stringValue = "Searching for \(a.isEmpty ? "the release" : a) and for \(min(songs.count, 4)) of your song titles…" }
        let guessed = guesses.map { g in
            InfoCandidate(source: .names, artist: g.artist, album: g.album, year: g.year, genre: nil, thumbURL: nil, coverURL: nil,
                          detail: "a guess \(g.why)", score: 0.3)
        }
        let unknown = unknownArtist
        searchTask = Task { @MainActor [weak self] in
            // An empty album field (a show): the date is what's searched for.
            async let bySongs = MetadataLookup.shared.identify(songs, artistHint: a.isEmpty ? nil : a)
            let named = a.isEmpty && b.isEmpty ? [] : await MetadataLookup.shared.candidates(artist: a, album: b.isEmpty ? (date ?? "") : b, showDate: date)
            // Searched by artist alone: any of their albums; the songs tell which.
            var found = await bySongs + named.map { c in var c = c; if b.isEmpty, unknown { c.score *= 0.6 }; return c }
            found.sort { $0.score > $1.score }
            found += guessed
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
            guard let data = await MetadataLookup.shared.image(url),
                  let img = await Task.detached(operation: { ArtworkStore.image(data, maxPixels: 120) }).value else { return }
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
            // Decoded off the main thread (a full-size original can take a moment).
            if let data, let img = await Task.detached(operation: { ArtworkStore.image(data, maxPixels: 300) }).value,
               !Task.isCancelled, self.table.selectedRow == r { self.cover.image = img }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { tableView.reusableRowView("cardRow", CardRowView.init) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = candidates[row]
        let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cand"), owner: nil) as? CandidateCell) ?? CandidateCell()
        cell.show(c, thumb: c.thumbURL.flatMap { thumbs[$0] })
        return cell
    }

    // MARK: Applying

    @objc private func cancel() {
        guard !busy else { return }
        searchTask?.cancel()
        coverTask?.cancel()
        onDone?(nil)
    }

    @objc private func apply() {
        guard !busy else { return }
        busy = true
        cancelButton?.isEnabled = false
        func value(_ f: NSTextField) -> String? {
            let v = f.stringValue.trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        let tags = BasicTags(artist: value(artist), album: value(albumField), year: value(year), genre: value(genre))
        let paths = writeTags.state == .on
            ? Array(Set(tracks.map(\.path).filter { ["mp3", "flac"].contains(($0 as NSString).pathExtension.lowercased()) })).sorted() : []
        let folder = album.folder, release = album.sharedFolder ? album.firstPath : nil   // as LibraryArt knows it
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
            let result = await Task.detached { FindInfoSheet.write(tags, paths: paths, cover: coverBytes, folder: folder, release: release) }.value
            if coverBytes != nil { LibraryArt.shared.forget(folder: folder) }
            // The files keep their dates (TagWriter): told to read them again rather than left to notice.
            MusicCollection.shared.reread(paths, in: folder)
            self.onDone?(result)
        }
    }

    /// Off the main thread: tags into the files, the cover into the folder (or for a `release` sharing its folder
    /// with others, into OmniAmp's own store). Returns a line for the status bar.
    nonisolated static func write(_ tags: BasicTags, paths: [String], cover: Data?, folder: String, release: String? = nil) -> String {
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
        if let cover, let release {
            if (try? cover.write(to: LibraryArt.chosenFile(release: release), options: .atomic)) != nil {
                parts.append("cover kept for this release")
            } else {
                failed.append("couldn't keep the cover")
            }
        } else if let cover {
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
        art.cornerRadius = 4
        art.surface = Dash.cardRaised
        art.iconColor = Dash.text3
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
        title.font = Dash.font(13, .semibold)
        title.textColor = Dash.text
        sub.stringValue = ([c.source.rawValue.uppercased()] + [c.year.map(String.init), c.genre, c.detail].compactMap { $0 }.filter { !$0.isEmpty })
            .joined(separator: " · ")
        sub.font = Dash.font(11)
        sub.textColor = Dash.text2
    }
}
