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

    /// Identity in the playlist: CUE tracks share their file's path, so the start time is part of it.
    var key: String { cueStart.map { "\(path)#\($0)" } ?? path }
    var cueRange: (start: Double, end: Double?)? { cueStart.map { ($0, cueEnd) } }

    var url: URL { URL(fileURLWithPath: path) }

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
