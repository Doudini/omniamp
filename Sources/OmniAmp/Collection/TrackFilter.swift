import Foundation

/// What the Tracks list is narrowed to: years, how often and how lately a song was played, when it was added, genres,
/// kinds of release, an artist or an album. One state, set from the filter panel, the right-click Filter menu or words
/// typed into the search ("year:1990-1992 plays:10+"); its conditions show as chips above the list.
struct TrackFilter: Equatable, Sendable {
    enum Plays: Equatable, Sendable {
        case any, never
        case atLeast(Int)
    }
    enum LastPlayed: Equatable, Sendable {
        case any, thisYear, never
        /// Played, but not in the last n years.
        case yearsAgo(Int)
    }
    enum Added: Equatable, Sendable {
        case any, thisYear
        case days(Int)
    }
    /// Kinds of release, as people think of them.
    enum KindGroup: String, CaseIterable, Sendable {
        case albums, live, shows, demos
        var title: String {
            switch self {
            case .albums: "Albums"
            case .live: "Live"
            case .shows: "Shows"
            case .demos: "Demos"
            }
        }
        func contains(_ k: ReleaseKind) -> Bool {
            switch self {
            case .albums: [.album, .single, .compilation].contains(k)
            case .live: k == .live
            case .shows: k == .show
            case .demos: k == .unreleased
            }
        }
    }
    /// An artist or album picked from a track (its key, and how to show it).
    struct Named: Equatable, Sendable {
        let key: String
        let name: String
    }

    var years: ClosedRange<Int>?
    /// Played in these years (the play history's). With it, Plays counts only the plays in them.
    var playedYears: ClosedRange<Int>?
    var plays: Plays = .any
    var lastPlayed: LastPlayed = .any
    var added: Added = .any
    /// Genre names as the library spells them; a track with any of them.
    var genres: [String] = []
    /// Empty: every kind.
    var kinds: Set<KindGroup> = []
    var artist: Named?
    var album: Named?

    var isEmpty: Bool { self == TrackFilter() }
    /// Year bounds that mean "open that way" ("up to 1992", "1990 and later").
    static let earliest = 1000, latest = 2999
    /// Plays or last played: needs the play counts.
    var usesCounts: Bool { plays != .any || lastPlayed != .any || playedYears != nil }

    static let forgottenFavourites = TrackFilter(plays: .atLeast(10), lastPlayed: .yearsAgo(5))
    static let neverPlayed = TrackFilter(plays: .never)

    // MARK: Matching

    /// Thresholds worked out once for a pass over the list (not per track).
    struct Matcher: Sendable {
        let filter: TrackFilter
        let genreKeys: Set<String>
        let startOfYear: Int, lastCut: Int?, addedCut: Double?

        func matches(_ r: TrackRow, _ count: PlayCount?) -> Bool {
            let f = filter
            if let y = f.years { guard let year = r.year, y.contains(year) else { return false } }
            if !f.kinds.isEmpty, !f.kinds.contains(where: { $0.contains(r.kind) }) { return false }
            if let a = f.artist, r.performerKey != a.key, r.artistKey != a.key { return false }
            if let a = f.album, r.track.albumKey != a.key { return false }
            if !genreKeys.isEmpty, !r.genreKeys.contains(where: genreKeys.contains) { return false }
            let plays = count?.plays(in: f.playedYears) ?? 0, last = count?.last ?? 0
            switch f.plays {
            case .any: if f.playedYears != nil, plays == 0 { return false }   // played in those years at all
            case .never: if plays > 0 { return false }
            case .atLeast(let n): if plays < n { return false }
            }
            switch f.lastPlayed {
            case .any: break
            case .never: if (count?.plays ?? 0) > 0 { return false }
            case .thisYear: if last < startOfYear { return false }
            case .yearsAgo: if last == 0 || last >= lastCut ?? 0 { return false }
            }
            if f.added != .any, r.added < addedCut ?? 0 { return false }
            return true
        }
    }

    func matcher(now: Date = Date()) -> Matcher {
        let cal = Calendar.current
        let year = cal.dateInterval(of: .year, for: now)?.start ?? now
        var lastCut: Int?
        if case .yearsAgo(let n) = lastPlayed { lastCut = Int(cal.date(byAdding: .year, value: -n, to: now)?.timeIntervalSince1970 ?? 0) }
        var addedCut: Double?
        switch added {
        case .any: break
        case .thisYear: addedCut = year.timeIntervalSince1970
        case .days(let n): addedCut = now.timeIntervalSince1970 - Double(n) * 86400
        }
        return Matcher(filter: self, genreKeys: Set(genres.map(Keys.fold)), startOfYear: Int(year.timeIntervalSince1970),
                       lastCut: lastCut, addedCut: addedCut)
    }

    func matches(_ r: TrackRow, _ count: PlayCount?, now: Date = Date()) -> Bool { matcher(now: now).matches(r, count) }

    // MARK: Chips

    /// One condition, as a chip shows it (its × takes it away).
    enum Condition: Hashable, Sendable {
        case years, playedYears, plays, lastPlayed, added, artist, album
        case genre(String)
        case kind(KindGroup)
    }

    var conditions: [Condition] {
        var c: [Condition] = []
        if years != nil { c.append(.years) }
        if playedYears != nil { c.append(.playedYears) }
        if artist != nil { c.append(.artist) }
        if album != nil { c.append(.album) }
        if plays != .any { c.append(.plays) }
        if lastPlayed != .any { c.append(.lastPlayed) }
        if added != .any { c.append(.added) }
        c += genres.map { .genre($0) }
        c += KindGroup.allCases.filter(kinds.contains).map { .kind($0) }
        return c
    }

    func title(_ c: Condition) -> String {
        switch c {
        case .years:
            guard let y = years else { return "" }
            if y.lowerBound <= Self.earliest { return "Up to \(y.upperBound)" }
            if y.upperBound >= Self.latest { return "\(y.lowerBound) and later" }
            if y.lowerBound == y.upperBound { return "Year \(y.lowerBound)" }
            if y.lowerBound % 10 == 0, y.upperBound == y.lowerBound + 9 { return "\(y.lowerBound)s" }
            return "\(y.lowerBound)–\(y.upperBound)"
        case .playedYears:
            guard let y = playedYears else { return "" }
            return "Played " + Self.span(y)
        case .plays:
            switch plays {
            case .any: return ""
            case .never: return "Never played"
            case .atLeast(1): return "Played"
            case .atLeast(let n): return "Played \(n)+ times"
            }
        case .lastPlayed:
            switch lastPlayed {
            case .any: return ""
            case .never: return "Never played"
            case .thisYear: return "Played this year"
            case .yearsAgo(1): return "Not played in a year"
            case .yearsAgo(let n): return "Not played in \(n) years"
            }
        case .added:
            switch added {
            case .any: return ""
            case .thisYear: return "Added this year"
            case .days(let n): return "Added in the last \(n) days"
            }
        case .artist: return artist?.name ?? ""
        case .album: return album?.name ?? ""
        case .genre(let g): return g
        case .kind(let k): return k.title
        }
    }

    /// "in 2008", "2008–2010", "up to 2010", "since 2015" (how played years read).
    static func span(_ y: ClosedRange<Int>) -> String {
        if y.lowerBound <= earliest { return "up to \(y.upperBound)" }
        if y.upperBound >= latest { return "since \(y.lowerBound)" }
        return y.lowerBound == y.upperBound ? "in \(y.lowerBound)" : "\(y.lowerBound)–\(y.upperBound)"
    }

    func removing(_ c: Condition) -> TrackFilter {
        var f = self
        switch c {
        case .years: f.years = nil
        case .playedYears: f.playedYears = nil
        case .plays: f.plays = .any
        case .lastPlayed: f.lastPlayed = .any
        case .added: f.added = .any
        case .artist: f.artist = nil
        case .album: f.album = nil
        case .genre(let g): f.genres.removeAll { $0 == g }
        case .kind(let k): f.kinds.remove(k)
        }
        return f
    }

    /// This filter with another's conditions on top (typed words added to what's set).
    func merged(with o: TrackFilter) -> TrackFilter {
        var f = self
        if o.years != nil { f.years = o.years }
        if o.playedYears != nil { f.playedYears = o.playedYears }
        if o.plays != .any { f.plays = o.plays }
        if o.lastPlayed != .any { f.lastPlayed = o.lastPlayed }
        if o.added != .any { f.added = o.added }
        for g in o.genres where !f.genres.contains(where: { Keys.fold($0) == Keys.fold(g) }) { f.genres.append(g) }
        f.kinds.formUnion(o.kinds)
        if o.artist != nil { f.artist = o.artist }
        if o.album != nil { f.album = o.album }
        return f
    }

    // MARK: Typed

    /// Filter words out of a search ("cat power year:1998-2003 kind:show" → the years and shows, "cat power" left to
    /// search). Words it doesn't know (and "x:y" with a key it doesn't know) stay search words.
    static func parse(_ query: String) -> (filter: TrackFilter, rest: String) {
        var f = TrackFilter(), rest: [String] = []
        var words = query.split(separator: " ", omittingEmptySubsequences: true).map(String.init)[...]
        while let w = words.popFirst() {
            guard let colon = w.firstIndex(of: ":"), colon != w.startIndex else { rest.append(w); continue }
            let key = w[..<colon].lowercased()
            var value = String(w[w.index(after: colon)...])
            // A quoted value runs to its closing quote: genre:"post punk".
            if value.hasPrefix("\"") {
                while !(value.count > 1 && value.hasSuffix("\"")), let next = words.popFirst() { value += " " + next }
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            if !apply(key, value, to: &f) { rest.append(w) }
        }
        return (f, rest.joined(separator: " "))
    }

    private static func apply(_ key: String, _ raw: String, to f: inout TrackFilter) -> Bool {
        let v = raw.lowercased()
        switch key {
        case "year", "years":
            guard let r = years(v) else { return false }
            f.years = r
        case "plays":
            if v == "never" || v == "0" { f.plays = .never; return true }
            guard let n = Int(v.trimmingCharacters(in: CharacterSet(charactersIn: "+>="))), n > 0 else { return false }
            f.plays = .atLeast(n)
        case "played":
            if v == "never" { f.plays = .never; return true }
            guard let r = years(v) else { return false }
            f.playedYears = r
        case "last":
            if v == "never" { f.lastPlayed = .never; return true }
            if v == "thisyear" || v == "this-year" { f.lastPlayed = .thisYear; return true }
            guard v.hasSuffix("y+") || v.hasSuffix("y"), let n = Int(v.trimmingCharacters(in: CharacterSet(charactersIn: "y+"))), n > 0 else { return false }
            f.lastPlayed = .yearsAgo(n)
        case "added":
            if v == "thisyear" || v == "this-year" { f.added = .thisYear; return true }
            guard v.hasSuffix("d"), let n = Int(v.dropLast()), n > 0 else { return false }
            f.added = .days(n)
        case "genre":
            guard !raw.isEmpty else { return false }
            if !f.genres.contains(where: { Keys.fold($0) == Keys.fold(raw) }) { f.genres.append(raw) }
        case "kind":
            let k: KindGroup? = switch v {
            case "album", "albums": .albums
            case "live": .live
            case "show", "shows": .shows
            case "demo", "demos", "unreleased": .demos
            default: nil
            }
            guard let k else { return false }
            f.kinds.insert(k)
        default:
            return false
        }
        return true
    }

    /// "1991", "1990-1992", "1990..1992", "1990s", "90s", "-1992" (up to), "1990-" (and later).
    private static func years(_ v: String) -> ClosedRange<Int>? {
        func year(_ s: Substring) -> Int? { Int(s).flatMap { (1000...2999).contains($0) ? $0 : nil } }
        if v.hasPrefix("-"), let y = year(v.dropFirst()) { return earliest...y }
        if v.hasSuffix("-"), let y = year(v.dropLast()) { return y...latest }
        if v.hasSuffix("s"), let d = Int(v.dropLast()) {
            let start = d < 100 ? (d >= 30 ? 1900 + d : 2000 + d) : d
            return start % 10 == 0 && (1000...2999).contains(start) ? start...(start + 9) : nil
        }
        let parts = v.contains("..") ? v.components(separatedBy: "..").map { Substring($0) } : v.split(separator: "-")
        if parts.count == 1, let y = year(parts[0]) { return y...y }
        if parts.count == 2, let a = year(parts[0]), let b = year(parts[1]) { return min(a, b)...max(a, b) }
        return nil
    }

    /// The filter as typed words (the test hook writes it, and it reads back the same).
    var text: String {
        var w: [String] = []
        if let y = years {
            w.append(y.lowerBound <= Self.earliest ? "year:-\(y.upperBound)" : y.upperBound >= Self.latest ? "year:\(y.lowerBound)-"
                     : y.lowerBound == y.upperBound ? "year:\(y.lowerBound)" : "year:\(y.lowerBound)-\(y.upperBound)")
        }
        if let y = playedYears {
            w.append(y.lowerBound <= Self.earliest ? "played:-\(y.upperBound)" : y.upperBound >= Self.latest ? "played:\(y.lowerBound)-"
                     : y.lowerBound == y.upperBound ? "played:\(y.lowerBound)" : "played:\(y.lowerBound)-\(y.upperBound)")
        }
        switch plays {
        case .any: break
        case .never: w.append("played:never")
        case .atLeast(let n): w.append("plays:\(n)+")
        }
        switch lastPlayed {
        case .any: break
        case .never: w.append("last:never")
        case .thisYear: w.append("last:thisyear")
        case .yearsAgo(let n): w.append("last:\(n)y+")
        }
        switch added {
        case .any: break
        case .thisYear: w.append("added:thisyear")
        case .days(let n): w.append("added:\(n)d")
        }
        w += genres.map { $0.contains(" ") ? "genre:\"\($0)\"" : "genre:\($0)" }
        w += KindGroup.allCases.filter(kinds.contains).map { "kind:\($0.rawValue)" }
        return w.joined(separator: " ")
    }
}
