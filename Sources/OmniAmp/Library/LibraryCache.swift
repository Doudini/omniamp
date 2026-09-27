import Foundation

/// Persists the playlist (with tags) so relaunch is instant.
enum LibraryCache {
    /// Bump when tags gain new fields: older caches are then re-read in the background.
    static let currentVersion = 2

    struct Payload: Codable {
        var version = LibraryCache.currentVersion
        var tracks: [Track]
        var currentIndex: Int?
        var volume: Float?
        var shuffle: Bool?
        var repeatAll: Bool?
    }

    /// True inside XCTest.
    static let runningTests = NSClassFromString("XCTestCase") != nil

    static var fileURL: URL {
        // OMNIAMP_CACHE_DIR lets test runs use a throwaway cache. Unit tests never use the real one, even when a
        // delayed save fires after a test has reset the variable (that once wrote test tracks into the library).
        let dir = ProcessInfo.processInfo.environment["OMNIAMP_CACHE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? (runningTests ? FileManager.default.temporaryDirectory.appendingPathComponent("OmniAmp-tests", isDirectory: true) : nil)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OmniAmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.cache")
    }

    static func load() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL),
              var p = try? PropertyListDecoder().decode(Payload.self, from: data) else { return nil }
        if p.version < currentVersion {
            // v2 added ReplayGain: re-read tags once (fast, in the background).
            for i in p.tracks.indices { p.tracks[i].tagsLoaded = false }
            p.version = currentVersion
        }
        return p
    }

    static func save(_ payload: Payload) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let data = try? enc.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
