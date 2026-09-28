import Foundation

/// Where long tracks and podcast episodes were left off, and when (the oldest go first past `limit`).
/// Kept in memory (the podcast window asks for every row it draws) and in resume.json next to the playlist,
/// written in the background. Earlier versions kept this in UserDefaults: taken over once.
final class ResumeStore {
    private struct File: Codable { var positions: [String: Double]; var dates: [String: Double] }

    private(set) var positions: [String: Double] = [:]
    private var dates: [String: Double] = [:]
    private let url: URL
    private let limit: Int
    private static let writes = DispatchQueue(label: "omniamp.resume-save", qos: .utility)

    init(url: URL = LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("resume.json"), limit: Int = 1000) {
        self.url = url
        self.limit = limit
        Self.writes.sync {}   // a save still on its way lands first
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) {
            positions = f.positions
            dates = f.dates
        } else if url == Self.defaultURL, let old = UserDefaults.standard.dictionary(forKey: Pref.resumePositions) as? [String: Double] {
            positions = old
            dates = UserDefaults.standard.dictionary(forKey: Pref.resumeDates) as? [String: Double] ?? [:]
            save()
            Self.writes.sync {}
            UserDefaults.standard.removeObject(forKey: Pref.resumePositions)
            UserDefaults.standard.removeObject(forKey: Pref.resumeDates)
        }
    }

    private static var defaultURL: URL { LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("resume.json") }

    subscript(key: String) -> Double? { positions[key] }

    func set(_ key: String, _ seconds: Double) {
        positions[key] = seconds
        dates[key] = Date().timeIntervalSince1970
        if positions.count > limit {
            // Oldest first; never the one just saved (it has the newest date).
            for k in positions.keys.sorted(by: { (dates[$0] ?? 0) < (dates[$1] ?? 0) }).prefix(positions.count - limit) {
                positions.removeValue(forKey: k)
                dates.removeValue(forKey: k)
            }
        }
        save()
    }

    func remove(_ key: String) {
        guard positions.removeValue(forKey: key) != nil else { return }
        dates.removeValue(forKey: key)
        save()
    }

    /// Keys renamed (an episode's address changed in its feed).
    func rename(_ moved: [String: String]) {
        var changed = false
        for (was, now) in moved {
            if let p = positions.removeValue(forKey: was) { positions[now] = p; changed = true }
            if let d = dates.removeValue(forKey: was) { dates[now] = d }
        }
        if changed { save() }
    }

    private func save() {
        let f = File(positions: positions, dates: dates), url = url
        Self.writes.async { try? JSONEncoder().encode(f).write(to: url, options: .atomic) }
    }

    /// Let pending writes finish (quitting).
    static func flush() { writes.sync {} }
}
