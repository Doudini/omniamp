import Foundation

/// The order an album's tracks play in. The tags usually tell it, but a loosely kept collection has albums where
/// they don't: files with no number, a disc number on some files only, numbers copied from another release. The
/// file names are the other witness: Finder order is how the folder was meant to be played (the playlist plays a
/// dropped folder that way too).
///
/// - No disc number is disc 1, so a disc number on some files only doesn't split the album in two.
/// - Tracks with no number fill the gaps in the numbering when there are exactly as many of them as gaps ("02"–"20"
///   and one file without a number: it's the opener), else they come after the numbered ones, in Finder order.
/// - When two tracks claim the same place (disc and number), this album's tags aren't trusted: the numbers in the
///   file names are used when every file has its own. Else each folder (a disc folder) and each CUE image plays
///   whole, in Finder order, by its tags' numbers inside (a copied or bonus track doesn't turn the album A–Z).
/// A CUE sheet's tracks keep their order inside their file.
enum TrackOrder {
    static func sorted(_ tracks: [LibraryTrack]) -> [LibraryTrack] {
        var places = Set<Place>()
        let clash = tracks.contains { t in t.number.map { !places.insert(Place(disc: disc(t), number: $0)).inserted } ?? false }
        if !clash {
            let filled = gapFill(tracks)
            return tracks.sorted { before($0, $0.number ?? filled[$0.id], $1, $1.number ?? filled[$1.id]) }
        }
        if let fromNames = fileNumbers(tracks) {
            return tracks.sorted { before($0, fromNames[$0.path], $1, fromNames[$1.path]) }
        }
        return tracks.sorted { a, b in
            if disc(a) != disc(b) { return disc(a) < disc(b) }
            let ga = group(a), gb = group(b)
            if ga != gb { return ga.localizedStandardCompare(gb) == .orderedAscending }
            return before(a, a.number, b, b.number)
        }
    }

    /// What plays as one piece when the numbers clash: a CUE image, else the folder the file is in.
    private static func group(_ t: LibraryTrack) -> String {
        t.cueStart != nil ? t.path : (t.path as NSString).deletingLastPathComponent
    }

    /// Numbers for the tracks without one, when they exactly fill their disc's gaps (in Finder order). CUE tracks
    /// always have theirs.
    private static func gapFill(_ tracks: [LibraryTrack]) -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for list in Dictionary(grouping: tracks, by: disc).values {
            let missing = list.filter { $0.number == nil }
            let used = Set(list.compactMap(\.number))
            guard !missing.isEmpty, missing.allSatisfy({ $0.cueStart == nil }), let top = used.max(), top >= 1 else { continue }
            let gaps = (1...top).filter { !used.contains($0) }
            guard gaps.count == missing.count else { continue }
            let inOrder = missing.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            for (t, n) in zip(inOrder, gaps) { out[t.id] = n }
        }
        return out
    }

    private struct Place: Hashable { let disc: Int, number: Int }

    private static func disc(_ t: LibraryTrack) -> Int { t.disc ?? 1 }

    private static func before(_ a: LibraryTrack, _ an: Int?, _ b: LibraryTrack, _ bn: Int?) -> Bool {
        if disc(a) != disc(b) { return disc(a) < disc(b) }
        switch (an, bn) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        let names = a.path.localizedStandardCompare(b.path)
        if names != .orderedSame { return names == .orderedAscending }
        if a.cueStart != b.cueStart { return (a.cueStart ?? 0) < (b.cueStart ?? 0) }
        return a.id < b.id
    }

    /// Each file's number from its name ("08 - common bird" → 8), or nil unless every file has one of its own.
    private static func fileNumbers(_ tracks: [LibraryTrack]) -> [String: Int]? {
        var out: [String: Int] = [:]
        var places = Set<Place>()
        for t in tracks where out[t.path] == nil {
            let name = ((t.path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard let n = ReleaseClassifier.fromFileName(name, artist: t.artist).track,
                  places.insert(Place(disc: disc(t), number: n)).inserted else { return nil }
            out[t.path] = n
        }
        return out
    }
}
