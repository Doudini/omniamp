import AppKit
import ImageIO
import Darwin.malloc

/// Details + artwork for the few tracks on screen, loaded in the background.
///
/// Memory: images are decoded straight to the size they are shown at (ImageIO thumbnails, never the full
/// multi-megapixel cover), and only a handful of entries are kept. The large hover image is made on demand.
final class ArtworkStore {
    static let shared = ArtworkStore()

    struct Entry {
        let details: TrackDetails     // artwork bytes dropped after decoding (covers can be several MB)
        let thumb: CGImage?           // panel slot / drawer size
        let artPixels: CGSize?        // original cover size, for the info line
    }

    private var cache: [String: Entry] = [:]
    private var order: [String] = []
    private var waiting: [String: [(Entry) -> Void]] = [:]
    private let queue = DispatchQueue(label: "omniamp.artwork", qos: .userInitiated)
    private let capacity = 6
    /// Thumbnails are rendered at this pixel size (drawer shows 140 pt @2x).
    static let thumbPixels = 280

    /// Calls back on the main queue (immediately if cached).
    func load(_ path: String, completion: @escaping (Entry) -> Void) {
        if let e = cache[path] { touch(path); completion(e); return }
        if waiting[path] != nil { waiting[path]!.append(completion); return }
        waiting[path] = [completion]
        queue.async {
            // Drain ImageIO's temporaries now: without a pool, the full-size decode buffer lives on.
            let entry: Entry = autoreleasepool {
                var d = DetailsReader.read(path: path)
                let thumb = d.artwork.flatMap { Self.image($0, maxPixels: Self.thumbPixels) }
                let pixels = d.artwork.flatMap(Self.pixelSize)
                d.artwork = nil
                if thumb == nil { d.artworkSource = nil }
                return Entry(details: d, thumb: thumb, artPixels: pixels)
            }
            // Covers pass through a few MB of temporary buffers; give those pages back to the system
            // instead of letting the allocator keep them dirty.
            malloc_zone_pressure_relief(nil, 0)
            DispatchQueue.main.async {
                self.cache[path] = entry
                self.touch(path)
                let cbs = self.waiting.removeValue(forKey: path) ?? []
                cbs.forEach { $0(entry) }
            }
        }
    }

    func cached(_ path: String) -> Entry? { cache[path] }

    /// A large rendering (hover card), read again from disk so no big bitmap or bytes stay in memory.
    func largeImage(_ path: String, maxPixels: Int, completion: @escaping (CGImage?) -> Void) {
        queue.async {
            let img = autoreleasepool { DetailsReader.read(path: path).artwork.flatMap { Self.image($0, maxPixels: maxPixels) } }
            malloc_zone_pressure_relief(nil, 0)
            DispatchQueue.main.async { completion(img) }
        }
    }

    /// Decode compressed image bytes directly at a bounded size.
    static func image(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,   // decode the small thumbnail now…
            kCGImageSourceShouldCache: false,             // …but never keep the full-size decode around
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // The thumbnail can keep a reference to the compressed source bytes (a whole cover file);
        // redraw it into its own bitmap so those bytes can be freed.
        guard let ctx = CGContext(data: nil, width: thumb.width, height: thumb.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return thumb }
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: thumb.width, height: thumb.height))
        return ctx.makeImage() ?? thumb
    }

    /// Pixel size of the original artwork (for the info line), without decoding it.
    static func pixelSize(_ data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    private func touch(_ path: String) {
        order.removeAll { $0 == path }
        order.append(path)
        while order.count > capacity { cache.removeValue(forKey: order.removeFirst()) }
    }
}
