// Converts .woff2 fonts to plain .ttf (run: swift scripts/woff2-to-ttf.swift in.woff2... outDir).
//
// Why: macOS must decompress a WOFF2 font into RAM (~16 MB per Nerd Font), but it memory-maps a TTF from
// disk and only pages in the glyphs it uses. The app ships TTFs built from fonts/*.woff2 by make-app.sh.
//
// It also adds an OpenType 'meta' table declaring the fonts' languages (Latin). Without one, CoreText works
// them out by testing the character set against every language it knows, and keeps ~370 character-set
// bitmaps in memory for it (~3 MB per app, measured).
import CoreText
import Foundation

func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

func checksum(_ d: [UInt8]) -> UInt32 {
    var sum: UInt32 = 0
    var i = 0
    while i < d.count {
        var w: UInt32 = 0
        for k in 0..<4 { w = w << 8 | UInt32(i + k < d.count ? d[i + k] : 0) }
        sum = sum &+ w
        i += 4
    }
    return sum
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print("usage: woff2-to-ttf.swift in.woff2... outDir"); exit(1) }
let outDir = URL(fileURLWithPath: args.last!)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for path in args.dropLast() {
    let url = URL(fileURLWithPath: path)
    guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let d = descs.first else {
        print("skip \(path): not a font"); continue
    }
    let font = CTFontCreateWithFontDescriptor(d, 12, nil)
    guard let tagArray = CTFontCopyAvailableTables(font, CTFontTableOptions(rawValue: 0)) else { continue }
    // The array holds unboxed tag values, not CFNumbers.
    let tags = (0..<CFArrayGetCount(tagArray)).map { UInt32(UInt(bitPattern: CFArrayGetValueAtIndex(tagArray, $0))) }
    var tables: [(tag: UInt32, data: [UInt8])] = []
    for tag in tags {
        guard let data = CTFontCopyTable(font, CTFontTableTag(tag), CTFontTableOptions(rawValue: 0)) as Data? else { continue }
        tables.append((tag, [UInt8](data)))
    }
    let metaTag: UInt32 = 0x6D65_7461 // 'meta'
    if !tables.contains(where: { $0.tag == metaTag }) {
        // meta v1: header, then data maps for 'dlng' (design languages) and 'slng' (supported languages).
        let langs = Array("Latn".utf8)
        let maps: [UInt32] = [0x646C_6E67, 0x736C_6E67] // 'dlng', 'slng'
        var meta = be32(1) + be32(0) + be32(0) + be32(UInt32(maps.count))
        var dataOffset = UInt32(16 + 12 * maps.count)
        for tag in maps { meta += be32(tag) + be32(dataOffset) + be32(UInt32(langs.count)); dataOffset += UInt32(langs.count) }
        for _ in maps { meta += langs }
        tables.append((metaTag, meta))
    }
    tables.sort { $0.tag < $1.tag }

    // sfnt header + table directory, then 4-byte aligned tables.
    let n = UInt16(tables.count)
    var pow2: UInt16 = 1, log2: UInt16 = 0
    while pow2 * 2 <= n { pow2 *= 2; log2 += 1 }
    let isCFF = tables.contains { $0.tag == 0x4346_4620 } // 'CFF '
    var out: [UInt8] = be32(isCFF ? 0x4F54_544F : 0x0001_0000) + be16(n) + be16(pow2 * 16) + be16(log2) + be16(n * 16 - pow2 * 16)
    var offset = UInt32(12 + 16 * tables.count)
    var body: [UInt8] = []
    var headOffset: Int?
    for t in tables {
        if t.tag == 0x6865_6164 { headOffset = Int(offset) } // 'head'
        out += be32(t.tag) + be32(checksum(t.data)) + be32(offset) + be32(UInt32(t.data.count))
        body += t.data
        while body.count % 4 != 0 { body.append(0) }
        offset = UInt32(12 + 16 * tables.count + body.count)
    }
    out += body
    // head.checkSumAdjustment = 0xB1B0AFBA - checksum(whole font), with the field zeroed first.
    if let h = headOffset {
        for k in 8..<12 { out[h + k] = 0 }
        let adj = 0xB1B0_AFBA &- checksum(out)
        out.replaceSubrange((h + 8)..<(h + 12), with: be32(adj))
    }
    let dest = outDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".ttf")
    try Data(out).write(to: dest)
    print("wrote \(dest.lastPathComponent) (\(out.count / 1024) KB, \(tables.count) tables)")
}
