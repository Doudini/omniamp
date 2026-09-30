import Foundation

/// The order an album's tracks play in. The tags usually tell it, but a loosely kept collection has albums where
/// they don't: files with no number, a disc number on some files only, numbers copied from another release. The
/// file names are the other witness: Finder order is how the folder was meant to be played (the playlist plays a
/// dropped folder that way too).
///
/// - No disc number is disc 1, so a disc number on some files only doesn't split the album in two.
/// - Tracks with no number come after the numbered ones, in Finder order.
/// - When two tracks claim the same place (disc and number), this album's tags aren't trusted: the numbers in the
///   file names are used when every file has its own, else Finder order.
/// A CUE sheet's tracks keep their order inside their file.
enum TrackOrder {
    static func sorted(_ tracks: [LibraryTrack]) -> [LibraryTrack] {
        var places = Set<Place>()
        let clash = tracks.contains { t in t.number.map { !places.insert(Place(disc: disc(t), number: $0)).inserted } ?? false }
        let numbers: [String: Int]
        if !clash {
            return tracks.sorted { before($0, $0.number, $1, $1.number) }
        } else if let fromNames = fileNumbers(tracks) {
            numbers = fromNames
        } else {
            numbers = [:]
        }
        return tracks.sorted { before($0, numbers[$0.path], $1, numbers[$1.path]) }
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
