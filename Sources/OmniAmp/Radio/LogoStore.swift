import AppKit
import CryptoKit

/// Station logos: downloaded once, kept on disk (Caches/OmniAmp/logos) and in a small memory cache,
/// decoded straight to display size.
final class LogoStore {
    static let shared = LogoStore()

    private var memory: [String: CGImage] = [:]
    private var order: [String] = []
    private var waiting: [String: [(CGImage?) -> Void]] = [:]
    /// When a logo last failed: not asked again for a while (a dead link), but retried later (offline, a server hiccup).
    private var failed: [String: Date] = [:]
    private static let retryAfter: TimeInterval = 300
    private let capacity = 200

    private static var dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("OmniAmp/logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func file(for url: String) -> URL {
        dir.appendingPathComponent(Insecure.SHA1.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    /// Row thumbnails (podcast episodes) are decoded small: ~64 px instead of 280 is a 20th of the memory.
    enum Size { case regular, small }
    private static func key(_ url: String, _ size: Size) -> String { size == .regular ? url : "small|" + url }

    func cached(_ url: String?, size: Size = .regular) -> CGImage? { url.flatMap { memory[Self.key($0, size)] } }

    /// Calls back on the main queue with the logo (nil if there is none or it can't be loaded).
    func load(_ url: String?, size: Size = .regular, completion: @escaping (CGImage?) -> Void) {
        guard let url, !url.isEmpty, let remote = URL(string: url),
              failed[url].map({ Date().timeIntervalSince($0) > Self.retryAfter }) ?? true else { completion(nil); return }
        let key = Self.key(url, size)
        if let img = memory[key] { completion(img); return }
        if waiting[key] != nil { waiting[key]!.append(completion); return }
        waiting[key] = [completion]
        Task.detached(priority: .utility) {
            let disk = Self.file(for: url)
            var data = try? Data(contentsOf: disk)
            if data == nil {
                var req = URLRequest(url: remote)
                req.setValue("OmniAmp/1.0", forHTTPHeaderField: "User-Agent")
                req.timeoutInterval = 10
                if let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode ?? 200 < 400, d.count < 5_000_000 {
                    data = d
                    try? d.write(to: disk, options: .atomic)
                }
            }
            let img = data.flatMap { Self.decode($0, maxPixels: size == .small ? 64 : ArtworkStore.thumbPixels) }
            if img == nil { try? FileManager.default.removeItem(at: disk) }   // don't keep serving an unreadable file
            await MainActor.run { self.finish(url, key: key, img) }
        }
    }

    /// PNG/JPEG/ICO/GIF via ImageIO at ≤ 280 px; anything else NSImage understands (e.g. SVG) as a fallback.
    private static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        if let img = ArtworkStore.image(data, maxPixels: maxPixels) { return img }
        guard let ns = NSImage(data: data) else { return nil }
        var rect = NSRect(x: 0, y: 0, width: maxPixels, height: maxPixels)
        return ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func finish(_ url: String, key: String, _ img: CGImage?) {
        if let img {
            memory[key] = img
            failed.removeValue(forKey: url)
            order.append(key)
            if order.count > capacity { memory.removeValue(forKey: order.removeFirst()) }
        } else {
            failed[url] = Date()
        }
        waiting.removeValue(forKey: key)?.forEach { $0(img) }
    }
}
