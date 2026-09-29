import Foundation

/// What in the library could be better: missing tags, spellings, duplicates, formats. Each entry leads to the
/// release or artist (and for missing tags, straight to Find Missing Info).
struct LibraryAttention: Sendable {
    enum Fix: Sendable, Equatable {
        case findInfo(artist: String, album: String)   // open the release and look it up
        case open(artist: String, album: String)
        case artist(String)
        case folder(String)                          // show it in Finder (files to move)
    }

    struct Entry: Sendable, Equatable {
        let lead: String      // "1977", "×3"
        let title: String
        let detail: String
        let fix: Fix
    }

    struct Group: Sendable {
        let id: String
        let title: String
        let note: String
        let total: Int
        let entries: [Entry]
    }

    var groups: [Group] = []
    var total: Int { groups.reduce(0) { $0 + $1.total } }
}

extension CollectionDB {
    /// `only`: that group alone (its full list, with a large `limit`).
    func attention(limit: Int = 12, only: String? = nil) throws -> LibraryAttention {
        var out = LibraryAttention()
        func wanted(_ id: String) -> Bool { only == nil || only == id }
        func albums(_ id: String, _ title: String, _ note: String, _ condition: String, fix: (LibraryAlbum) -> LibraryAttention.Fix,
                    detail: (LibraryAlbum) -> String) throws {
            guard wanted(id) else { return }
            let total = Int(try db.scalar("SELECT count(*) FROM albums a WHERE \(condition)") ?? 0)
            guard total > 0 else { return }
            let list = try albumsWhere(condition, [], order: "a.tracks DESC LIMIT \(limit)")
            out.groups.append(.init(id: id, title: title, note: note, total: total, entries: list.map {
                .init(lead: $0.year.map(String.init) ?? "–", title: "\($0.artist) — \($0.title)", detail: detail($0), fix: fix($0))
            }))
        }
        let tracks: (LibraryAlbum) -> String = { "\($0.tracks) track\($0.tracks == 1 ? "" : "s")" }

        try albums("unknown", "Unknown artist", "click to look them up",
                   "a.artist_key IN ('unknown artist', '')", fix: { .findInfo(artist: $0.artistKey, album: $0.key) }, detail: tracks)
        try albums("year", "No year", "official releases · click to look them up",
                   "a.year IS NULL AND a.kind <= \(ReleaseKind.live.rawValue)", fix: { .findInfo(artist: $0.artistKey, album: $0.key) }, detail: tracks)
        try albums("genre", "No genre", "click to look them up",
                   "NOT EXISTS (SELECT 1 FROM files f WHERE f.album_key = a.key AND f.genre IS NOT NULL)",
                   fix: { .findInfo(artist: $0.artistKey, album: $0.key) }, detail: tracks)

        // One artist, several spellings (case, "The", accents, even the same letters in two Unicode forms).
        var spellings: [LibraryAttention.Entry] = []
        var spellTotal = 0
        if wanted("spelling") { try db.query("""
            SELECT artist_key, group_concat(DISTINCT album_artist), count(DISTINCT album_artist), count(*) FROM files
            WHERE artist_key NOT IN ('unknown artist', '') GROUP BY artist_key HAVING count(DISTINCT album_artist) > 1 ORDER BY count(*) DESC
            """) { r in
            spellTotal += 1
            guard spellings.count < limit else { return }
            let forms = r.text(1).components(separatedBy: ",")
            let lookAlike = Set(forms.map { $0.precomposedStringWithCanonicalMapping }).count < forms.count
            spellings.append(.init(lead: "×\(r.int(2))", title: forms.joined(separator: " · "),
                                   detail: lookAlike ? "same letters, stored two ways" : "\(r.int(3)) tracks", fix: .artist(r.text(0))))
        } }
        if spellTotal > 0 {
            out.groups.append(.init(id: "spelling", title: "Artists spelled several ways", note: "retag to one spelling",
                                    total: spellTotal, entries: spellings))
        }

        // The same release title by the same artist in more than one folder.
        var dupes: [LibraryAttention.Entry] = []
        var dupeTotal = 0
        if wanted("dupes") { try db.query("""
            SELECT a.artist_key, min(a.artist), min(a.title), count(*), min(a.key), sum(a.tracks) FROM albums a
            WHERE a.artist_key NOT IN ('unknown artist', '') GROUP BY a.artist_key, lower(a.title) HAVING count(*) > 1 ORDER BY count(*) DESC, sum(a.tracks) DESC
            """) { r in
            dupeTotal += 1
            guard dupes.count < limit else { return }
            dupes.append(.init(lead: "×\(r.int(3))", title: "\(r.text(1)) — \(r.text(2))", detail: "\(r.int(5)) tracks in all",
                               fix: .open(artist: r.text(0), album: r.text(4))))
        } }
        if dupeTotal > 0 {
            out.groups.append(.init(id: "dupes", title: "Same title in several folders", note: "copies, or other sources of a show",
                                    total: dupeTotal, entries: dupes))
        }

        // Several releases loose in one folder (told apart by their tags): a cover.jpg there is every one's, and
        // other players mix them up. Each in a folder of its own fixes both.
        var shared: [LibraryAttention.Entry] = []
        var sharedTotal = 0
        if wanted("folders") { try db.query("""
            SELECT a.folder, count(*), group_concat(a.title, ' · '), min(a.artist_key), min(a.key), sum(a.tracks) FROM albums a
            GROUP BY a.folder HAVING count(*) > 1 ORDER BY count(*) DESC, sum(a.tracks) DESC
            """) { r in
            sharedTotal += 1
            guard shared.count < limit else { return }
            let folder = r.text(0)
            shared.append(.init(lead: "×\(r.int(1))", title: (folder as NSString).lastPathComponent, detail: r.text(2),
                                fix: .folder(folder)))
        } }
        if sharedTotal > 0 {
            out.groups.append(.init(id: "folders", title: "Several releases in one folder", note: "move each into its own folder",
                                    total: sharedTotal, entries: shared))
        }

        try albums("unplayable", "Formats OmniAmp can't play", "convert with scripts/convert-unplayable.sh",
                   "a.unplayable > 0", fix: { .open(artist: $0.artistKey, album: $0.key) },
                   detail: { "\($0.unplayable) \($0.unplayableFormat ?? "") track\($0.unplayable == 1 ? "" : "s")" })
        return out
    }
}
