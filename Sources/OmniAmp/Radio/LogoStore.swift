import AppKit
import CryptoKit

/// Station logos: downloaded once, kept on disk (Caches/OmniAmp/logos) and in a small memory cache,
/// decoded straight to display size.
@MainActor
final class LogoStore {
    static let shared = LogoStore()

    private var memory: [String: CGImage] = [:]
    private var order: [String] = []
    /// Decoded images are held up to this many bytes (a 280 px logo is ~300 KB, a row thumbnail ~16 KB).
    private var memoryBytes = 0
    private let maxBytes = 20 * 1024 * 1024
    private var waiting: [String: [(CGImage?) -> Void]] = [:]
    /// When a logo last failed: not asked again for a while (a dead link), but retried later (offline, a server hiccup).
    private var failed: [String: Date] = [:]
    nonisolated private static let retryAfter: TimeInterval = 300
    private let capacity = 200

    nonisolated private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("OmniAmp/logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .background).async { trimDisk(d) }
        return d
    }()

    /// The logo and cover files are kept up to 200 MB; the least recently used go first.
    nonisolated private static func trimDisk(_ d: URL, limit: Int = 200 * 1024 * 1024) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: keys) else { return }
        let info = files.map { f -> (URL, Int, Date) in
            let v = try? f.resourceValues(forKeys: Set(keys))
            return (f, v?.fileSize ?? 0, v?.contentAccessDate ?? .distantPast)
        }
        var total = info.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        for (f, size, _) in info.sorted(by: { $0.2 < $1.2 }) where total > limit {
            try? FileManager.default.removeItem(at: f)
            total -= size
        }
    }

    nonisolated private static func file(for url: String) -> URL {
        dir.appendingPathComponent(Insecure.SHA1.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    /// Apple's artwork addresses name their size (…/600x600bb.jpg): ask for 120 px for list rows, a tenth of
    /// the download. Other addresses are left alone (they're decoded small anyway).
    nonisolated static func thumbnail(_ url: String?) -> String? {
        guard let url, url.contains("mzstatic.com") else { return url }
        return url.replacingOccurrences(of: "/\\d+x\\d+(bb|cc)\\.(jpg|png|webp)$", with: "/120x120bb.$2", options: .regularExpression)
    }

    /// Row thumbnails (podcast episodes) are decoded small: ~64 px instead of 280 is a 20th of the memory.
    enum Size { case regular, small }
    private static func key(_ url: String, _ size: Size) -> String { size == .regular ? url : "small|" + url }

    func cached(_ url: String?, size: Size = .regular) -> CGImage? { url.flatMap { memory[Self.key($0, size)] } }

    /// Calls back on the main queue with the logo (nil if there is none or it can't be loaded).
    func load(_ url: String?, size: Size = .regular, completion: @escaping @MainActor (CGImage?) -> Void) {
        guard let url, !url.isEmpty, let remote = URL(string: url), ["http", "https"].contains(remote.scheme?.lowercased() ?? ""),
              failed[url].map({ Date().timeIntervalSince($0) > Self.retryAfter }) ?? true else { completion(nil); return }
        let key = Self.key(url, size)
        if let img = memory[key] { completion(img); return }
        if waiting[key] != nil { waiting[key]!.append(completion); return }
        waiting[key] = [completion]
        let maxPixels = size == .small ? 72 : ArtworkStore.thumbPixels   // 36 pt rows on Retina
        enqueue { [weak self] in self?.fetch(url, remote: remote, key: key, maxPixels: maxPixels) }
    }

    // A few at a time, newest first: scrolling a long episode list mustn't start hundreds of downloads (episode
    // art is often a multi-MB original), and the rows on screen now matter more than those scrolled past.
    private var running = 0
    private let maxRunning = 4
    private var queued: [() -> Void] = []

    private func enqueue(_ job: @escaping () -> Void) {
        if running < maxRunning { running += 1; job() } else { queued.append(job) }
    }

    private func jobDone() {
        running -= 1
        if !queued.isEmpty { running += 1; queued.removeLast()() }
    }

    nonisolated private static let maxFileBytes = 20 * 1024 * 1024

    private func fetch(_ url: String, remote: URL, key: String, maxPixels: Int) {
        Task.detached(priority: .utility) {
            let disk = Self.file(for: url)
            var tooBig = false
            if !FileManager.default.fileExists(atPath: disk.path) {
                // To a file, not into memory: then ImageIO decodes a small thumbnail straight from it.
                var req = URLRequest(url: remote)
                req.setValue("OmniAmp/1.0", forHTTPHeaderField: "User-Agent")
                req.timeoutInterval = 15
                do {
                    // Stopped at the limit, not checked after: a logo address can point at a stream or a huge file.
                    let (tmp, r) = try await BoundedFetch.download(for: req, limit: Self.maxFileBytes, deadline: 60)
                    if (r as? HTTPURLResponse)?.statusCode ?? 200 < 400 {
                        try? FileManager.default.removeItem(at: disk); try? FileManager.default.moveItem(at: tmp, to: disk)
                    } else {
                        try? FileManager.default.removeItem(at: tmp)
                    }
                } catch is BoundedFetch.TooLarge {
                    tooBig = true
                } catch {}
            }
            let img = autoreleasepool { Self.decode(disk, maxPixels: maxPixels) }
            if img == nil { try? FileManager.default.removeItem(at: disk) }   // don't keep serving an unreadable file
            let permanent = tooBig
            await MainActor.run {
                self.finish(url, key: key, img, permanent: permanent)
                self.jobDone()
            }
        }
    }

    /// PNG/JPEG/ICO/GIF via ImageIO at display size; anything else NSImage understands (e.g. SVG) as a fallback.
    nonisolated private static func decode(_ file: URL, maxPixels: Int) -> CGImage? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        if let img = ArtworkStore.image(contentsOf: file, maxPixels: maxPixels) { return img }
        guard let ns = NSImage(contentsOf: file) else { return nil }
        var rect = NSRect(x: 0, y: 0, width: maxPixels, height: maxPixels)
        return ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// `permanent`: never ask again this session (an image too big to be worth it).
    private func finish(_ url: String, key: String, _ img: CGImage?, permanent: Bool = false) {
        if let img {
            memory[key] = img
            failed.removeValue(forKey: url)
            order.append(key)
            memoryBytes += img.bytesPerRow * img.height
            // Oldest out first, by size and by count.
            while (memoryBytes > maxBytes || order.count > capacity), !order.isEmpty {
                if let old = memory.removeValue(forKey: order.removeFirst()) { memoryBytes -= old.bytesPerRow * old.height }
            }
        } else {
            failed[url] = permanent ? .distantFuture : Date()
        }
        waiting.removeValue(forKey: key)?.forEach { $0(img) }
    }
}
