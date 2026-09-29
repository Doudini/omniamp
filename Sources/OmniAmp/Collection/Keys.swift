import Foundation

/// Bump when `title(_:)` changes: the library recomputes its song keys from the stored titles.
let songKeyVersion = 2

/// Names folded for grouping and sorting: "The Beatles", "BEATLES" and "Beatles, The" are one artist, and
/// "Song (Live)", "Song - 2011 Remaster" and "Song [demo]" are one song.
enum Keys {
    /// Lowercase, no accents, "&" = "and", only letters and digits separated by single spaces.
    static func fold(_ s: String) -> String {
        let lower = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        var out = "", space = false
        out.reserveCapacity(lower.count)
        for ch in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) {
                if space, !out.isEmpty { out.append(" ") }
                out.unicodeScalars.append(ch)
                space = false
            } else {
                space = true
            }
        }
        return out
    }

    /// "The Beatles", "Beatles, The" → "beatles".
    static func artist(_ name: String) -> String {
        var k = fold(name)
        if k.hasPrefix("the ") { k.removeFirst(4) }
        if k.hasSuffix(" the") { k.removeLast(4) }
        return k.isEmpty ? fold(name) : k
    }

    /// How an artist sorts: without a leading "The ".
    static func sortName(_ name: String) -> String {
        // Brackets, quotes and dots in front don't count ("(Smog)" sorts under S, where its letter is).
        let leading: Set<Character> = ["(", "[", "{", "\"", "'", ".", "-", "_", "¡", "¿"]
        let t = String(name.trimmingCharacters(in: .whitespaces).drop { leading.contains($0) }).trimmingCharacters(in: .whitespaces)
        if t.count > 4, t.lowercased().hasPrefix("the ") { return String(t.dropFirst(4)) }
        return t
    }

    /// The A–Z index letter: "#" for digits, symbols and non-Latin scripts.
    static func letter(_ name: String) -> String {
        guard let c = fold(sortName(name)).unicodeScalars.first, ("a"..."z").contains(Character(c)) else { return "#" }
        return String(Character(c)).uppercased()
    }

    private static let versionWords = ["live", "demo", "remaster", "remastered", "version", "mix", "remix", "edit", "take",
                                       "acoustic", "mono", "stereo", "bonus", "outtake", "rehearsal", "alternate", "alt",
                                       "instrumental", "single", "session", "early", "rough", "unreleased", "radio", "extended",
                                       "reprise", "mixed", "bootleg", "sbd", "aud", "soundboard"]

    /// One song whatever the recording: bracketed version notes and " - 2011 Remaster" style suffixes go.
    static func title(_ title: String) -> String {
        var t = title
        // Bracketed parts that describe a version: "(Live)", "[Demo 1983]", "{take 3}".
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
            while let o = t.range(of: open, options: .backwards), let c = t.range(of: close, range: o.upperBound..<t.endIndex) {
                let raw = String(t[o.upperBound..<c.lowerBound]), inner = fold(raw)
                // A version note: "(Live)", "[Demo]", or anything with a year in it ("(Paris 4 mai 2002)", "[BBC 1989]").
                guard inner.split(separator: " ").contains(where: { versionWords.contains(String($0)) }) || inner.allSatisfy(\.isNumber)
                        || year(raw) != nil
                else { break }
                t.removeSubrange(o.lowerBound..<c.upperBound)
            }
        }
        // "Song - Live at …", "Song - 2011 Remaster".
        if let dash = t.range(of: " - ", options: .backwards) {
            let tail = fold(String(t[dash.upperBound...]))
            if tail.split(separator: " ").contains(where: { versionWords.contains(String($0)) }) { t = String(t[..<dash.lowerBound]) }
        }
        let k = fold(t)
        return k.isEmpty ? fold(title) : k
    }

    /// How to show a song spelled several ways: a spelling without version notes if there is one, the most common.
    static func displayTitle(_ spellings: [String: Int]) -> String {
        let plain = spellings.filter { fold($0.key) == title($0.key) }
        let pool = plain.isEmpty ? spellings : plain
        return pool.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
    }

    /// The year in a date tag or name: "1977-05-08", "1977", "May 1977" → 1977.
    static func year(_ s: String?) -> Int? {
        guard let s else { return nil }
        // Only a run of exactly four digits counts (not part of a catalog number), 1900–2099.
        var run = ""
        for ch in s.unicodeScalars.map(Character.init) + [" "] {
            if ch.isASCII, ch.isNumber { run.append(ch); continue }
            if run.count == 4, let y = Int(run), (1900...2099).contains(y) { return y }
            run = ""
        }
        return nil
    }
}
