import AppKit

/// A saved playlist's text, entry by entry, for editing: every line is kept as written (other apps' directives,
/// relative paths, entries OmniAmp can't play, files that are gone), so moving or removing one entry changes
/// nothing else in the file. Reading a playlist to play it is PlaylistFile's; this is only for changing one.
struct PlaylistDocument: Sendable {
    /// One entry: the lines before it (#EXTINF and any other directive) and the line naming the file or URL.
    struct Item: Sendable {
        let id: UUID
        var lines: [String]
        var refLine: String

        init(lines: [String], refLine: String) {
            id = UUID()
            self.lines = lines
            self.refLine = refLine
        }

        var ref: String { refLine.trimmingCharacters(in: .whitespaces) }
        /// What its #EXTINF says: the attributes (length first) and the title.
        var extinf: (head: String, title: String)? {
            lines.reversed().lazy.compactMap { PlaylistFile.extinf($0.trimmingCharacters(in: .whitespaces)) }.first
        }
    }

    /// #EXTM3U, #PLAYLIST: and the like before the first entry, and whatever follows the last one.
    var header: [String] = ["#EXTM3U"]
    var items: [Item] = []
    var trailer: [String] = []
    /// A .pls: shown, never written (its numbered keys would have to be renumbered; save it as .m3u8 to edit it).
    var readOnly = false

    static func parse(_ text: String, pls: Bool = false) -> PlaylistDocument {
        var doc = PlaylistDocument(header: [], items: [], trailer: [], readOnly: pls)
        if pls {
            doc.items = PlaylistFile.refs(text, pls: true).map { r in
                Item(lines: r.title.map { ["#EXTINF:-1,\($0)"] } ?? [], refLine: r.ref)
            }
            return doc
        }
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        body = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = body.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // the final line break
        var pending: [String] = []
        var inHeader = true
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if inHeader, t.hasPrefix("#EXTM3U") || t.hasPrefix("#PLAYLIST:") {
                doc.header.append(line)
                continue
            }
            inHeader = false
            if t.isEmpty || t.hasPrefix("#") { pending.append(line); continue }
            doc.items.append(Item(lines: pending, refLine: line))
            pending = []
        }
        doc.trailer = pending
        return doc
    }

    func text() -> String {
        var out = header.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTM3U") } ? header : ["#EXTM3U"] + header
        for i in items { out += i.lines + [i.refLine] }
        out += trailer
        return out.joined(separator: "\n") + "\n"
    }

    mutating func insert(_ tracks: [Track], at index: Int? = nil) {
        let new = tracks.map { t in
            let l = PlaylistFile.lines(for: t)
            return Item(lines: [l.extinf], refLine: l.ref)
        }
        items.insert(contentsOf: new, at: min(max(0, index ?? items.count), items.count))
    }

    /// Moves rows to just above `row` (a table's "above" drop); returns where they are now.
    @discardableResult
    mutating func move(_ rows: IndexSet, to row: Int) -> IndexSet {
        let valid = rows.filteredIndexSet { $0 < items.count }
        guard !valid.isEmpty else { return [] }
        let moving = valid.map { items[$0] }
        let target = min(max(0, row), items.count) - valid.count(where: { $0 < row })
        for i in valid.reversed() { items.remove(at: i) }
        items.insert(contentsOf: moving, at: target)
        return IndexSet(target..<(target + moving.count))
    }

    mutating func remove(_ rows: IndexSet) {
        for i in rows.reversed() where i < items.count { items.remove(at: i) }
    }

    /// An entry read the way playing the playlist reads it (relative paths against `base`, the playlist's folder).
    func entry(_ i: Int, base: URL) -> PlaylistFile.Entry? {
        let item = items[i], inf = item.extinf
        return PlaylistFile.entry(ref: item.ref, title: inf?.title, head: inf?.head, base: base)
    }
}

/// A saved playlist's entry as its page shows it: the library's tags where the file is in the library, else what
/// the playlist itself says (#EXTINF title and length, or the file name).
struct PlaylistRow: Sendable {
    let itemID: UUID
    var title: String
    var artist = ""
    var album = ""
    var duration: Double?
    var format = ""
    var library: LibraryTrack?
    /// What plays: nil for an entry that can't (a file that's gone, an unknown kind of line).
    var track: Track?
    var missing = false

    /// Rows for every entry. `db`: the library, on a connection of the caller's thread; `checkFiles`: look up the
    /// files the library doesn't know (a round trip each on a network share: never on the main thread).
    static func resolve(_ doc: PlaylistDocument, base: URL, db: CollectionDB?, checkFiles: Bool) -> [PlaylistRow] {
        let entries = doc.items.indices.map { doc.entry($0, base: base) }
        let keys = entries.compactMap { e -> String? in
            guard let e, e.url.isFileURL else { return nil }
            return e.cueStart.map { "\(e.url.path)#\($0)" } ?? e.url.path
        }
        let known = (try? db?.tracks(keys: keys)) ?? [:]
        return doc.items.indices.map { i in
            let item = doc.items[i], inf = item.extinf
            var row = PlaylistRow(itemID: item.id, title: inf?.title ?? item.ref)
            guard let e = entries[i] else { row.missing = true; return row }
            row.duration = e.seconds
            if let remote = PlaylistFile.remoteTrack(e) {
                row.track = remote
                row.title = remote.title ?? row.title
                row.artist = remote.artist ?? ""
                row.album = remote.podcast.map { $0.isEmpty ? "" : $0 } ?? ""
                row.duration = remote.duration ?? e.seconds
                row.format = remote.isStream ? "Radio" : remote.isWebFile ? "Web" : "Podcast"
                return row
            }
            let path = e.url.path
            if let t = known[e.cueStart.map { "\(path)#\($0)" } ?? path] {
                row.library = t
                row.track = t.playable ? t.track : nil
                row.title = t.title
                row.artist = t.artist
                row.album = t.album
                row.duration = t.duration ?? e.seconds
                row.format = t.format
                return row
            }
            if inf == nil || inf?.title.isEmpty == true { row.title = (path as NSString).lastPathComponent }
            row.format = (path as NSString).pathExtension.uppercased()
            if checkFiles, !ExactPath.exists(path) { row.missing = true; return row }
            var t = Track(path: path, size: 0, mtime: 0)
            t.cueStart = e.cueStart
            t.cueEnd = e.cueEnd
            t.cueNumber = e.cueNumber
            row.track = FolderScanner.audioExtensions.contains((path as NSString).pathExtension.lowercased()) ? t : nil
            return row
        }
    }
}

/// A group's color: Finder's color tags (the numbers are Finder's label numbers, so a color set in Finder shows up
/// here and the other way round), drawn in tones that sit well on the library's dark cards.
enum PlaylistColor: Int, CaseIterable, Sendable {
    case red = 6, orange = 7, yellow = 5, green = 2, blue = 4, purple = 3, gray = 1

    var name: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }

    var color: NSColor {
        switch self {
        case .red: Dash.rgb(0xE5534B)
        case .orange: Dash.rgb(0xE0823D)
        case .yellow: Dash.rgb(0xD4AE3A)
        case .green: Dash.rgb(0x57AB5A)
        case .blue: Dash.rgb(0x539BF5)
        case .purple: Dash.rgb(0xA67EF0)
        case .gray: Dash.rgb(0x8B949E)
        }
    }

    /// A small round swatch for menus.
    @MainActor var swatch: NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            self.color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

enum SavedPlaylistError: LocalizedError {
    case nameTaken(String), badName, readOnly, gone(String)

    var errorDescription: String? {
        switch self {
        case .nameTaken(let n): "There's already a playlist called “\(n)”."
        case .badName: "A playlist needs a name."
        case .readOnly: "OmniAmp can't change .pls playlists. Load it and save it as a new playlist to edit it."
        case .gone(let n): "The playlist “\(n)” isn't there anymore (deleted or renamed)."
        }
    }
}

/// The playlists in the saved-playlists folder (Application Support/OmniAmp/Playlists): the library's sidebar
/// lists them, the Playlist menu loads them, and songs are added to them from anywhere. They stay ordinary
/// .m3u8 files, so other players and Finder can use them too; changes made outside OmniAmp show up at once.
@MainActor
final class SavedPlaylists {
    static let shared = SavedPlaylists()
    /// The list, a name, or a playlist's entries changed.
    static let changed = Notification.Name("OmniAmpSavedPlaylistsChanged")

    /// A folder of playlists (one level: a group holds playlists, not other groups).
    struct Group: Equatable {
        let url: URL
        var color: PlaylistColor?
        var playlists: [URL]
        var name: String { url.lastPathComponent }
    }

    let directory: URL
    /// The groups A–Z, and the playlists in no group.
    private(set) var groups: [Group] = []
    private(set) var ungrouped: [URL] = []
    /// Every playlist, the groups' first.
    var urls: [URL] { groups.flatMap(\.playlists) + ungrouped }
    /// Each file's modification date when last listed: a change inside a playlist counts too.
    private var dates: [URL: Date] = [:]
    private let watcher = FolderWatcher()

    init(directory: URL = PlaylistFile.directory, watch: Bool = true) {
        self.directory = directory
        list()
        if watch {
            watcher.onEvents = { [weak self] _, _, _ in self?.refresh() }
            watcher.watch([directory.path])
        }
    }

    /// Reads the folder again; says so when anything changed (its own writes and Finder's alike).
    func refresh() {
        if list() { NotificationCenter.default.post(name: Self.changed, object: self) }
    }

    @discardableResult
    private func list() -> Bool {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .labelNumberKey]
        func items(_ dir: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
                .sorted { Self.name($0).localizedStandardCompare(Self.name($1)) == .orderedAscending }   // by name, as listed
        }
        var newGroups: [Group] = [], loose: [URL] = [], newDates: [URL: Date] = [:]
        func date(_ u: URL) { newDates[u] = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        for item in items(directory) {
            let v = try? item.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true, v?.isPackage != true {
                let lists = items(item).filter(PlaylistFile.isPlaylist)
                lists.forEach(date)
                newGroups.append(Group(url: item, color: v?.labelNumber.flatMap(PlaylistColor.init), playlists: lists))
            } else if PlaylistFile.isPlaylist(item) {
                loose.append(item)
                date(item)
            }
        }
        guard newGroups != groups || loose != ungrouped || newDates != dates else { return false }
        groups = newGroups
        ungrouped = loose
        dates = newDates
        return true
    }

    /// The group a playlist is in; nil for one in no group.
    func group(of url: URL) -> Group? {
        let dir = url.deletingLastPathComponent()
        return groups.first { Self.same($0.url, dir) }
    }

    static func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
    static func isReadOnly(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pls" }

    func document(_ url: URL) -> PlaylistDocument {
        guard let data = try? Data(contentsOf: url) else { return PlaylistDocument(header: [], readOnly: Self.isReadOnly(url)) }
        // An older playlist in Latin-1 is read as such (and written back as UTF-8 if it's changed).
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return PlaylistDocument.parse(text, pls: Self.isReadOnly(url))
    }

    /// `base`, or "base 2", "base 3"… whichever no playlist in that group (nil: in no group) has yet.
    func uniqueName(_ base: String, in group: URL? = nil) -> String {
        let siblings = group.map { g in groups.first { Self.same($0.url, g) }?.playlists ?? [] } ?? ungrouped
        return Self.unique(base, taken: Set(siblings.map { Self.name($0).lowercased() }))
    }

    /// The same file or folder: a folder's URL may or may not end in "/", and a listing may spell a folder by its
    /// real path (/private/var for /var). Only for comparing: standardizedFileURL decomposes accented names (see
    /// ExactPath), the same way on both sides, so it's never used to reach a file.
    static func same(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.path == b.standardizedFileURL.path }

    private static func unique(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// A name for a playlist made from these songs: their album, else their artist.
    nonisolated static func suggestedName(for tracks: [Track]) -> String {
        func shared(_ value: (Track) -> String?) -> String? {
            let all = Set(tracks.map { value($0)?.trimmingCharacters(in: .whitespaces) ?? "" })
            guard all.count == 1, let v = all.first, !v.isEmpty else { return nil }
            return v
        }
        return shared(\.album) ?? shared(\.artist) ?? "New Playlist"
    }

    /// A name usable as a file name: one line, no "/" or ":" (Finder shows ":" as "/"), not hidden, NFC (as typed
    /// on a Mac; the NAS keeps the bytes it's given).
    nonisolated static func cleanName(_ s: String) -> String? {
        var n = s.precomposedStringWithCanonicalMapping
            .components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while n.hasPrefix(".") { n.removeFirst() }
        n = n.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : String(n.prefix(200))
    }

    /// A new playlist (in a group, or in none); its name made unique if it's taken.
    @discardableResult
    func create(named name: String, tracks: [Track] = [], in group: URL? = nil) throws -> URL {
        guard let clean = Self.cleanName(name) else { throw SavedPlaylistError.badName }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = (group ?? directory).appendingExact(uniqueName(clean, in: group) + ".m3u8")
        var doc = PlaylistDocument()
        doc.insert(tracks)
        try write(doc, to: url)
        return url
    }

    func append(_ tracks: [Track], to url: URL) throws { try update(url) { $0.insert(tracks) } }

    /// Reads the playlist, changes it and writes it back. A playlist that's gone (deleted or renamed while songs
    /// were being read for it) isn't made again.
    func update(_ url: URL, _ edit: (inout PlaylistDocument) -> Void) throws {
        guard ExactPath.exists(url.path) else { throw SavedPlaylistError.gone(Self.name(url)) }
        var doc = document(url)
        guard !doc.readOnly else { throw SavedPlaylistError.readOnly }
        edit(&doc)
        try write(doc, to: url)
    }

    func write(_ doc: PlaylistDocument, to url: URL) throws {
        guard !doc.readOnly else { throw SavedPlaylistError.readOnly }
        try doc.text().write(to: url, atomically: true, encoding: .utf8)
        refresh()
    }

    /// Renames the file; returns where it is now.
    func rename(_ url: URL, to name: String) throws -> URL {
        guard let clean = Self.cleanName(name) else { throw SavedPlaylistError.badName }
        let target = url.deletingLastPathComponent().appendingExact(clean + "." + url.pathExtension)
        let siblings = group(of: url)?.playlists ?? ungrouped
        try Self.move(url, to: target, taken: siblings.contains { Self.name($0).lowercased() == clean.lowercased() }, name: clean)
        refresh()
        return target
    }

    /// Moves or renames a file or folder. Only a change of case: by way of another name (a case-insensitive disk
    /// sees the same item). `taken`: something else already has the name.
    private static func move(_ url: URL, to target: URL, taken: Bool, name: String) throws {
        let sameFolder = same(target.deletingLastPathComponent(), url.deletingLastPathComponent())
        guard target.lastPathComponent != url.lastPathComponent || !sameFolder else { return }
        let fm = FileManager.default
        if sameFolder,
           target.lastPathComponent.lowercased() == url.lastPathComponent.lowercased() {
            let hop = url.deletingLastPathComponent().appendingExact(".rename-" + UUID().uuidString)
            try fm.moveItem(at: url, to: hop)
            try fm.moveItem(at: hop, to: target)
            return
        }
        if taken || ExactPath.exists(target.path) { throw SavedPlaylistError.nameTaken(name) }
        try fm.moveItem(at: url, to: target)
    }

    /// Into a group (nil: out of any); a name the group has already gets a number. Returns where it is now.
    func move(_ url: URL, toGroup g: URL?) throws -> URL {
        let dest = g ?? directory
        guard !Self.same(dest, url.deletingLastPathComponent()) else { return url }
        let target = dest.appendingExact(uniqueName(Self.name(url), in: g) + "." + url.pathExtension)
        try FileManager.default.moveItem(at: url, to: target)
        refresh()
        return target
    }

    // MARK: Groups

    @discardableResult
    func createGroup(named name: String) throws -> URL {
        guard let clean = Self.cleanName(name) else { throw SavedPlaylistError.badName }
        let url = directory.appendingExact(Self.unique(clean, taken: Set(groups.map { $0.name.lowercased() })), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        refresh()
        return url
    }

    func renameGroup(_ url: URL, to name: String) throws -> URL {
        guard let clean = Self.cleanName(name) else { throw SavedPlaylistError.badName }
        let target = directory.appendingExact(clean, isDirectory: true)
        try Self.move(url, to: target, taken: groups.contains { !Self.same($0.url, url) && $0.name.lowercased() == clean.lowercased() }, name: clean)
        refresh()
        return target
    }

    /// Sets the folder's Finder color tag (nil: none).
    func setColor(_ color: PlaylistColor?, of group: URL) throws {
        var values = URLResourceValues()
        values.labelNumber = color?.rawValue ?? 0
        var u = group
        try u.setResourceValues(values)
        refresh()
    }

    /// The group goes; its playlists stay, in no group (renumbered where a name is taken). The emptied folder goes
    /// to the Trash, with anything else that was in it. Returns where each playlist went.
    @discardableResult
    func deleteGroup(_ url: URL) throws -> [URL: URL] {
        var moved: [URL: URL] = [:]
        for p in groups.first(where: { Self.same($0.url, url) })?.playlists ?? [] { moved[p] = try move(p, toGroup: nil) }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        refresh()
        return moved
    }

    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        refresh()
    }

    // MARK: Menus

    /// "Add to Playlist ▸": Current Playlist (the player's; none when `current` is nil), the saved playlists,
    /// New Playlist…. `saved` gets the playlist's URL as the item's representedObject.
    func addMenuItem(target: AnyObject, current: Selector?, saved: Selector, new: Selector) -> NSMenuItem {
        let sub = NSMenu(title: "Add to Playlist")
        sub.autoenablesItems = false
        if let current {
            sub.addItem(withTitle: "Current Playlist", action: current, keyEquivalent: "").target = target
            if !urls.isEmpty { sub.addItem(.separator()) }
        }
        fill(sub) { u in
            let it = NSMenuItem(title: Self.name(u), action: saved, keyEquivalent: "")
            it.target = target
            it.representedObject = u
            it.isEnabled = !Self.isReadOnly(u)
            return it
        }
        sub.addItem(.separator())
        sub.addItem(withTitle: "New Playlist…", action: new, keyEquivalent: "").target = target
        let item = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    /// The playlists into a menu: each group a submenu (with its color), then the ones in no group.
    func fill(_ menu: NSMenu, item: (URL) -> NSMenuItem) {
        for g in groups {
            let sub = NSMenu(title: g.name)
            sub.autoenablesItems = false
            g.playlists.forEach { sub.addItem(item($0)) }
            if g.playlists.isEmpty { sub.addItem(withTitle: "Empty", action: nil, keyEquivalent: "").isEnabled = false }
            let gi = NSMenuItem(title: g.name, action: nil, keyEquivalent: "")
            gi.image = g.color?.swatch
            gi.submenu = sub
            menu.addItem(gi)
        }
        ungrouped.forEach { menu.addItem(item($0)) }
    }

    /// Asks for a name (the songs' album or artist suggested), then makes the playlist. nil when cancelled or it failed.
    @discardableResult
    func promptNew(tracks: [Track]) -> URL? {
        let a = NSAlert()
        a.messageText = "New Playlist"
        a.informativeText = tracks.isEmpty ? "" : "With \(tracks.count == 1 ? "1 song" : "\(tracks.count.formatted()) songs")."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = uniqueName(Self.suggestedName(for: tracks))
        a.accessoryView = field
        a.addButton(withTitle: "Create")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        do { return try create(named: field.stringValue, tracks: tracks) } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }
}
