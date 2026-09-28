import Foundation

/// Who and what a release is when its tags don't say: guesses from folder and file names, then MusicBrainz
/// searched by the track titles and lengths (a release that has several of them is very likely the one).
enum ReleaseGuess {
    /// An artist and album to search for, and where the guess came from.
    struct Guess: Equatable, Sendable {
        var artist: String
        var album: String
        var year: Int?
        var why: String
    }

    /// Best first. Pure: names only.
    static func guesses(folder: String, albumTitle: String, fileNames: [String], titles: [String]) -> [Guess] {
        var out: [Guess] = []
        let name = clean((folder as NSString).lastPathComponent)
        // "Sophie Hunger - 1983 (2010)": artist, album, year.
        if let (a, b) = split(name) {
            // The year in brackets at the end ("1983 (2010)": the album is called 1983).
            var album = b, year: Int?
            if let r = album.range(of: #"[\(\[]\s*(19|20)\d\d\s*[\)\]]\s*$"#, options: .regularExpression) {
                year = Keys.year(String(album[r]))
                album.removeSubrange(r)
            }
            out.append(Guess(artist: a, album: album.trimmingCharacters(in: .whitespaces), year: year, why: "from the folder name"))
        }
        // "Human Tetris - Things I Don't Need.mp3" on most files: that artist.
        let prefixes = (titles + fileNames.map { ($0 as NSString).deletingPathExtension }).compactMap { t -> String? in
            guard let (a, _) = split(clean(t)), !a.allSatisfy(\.isNumber) else { return nil }
            return a
        }
        let byKey = Dictionary(grouping: prefixes, by: Keys.artist)
        if let best = byKey.max(by: { $0.value.count < $1.value.count }), best.value.count * 2 >= max(fileNames.count, 1),
           !["track", "artist", "unknown artist"].contains(best.key) {
            let artist = best.value[0]
            if !out.contains(where: { Keys.artist($0.artist) == best.key }) {
                let album = clean(albumTitle)
                out.append(Guess(artist: artist, album: album == name || Keys.artist(album) == best.key || album == "Unknown Album" ? "" : album,
                                 year: nil, why: "from the file names"))
            }
        }
        // A plain folder right in the library ("Catie Curtis"): often the artist.
        if out.isEmpty, !name.isEmpty, name != "Unknown Album" {
            out.append(Guess(artist: name, album: "", year: nil, why: "the folder's name, as the artist"))
        }
        return out
    }

    /// Track titles worth searching for: no "Track 7", no bitrate notes, no artist in front.
    static func searchTitles(_ tracks: [(title: String, duration: Double?)], artist: String?) -> [(title: String, duration: Double?)] {
        tracks.compactMap { t in
            var s = clean(t.title)
            if let (a, b) = split(s), artist == nil || Keys.artist(a) == Keys.artist(artist ?? "") { s = b }
            // "(320 kbps)", "[Full Album]".
            for pattern in [#"\((\d+\s*kbps|\d+)\)"#, #"\[[^\]]*\]"#] {
                s = s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            }
            s = s.trimmingCharacters(in: .whitespaces)
            let k = Keys.fold(s)
            guard k.count >= 3, !k.hasPrefix("track"), !k.contains("unknown"), !k.allSatisfy({ $0.isNumber || $0 == " " }) else { return nil }
            return (s, t.duration)
        }
    }

    /// Underscores as spaces, HTML entities decoded, spaces collapsed.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "_", with: " ")
        for (e, c) in [("&#039;", "'"), ("&#39;", "'"), ("&amp;", "&"), ("&quot;", "\""), ("&apos;", "'")] { t = t.replacingOccurrences(of: e, with: c) }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// "A - B" (the first " - "), both sides non-empty.
    static func split(_ s: String) -> (String, String)? {
        guard let r = s.range(of: " - ") else { return nil }
        let a = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces), b = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return a.isEmpty || b.isEmpty ? nil : (a, b)
    }
}

extension MetadataLookup {
    /// Releases that have these recordings (by title, and length when known), most titles matched first.
    /// Up to 4 titles are searched (one MusicBrainz request each).
    func identify(_ tracks: [(title: String, duration: Double?)], artistHint: String?) async -> [InfoCandidate] {
        let picked = Array(tracks.prefix(4))
        guard !picked.isEmpty else { return [] }
        struct Hit { var title: String, artist: String, date: String?, type: String?, titles: Set<String> }
        var hits: [String: Hit] = [:]
        for t in picked {
            var q = "recording:\(Self.lucene(t.title))"
            if let d = t.duration, d > 20 { q += " AND dur:[\(Int((d - 6) * 1000)) TO \(Int((d + 6) * 1000))]" }
            guard let json = await get(Self.url("https://musicbrainz.org/ws/2/recording", ["query": q, "fmt": "json", "limit": "10"]),
                                       musicBrainz: true) as? [String: Any] else { continue }
            for r in (json["recordings"] as? [[String: Any]]) ?? [] where (r["score"] as? Int ?? 0) >= 90 {
                let credit = (r["artist-credit"] as? [[String: Any]])?.compactMap { p in (p["name"] as? String).map { $0 + ((p["joinphrase"] as? String) ?? "") } }
                    .joined() ?? ""
                for rel in (r["releases"] as? [[String: Any]]) ?? [] {
                    guard let g = rel["release-group"] as? [String: Any], let id = g["id"] as? String, let title = g["title"] as? String else { continue }
                    var h = hits[id] ?? Hit(title: title, artist: credit, date: rel["date"] as? String, type: g["primary-type"] as? String, titles: [])
                    h.titles.insert(t.title)
                    if let d = rel["date"] as? String, d < (h.date ?? "9999") { h.date = d }
                    hits[id] = h
                }
            }
        }
        let hint = artistHint.map(Keys.artist)
        return hits.map { id, h in
            // Share of the searched titles on it; a little more for an album, and for the artist the names suggested.
            // Several of your songs on one release is strong evidence; one song, much less (hits and compilations).
            let share = Double(h.titles.count) / Double(picked.count)
            var score = h.titles.count >= 2 ? 0.55 + 0.35 * share : 0.45 * share
            if h.type == "Album" { score += 0.05 }
            if let hint, Keys.artist(h.artist) == hint { score += 0.1 }
            return InfoCandidate(source: .musicBrainz, artist: h.artist, album: h.title, year: Keys.year(h.date), genre: nil,
                                 thumbURL: URL(string: "https://coverartarchive.org/release-group/\(id)/front-250"),
                                 coverURL: URL(string: "https://coverartarchive.org/release-group/\(id)/front-1200"),
                                 detail: "has \(h.titles.count) of your \(picked.count) songs" + (h.type.map { " · \($0)" } ?? "")
                                    + (h.date.map { " · \($0)" } ?? ""),
                                 score: min(score, 1))
        }
        .sorted { $0.score > $1.score }
        .prefix(6).map { $0 }
    }
}
