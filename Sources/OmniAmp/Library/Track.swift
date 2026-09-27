import Foundation

struct Track: Codable, Sendable {
    var path: String
    var size: Int64
    var mtime: Double
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var bitrate: Int?      // kbps
    var sampleRate: Int?   // Hz
    var bitDepth: Int?     // bits per sample (lossless/PCM only)
    var rgTrackGain: Float?
    var rgAlbumGain: Float?
    var rgTrackPeak: Float?
    var rgAlbumPeak: Float?
    var tagsLoaded: Bool = false
    // CUE sheet track: a slice of `path` (seconds). nil for normal files.
    var cueStart: Double?
    var cueEnd: Double?
    var cueNumber: Int?
    /// Radio station logo URL.
    var logo: String?
    /// Radio: genre and country from the directory, e.g. "deep house, techno · Germany".
    var stationTags: String?
    /// Podcast episode: the show's name (also the `artist`); nil for everything else.
    var podcast: String?
    /// Podcast episode: release date (seconds since 1970) and the show notes as plain text.
    var published: Double?
    var summary: String?

    /// Identity in the playlist: CUE tracks share their file's path, so the start time is part of it.
    var key: String { cueStart.map { "\(path)#\($0)" } ?? path }
    var cueRange: (start: Double, end: Double?)? { cueStart.map { ($0, cueEnd) } }

    /// A web URL: a radio station or a podcast episode.
    var isRemote: Bool { path.hasPrefix("http://") || path.hasPrefix("https://") }
    /// Internet radio (live, endless): a web URL that isn't a podcast episode.
    var isStream: Bool { isRemote && podcast == nil }
    /// A podcast episode: a web audio file with a length, played by seeking/resuming like a file.
    var isEpisode: Bool { isRemote && podcast != nil }
    var url: URL { isRemote ? (URL(string: path) ?? URL(fileURLWithPath: path)) : URL(fileURLWithPath: path) }

    /// A radio station entry for the playlist.
    static func stream(_ url: String, name: String?, logo: String? = nil) -> Track {
        var t = Track(path: url, size: 0, mtime: 0)
        t.title = name
        t.logo = logo
        t.tagsLoaded = true
        return t
    }

    /// A podcast episode entry for the playlist.
    static func episode(_ url: String, title: String, show: String, artwork: String?, duration: Double?,
                        published: Double?, summary: String?) -> Track {
        var t = Track(path: url, size: 0, mtime: 0)
        t.title = title
        t.artist = show
        t.album = show
        t.podcast = show
        t.logo = artwork
        t.duration = duration
        t.published = published
        t.summary = summary
        t.tagsLoaded = true
        return t
    }

    var fileStem: String { (path as NSString).lastPathComponent.replacingOccurrences(of: "." + (path as NSString).pathExtension, with: "") }

    var displayTitle: String {
        if let t = title, !t.isEmpty {
            if let a = artist, !a.isEmpty { return "\(a) - \(t)" }
            return t
        }
        return fileStem
    }
}

enum TimeFormat {
    static func mmss(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s >= 0 else { return "" }
        let total = Int(s.rounded())
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
