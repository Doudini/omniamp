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

    /// `preload()`'s result, taken by the first `load()`.
    private final class Pending: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var result: Payload?
    }
    @MainActor private static var pending: Pending?

    /// Read and decode in the background now (while AppKit starts up); `load()` then waits only for what's left.
    @MainActor static func preload() {
        let p = Pending()
        pending = p
        DispatchQueue.global(qos: .userInitiated).async {
            p.result = read()
            p.done.signal()   // the semaphore orders the write before the waiting read
        }
    }

    @MainActor static func load() -> Payload? {
        guard let p = pending else { return read() }
        pending = nil
        p.done.wait()
        return p.result
    }

    private static func read() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard var p = try? PropertyListDecoder().decode(Payload.self, from: data) else {
            // Unreadable (damaged, or from a future version): set it aside rather than overwrite it with an
            // empty playlist on the next save.
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).cache")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            NSLog("OmniAmp: the library cache couldn't be read; kept it as %@", aside.lastPathComponent)
            return nil
        }
        // Caches written before lengths were checked may hold impossible values (a crafted tag): clean them.
        for i in p.tracks.indices {
            p.tracks[i].duration = Sane.duration(p.tracks[i].duration)
            if p.tracks[i].cueStart != nil { p.tracks[i].cueStart = Sane.offset(p.tracks[i].cueStart) ?? 0 }
            p.tracks[i].cueEnd = Sane.offset(p.tracks[i].cueEnd)
            if let b = p.tracks[i].bitrate, !(0..<1_000_000).contains(b) { p.tracks[i].bitrate = nil }
        }
        if p.version < currentVersion {
            // v2 added ReplayGain: re-read tags once (fast, in the background).
            // Only files: radio stations and podcast episodes have no tags to read, and their names would be lost.
            for i in p.tracks.indices where !p.tracks[i].isRemote { p.tracks[i].tagsLoaded = false }
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
