import Compression
import Foundation

/// Minimal read-only ZIP reader (stored + deflate), enough for .wsz skins.
struct ZipArchive {
    enum ZipError: Error { case notZip, corrupt, unsupported(UInt16) }

    /// Entries keyed by lowercase file name (directories stripped).
    private(set) var entries: [String: Data] = [:]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { i + 2 <= b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 4 <= b.count ? u16(i) | u16(i + 2) << 16 : 0 }

        // End of central directory: scan backwards (comment may follow).
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 22 - 65_535) {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)

        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x0201_4B50 else { throw ZipError.corrupt }
            let method = UInt16(u16(p + 10))
            let compSize = u32(p + 20)
            let size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let localOffset = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<min(p + 46 + nameLen, b.count)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            guard !name.hasSuffix("/"), u32(localOffset) == 0x0403_4B50 else { continue }
            let start = localOffset + 30 + u16(localOffset + 26) + u16(localOffset + 28)
            guard start + compSize <= b.count else { throw ZipError.corrupt }
            let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + compSize))
            let key = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased()
            switch method {
            case 0: entries[key] = raw
            case 8: entries[key] = try Self.inflate(raw, size: size)
            default: continue // skip odd entries rather than failing the whole skin
            }
        }
    }

    private static func inflate(_ src: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        guard size <= 64 * 1024 * 1024 else { throw ZipError.corrupt }   // no skin file is this big
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw ZipError.corrupt }
        return out
    }
}
