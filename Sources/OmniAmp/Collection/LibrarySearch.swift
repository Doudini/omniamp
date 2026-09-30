import Foundation

/// What a library search looks for, as a query for the `search` index (FTS5).
///
/// - Every word has to match somewhere, as the start of a word: "bjork hom" finds Björk's Homogenic (accents and
///   case don't count).
/// - "Words in quotes" match as they are, next to each other.
/// - A date matches in any spelling the collection uses: "1977-05-08", "77-05-08", "5/8/77", "8.5.1977" and etree's
///   "gd77-05-08" all find the show on 8 May 1977. A date that reads two ways (5/8/77) looks for both.
enum LibrarySearch {
    static func query(_ typed: String) -> String {
        var parts: [String] = []
        // Odd pieces between quotes are phrases; a quote left open runs to the end.
        for (i, piece) in typed.components(separatedBy: "\"").enumerated() {
            if i % 2 == 1 {
                let phrase = piece.trimmingCharacters(in: .whitespaces)
                if !phrase.isEmpty { parts.append(quoted(phrase)) }
                continue
            }
            for word in piece.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                let days = dates(word)
                if days.isEmpty {
                    parts.append(quoted(word) + "*")
                } else {
                    // The day in the index's spelling, or the word as typed (a folder named "gd77-05-08").
                    parts.append("(" + (days.map { quoted($0) } + [quoted(word) + "*"]).joined(separator: " OR ") + ")")
                }
            }
        }
        return parts.isEmpty ? "\"\"" : parts.joined(separator: " ")
    }

    /// A string FTS5 takes as it is (no operators from the user).
    private static func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private static let datePattern = try! NSRegularExpression(pattern: #"^[a-z]{0,4}(\d{1,4})[-./_](\d{1,2})[-./_](\d{1,4})$"#, options: .caseInsensitive)

    /// The days a word can mean, as the index's words ("1977 05 08"), most likely first. None: not a date.
    static func dates(_ word: String) -> [String] {
        let ns = word as NSString
        guard let m = datePattern.firstMatch(in: word, range: NSRange(location: 0, length: ns.length)) else { return [] }
        let a = ns.substring(with: m.range(at: 1)), b = ns.substring(with: m.range(at: 2)), c = ns.substring(with: m.range(at: 3))
        guard let x = Int(a), let y = Int(b), let z = Int(c) else { return [] }
        var days: [(Int, Int, Int)] = []   // year, month, day
        if a.count == 4 {
            days = [(x, y, z)]                     // 1977-05-08
        } else if c.count == 4 {
            days = [(z, y, x), (z, x, y)]          // 8.5.1977 (day first, as in Europe), 5/8/1977 (month first)
        } else if a.count <= 2, c.count <= 2 {
            // Two-digit years: etree's 77-05-08 first, then 02-14-94 and 14.02.94.
            days = [(year(x), y, z), (year(z), x, y), (year(z), y, x)]
        }
        var out: [String] = []
        for (yy, mm, dd) in days where (1...12).contains(mm) && (1...31).contains(dd) && yy >= 1000 {
            let s = String(format: "%04d %02d %02d", yy, mm, dd)
            if !out.contains(s) { out.append(s) }
        }
        return out
    }

    /// 77 → 1977, 05 → 2005 (up to this year's two digits: the 2000s).
    private static func year(_ yy: Int) -> Int {
        let now = Calendar.current.component(.year, from: Date()) % 100
        return yy <= now ? 2000 + yy : 1900 + yy
    }

    /// The typed words as the index keeps them: no case or accents ("Björk" → "bjork").
    static func folded(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// Letters to change, add, remove or swap (two next to each other) to turn one word into the other. Three rows
    /// of the table, not all of it (it runs over many words while a search finds nothing).
    static func distance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty || t.isEmpty { return max(s.count, t.count) }
        var before = [Int](repeating: 0, count: t.count + 1), last = Array(0...t.count), row = before
        for i in 1...s.count {
            row[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                row[j] = min(last[j] + 1, row[j - 1] + 1, last[j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] { row[j] = min(row[j], before[j - 2] + 1) }
            }
            (before, last, row) = (last, row, before)
        }
        return last[t.count]
    }
}

extension CollectionDB {
    /// A search that found nothing, spelled like the library: each word that starts no word in it is replaced by the
    /// closest one there (a letter off, two in longer words; the most used when several are as close). nil: no
    /// better spelling. Quoted phrases and dates are kept as typed.
    func suggestion(for typed: String) throws -> String? {
        guard hasFTS, !typed.contains("\"") else { return nil }
        var words = typed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var changed = false
        for (i, word) in words.enumerated() {
            let w = LibrarySearch.folded(word)
            guard w.count >= 3, w.allSatisfy({ $0.isLetter || $0.isNumber }), LibrarySearch.dates(word).isEmpty else { continue }
            let upper = w + "\u{10FFFF}"
            guard try db.scalar("SELECT 1 FROM search_terms WHERE term >= ? AND term < ? LIMIT 1", [w, upper]) == nil else { continue }
            // Words starting with the same letter, about as long.
            let first = String(w.prefix(1)), allowed = w.count <= 4 ? 1 : 2
            var best: (term: String, distance: Int, docs: Int)?
            try db.query("SELECT term, doc FROM search_terms WHERE term >= ? AND term < ?", [first, first + "\u{10FFFF}"]) { r in
                let term = r.text(0)
                guard abs(term.count - w.count) <= allowed else { return }
                let d = LibrarySearch.distance(w, term)
                guard d <= allowed else { return }
                if best == nil || d < best!.distance || (d == best!.distance && r.int(1) > best!.docs) { best = (term, d, r.int(1)) }
            }
            if let best {
                words[i] = best.term
                changed = true
            }
        }
        return changed ? words.joined(separator: " ") : nil
    }
}
