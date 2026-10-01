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
/// A song's plays, the last one (UNIX time; 0: never), and its plays per year.
struct PlayCount: Sendable, Equatable {
    var plays = 0
    var last = 0
    var byYear: [Int: Int] = [:]

    /// Plays in those years (all of them without).
    func plays(in years: ClosedRange<Int>?) -> Int {
        guard let years else { return plays }
        return byYear.reduce(0) { years.contains($1.key) ? $0 + $1.value : $0 }
    }
}

struct TrackRow: Sendable {
    let track: LibraryTrack
    let genre: String
    let year: Int?
    let added: Double
    let artistKey: String
    /// The song's key (Keys.title).
    let titleKey: String
    /// Who performs it (Keys.artist of the track's own artist; a compilation's tracks are "Various Artists" in the
    /// library but their own artist on last.fm).
    let performerKey: String
    /// Its plays are kept under the performer and the song. Worked out once (sorting by plays looks it up in every
    /// comparison).
    let countKey: String
    /// Its release's kind and whether it's lossless (what the filters look at).
    var kind: ReleaseKind = .album
    var official: Bool { kind.isOfficial }
    var lossless = false
    /// Its genres, split ("Disco; Soul" is both) and folded, for the genre filter.
    let genreKeys: [String]
    /// The genres as the column shows them (old ID3 numbers as names: "(17)" is Rock).
    let genreName: String
    /// Its album has more than one disc: the track number shows the disc ("2-05").
    var multiDisc = false
    let artistSort: String, albumSort: String, titleSort: String, genreSort: String

    /// `keys`: sort keys already worked out for this artist, album and genre (they repeat: each is folded once).
    /// `performerKey`: Keys.artist of the track's own artist (worked out once per artist by the caller).
    init(track: LibraryTrack, genre: String, year: Int?, added: Double, artistKey: String, titleKey: String? = nil,
         performerKey: String? = nil, genreKeys: [String]? = nil, genreName: String? = nil,
         keys: (artist: String, album: String, genre: String)? = nil) {
        self.track = track
        self.genre = genre
        self.year = year
        self.added = added
        self.artistKey = artistKey
        self.titleKey = titleKey ?? Keys.title(track.title)
        self.performerKey = performerKey ?? Keys.artist(track.artist)
        countKey = self.performerKey + "\u{1}" + self.titleKey
        self.genreKeys = genreKeys ?? Self.genreKeys(genre)
        artistSort = keys?.artist ?? Self.sortKey(Keys.sortName(track.artist))
        albumSort = keys?.album ?? Self.sortKey(track.album)
        titleSort = Self.sortKey(track.title)
        let name = genreName ?? CollectionDB.genres(genre).joined(separator: ", ")
        self.genreName = name
        genreSort = keys?.genre ?? Self.sortKey(name)
    }

    /// Case and accents don't count ("Björk" by "bjork"). Cheaper than `Keys.fold` (it runs for every track).
    static func sortKey(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// "Disco; Soul" → ["disco", "soul"] (split as the Genres section splits them).
    static func genreKeys(_ genre: String) -> [String] { CollectionDB.genres(genre).map(Keys.fold) }

    /// What the window's filters, the search (`ids`: its files; nil: no search) and the Tracks filter let through.
    /// `rangePlays`: each song's plays in the filter's played years, when it has some (worked out once by the caller).
    static func visible(_ rows: [TrackRow], filter: LibraryFilter, ids: Set<Int64>?, tracks: TrackFilter = TrackFilter(),
                        counts: [String: PlayCount] = [:], rangePlays: [String: Int]? = nil, now: Date = Date()) -> [TrackRow] {
        if filter == LibraryFilter(), ids == nil, tracks.isEmpty { return rows }
        let m = tracks.isEmpty ? nil : tracks.matcher(now: now)
        // Counts only looked up when a condition needs them (a year or genre filter doesn't).
        let needsCounts = tracks.usesCounts
        let inRange = tracks.playedYears == nil ? nil : rangePlays ?? counts.mapValues { $0.plays(in: tracks.playedYears) }
        return rows.filter { r in
            switch filter.scope {
            case .all: break
            case .official: if !r.official { return false }
            case .unofficial: if r.official { return false }
            }
            if filter.losslessOnly, !r.lossless { return false }
            if let ids, !ids.contains(r.track.id) { return false }
            guard let m else { return true }
            return needsCounts ? m.matches(r, counts[r.countKey], rangePlays: inRange?[r.countKey] ?? 0) : m.matches(r, nil)
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

    /// `counts`: plays per song (TrackRow.countKey), for the Plays and Last Played columns; `played`: the years
    /// Plays counts (a filter's played range; nil: all).
    func sorted(_ rows: [TrackRow], counts: [String: PlayCount] = [:], played: ClosedRange<Int>? = nil,
                rangePlays: [String: Int]? = nil) -> [TrackRow] {
        // Plays in a range: summed once per song (or handed in), not in every comparison.
        let inRange: [String: Int]? = column == .plays && played != nil ? rangePlays ?? counts.mapValues { $0.plays(in: played) } : nil
        return rows.sorted { a, b in
            let c = primary(a, b, counts, inRange)
            if c != 0 { return ascending ? c < 0 : c > 0 }
            return Self.natural(a, b)
        }
    }

    /// -1, 0 or 1 by the column; a missing value after a present one either way (so it's flipped back for descending).
    private func primary(_ a: TrackRow, _ b: TrackRow, _ counts: [String: PlayCount], _ inRange: [String: Int]?) -> Int {
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
        case .plays:
            if let inRange { return num(inRange[a.countKey] ?? 0, inRange[b.countKey] ?? 0) }
            return num(counts[a.countKey]?.plays ?? 0, counts[b.countKey]?.plays ?? 0)
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
    /// Filter words typed into the search were taken out of it (they're chips now): the search field's new text.
    var onSearchText: ((String) -> Void)?

    private let table = KeyTableView()
    private let scroll = NSScrollView()
    private let empty = EmptyNotice()
    /// Every track, sorted by `allSort`; `rows` is what the filters and the search let through of it.
    private var all: [TrackRow] = []
    private var allSort: TrackSort?
    /// The played years `all` was sorted with (it matters when sorted by Plays), and each song's plays in them
    /// (worked out once per refresh, for the sort, the filter and the Plays cells).
    private var allPlayed: ClosedRange<Int>?
    private var shownPlays: [String: Int]?
    /// One refresh at a time: a slider being dragged asks for one per mouse move, and only the latest matters.
    private var refreshing = false, refreshAgain = false, revealAgain = false
    /// What the play history was when the counts were read ("plays:newest"): unchanged, they aren't read again.
    private var countsFingerprint = ""
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
    /// The Tracks filter (the bar's chips), and a filter word still being typed in the search (it filters as it's
    /// typed, and becomes a chip once it's finished: a space after it, or Return).
    private var trackFilter = TrackFilter()
    private var typed = TrackFilter()
    private let bar = TrackFilterBar()

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
                // Hidden (another section, the window covered, in the Dock or closed): read when it's seen again, not on
                // every import page or play.
                if self.loaded, !self.isHidden, self.onScreen { self.readCounts() } else { self.countsDirty = true }
            }
        })
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        table.headerView?.menu = headerMenu
        showSortIndicator()
        empty.isHidden = true
        empty.onAction = { [weak self] in self?.setFilter(TrackFilter()) }
        bar.onChange = { [weak self] f in self?.setFilter(f) }
        bar.onPreset = { [weak self] f, s in
            guard let self else { return }
            self.trackFilter = f
            if let s { self.sort = s; UserDefaults.standard.set(s.pref, forKey: Pref.libraryTracksSort); self.showSortIndicator() }
            self.refresh(revealSelection: true)
        }
        bar.onToggle = { open in UserDefaults.standard.set(open, forKey: Pref.libraryTracksFiltersOpen) }
        let env = ProcessInfo.processInfo.environment
        // Test hooks: OMNIAMP_TRACKS_FILTER="year:1990-1992 plays:10+" sets the filter, OMNIAMP_TRACKS_FILTERS_OPEN=1 opens the panel.
        if let typed = env["OMNIAMP_TRACKS_FILTER"] { trackFilter = TrackFilter.parse(typed).filter }
        bar.filter = trackFilter
        bar.isOpen = env["OMNIAMP_TRACKS_FILTERS_OPEN"] != nil || UserDefaults.standard.bool(forKey: Pref.libraryTracksFiltersOpen)
        for v in [bar, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Loading

    /// The library has new, changed or removed files: read it again the next time the list is shown.
    func libraryChanged() { libraryVersion += 1 }

    private var onScreen: Bool {
        guard let w = window else { return false }
        return w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
    }

    /// The window can be seen again: play counts that changed meanwhile, now (the list itself refreshes with the
    /// window's own catch-up when the library changed).
    func becameVisible() {
        if loaded, !isHidden, countsDirty, onScreen { readCounts() }
    }

    /// The list for this filter and search, the selection kept by track.
    func reload(filter: LibraryFilter, query: String, emptyText: String) {
        self.emptyText = emptyText
        self.filter = filter
        self.query = takeFilterWords(query)
        refresh()
    }

    /// Filter words in the search ("year:1990-1992") become chips once they're finished; the one still being typed
    /// (the last, with no space after it) filters as it is but stays in the field. Returns the words left to search.
    private func takeFilterWords(_ text: String, finished: Bool = false) -> String {
        let (head, last) = Self.splitLast(text, finished: finished)
        let done = TrackFilter.parse(head)
        let lastParsed = TrackFilter.parse(last)
        let lastIsFilter = !last.isEmpty && lastParsed.rest.isEmpty && !lastParsed.filter.isEmpty
        typed = lastIsFilter ? lastParsed.filter : TrackFilter()
        if !done.filter.isEmpty {
            trackFilter = trackFilter.merged(with: done.filter)
            bar.filter = trackFilter
            // The finished words leave the field; what's left (and the word being typed) stays.
            let left = [done.rest, last].filter { !$0.isEmpty }.joined(separator: " ")
            onSearchText?(left.isEmpty ? left : left + (text.hasSuffix(" ") ? " " : ""))
        }
        return [done.rest, lastIsFilter ? "" : last].filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Return in the search: the filter word being typed is finished too.
    func finishTyping(_ text: String) {
        guard !typed.isEmpty else { return }
        query = takeFilterWords(text, finished: true)
        refresh()
    }

    /// The last word (a quoted value with its spaces), unless the text ends in a space or it's `finished`.
    static func splitLast(_ text: String, finished: Bool) -> (head: String, last: String) {
        if finished || text.hasSuffix(" ") || text.isEmpty { return (text, "") }
        var start = text.startIndex, quoted = false, i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\"" { quoted.toggle() } else if text[i] == " ", !quoted { start = text.index(after: i) }
            i = text.index(after: i)
        }
        return (String(text[..<start]), String(text[start...]))
    }

    /// A change from the bar (or Clear filters): the list again, with the selection kept.
    private func setFilter(_ f: TrackFilter) {
        trackFilter = f
        bar.filter = f
        refresh()
    }

    /// The one way the list changes (filter, search, sort, new files, new counts): worked out in the background from
    /// what's known (the library read again only when it changed, sorted again only when the order did), then shown.
    /// A newer refresh replaces one still running and starts from the same state, so nothing asked for is lost.
    private func refresh(revealSelection: Bool = false) {
        if refreshing {
            refreshAgain = true
            revealAgain = revealAgain || revealSelection
            return
        }
        refreshing = true
        generation += 1
        let gen = generation, sort = sort, q = query, filter = filter, counts = counts, version = libraryVersion
        let tracks = trackFilter.merged(with: typed)
        let known = readVersion == libraryVersion ? all : nil
        let range = tracks.playedYears
        let inOrder = known != nil && allSort == sort && (sort.column != .plays || allPlayed == range)
        if !loaded { showEmpty("Loading…") }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let db = known == nil || !q.isEmpty ? try? CollectionDB() : nil
            let rangePlays = range.map { r in counts.mapValues { $0.plays(in: r) } }
            let everything: [TrackRow]
            if let known {
                everything = inOrder ? known : sort.sorted(known, counts: counts, played: range, rangePlays: rangePlays)
            } else {
                everything = sort.sorted((try? db?.trackRows()) ?? [], counts: counts, played: range, rangePlays: rangePlays)
            }
            let ids = q.isEmpty ? nil : ((try? db?.fileIDs(matching: q)) ?? [])
            let list = TrackRow.visible(everything, filter: filter, ids: ids, tracks: tracks, counts: counts, rangePlays: rangePlays)
            // Read again: the years and genres the filter bar offers.
            let library = known == nil ? Self.facts(everything) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshing = false
                if gen == self.generation {
                    self.all = everything
                    self.allSort = sort
                    self.allPlayed = range
                    self.shownPlays = rangePlays
                    self.showPlayedHeader(range)
                    if known == nil { self.readVersion = version }   // a change during the read: read again next time
                    if let library { self.bar.setLibrary(years: library.years, genres: library.genres) }
                    self.show(list)
                    if revealSelection, let first = self.table.selectedRowIndexes.first { self.table.scrollRowToVisible(first) }
                    if self.countsDirty { self.readCounts() }
                }
                // Asked again meanwhile (a slider dragged on): once more, with what's set now.
                if self.refreshAgain {
                    let reveal = self.revealAgain
                    self.refreshAgain = false
                    self.revealAgain = false
                    self.refresh(revealSelection: reveal)
                }
            }
        }
    }

    /// Tracks per year, and the genres (as the library spells them, most tracks first).
    nonisolated private static func facts(_ rows: [TrackRow]) -> (years: [Int: Int], genres: [(String, Int)]) {
        var years: [Int: Int] = [:], counts: [String: Int] = [:], names: [String: String] = [:]
        // Each genre string split and folded once (they repeat a lot).
        var parts: [String: [(name: String, key: String)]] = [:]
        for r in rows {
            if let y = r.year { years[y, default: 0] += 1 }
            guard !r.genre.isEmpty else { continue }
            let ps = parts[r.genre] ?? { let p = CollectionDB.genres(r.genre).map { ($0, Keys.fold($0)) }; parts[r.genre] = p; return p }()
            for (g, k) in ps {
                counts[k, default: 0] += 1
                if names[k] == nil { names[k] = g }
            }
        }
        return (years, counts.sorted { $0.value > $1.value }.map { (names[$0.key]!, $0.value) })
    }

    /// Plays per song, in the background. Sorted by plays: sorted again; else just those columns redrawn.
    private func readCounts() {
        countsDirty = false
        let known = countsFingerprint
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let db = try? CollectionDB()
            // The history as it is (plays and the newest): the same as last time, nothing to read or redraw.
            let fingerprint = (try? db?.playsFingerprint()) ?? ""
            guard fingerprint != known || fingerprint.isEmpty else { return }
            let c = (try? db?.playCounts()) ?? [:]
            // Plays per year over the whole history, for the filter's Played chart.
            var perYear: [Int: Int] = [:]
            for song in c.values { for (y, n) in song.byYear { perYear[y, default: 0] += n } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.countsFingerprint = fingerprint
                self.counts = c
                self.bar.setPlays(years: perYear)
                let sortsByPlays = self.sort.column == .plays || self.sort.column == .lastPlayed
                if sortsByPlays || self.trackFilter.merged(with: self.typed).usesCounts {
                    if sortsByPlays { self.allSort = nil }
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
        let filtered = !trackFilter.merged(with: typed).isEmpty
        empty.actionTitle = rows.isEmpty && filtered ? "Clear Filters" : nil
        showEmpty(rows.isEmpty ? (filtered && !all.isEmpty ? "Nothing matches these filters." : emptyText) : nil)
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

    /// The Plays column says which years it counts ("Plays 2008–2010") while a played range is set.
    private func showPlayedHeader(_ range: ClosedRange<Int>?) {
        guard let col = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(TrackColumn.plays.rawValue)) else { return }
        let title = range.map { "Plays " + TrackFilter.span($0).replacingOccurrences(of: "in ", with: "") } ?? TrackColumn.plays.title
        guard col.title != title else { return }
        col.title = title
        col.headerCell.stringValue = title
        // Room for the years in the header.
        if range != nil, col.width < 96 { col.width = 96 } else if range == nil, col.width == 96 { col.width = TrackColumn.plays.width }
        table.headerView?.needsDisplay = true
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
        if sel.count > 1 { return "\(sel.count.formatted()) of \(n) selected · \(time)" }
        // Narrowed (filters, a search): how much of the library that is.
        return rows.count < all.count ? "\(rows.count.formatted()) of \(all.count.formatted()) tracks · \(time)" : "\(n) · \(time)"
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
            let item = menu.addItem(withTitle: bar.isOpen ? "Hide Filters" : "Show Filters", action: #selector(toggleFilters), keyEquivalent: "")
            item.target = self
            menu.addItem(.separator())
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
        if table.selectedRowIndexes.count == 1, let r = clicked {
            // Narrow the list to what this track has.
            let sub = NSMenu()
            func by(_ title: String, _ f: TrackFilter) {
                let item = sub.addItem(withTitle: title, action: #selector(filterBy(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = FilterBox(f)
            }
            var f = trackFilter
            f.artist = .init(key: r.performerKey, name: r.track.artist)
            by("Same Artist (\(r.track.artist))", f)
            f = trackFilter
            f.album = .init(key: r.track.albumKey, name: r.track.album)
            by("Same Album (\(r.track.album))", f)
            if let y = r.year {
                f = trackFilter
                f.years = y...y
                by("Same Year (\(y))", f)
                f.years = (y / 10 * 10)...(y / 10 * 10 + 9)
                by("Same Decade (\(y / 10 * 10)s)", f)
            }
            for g in CollectionDB.genres(r.genre) {
                f = trackFilter
                if !f.genres.contains(where: { Keys.fold($0) == Keys.fold(g) }) { f.genres.append(g) }
                by("Genre \(g)", f)
            }
            let filterItem = menu.addItem(withTitle: "Filter", action: nil, keyEquivalent: "")
            filterItem.submenu = sub
            menu.addItem(.separator())
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

    @objc private func filterBy(_ sender: NSMenuItem) {
        if let f = (sender.representedObject as? FilterBox)?.filter { setFilter(f) }
    }

    @objc private func toggleFilters() {
        bar.isOpen.toggle()
        UserDefaults.standard.set(bar.isOpen, forKey: Pref.libraryTracksFiltersOpen)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let col = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return }
        col.isHidden.toggle()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { tableView.reusableRowView("cardRow", CardRowView.init) }

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
        case .genre: f.stringValue = r.genreName
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
            // The range the rows were filtered with, and its plays per song (worked out with them, not per cell).
            let range = allPlayed
            let n = shownPlays.map { $0[r.countKey] ?? 0 } ?? counts[r.countKey]?.plays ?? 0
            f.stringValue = n > 0 ? n.formatted() : ""
            f.font = Dash.mono(11)
            // Counted by song: a live recording shows the studio one's plays too.
            let when = range.map { " " + TrackFilter.span($0) } ?? ""
            if n > 0 { f.toolTip = "\(n.formatted()) play\(n == 1 ? "" : "s") of this song\(when) (every recording)" }
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

/// A filter carried by a menu item (representedObject needs an object).
private final class FilterBox: NSObject {
    let filter: TrackFilter
    init(_ f: TrackFilter) { filter = f }
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
