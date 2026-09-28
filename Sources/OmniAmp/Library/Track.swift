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
    var url: URL { isRemote ? (URL(string: path) ?? URL(exactPath: path)) : URL(exactPath: path) }

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

    /// An audio file on the web (added by URL): seekable and resumable like an episode, but without a show.
    static func webFile(_ url: String, title: String) -> Track {
        var t = episode(url, title: title, show: "", artwork: nil, duration: nil, published: nil, summary: nil)
        t.artist = nil
        t.album = nil
        return t
    }

    /// A web file added by URL rather than a podcast episode (both play the same way).
    var isWebFile: Bool { isEpisode && podcast?.isEmpty == true }

    var fileStem: String { (path as NSString).lastPathComponent.replacingOccurrences(of: "." + (path as NSString).pathExtension, with: "") }

    var displayTitle: String {
        if let t = title, !t.isEmpty {
            if let a = artist, !a.isEmpty { return "\(a) - \(t)" }
            return t
        }
        return fileStem
    }
}

/// Tags, CUE sheets, playlists and feeds can claim anything (1e25 seconds, infinity): every time and rate that
/// reaches the app goes through these, so nothing downstream can trap converting it to an Int.
enum Sane {
    /// Longest believable length: ~115 days.
    static let maxSeconds = 10_000_000.0

    /// A length in seconds: finite, positive and believable, else nil.
    static func duration(_ d: Double?) -> Double? {
        guard let d, d.isFinite, d > 0, d < maxSeconds else { return nil }
        return d
    }

    /// A time within a file (may be 0), same bounds.
    static func offset(_ d: Double?) -> Double? {
        guard let d, d.isFinite, d >= 0, d < maxSeconds else { return nil }
        return d
    }

    /// kbit/s from a size and a length; nil when that can't be meaningful (tiny or bogus lengths).
    static func kbps(bytes: Int64, seconds: Double?) -> Int? {
        guard let s = duration(seconds), s >= 0.1 else { return nil }
        let k = Double(bytes) * 8 / s / 1000
        return k.isFinite && k >= 0 && k < 1_000_000 ? Int(k.rounded()) : nil
    }

    /// Any Double as an Int without trapping (non-finite → 0, clamped to ±1e12).
    static func int(_ x: Double) -> Int { x.isFinite ? Int(max(-1e12, min(x, 1e12))) : 0 }
}

enum TimeFormat {
    static func mmss(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s >= 0, s < Sane.maxSeconds else { return "" }
        let total = Int(s.rounded())
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
