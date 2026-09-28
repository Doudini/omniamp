import Foundation

/// What a recording is, as a collector sorts them. Official releases first, then what circulates unofficially.
enum ReleaseKind: Int, CaseIterable, Sendable {
    case album = 0, single, compilation, live   // official
    case show, unreleased                      // unofficial: concert recordings; demos, outtakes, sessions, leaks

    var isOfficial: Bool { rawValue <= ReleaseKind.live.rawValue }

    var title: String {
        switch self {
        case .album: "Albums"
        case .single: "EPs & Singles"
        case .compilation: "Compilations"
        case .live: "Live Albums"
        case .show: "Shows & Bootlegs"
        case .unreleased: "Demos & Unreleased"
        }
    }
}

/// Makes sense of a file in a loosely organized collection from its tags and where it sits: which artist and
/// album it belongs to, whether it's official, and for concert recordings the date and venue.
///
/// Tags win when they say something (RELEASESTATUS, RELEASETYPE, album artist); otherwise the folder names
/// decide: etree-style dates ("gd1977-05-08", "1977-05-08 Barton Hall"), words like SBD, bootleg, demo, and
/// folders named "Bootlegs" or "Unreleased" further up.
enum ReleaseClassifier {
    struct Tags: Sendable {
        var title: String?
        var artist: String?
        var albumArtist: String?
        var album: String?
        var date: String?
        var originalDate: String?
        var releaseType: String?
        var releaseStatus: String?
    }

    struct Result: Equatable, Sendable {
        var kind: ReleaseKind
        /// The album's artist (grouping key source): album artist tag, artist tag, or from the folders.
        var artist: String
        var album: String
        var year: Int?
        /// Concert recordings: "1977-05-08", and the venue when the name has one.
        var showDate: String?
        var venue: String?
        /// The folder that holds the album (disc folders like "CD1" folded into their parent).
        var albumFolder: String
    }

    static func classify(path: String, root: String, tags t: Tags) -> Result {
        let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : (path as NSString).lastPathComponent
        var folders = rel.split(separator: "/").dropLast().map(String.init)   // root … parent, without the file
        // Disc folders belong to the album above them.
        var albumFolderPath = (path as NSString).deletingLastPathComponent
        if let last = folders.last, isDiscFolder(last), folders.count > 1 {
            folders.removeLast()
            albumFolderPath = (albumFolderPath as NSString).deletingLastPathComponent
        }
        let albumFolder = folders.last
        let ancestors = folders.dropLast()   // above the album folder

        // Where to look for words and dates: the album tag and the album folder first.
        let near = [t.album, albumFolder].compactMap { $0 }
        let above = Array(ancestors)
        let nearText = near.map(Keys.fold).joined(separator: " | ")
        let aboveText = above.map(Keys.fold).joined(separator: " | ")

        // Date and venue: "1977-05-08 Barton Hall, Ithaca", "gd1977-05-08.sbd.flac16", "Artist - 1977.05.08 - Venue".
        var showDate: String?, venue: String?
        for name in near + above.reversed() {
            if let (d, v) = dateAndVenue(name) { showDate = d; venue = v; break }
        }

        let type = (t.releaseType ?? "").lowercased()
        let status = (t.releaseStatus ?? "").lowercased()
        func typeHas(_ w: String) -> Bool { type.split(whereSeparator: { !$0.isLetter && $0 != "-" }).contains { $0 == w } }
        func words(_ text: String, _ list: Set<String>) -> Bool {
            let w = text.split(whereSeparator: { $0 == " " || $0 == "|" })
            return w.contains { list.contains(String($0)) } || list.contains { $0.contains(" ") && text.contains($0) }
        }

        let unofficialNear = words(nearText, bootlegWords)
        let unofficialAbove = words(aboveText, bootlegWords) || words(aboveText, unreleasedWords)
        let tagDay = t.date.flatMap(isoDate)
        let liveish = (tagDay != nil && (unofficialNear || unofficialAbove)) || typeHas("live") || typeHas("broadcast") || showDate != nil || words(nearText, liveWords)
            || near.contains { let k = Keys.fold($0); return k == "live" || k.hasSuffix(" live") }
        let unreleasedNear = words(nearText, unreleasedWords) || typeHas("demo")

        let kind: ReleaseKind
        if status == "bootleg" {
            kind = liveish ? .show : .unreleased
        } else if status == "official" || status == "promotion" || !type.isEmpty && status.isEmpty && !unofficialNear && !unofficialAbove {
            kind = typeHas("demo") ? .unreleased
                : typeHas("live") ? .live
                : typeHas("compilation") ? .compilation
                : (typeHas("single") || typeHas("ep")) ? .single : .album
        } else if showDate != nil || (unofficialNear && liveish) || (unofficialAbove && liveish && !unreleasedNear) {
            kind = .show
        } else if unofficialNear || unreleasedNear || unofficialAbove {
            kind = .unreleased
        } else if liveish || above.contains(where: { ["live", "live albums", "live recordings"].contains(Keys.fold($0)) }) {
            kind = .live
        } else if words(nearText, compilationWords) || isVarious(t.albumArtist) {
            kind = .compilation
        } else if nearText.hasSuffix(" ep") || words(nearText, ["single", "ep"]) {
            kind = .single
        } else {
            kind = .album
        }

        let artist = clean(t.albumArtist) ?? clean(t.artist) ?? artistFromFolders(albumFolder: albumFolder, ancestors: Array(ancestors))
            ?? "Unknown Artist"
        if showDate == nil, kind == .show { showDate = tagDay }
        // An untagged show is named by its date and place, whatever the tape folder is called.
        let showName = showDate.map { d in venue.map { "\(d) \($0)" } ?? d }
        let album = clean(t.album) ?? (kind == .show ? showName : nil) ?? albumFromFolder(albumFolder, artist: artist)
            ?? "Unknown Album"
        let year = Keys.year(t.originalDate) ?? Keys.year(t.date) ?? showDate.flatMap(Keys.year)
            ?? albumFolder.flatMap(Keys.year) ?? t.album.flatMap(Keys.year)
        return Result(kind: kind, artist: artist, album: album, year: year, showDate: showDate, venue: venue,
                      albumFolder: albumFolderPath)
    }

    // MARK: Words

    // Only words that rarely name an official record ("Master of Puppets", "Live Through This", "Tour de France"
    // must stay albums), so "live" alone doesn't count: "live at", "live in", or a name ending in "live" does.
    static let bootlegWords: Set<String> = ["bootleg", "bootlegs", "sbd", "aud", "soundboard", "mtx", "unofficial", "fob",
                                            "taper", "etree", "shnid", "pre fm", "fm broadcast"]
    static let liveWords: Set<String> = ["live at", "live in", "live from", "live on", "in concert", "unplugged", "concert"]
    static let unreleasedWords: Set<String> = ["demo", "demos", "outtake", "outtakes", "unreleased", "rehearsal", "rehearsals",
                                               "sessions", "leak", "leaked", "leaks", "rough mix", "rough mixes", "alternate takes",
                                               "work tape", "work tapes", "unfinished", "acetate", "acetates", "early versions",
                                               "studio outtakes", "unreleased tracks"]
    static let compilationWords: Set<String> = ["greatest hits", "best of", "anthology", "collection", "hits", "the essential",
                                                "compilation", "retrospective"]

    /// Folders that sort things rather than name an artist.
    static let genericFolders: Set<String> = ["music", "mp3", "mp3s", "flac", "lossless", "albums", "album", "singles", "eps", "ep",
                                              "compilations", "bootlegs", "bootleg", "live", "demos", "unreleased", "misc", "various",
                                              "various artists", "va", "downloads", "new", "rips", "cd", "vinyl", "shows", "concerts",
                                              "rarities", "sessions", "outtakes", "other", "unsorted", "incoming", "itunes", "itunes media",
                                              "media", "audio", "complete", "discography", "studio albums", "live albums", "official",
                                              "unofficial", "leaks", "tapes", "soundboards", "sbd", "aud"]

    /// Words that describe an edition, after a dash in a folder name.
    static let albumNotes: Set<String> = ["live", "remaster", "remastered", "deluxe", "edition", "expanded", "anniversary",
                                          "demo", "demos", "bootleg", "sbd", "aud", "mono", "stereo", "reissue", "bonus", "tracks",
                                          "version", "special", "super", "complete", "the", "and", "disc", "cd", "vinyl", "rip"]

    private static func isVarious(_ s: String?) -> Bool {
        guard let s else { return false }
        return ["various artists", "various", "va"].contains(Keys.fold(s))
    }

    private static func clean(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    // MARK: Folders

    private static let discFolder = try! NSRegularExpression(pattern: #"^(cd|disc|disk|set|side|d)[\s_.-]*\d{1,2}\b"#, options: .caseInsensitive)

    static func isDiscFolder(_ name: String) -> Bool {
        discFolder.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// The closest folder above the album that names someone: "Artist/Album", "Artist/Bootlegs/1977-05-08",
    /// or "Artist - Album" in one folder name.
    private static func artistFromFolders(albumFolder: String?, ancestors: [String]) -> String? {
        // "Artist - Album", but not "Album - Live" / "Album - Remastered" (a note about the album, not its artist).
        if let a = albumFolder, let dash = a.range(of: " - ") {
            let left = a[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = Keys.fold(stripJunk(String(a[dash.upperBound...])))
            let note = !right.isEmpty && right.split(separator: " ").allSatisfy { albumNotes.contains(String($0)) || $0.allSatisfy(\.isNumber) }
            if !note, !left.isEmpty, dateAndVenue(left) == nil, Keys.year(left) == nil || left.count > 4 {
                // The same name as a folder above ("Shannon Wright/shannon wright - 30.04.04"): that one's spelling.
                return ancestors.last { Keys.artist($0) == Keys.artist(left) } ?? left
            }
        }
        for name in ancestors.reversed() {
            let k = Keys.fold(name)
            if k.isEmpty || genericFolders.contains(k) || isDiscFolder(name) || dateAndVenue(name) != nil { continue }
            if k.count == 1 || (k.allSatisfy(\.isNumber)) { continue }   // "A", "B" letter folders, year folders
            return name
        }
        return nil
    }

    /// "Artist - Album (1999) [FLAC]" → "Album".
    private static func albumFromFolder(_ folder: String?, artist: String) -> String? {
        guard var name = folder else { return nil }
        if let dash = name.range(of: " - "), Keys.artist(String(name[..<dash.lowerBound])) == Keys.artist(artist) {
            name = String(name[dash.upperBound...])
        }
        name = stripJunk(name)
        return name.isEmpty ? folder : name
    }

    /// Format and source notes collectors put in names: "[FLAC]", "(24-96)", "{SBD}".
    private static let junk = try! NSRegularExpression(
        pattern: #"\s*[\[\{\(](?:[^\]\}\)]*\b(?:flac|mp3|320|v0|24[-_ ]?bit|16[-_ ]?bit|24[-_]\d+|16[-_]44|web|cd|vinyl|lossless|sbd|aud|shnid|remaster(?:ed)?|\d{4,6})\b[^\]\}\)]*)[\]\}\)]"#,
        options: .caseInsensitive)

    static func stripJunk(_ s: String) -> String {
        let out = junk.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " -_.").union(.whitespaces))
    }

    // MARK: File names

    private static let etreeTrack = try! NSRegularExpression(pattern: #"d(\d{1,2})[_.-]?t(\d{1,3})$"#, options: .caseInsensitive)
    private static let leadingNumber = try! NSRegularExpression(pattern: #"^(?:(\d)[-.])?(\d{1,3})(?:\s*[-._)]\s*|\s+)(?=\S)"#)

    /// A title and numbers from an untagged file's name: "shannon wright - 01 - plea" → "plea", 1;
    /// "03. Airbag" → "Airbag", 3; "gd77-05-08d1t01" → disc 1, track 1.
    static func fromFileName(_ name: String, artist: String?) -> (title: String, track: Int?, disc: Int?) {
        let ns = name as NSString
        if let m = etreeTrack.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) {
            return (name, Int(ns.substring(with: m.range(at: 2))), Int(ns.substring(with: m.range(at: 1))))
        }
        var parts = name.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        var track: Int?
        if parts.count > 1 {
            let a = artist.map(Keys.artist)
            let kept = parts.filter { a == nil || Keys.artist($0) != a }
            if !kept.isEmpty { parts = kept }
            if parts.count > 1, let i = parts.firstIndex(where: { $0.count <= 3 && !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                track = Int(parts[i])
                parts.remove(at: i)
            }
        }
        var title = parts.joined(separator: " - ")
        if track == nil {
            let t = title as NSString
            if let m = leadingNumber.firstMatch(in: title, range: NSRange(location: 0, length: t.length)) {
                track = Int(t.substring(with: m.range(at: 2)))
                title = t.substring(from: m.range.upperBound)
            }
        }
        title = title.trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? name : title, track, nil)
    }

    // MARK: Dates

    /// YYYY-MM-DD with -, ., _ or space; or etree's band abbreviation + date ("gd77-05-08", "ph1997-12-31").
    private static let fullDate = try! NSRegularExpression(
        pattern: #"(?<![0-9])((?:19|20)\d\d)[-._ ](0[1-9]|1[0-2])[-._ ](0[1-9]|[12]\d|3[01])(?![0-9])"#)
    private static let etreeDate = try! NSRegularExpression(
        pattern: #"^[a-z]{1,6}((?:19|20)?\d\d)[-._](0[1-9]|1[0-2])[-._](0[1-9]|[12]\d|3[01])(?![0-9])"#, options: .caseInsensitive)

    /// Tokens after a date that aren't a venue ("sbd", "flac16", "miller", "d1t01"…).
    private static let tapeToken = try! NSRegularExpression(
        pattern: #"^(?:sbd|aud|fm|mtx|matrix|flac\d*|shn|mp3|\d+|24bit|16bit|24-96|remaster(?:ed)?|d\d+t?\d*|set\d|early|late|[a-z]\d+|\d+k)$"#,
        options: .caseInsensitive)

    /// The date in a name, as YYYY-MM-DD, and whatever place follows it.
    /// Day and month in either order with the year last: "30.04.04", "04.05.2002", "11-23-91", "26.10.89_-_share".
    private static let dayMonthYear = try! NSRegularExpression(pattern: #"(?<![0-9])(\d{1,2})([.\-/_])(\d{1,2})\2(\d{4}|\d{2})(?![0-9])"#)
    /// "20010905" (in brackets or on its own), and a name starting with six digits: US-style "092393".
    private static let compactDate = try! NSRegularExpression(pattern: #"(?<![0-9])((?:19|20)\d\d)(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?![0-9])"#)
    private static let sixDigits = try! NSRegularExpression(pattern: #"^(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(\d\d)(?![0-9])"#)

    private static func fullYear(_ y: String) -> String { y.count == 2 ? (Int(y)! > 30 ? "19" : "20") + y : y }

    private static func iso(_ y: String, _ m: Int, _ d: Int) -> String? {
        guard (1...12).contains(m), (1...31).contains(d), let year = Int(fullYear(y)), (1900...2099).contains(year) else { return nil }
        return String(format: "%04d-%02d-%02d", year, m, d)
    }

    /// The date in a name, as YYYY-MM-DD, and the place: what follows the date, or else what comes before it
    /// ("café de la danse 04.05.2002", "shannon wright - café de la danse, paris, 30.04.2004").
    static func dateAndVenue(_ name: String) -> (String, String?)? {
        let ns = name as NSString
        let range = NSRange(location: 0, length: ns.length)
        func g(_ m: NSTextCheckingResult, _ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        var date: String?, match: NSRange?
        if let m = fullDate.firstMatch(in: name, range: range) {
            date = "\(g(m, 1))-\(g(m, 2))-\(g(m, 3))"; match = m.range
        } else if let m = compactDate.firstMatch(in: name, range: range) {
            date = "\(g(m, 1))-\(g(m, 2))-\(g(m, 3))"; match = m.range
        } else if let m = etreeDate.firstMatch(in: name, range: range) {
            date = "\(fullYear(g(m, 1)))-\(g(m, 2))-\(g(m, 3))"; match = m.range
        } else if let m = dayMonthYear.firstMatch(in: name, range: range) {
            let a = Int(g(m, 1))!, b = Int(g(m, 3))!, sep = g(m, 2), y = g(m, 4)
            // Day first unless that's impossible; month first when the day is (23-11) or the style is American
            // (dashes or slashes with a two-digit year: "11-23-91").
            let usStyle = (sep == "-" || sep == "/") && y.count == 2
            if a > 31, y.count == 2 { date = iso(g(m, 1), b, Int(y)!) }   // "91-12-04": year first
            else if a > 12 { date = iso(y, b, a) } else if b > 12 { date = iso(y, a, b) } else { date = usStyle ? iso(y, a, b) : iso(y, b, a) }
            match = m.range
        } else if let m = sixDigits.firstMatch(in: name, range: range) {
            date = iso(g(m, 3), Int(g(m, 1))!, Int(g(m, 2))!); match = m.range
        }
        guard let date, let match else { return nil }
        let after = venue(from: ns.substring(from: match.upperBound))
        if let after { return (date, after) }
        // Before the date: drop "artist - " and a trailing "[", "(" or separator.
        var before = ns.substring(to: match.location)
        if let dash = before.range(of: " - ", options: .backwards) { before = String(before[dash.upperBound...]) }
        before = before.trimmingCharacters(in: CharacterSet(charactersIn: " -_.,:[(").union(.whitespaces))
        return (date, before.isEmpty ? nil : venue(from: before))
    }

    private static func venue(from after: String) -> String? {
        var s = stripJunk(after)
        // Dotted tape names ("sbd.miller.flac16") carry no place: drop tokens, keep words.
        if !s.contains(" "), s.contains(".") || s.contains("_") {
            let parts = s.split(whereSeparator: { $0 == "." || $0 == "_" }).map(String.init)
                .filter { tapeToken.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }
            s = parts.count > 1 ? parts.joined(separator: " ") : ""   // a lone leftover is a taper's name, not a place
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -_.,:[](){}").union(.whitespaces))
        // "live, rock school barbey", "Live at the Roxy": the place without the "live".
        for prefix in ["live at ", "live @ ", "live in ", "live, ", "live - ", "live "] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard s.count >= 3, s.contains(where: \.isLetter),
              tapeToken.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil else { return nil }
        return s
    }

    /// "1977-05-08" → itself; anything else (a bare year, "May 1977") → nil.
    private static func isoDate(_ s: String) -> String? {
        let ns = s as NSString
        guard let m = fullDate.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return "\(ns.substring(with: m.range(at: 1)))-\(ns.substring(with: m.range(at: 2)))-\(ns.substring(with: m.range(at: 3)))"
    }
}
