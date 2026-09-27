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

    func cached(_ url: String?) -> CGImage? { url.flatMap { memory[$0] } }

    /// Calls back on the main queue with the logo (nil if there is none or it can't be loaded).
    func load(_ url: String?, completion: @escaping (CGImage?) -> Void) {
        guard let url, !url.isEmpty, let remote = URL(string: url),
              failed[url].map({ Date().timeIntervalSince($0) > Self.retryAfter }) ?? true else { completion(nil); return }
        if let img = memory[url] { completion(img); return }
        if waiting[url] != nil { waiting[url]!.append(completion); return }
        waiting[url] = [completion]
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
            let img = data.flatMap { Self.decode($0) }
            if img == nil { try? FileManager.default.removeItem(at: disk) }   // don't keep serving an unreadable file
            await MainActor.run { self.finish(url, img) }
        }
    }

    /// PNG/JPEG/ICO/GIF via ImageIO at ≤ 280 px; anything else NSImage understands (e.g. SVG) as a fallback.
    private static func decode(_ data: Data) -> CGImage? {
        if let img = ArtworkStore.image(data, maxPixels: ArtworkStore.thumbPixels) { return img }
        guard let ns = NSImage(data: data) else { return nil }
        var rect = NSRect(x: 0, y: 0, width: 280, height: 280)
        return ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func finish(_ url: String, _ img: CGImage?) {
        if let img {
            memory[url] = img
            failed.removeValue(forKey: url)
            order.append(url)
            if order.count > capacity { memory.removeValue(forKey: order.removeFirst()) }
        } else {
            failed[url] = Date()
        }
        waiting.removeValue(forKey: url)?.forEach { $0(img) }
    }
}
