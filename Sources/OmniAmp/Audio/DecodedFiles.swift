import CryptoKit
import Foundation

/// Files macOS can't play that OmniAmp converts first (DSD): converted once into a cache folder and played from
/// there like any other file, so seeking, gapless, EQ and bit-perfect output just work. The player opens files
/// off the main thread and looks at the next track early, so the wait is mostly hidden.
enum DecodedFiles {
    static func needsDecoding(_ url: URL) -> Bool { url.isFileURL && DSD.extensions.contains(url.pathExtension.lowercased()) }

    /// Converted copies are kept up to this size in all; the least recently played go first.
    static let limit: Int64 = 4 << 30

    static var directory: URL {
        let base = ProcessInfo.processInfo.environment["OMNIAMP_CACHE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? (LibraryCache.runningTests ? FileManager.default.temporaryDirectory.appendingPathComponent("OmniAmp-tests") : nil)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("OmniAmp")
        let d = base.appendingPathComponent("Decoded", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// One conversion at a time: opening a track and getting the next one ready can ask for the same file.
    private static let converting = NSLock()

    /// What to open for `url`: itself, or its converted copy (converting it now if needed; seconds for a long
    /// DSD track, so never on the main thread).
    static func playable(_ url: URL) throws -> URL {
        guard needsDecoding(url) else { return url }
        let path = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
        var st = stat()
        guard stat(path, &st) == 0 else { throw DSD.DecodeError.unreadable }
        // The file's name, size and date: a changed file (retagged, replaced) is converted again.
        let id = "\(path)|\(st.st_size)|\(st.st_mtimespec.tv_sec)"
        let key = Insecure.SHA1.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let out = directory.appendingPathComponent(key + ".caf")
        converting.lock()
        defer { converting.unlock() }
        if FileManager.default.fileExists(atPath: out.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: out.path)   // recently used
            return out
        }
        let partial = directory.appendingPathComponent(key + ".partial.caf")
        try? FileManager.default.removeItem(at: partial)
        let started = Date()
        do {
            try DSD.decode(path: path, to: partial)
            try FileManager.default.moveItem(at: partial, to: out)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        NSLog("OmniAmp: converted %@ to PCM in %.1fs", (path as NSString).lastPathComponent, Date().timeIntervalSince(started))
        DispatchQueue.global(qos: .background).async { trim() }
        return out
    }

    /// Down to the size limit, least recently played first (a copy is touched each time it's opened).
    static func trim(limit: Int64 = limit) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let info = files.filter { $0.pathExtension == "caf" && !$0.lastPathComponent.contains(".partial.") }.map { f -> (URL, Int64, Date) in
            let v = try? f.resourceValues(forKeys: Set(keys))
            return (f, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast)
        }
        var total = info.reduce(0) { $0 + $1.1 }
        for (f, size, _) in info.sorted(by: { $0.2 < $1.2 }) where total > limit {
            try? FileManager.default.removeItem(at: f)
            total -= size
        }
    }
}
