import AppKit
import ImageIO
import UniformTypeIdentifiers

/// "Edit Tags…" for one release: the album's fields, every track's title, artist and numbers, and its cover
/// (dropped in or chosen), written into its MP3 and FLAC files. Only what was changed is written.
final class TagEditorSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row {
        let path: String
        var title: String, artist: String, number: String, disc: String
        /// MP3 or FLAC, one track per file (a CUE sheet's tracks share theirs).
        let editable: Bool
    }
    private let album: LibraryAlbum
    private var rows: [Row]
    private let original: [Row]
    private let initial: (artist: String, album: String, year: String, genre: String)

    private let table = KeyTableView()
    private let scroll = NSScrollView()
    private let well = CoverWell()
    private let artist = DashField(), albumField = DashField(), year = DashField(), genre = DashField(), comment = DashField()
    /// The comment in the first file, once read (it isn't in the library's database).
    private var initialComment = ""
    private let saveCover = DashCheck(checkboxWithTitle: "", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var applyButton: Pill!
    private var cancelButton: Pill?
    private var busy = false
    /// A new cover, ready to write (JPEG or PNG).
    private var coverData: Data? { didSet { saveCover.isEnabled = coverData != nil } }

    /// Called when done (with a line for the status bar), or with nil when cancelled.
    var onDone: ((String?) -> Void)?

    init(album: LibraryAlbum, tracks: [LibraryTrack], genre: String?) {
        self.album = album
        let counts = Dictionary(tracks.map { ($0.path, 1) }, uniquingKeysWith: +)
        rows = tracks.sorted { ($0.disc ?? 0, $0.number ?? 0) < ($1.disc ?? 0, $1.number ?? 0) }.map { t in
            Row(path: t.path, title: t.title, artist: t.artist, number: t.number.map(String.init) ?? "", disc: t.disc.map(String.init) ?? "",
                editable: counts[t.path] == 1 && TagEditorSheet.writable(t.path))
        }
        original = rows
        initial = (album.artist, album.title, album.year.map(String.init) ?? "", genre ?? "")
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        super.init(window: w)
        build()
        _ = LibraryArt.shared.load(album, large: true) { [weak self] img in
            guard let self, self.coverData == nil else { return }
            self.well.art.image = img
        }
        // Off the main thread: the file may be on a slow share.
        if let first = rows.first?.path {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let c = DetailsReader.read(path: first, folderArt: false).comment ?? ""
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.comment.stringValue.isEmpty else { return }
                        self.initialComment = c
                        self.comment.stringValue = c
                    }
                }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    nonisolated static func writable(_ path: String) -> Bool { ["mp3", "flac"].contains((path as NSString).pathExtension.lowercased()) }

    // MARK: Layout

    private func build() {
        let title = NSTextField(labelWithAttributedString: Dash.title("Edit tags"))
        // Some of a release's tracks: those are what's written, album fields included.
        let subject = rows.count == 1 ? "\(rows[0].artist) — \(rows[0].title)" : "\(album.artist) — \(album.title)"
        let what = Dash.label(subject, Dash.font(13, .medium), Dash.text)
        what.lineBreakMode = .byTruncatingTail

        for (id, width, flexible) in [("disc", 34.0, false), ("number", 34.0, false), ("title", 260.0, true), ("artist", 160.0, true)] {
            let c = ListLook.column(id, width, flexible: flexible)
            c.title = ["disc": "Disc", "number": "#", "title": "Title", "artist": "Artist"][id] ?? id
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        Dash.applyList(table, in: scroll, rowHeight: 26)
        table.headerView = NSTableHeaderView()

        well.art.cornerRadius = 3
        well.art.surface = Dash.cardRaised
        well.art.iconColor = Dash.text3
        well.art.onClick = { [weak self] in self?.chooseCover() }
        well.onDrop = { [weak self] url in self?.useCover(at: url) }
        well.toolTip = "Click to choose a cover, or drop an image here"
        well.widthAnchor.constraint(equalToConstant: 150).isActive = true
        well.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let form = NSGridView(numberOfColumns: 2, rows: 0)
        form.rowSpacing = 6
        form.columnSpacing = 8
        for (name, field, now) in [("ALBUM ARTIST", artist, initial.artist), ("ALBUM", albumField, initial.album),
                                   ("YEAR", year, initial.year), ("GENRE", genre, initial.genre), ("COMMENT", comment, "")] {
            field.stringValue = now
            field.font = Dash.font(13)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            let l = NSTextField(labelWithString: name)
            l.font = Dash.mono(9, bold: true)
            l.textColor = Dash.text2
            form.addRow(with: [l, field])
        }
        form.column(at: 0).xPlacement = .trailing

        saveCover.title = album.sharedFolder ? "Also use it as this release's cover in OmniAmp" : "Also save it as the folder's cover file"
        saveCover.state = .on
        saveCover.isEnabled = false
        saveCover.font = Dash.font(12)

        let files = Set(rows.filter(\.editable).map(\.path)).count
        let others = rows.filter { !$0.editable }.count
        status.font = Dash.font(11.5)
        status.textColor = Dash.text2
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.stringValue = files == 0 ? "No MP3 or FLAC files here: tags can't be written."
            : "Writes into \(files) MP3/FLAC file\(files == 1 ? "" : "s")" + (others > 0 ? " · \(others) other track\(others == 1 ? "" : "s") greyed out" : "")
        let cancel = Pill("Cancel", target: self, action: #selector(cancel))
        cancelButton = cancel
        cancel.keyEquivalent = "\u{1b}"
        applyButton = Pill("Apply", target: self, action: #selector(apply))
        applyButton.prominent = true
        applyButton.isEnabled = files > 0
        let bottom = NSStackView(views: [status, NSView(), cancel, applyButton])

        let left = NSStackView(views: [well, form, saveCover])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 12

        let root = TagEditorPage()
        for v in [title, what, left, scroll, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            what.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            what.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 12),
            what.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            left.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            left.widthAnchor.constraint(equalToConstant: 300),
            scroll.topAnchor.constraint(equalTo: left.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        window?.contentView = root
    }

    // MARK: Tracks

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let f = NSTextField(string: value(rows[row], id))
        f.isBordered = false
        f.drawsBackground = false
        f.font = id == "disc" || id == "number" ? Dash.mono(11.5) : Dash.font(12.5)
        f.textColor = rows[row].editable ? Dash.text : Dash.text3
        f.isEditable = rows[row].editable
        f.lineBreakMode = .byTruncatingTail
        f.cell?.sendsActionOnEndEditing = true
        f.tag = row
        f.identifier = NSUserInterfaceItemIdentifier(id)
        f.target = self
        f.action = #selector(edited(_:))
        return f
    }

    private func value(_ r: Row, _ id: String) -> String {
        switch id {
        case "disc": r.disc
        case "number": r.number
        case "title": r.title
        default: r.artist
        }
    }

    @objc private func edited(_ f: NSTextField) {
        guard f.tag < rows.count else { return }
        let v = f.stringValue.trimmingCharacters(in: .whitespaces)
        switch f.identifier?.rawValue {
        case "disc": rows[f.tag].disc = v
        case "number": rows[f.tag].number = v
        case "title": rows[f.tag].title = v
        default: rows[f.tag].artist = v
        }
    }

    // MARK: Cover

    private func chooseCover() {
        guard let w = window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.useCover(at: url)
        }
    }

    private func useCover(at url: URL) {
        guard let data = try? Data(contentsOf: url), let bytes = Self.coverBytes(data) else {
            status.stringValue = "That file isn't an image OmniAmp can read."
            return
        }
        coverData = bytes
        well.art.image = ArtworkStore.image(bytes, maxPixels: 600)
    }

    /// JPEG and PNG up to 2 MB as they are; anything else (or bigger) as a JPEG at most 1200 px wide, so a cover
    /// in every file doesn't add megabytes to each.
    nonisolated static func coverBytes(_ data: Data) -> Data? {
        let plain = data.starts(with: [0xFF, 0xD8]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        if plain, data.count <= 2 << 20 { return data }
        guard let img = ArtworkStore.image(data, maxPixels: 1200) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // MARK: Writing

    @objc private func cancel() {
        guard !busy else { return }
        onDone?(nil)
    }

    @objc private func apply() {
        guard !busy else { return }
        window?.makeFirstResponder(nil)   // the field being typed in ends its edit
        func changed(_ f: NSTextField, _ was: String) -> String? {
            let v = f.stringValue.trimmingCharacters(in: .whitespaces)
            return v.isEmpty || v == was ? nil : v
        }
        var shared = BasicTags(artist: changed(artist, initial.artist), album: changed(albumField, initial.album),
                               year: changed(year, initial.year), genre: changed(genre, initial.genre))
        shared.comment = changed(comment, initialComment)
        shared.cover = coverData
        var jobs: [(String, BasicTags)] = []
        for (r, was) in zip(rows, original) where r.editable {
            var t = shared
            func diff(_ a: String, _ b: String) -> String? { a.isEmpty || a == b ? nil : a }
            t.title = diff(r.title, was.title)
            t.trackArtist = diff(r.artist, was.artist)
            t.track = diff(r.number, was.number)
            t.disc = diff(r.disc, was.disc)
            if !t.isEmpty { jobs.append((r.path, t)) }
        }
        let folderCover = saveCover.state == .on ? coverData : nil
        guard !jobs.isEmpty || folderCover != nil else { onDone?("Nothing changed."); return }
        busy = true
        cancelButton?.isEnabled = false
        applyButton.isEnabled = false
        status.stringValue = "Writing…"
        let folder = album.folder, release = album.sharedFolder ? album.firstPath : nil
        let wrote = coverData != nil, todo = jobs
        Task { @MainActor [weak self] in
            let result = await Task.detached { TagEditorSheet.write(todo, cover: folderCover, folder: folder, release: release) }.value
            if wrote { LibraryArt.shared.forget(folder: folder) }
            // The files keep their dates (TagWriter): told to read them again rather than left to notice.
            MusicCollection.shared.reread(todo.map(\.0), in: folder)
            self?.onDone?(result)
        }
    }

    /// Off the main thread: each file's tags, then the cover for the folder (FindInfoSheet's way). A line for the status bar.
    nonisolated static func write(_ jobs: [(String, BasicTags)], cover: Data?, folder: String, release: String?) -> String {
        var written = 0, failed: [String] = [], skipped: [String] = []
        for (p, t) in jobs {
            switch TagWriter.write(t, to: p) {
            case .written: written += 1
            case .unchanged: break
            case .unsupported(let why): skipped.append(why)
            case .failed(let why): failed.append("\((p as NSString).lastPathComponent): \(why)")
            }
        }
        var parts: [String] = []
        if written > 0 { parts.append("tags written into \(written) file\(written == 1 ? "" : "s")") }
        if cover != nil {
            // Its line, as a part of this one ("Saved cover.jpg." → "saved cover.jpg").
            var line = FindInfoSheet.write(BasicTags(), paths: [], cover: cover, folder: folder, release: release)
            if line.hasSuffix(".") { line.removeLast() }
            parts.append(line.prefix(1).lowercased() + line.dropFirst())
        }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped (\(Set(skipped).sorted().joined(separator: ", ")))") }
        if !failed.isEmpty { parts.append("\(failed.count) failed: \(failed[0])") }
        let line = parts.joined(separator: " · ")
        return line.isEmpty ? "Nothing changed." : line.prefix(1).uppercased() + line.dropFirst() + "."
    }
}

/// The cover, which takes a dropped image file.
private final class CoverWell: NSView {
    let art = ArtView()
    var onDrop: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(art)
        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: leadingAnchor), art.trailingAnchor.constraint(equalTo: trailingAnchor),
            art.topAnchor.constraint(equalTo: topAnchor), art.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func image(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL]
        return urls?.first
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { image(sender) == nil ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = image(sender) else { return false }
        onDrop?(url)
        return true
    }
}

/// The theme's page color, drawn (a sheet's own background is see-through material).
private final class TagEditorPage: NSView {
    override func draw(_ dirtyRect: NSRect) { Dash.page.setFill(); dirtyRect.fill() }
}
