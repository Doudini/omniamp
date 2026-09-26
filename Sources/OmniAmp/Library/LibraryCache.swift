import Foundation

/// Persists the playlist (with tags) so relaunch is instant.
enum LibraryCache {
    struct Payload: Codable {
        var version = 1
        var tracks: [Track]
        var currentIndex: Int?
        var volume: Float?
        var shuffle: Bool?
        var repeatAll: Bool?
    }

    static var fileURL: URL {
        // OMNIAMP_CACHE_DIR lets test runs use a throwaway cache.
        let dir = ProcessInfo.processInfo.environment["OMNIAMP_CACHE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OmniAmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.cache")
    }

    static func load() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? PropertyListDecoder().decode(Payload.self, from: data)
    }

    static func save(_ payload: Payload) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let data = try? enc.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
