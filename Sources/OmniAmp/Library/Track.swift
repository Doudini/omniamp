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
    var tagsLoaded: Bool = false

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
