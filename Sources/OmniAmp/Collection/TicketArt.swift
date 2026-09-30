import AppKit
import CoreText

/// Concert tickets for shows without a cover: a printed ticket in one of six styles (letterpress, neon, editorial,
/// festival, holographic, brutalist), picked by the era of the show, with the artist, date, venue and city on it.
/// The seat, ticket number and barcode are made up from the album, so every ticket differs but never changes.
///
/// A ticket is drawn once, off the main thread, into a bitmap (CoreText and Core Graphics only), and kept in memory:
/// the grid only paints the image, so scrolling, hovering and selecting cost what a cover costs.

/// What a ticket says, worked out from the album.
struct TicketInfo: Sendable, Equatable {
    var artist: String
    var year: Int?, month: Int?, day: Int?
    /// 1 = Sunday; only for a real date.
    var weekday: Int?
    var venue: String?, city: String?
    var seed: UInt64

    init(_ a: LibraryAlbum) {
        self.init(key: a.key, artist: a.artist, title: a.title, showDate: a.showDate, year: a.year, venue: a.venue)
    }

    init(key: String, artist: String, title: String, showDate: String?, year: Int?, venue: String?) {
        self.artist = Self.display(artist)
        seed = Self.fnv(key)
        let parts = (showDate ?? "").split(separator: "-").map { Int($0) }
        self.year = parts.first.flatMap { $0 }.flatMap { (1000...2999).contains($0) ? $0 : nil } ?? year
        month = parts.count > 1 ? parts[1].flatMap { (1...12).contains($0) ? $0 : nil } : nil
        day = month != nil && parts.count > 2 ? parts[2].flatMap { (1...31).contains($0) ? $0 : nil } : nil
        if let y = self.year, let m = month, let d = day {
            let c = DateComponents(calendar: Self.calendar, year: y, month: m, day: d)
            if c.isValidDate, let date = c.date { weekday = Self.calendar.component(.weekday, from: date) } else { day = nil }
        }
        // The venue; else the title, unless it's only the date again ("94-02-27"). "Barton Hall, Ithaca, NY": the
        // city is the last part, with the one before it when that's a state or country code.
        let place = Self.place(venue ?? (title.contains { $0.isLetter } ? title : nil), artist: artist)
        var bits = (place ?? "").components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if bits.count > 1 {
            let code = bits.last!.count <= 3 && bits.last!.allSatisfy(\.isLetter)
            let n = code && bits.count > 2 ? 2 : 1
            city = Self.display(bits.suffix(n).joined(separator: ", "))
            bits.removeLast(n)
        }
        self.venue = bits.isEmpty ? nil : Self.display(bits.joined(separator: ", "))
    }

    /// A folder named "Cat Power Live 2003-02-12" gives the venue "Cat Power Live": the artist again and "live"
    /// aren't a place.
    static func place(_ s: String?, artist: String) -> String? {
        guard var s else { return nil }
        let junk = CharacterSet(charactersIn: " -–—_.,:@").union(.whitespaces)
        if !artist.isEmpty, let r = s.range(of: artist, options: [.caseInsensitive, .anchored]) {
            s = String(s[r.upperBound...]).trimmingCharacters(in: junk)
        }
        for prefix in ["live at ", "live in ", "live @ ", "live, ", "live - ", "live "] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: junk)
            break
        }
        if s.lowercased() == "live" { return nil }
        guard s.filter(\.isLetter).count >= 2 else { return nil }
        // What's left may start mid-sentence ("the Roxy"); all lower case is title-cased later (`display`).
        return s == s.lowercased() ? s : s.prefix(1).uppercased() + s.dropFirst()
    }

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Folder names are often all lower case ("café de la danse"); a ticket is printed in title case.
    private static func display(_ s: String) -> String { s == s.lowercased() ? s.capitalized : s }

    /// FNV-1a: the same every launch (unlike `hashValue`).
    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    /// A made-up number from the seed (splitmix64 of the seed and a salt).
    func number(_ salt: UInt64, _ range: ClosedRange<Int>) -> Int {
        var z = seed &+ salt &* 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        z ^= z >> 31
        return range.lowerBound + Int(z % UInt64(range.count))
    }

    var ticketNumber: String { String(format: "%05d", number(1, 0...99_999)) }
    var section: String { String(UnicodeScalar(UInt8(65 + number(2, 0...11)))) }
    var row: Int { number(3, 1...30) }
    var seat: Int { number(4, 1...40) }

    private static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    private static let days = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
    var monthName: String? { month.map { Self.months[$0 - 1] } }
    var weekdayName: String? { weekday.map { Self.days[$0 - 1] } }
    var weekdayShort: String? { weekdayName.map { String($0.prefix(3)) } }
    var dayText: String? { day.map { String(format: "%02d", $0) } }
    var yearText: String? { year.map(String.init) }
}

enum TicketStyle: CaseIterable, Sendable {
    case letterpress, neon, editorial, festival, holographic, brutalist

    /// By the era of the show, so a '77 show looks like 1977; the seed picks within the era, so neighbours differ.
    static func style(for t: TicketInfo) -> TicketStyle {
        let era: [TicketStyle]
        switch t.year ?? 0 {
        case 0: era = allCases
        case ..<1970: era = [.letterpress, .festival]
        case ..<1980: era = [.festival, .letterpress]
        case ..<1990: era = [.letterpress, .neon, .editorial]
        case ..<2000: era = [.brutalist, .editorial, .letterpress]
        case ..<2010: era = [.brutalist, .neon, .editorial]
        default: era = [.neon, .holographic, .brutalist, .editorial]
        }
        return era[t.number(5, 0...(era.count - 1))]
    }
}

// MARK: - Rendering

enum TicketArt {
    /// A square ticket, `side` points at `scale` pixels per point. Safe on any thread.
    static func render(_ t: TicketInfo, style: TicketStyle? = nil, side: CGFloat, scale: CGFloat) -> CGImage? {
        let px = Int((side * scale).rounded())
        guard px > 0, let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Points, y down (like the grid's flipped views); CoreText's glyphs flipped back upright.
        ctx.translateBy(x: 0, y: CGFloat(px))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.interpolationQuality = .high
        let pen = Pen(ctx: ctx, s: side, scale: scale)
        let style = style ?? TicketStyle.style(for: t)
        if side < 80 {
            mini(t, style, pen)
        } else {
            switch style {
            case .letterpress: letterpress(t, pen)
            case .neon: neon(t, pen)
            case .editorial: editorial(t, pen)
            case .festival: festival(t, pen)
            case .holographic: holographic(t, pen)
            case .brutalist: brutalist(t, pen)
            }
        }
        return ctx.makeImage()
    }

    /// The fine print (seat, ticket number, barcode digits) is only drawn where it can be read.
    private static func detailed(_ p: Pen) -> Bool { p.s >= 150 }

    // MARK: Letterpress

    /// A 1980s letterpress stub: cream stock, a magenta band, the artist in heavy condensed capitals between stars,
    /// a double rule, the big day with month and year, and a tear-off with ADMIT ONE and a barcode.
    private static func letterpress(_ t: TicketInfo, _ p: Pen) {
        let s = p.s, ink = Pen.rgb(0x1D1714), magenta = Pen.rgb(0xE8589A)
        let perf = (s * 0.77).rounded(), band = s * 0.05
        let shape = p.ticket(notches: [CGPoint(x: 0, y: perf), CGPoint(x: s, y: perf)], radius: s * 0.042)
        p.clip(shape)
        p.linear([Pen.rgb(0xFAF3E6), Pen.rgb(0xF0E3CC)], from: .zero, to: CGPoint(x: 0, y: s))
        p.ctx.setFillColor(magenta)
        p.ctx.fill(CGRect(x: 0, y: 0, width: band, height: s))
        if detailed(p) {
            let f = Face.mono.font(s * 0.03)
            let band = p.line("SEC \(t.section) · ROW \(t.row) · SEAT \(t.seat)", f, Pen.rgb(0xFFF4F8), kern: s * 0.006)
            p.rotated(band, center: CGPoint(x: s * 0.025, y: s / 2), font: f)
        }

        let x0 = band + s * 0.07, x1 = s - s * 0.07, w = x1 - x0
        // Header.
        let hf = Face.compressedBold.font(max(5.5, s * 0.048))
        let top = s * 0.075
        p.draw(p.line("LIVE IN CONCERT", hf, ink, kern: hf.size * 0.28), x: x0, baseline: top + CTFontGetCapHeight(hf), width: w, align: .center)

        // The date row, just above the tear-off.
        let dayFont = Face.compressedBlack.font(s * 0.165), dayCap = CTFontGetCapHeight(dayFont)
        let dateBase = perf - s * 0.06, dateTop = dateBase - dayCap
        let small = Face.compressedBold.font(max(6, s * 0.058)), smallCap = CTFontGetCapHeight(small)
        var x = x0
        let big = p.line(t.dayText ?? t.yearText ?? "LIVE", dayFont, ink)
        p.draw(big, x: x, baseline: dateBase)
        x += p.width(big) + s * 0.022
        // Month over year beside the day; without a day the year is the big number, the month beside it.
        let column: [String?] = t.day != nil ? [t.monthName, t.yearText] : [t.monthName, nil]
        var colWidth: CGFloat = 0
        if let m = column[0] {
            let l = p.line(m, small, ink, kern: small.size * 0.12)
            p.draw(l, x: x, baseline: dateTop + smallCap)
            colWidth = p.width(l)
        }
        if let y = column[1] {
            let l = p.line(y, small, ink, kern: small.size * 0.12)
            p.draw(l, x: x, baseline: dateBase)
            colWidth = max(colWidth, p.width(l))
        }
        if colWidth > 0 { x += colWidth + s * 0.035 }
        let right = [t.weekdayName, t.city].compactMap { $0 }
        if !right.isEmpty, x1 - x > s * 0.12 {
            p.ctx.setFillColor(ink)
            p.ctx.fill(CGRect(x: x, y: dateTop, width: max(1, s * 0.008), height: dayCap))
            x += s * 0.035
            let rf = Face.compressedSemibold.font(max(6, s * 0.058))
            p.draw(p.line(right[0].uppercased(), right.count > 1 ? small : rf, ink, kern: s * 0.003), x: x, baseline: dateTop + smallCap, width: x1 - x)
            if right.count > 1 { p.draw(p.line(right[1].uppercased(), rf, ink, kern: s * 0.003), x: x, baseline: dateBase, width: x1 - x) }
        }

        // Double rule, the venue over it, the artist in what's left.
        let ruleY = dateTop - s * 0.05
        p.ctx.setFillColor(ink)
        p.ctx.fill(CGRect(x: x0, y: ruleY, width: w, height: max(1, s * 0.011)))
        p.ctx.fill(CGRect(x: x0, y: ruleY + s * 0.019, width: w, height: max(0.5, s * 0.004)))
        var artistBottom = ruleY - s * 0.04
        if let venue = t.venue {
            let vf = Face.compressedBold.font(max(6, s * 0.06))
            p.draw(p.line(venue.uppercased(), vf, ink, kern: vf.size * 0.14), x: x0, baseline: artistBottom, width: w, align: .center)
            artistBottom -= CTFontGetCapHeight(vf) + s * 0.04
        }
        let artistTop = top + CTFontGetCapHeight(hf) + s * 0.045
        let star = Face.compressedBlack.font(s * 0.07), starW = p.width(p.line("★", star, ink)), starRoom = 2 * (starW + s * 0.03)
        var block = p.fit(t.artist.uppercased(), .compressedBlack, color: ink, width: w, height: artistBottom - artistTop,
                          maxSize: s * 0.2, minSize: 7, lines: 2)
        // Stars either side of a one-line name that leaves room for them.
        if block.lines.count == 1, block.width + starRoom > w {
            block = p.fit(t.artist.uppercased(), .compressedBlack, color: ink, width: w - starRoom, height: artistBottom - artistTop,
                          maxSize: s * 0.2, minSize: 7, lines: 2)
        }
        let blockTop = artistTop + (artistBottom - artistTop - block.height) / 2
        p.draw(block, x: x0, top: blockTop, width: w, align: .center)
        if block.lines.count == 1, block.width + starRoom <= w {
            let mid = blockTop + block.height / 2 + CTFontGetCapHeight(star) / 2
            let gap = (block.width / 2) + s * 0.03
            p.draw(p.line("★", star, ink), x: x0 + w / 2 - gap - starW, baseline: mid)
            p.draw(p.line("★", star, ink), x: x0 + w / 2 + gap, baseline: mid)
        }

        // The tear-off.
        p.dashed(from: CGPoint(x: band, y: perf), to: CGPoint(x: s, y: perf), color: Pen.rgb(0x7A6E60, 0.8), width: max(0.75, s * 0.005), dash: s * 0.012)
        let mid = (perf + s) / 2
        let af = Face.compressedBold.font(max(6, s * 0.058))
        let admit = p.line("ADMIT ONE", af, ink, kern: af.size * 0.3)
        if detailed(p) {
            p.draw(admit, x: x0, baseline: mid - s * 0.008)
            let nf = Face.mono.font(s * 0.036)
            p.draw(p.line("No. \(t.ticketNumber)", nf, ink), x: x0, baseline: mid + CTFontGetCapHeight(nf) + s * 0.022)
        } else {
            p.draw(admit, x: x0, baseline: mid + CTFontGetCapHeight(af) / 2)
        }
        let barW = s * 0.34, barH = s * 0.1
        p.barcode(t, in: CGRect(x: x1 - barW, y: mid - barH / 2, width: barW, height: barH), color: ink)
        p.unclip()
        p.edge(shape, color: Pen.rgb(0x000000, 0.2))
    }

    // MARK: Neon

    /// After hours: near-black with violet, pink and cyan glows and faint scanlines, the artist in a white-to-cyan
    /// gradient, the date in a glowing pill, and a stub with ADMIT ONE up a gradient pill (and a code over it).
    private static func neon(_ t: TicketInfo, _ p: Pen) {
        let s = p.s, sx = (s * 0.79).rounded()
        let shape = p.ticket(notches: [CGPoint(x: sx, y: 0), CGPoint(x: sx, y: s)], radius: s * 0.042)
        p.clip(shape)
        p.ctx.setFillColor(Pen.rgb(0x0E0B18))
        p.ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        p.glow(Pen.rgb(0x7A4DFF, 0.6), at: CGPoint(x: s * 0.08, y: s * 0.02), radius: s * 0.8)
        p.glow(Pen.rgb(0xFF3EA5, 0.4), at: CGPoint(x: s * 1.02, y: s * 0.18), radius: s * 0.5)
        p.glow(Pen.rgb(0x22D3EE, 0.42), at: CGPoint(x: s * 0.72, y: s * 1.05), radius: s * 0.72)
        // Scanlines, a device pixel high.
        let lines = CGMutablePath()
        for y in stride(from: 0, to: s, by: 2.5) { lines.addRect(CGRect(x: 0, y: y, width: s, height: 1 / p.scale)) }
        p.ctx.addPath(lines)
        p.ctx.setFillColor(Pen.rgb(0xFFFFFF, 0.045))
        p.ctx.fillPath()
        let inner = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.03, dy: s * 0.03),
                           cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil)
        p.ctx.addPath(inner)
        p.ctx.setStrokeColor(Pen.rgb(0xFFFFFF, 0.1))
        p.ctx.setLineWidth(0.75)
        p.ctx.strokePath()
        p.dashed(from: CGPoint(x: sx, y: s * 0.04), to: CGPoint(x: sx, y: s * 0.96), color: Pen.rgb(0xFFFFFF, 0.3), width: max(0.75, s * 0.005), dash: s * 0.014)

        let x0 = s * 0.085, x1 = sx - s * 0.05, w = x1 - x0
        let white = Pen.rgb(0xFFFFFF), pink = Pen.rgb(0xFF4FB0)
        // Header: a cyan dot and a spaced line.
        let hf = Face.semibold.font(max(5.5, s * 0.04)), top = s * 0.085, hCap = CTFontGetCapHeight(hf)
        let dot = s * 0.022
        p.ctx.setFillColor(Pen.rgb(0x22D3EE))
        p.ctx.fillEllipse(in: CGRect(x: x0, y: top + hCap / 2 - dot / 2, width: dot, height: dot))
        let header = p.first([("LIVE IN CONCERT", 0.3), ("LIVE IN CONCERT", 0.12), ("LIVE", 0.3)], hf, Pen.rgb(0xFFFFFF, 0.8), width: w - dot - s * 0.025)
        p.draw(header, x: x0 + dot + s * 0.025, baseline: top + hCap, width: w - dot - s * 0.025)

        // From the bottom: seats, the date pill, city and venue; the artist in what's left.
        var bottom = s - s * 0.085
        if detailed(p) {
            let f = Face.mono.font(s * 0.033)
            p.draw(p.line("SEC \(t.section) · ROW \(t.row) · SEAT \(t.seat)", f, Pen.rgb(0xFFFFFF, 0.45), kern: s * 0.004), x: x0, baseline: bottom, width: w)
            bottom -= CTFontGetCapHeight(f) + s * 0.05
        }
        let cf = Face.bold.font(max(5.5, s * 0.038))
        // The longest date that fits: "SUN · MAY 8 · 1977", "MAY 8 · 1977", "1977".
        let monthDay: String? = t.monthName.map { m in t.day.map { "\(m) \($0)" } ?? m }
        let options: [[String?]] = [[t.weekdayShort, monthDay, t.yearText], [monthDay, t.yearText], [t.yearText]]
        let chipPad = s * 0.035, chipH = s * 0.095
        var chip: CTLine?
        for o in options {
            let text = o.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            guard !text.isEmpty else { continue }
            let l = p.line(text, cf, white, kern: cf.size * 0.1)
            if p.width(l) + 2 * chipPad <= w { chip = l; break }
        }
        if let chip {
            let r = CGRect(x: x0, y: bottom - chipH, width: p.width(chip) + 2 * chipPad, height: chipH)
            let pill = CGPath(roundedRect: r, cornerWidth: chipH / 2, cornerHeight: chipH / 2, transform: nil)
            p.ctx.saveGState()
            p.ctx.setShadow(offset: .zero, blur: s * 0.04, color: Pen.rgb(0xFF3EA5, 0.8))
            p.ctx.addPath(pill)
            p.ctx.setFillColor(Pen.rgb(0x2A0F2A, 0.9))
            p.ctx.fillPath()
            p.ctx.restoreGState()
            p.ctx.addPath(pill)
            p.ctx.setStrokeColor(pink)
            p.ctx.setLineWidth(max(0.75, s * 0.006))
            p.ctx.strokePath()
            p.draw(chip, x: r.minX + chipPad, baseline: r.midY + CTFontGetCapHeight(cf) / 2)
            bottom = r.minY - s * 0.06
        }
        let place = [t.city, t.venue].compactMap { $0 }
        for (i, text) in place.enumerated() {
            let f = i == 0 && t.city != nil ? Face.regular.font(max(5.5, s * 0.045)) : Face.medium.font(max(6, s * 0.05))
            p.draw(p.line(text.uppercased(), f, Pen.rgb(0xFFFFFF, i == 0 && t.city != nil ? 0.66 : 0.9), kern: f.size * 0.06), x: x0, baseline: bottom, width: w)
            bottom -= CTFontGetCapHeight(f) + s * 0.035
        }
        let artistTop = top + hCap + s * 0.06, artistBottom = bottom - s * 0.01
        let block = p.fit(t.artist.uppercased(), .heavy, color: white, width: w, height: artistBottom - artistTop,
                          maxSize: s * 0.15, minSize: 7, lines: 3, kern: -0.01)
        p.draw(block, x: x0, top: artistTop, width: w, align: .left,
               gradient: [white, Pen.rgb(0xD2BFFF), Pen.rgb(0x7DF3FF)])

        // The stub: a made-up code (when there's room to read it) over ADMIT ONE up a gradient pill.
        let stubMid = (sx + s) / 2, stubW = s - sx
        var pillTop = s * 0.1
        if detailed(p) {
            let q = stubW * 0.62
            p.code(t, in: CGRect(x: stubMid - q / 2, y: s * 0.1, width: q, height: q))
            pillTop = s * 0.1 + q + s * 0.05
        }
        let af = Face.bold.font(max(5.5, s * 0.036))
        let admit = p.line("ADMIT ONE", af, Pen.rgb(0x120E1C), kern: af.size * 0.3)
        let pillW = max(s * 0.085, CTFontGetCapHeight(af) + s * 0.05)
        let pillH = min(s * 0.9 - pillTop, p.width(admit) + s * 0.08)
        let pillRect = CGRect(x: stubMid - pillW / 2, y: pillTop + (s * 0.9 - pillTop - pillH) / 2, width: pillW, height: pillH)
        p.ctx.saveGState()
        p.ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: pillW / 2, cornerHeight: pillW / 2, transform: nil))
        p.ctx.clip()
        p.linear([Pen.rgb(0x29D3F0), Pen.rgb(0xFF4FB0)], from: CGPoint(x: 0, y: pillRect.maxY), to: CGPoint(x: 0, y: pillRect.minY))
        p.ctx.restoreGState()
        p.rotated(admit, center: CGPoint(x: pillRect.midX, y: pillRect.midY), font: af)
        p.unclip()
        p.edge(shape, color: Pen.rgb(0xFFFFFF, 0.16))
    }

    // MARK: Editorial

    /// Editorial minimal: off-white stock, a red tab, the artist in Didot as written, a hairline over venue and
    /// city, and a stub with the big day in Didot.
    private static func editorial(_ t: TicketInfo, _ p: Pen) {
        let s = p.s, ink = Pen.rgb(0x12100E), grey = Pen.rgb(0x6A635C), label = Pen.rgb(0x8A827A)
        let sx = (s * 0.74).rounded()
        let shape = p.ticket(notches: [CGPoint(x: sx, y: 0), CGPoint(x: sx, y: s)], radius: s * 0.036)
        p.clip(shape)
        p.linear([Pen.rgb(0xFDFBF7), Pen.rgb(0xF5F1E9)], from: .zero, to: CGPoint(x: 0, y: s))
        p.ctx.setFillColor(Pen.rgb(0xF7F3EA))
        p.ctx.fill(CGRect(x: sx, y: 0, width: s - sx, height: s))
        p.ctx.setFillColor(Pen.rgb(0x12100E, 0.28))
        p.ctx.fill(CGRect(x: sx, y: 0, width: max(0.5, 1 / p.scale), height: s))
        let x0 = s * 0.085, x1 = sx - s * 0.06, w = x1 - x0
        p.ctx.setFillColor(Pen.rgb(0xC2402A))
        p.ctx.fill(CGRect(x: x0, y: 0, width: s * 0.1, height: max(2, s * 0.016)))

        let mf = Face.mono.font(max(5, s * 0.032)), top = s * 0.085
        p.draw(p.first([("ADMIT ONE", 0.22), ("ADMIT ONE", 0.08)], mf, ink, width: w), x: x0, baseline: top + CTFontGetCapHeight(mf), width: w)

        // Venue and city under a hairline at the bottom; the artist in the middle of what's left.
        let vf = Face.semibold.font(max(6, s * 0.046)), lf = Face.mono.font(max(4.5, s * 0.024))
        let labels = detailed(p)
        var bottom = s - s * 0.08
        let cols: [(String, String)] = [("VENUE", t.venue), ("CITY", t.city)].compactMap { k, v in v.map { (k, $0) } }
        if !cols.isEmpty {
            let colW = cols.count == 2 ? [w * 0.58, w * 0.42] : [w]
            var cx = x0
            for (i, (k, v)) in cols.enumerated() {
                p.draw(p.line(v, vf, ink), x: cx, baseline: bottom, width: colW[i] - s * 0.02)
                if labels { p.draw(p.line(k, lf, label, kern: lf.size * 0.22), x: cx, baseline: bottom - CTFontGetCapHeight(vf) - s * 0.03) }
                cx += colW[i]
            }
            bottom -= CTFontGetCapHeight(vf) + (labels ? CTFontGetCapHeight(lf) + s * 0.06 : s * 0.045)
        }
        p.ctx.setFillColor(Pen.rgb(0x12100E, 0.85))
        p.ctx.fill(CGRect(x: x0, y: bottom, width: w, height: max(0.5, 1 / p.scale)))

        let tf = Face.regular.font(max(5, s * 0.032))
        let tour = p.first([("LIVE IN CONCERT", 0.3), ("LIVE IN CONCERT", 0.1), ("LIVE", 0.3)], tf, grey, width: w)
        let tourGap = s * 0.05, boxTop = top + CTFontGetCapHeight(mf) + s * 0.06, boxBottom = bottom - s * 0.06
        let block = p.fit(t.artist, .didot, color: ink, width: w, height: boxBottom - boxTop - tourGap - CTFontGetCapHeight(tf),
                          maxSize: s * 0.16, minSize: 8, lines: 3, kern: -0.02)
        let used = block.height + tourGap + CTFontGetCapHeight(tf)
        let blockTop = boxTop + (boxBottom - boxTop - used) / 2
        p.draw(block, x: x0, top: blockTop, width: w, align: .left)
        p.draw(tour, x: x0, baseline: blockTop + used, width: w)

        // The stub: year, the big day (or month), the month, and the ticket number.
        let stubX = sx + s * 0.02, stubW = s - sx - s * 0.04
        let yf = Face.mono.font(max(5, s * 0.03))
        if let y = t.yearText { p.draw(p.line(y, yf, ink, kern: yf.size * 0.2), x: stubX, baseline: s * 0.1 + CTFontGetCapHeight(yf), width: stubW, align: .center) }
        let big = p.fit(t.dayText ?? t.monthName ?? "LIVE", .didot, color: ink, width: stubW, height: s * 0.16, maxSize: s * 0.17, minSize: 8, lines: 1, kern: -0.03)
        let bigTop = s * 0.5 - big.height / 2 - s * 0.03
        p.draw(big, x: stubX, top: bigTop, width: stubW, align: .center)
        if t.day != nil, let m = t.monthName {
            let f = Face.regular.font(max(5, s * 0.032))
            p.draw(p.line(m, f, ink, kern: f.size * 0.36), x: stubX, baseline: bigTop + big.height + s * 0.06 + CTFontGetCapHeight(f), width: stubW, align: .center)
        }
        if labels {
            let nf = Face.mono.font(s * 0.024)
            p.draw(p.line("No. \(t.ticketNumber)", nf, Pen.rgb(0x4B453F), kern: nf.size * 0.1), x: stubX, baseline: s - s * 0.08, width: stubW, align: .center)
        }
        p.unclip()
        p.edge(shape, color: Pen.rgb(0x000000, 0.18))
    }

    // MARK: Festival

    /// A 70s festival screen print: sunburst rays, an orange sun and a teal hill, wave bands along the bottom, the
    /// artist in a slab face with an offset shadow, and an orange stub with the big date and a barcode.
    private static func festival(_ t: TicketInfo, _ p: Pen) {
        let s = p.s, ink = Pen.rgb(0x2B1220), plum = Pen.rgb(0x3F1D3D), gold = Pen.rgb(0xE9A227)
        let sx = (s * 0.76).rounded()
        let shape = p.ticket(notches: [CGPoint(x: sx, y: 0), CGPoint(x: sx, y: s)], radius: s * 0.045)
        p.clip(shape)
        p.ctx.setFillColor(Pen.rgb(0xF4E2B8))
        p.ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        p.rays(from: CGPoint(x: s * 0.28, y: s * 1.2), color: Pen.rgb(0xE9A227, 0.45), wedge: 7)
        p.ctx.setFillColor(Pen.rgb(0xE4572E, 0.9))
        p.ctx.fillEllipse(in: CGRect(x: sx - s * 0.2, y: -s * 0.2, width: s * 0.4, height: s * 0.4))
        p.ctx.setFillColor(Pen.rgb(0x1F7A6C, 0.85))
        p.ctx.fillEllipse(in: CGRect(x: -s * 0.2, y: s * 0.8, width: s * 0.36, height: s * 0.36))
        p.waves([(Pen.rgb(0x1F7A6C), s * 0.83), (Pen.rgb(0xE4572E), s * 0.89), (plum, s * 0.945)], width: sx, amplitude: s * 0.02)

        let x0 = s * 0.08, x1 = sx - s * 0.045, w = x1 - x0, top = s * 0.075
        // ADMIT ONE on a plum pill.
        let bf = Face.heavy.font(max(5, s * 0.034))
        let badge = p.first([("ADMIT ONE", 0.1), ("ADMIT", 0.1)], bf, Pen.rgb(0xF7E4BC), width: w - s * 0.06)
        let bh = s * 0.075, bw = p.width(badge) + s * 0.06
        p.ctx.addPath(CGPath(roundedRect: CGRect(x: x0, y: top, width: bw, height: bh), cornerWidth: bh / 2, cornerHeight: bh / 2, transform: nil))
        p.ctx.setFillColor(plum)
        p.ctx.fillPath()
        p.draw(badge, x: x0 + s * 0.03, baseline: top + bh / 2 + CTFontGetCapHeight(bf) / 2)

        // From the waves up: the city, the venue, then the artist.
        var bottom = s * 0.77
        if let city = t.city {
            let f = Face.rockwell.font(max(6, s * 0.05))
            p.draw(p.line(city, f, ink), x: x0, baseline: bottom, width: w)
            bottom -= CTFontGetCapHeight(f) + s * 0.025
            if detailed(p) {
                let lf = Face.heavy.font(s * 0.024)
                p.draw(p.line("CITY", lf, Pen.rgb(0x7A4A2A), kern: lf.size * 0.14), x: x0, baseline: bottom)
                bottom -= CTFontGetCapHeight(lf) + s * 0.04
            }
        }
        if let venue = t.venue {
            let f = Face.heavy.font(max(5.5, s * 0.042))
            p.draw(p.line(venue.uppercased(), f, plum, kern: f.size * 0.04), x: x0, baseline: bottom, width: w)
            bottom -= CTFontGetCapHeight(f) + s * 0.04
        }
        let artistTop = top + bh + s * 0.045
        let block = p.fit(t.artist.uppercased(), .rockwell, color: ink, width: w - s * 0.012, height: bottom - artistTop,
                          maxSize: s * 0.15, minSize: 7, lines: 3)
        p.draw(block, x: x0, top: artistTop, width: w, align: .left, shadow: (CGSize(width: s * 0.011, height: s * 0.011), gold))

        // The stub.
        p.ctx.setFillColor(gold)
        p.ctx.fill(CGRect(x: sx, y: 0, width: s - sx, height: s))
        p.dashed(from: CGPoint(x: sx, y: 0), to: CGPoint(x: sx, y: s), color: Pen.rgb(0x2B1220, 0.45), width: max(1, s * 0.011), dash: s * 0.02)
        let stubX = sx + s * 0.025, stubW = s - sx - s * 0.05
        var y = s * 0.26
        if t.day != nil, let m = t.monthName {
            let f = Face.rockwell.font(max(5.5, s * 0.045))
            p.draw(p.line(m, f, ink, kern: f.size * 0.1), x: stubX, baseline: y, width: stubW, align: .center)
            y += s * 0.03
        }
        let big = p.fit(t.dayText.map { String(Int($0)!) } ?? t.yearText ?? "LIVE", .rockwell, color: ink, width: stubW, height: s * 0.13,
                        maxSize: s * 0.14, minSize: 7, lines: 1)
        p.draw(big, x: stubX, top: y, width: stubW, align: .center)
        y += big.height + s * 0.035
        if t.day != nil, let yr = t.yearText {
            let f = Face.heavy.font(max(5, s * 0.036))
            p.draw(p.line(yr, f, ink, kern: f.size * 0.2), x: stubX, baseline: y + CTFontGetCapHeight(f), width: stubW, align: .center)
        }
        if detailed(p) {
            let f = Face.heavy.font(s * 0.024)
            p.draw(p.line("GA · SEC \(t.section)", f, ink, kern: f.size * 0.08), x: stubX, baseline: s * 0.74, width: stubW, align: .center)
        }
        let barH = s * 0.075
        p.barcode(t, in: CGRect(x: stubX + stubW * 0.08, y: s * 0.92 - barH, width: stubW * 0.84, height: barH), color: ink)
        p.unclip()
        p.edge(shape, color: Pen.rgb(0x000000, 0.2))
    }

    // MARK: Holographic

    /// Holographic VIP: charcoal with a blurred iridescent foil and a diagonal sheen, a gold hairline frame, the
    /// artist in wide capitals in a gold-to-mint gradient, and a tear-off with a gold-framed code.
    private static func holographic(_ t: TicketInfo, _ p: Pen) {
        let s = p.s, cream = Pen.rgb(0xF7E6BB), goldLine = Pen.rgb(0xE8C77B, 0.6)
        let perf = (s * 0.76).rounded()
        let shape = p.ticket(notches: [CGPoint(x: 0, y: perf), CGPoint(x: s, y: perf)], radius: s * 0.048)
        p.clip(shape)
        p.foil(s)
        p.ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.035, dy: s * 0.035),
                             cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil))
        p.ctx.setStrokeColor(goldLine)
        p.ctx.setLineWidth(0.75)
        p.ctx.strokePath()
        p.dashed(from: CGPoint(x: s * 0.06, y: perf), to: CGPoint(x: s * 0.94, y: perf), color: Pen.rgb(0xE8C77B, 0.5), width: max(0.5, 1 / p.scale), dash: s * 0.012)

        let x0 = s * 0.095, x1 = s - s * 0.095, w = x1 - x0, top = s * 0.095
        // ADMIT ONE · VIP in a gold outline.
        let bf = Face.expandedHeavy.font(max(4.5, s * 0.026))
        let badge = p.first([("ADMIT ONE · VIP", 0.35), ("VIP", 0.35)], bf, cream, width: w - s * 0.05)
        let bh = s * 0.065, bw = p.width(badge) + s * 0.04
        let badgeRect = CGRect(x: x0, y: top, width: bw, height: bh)
        p.ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: s * 0.012, cornerHeight: s * 0.012, transform: nil))
        p.ctx.setStrokeColor(Pen.rgb(0xE8C77B, 0.75))
        p.ctx.setLineWidth(max(0.5, s * 0.004))
        p.ctx.strokePath()
        p.draw(badge, x: x0 + s * 0.02, baseline: badgeRect.midY + CTFontGetCapHeight(bf) / 2)

        // From the perforation up: date (and city), the venue, then the artist.
        var bottom = perf - s * 0.065
        let kf = Face.expandedHeavy.font(max(4.5, s * 0.022)), vf = Face.semibold.font(max(5.5, s * 0.04))
        let monthDay: String? = t.monthName.map { m in t.day.map { "\(m) \($0)" } ?? m }
        let date = [t.weekdayShort, monthDay, t.yearText].compactMap { $0 }.joined(separator: " · ")
        let cells: [(String, String)] = [("DATE", date), ("CITY", t.city ?? "")].filter { !$0.1.isEmpty }
        if !cells.isEmpty {
            let dateW = cells.count == 2 ? w * 0.56 : w
            var cx = x0
            for (i, (k, v)) in cells.enumerated() {
                let cw = i == 0 ? dateW : w - dateW
                p.draw(p.line(v, vf, Pen.rgb(0xF4F1FF)), x: cx, baseline: bottom, width: cw - s * 0.02)
                p.draw(p.line(k, kf, Pen.rgb(0xE8C77B, 0.85), kern: kf.size * 0.28), x: cx, baseline: bottom - CTFontGetCapHeight(vf) - s * 0.028)
                cx += cw
            }
            bottom -= CTFontGetCapHeight(vf) + CTFontGetCapHeight(kf) + s * 0.07
        }
        if let venue = t.venue {
            let f = Face.regular.font(max(5, s * 0.034))
            p.draw(p.line(venue.uppercased(), f, Pen.rgb(0xF4F1FF, 0.72), kern: f.size * 0.26), x: x0, baseline: bottom, width: w)
            bottom -= CTFontGetCapHeight(f) + s * 0.045
        }
        let artistTop = top + bh + s * 0.05
        let block = p.fit(t.artist.uppercased(), .expandedBlack, color: Pen.rgb(0xFFF8E6), width: w, height: bottom - artistTop,
                          maxSize: s * 0.13, minSize: 6.5, lines: 3, kern: -0.03)
        p.draw(block, x: x0, top: artistTop, width: w, align: .left,
               gradient: [Pen.rgb(0xFFF8E6), Pen.rgb(0xE8C77B), Pen.rgb(0xFFFFFF), Pen.rgb(0xB9A7FF), Pen.rgb(0x6FE7DD)])

        // The tear-off: ADMIT ONE and the ticket id, a gold-framed code on the right.
        let mid = (perf + s) / 2, q = (s - perf) * 0.62
        let qr = CGRect(x: x1 - q, y: mid - q / 2, width: q, height: q)
        p.ctx.saveGState()
        p.ctx.addPath(CGPath(roundedRect: qr, cornerWidth: q * 0.14, cornerHeight: q * 0.14, transform: nil))
        p.ctx.clip()
        p.linear([Pen.rgb(0xFFF8E6), Pen.rgb(0xE8C77B), Pen.rgb(0xB9A7FF)], from: qr.origin, to: CGPoint(x: qr.maxX, y: qr.maxY))
        p.ctx.restoreGState()
        p.code(t, in: qr.insetBy(dx: q * 0.07, dy: q * 0.07))
        let af = Face.expandedHeavy.font(max(4.5, s * 0.028))
        let admit = p.first([("ADMIT ONE", 0.38), ("ADMIT ONE", 0.15)], af, cream, width: qr.minX - x0 - s * 0.03)
        if detailed(p) {
            p.draw(admit, x: x0, baseline: mid - s * 0.01, width: qr.minX - x0 - s * 0.03)
            let nf = Face.mono.font(s * 0.026)
            p.draw(p.line("ID \(t.ticketNumber)", nf, Pen.rgb(0xF4F1FF, 0.7), kern: nf.size * 0.22), x: x0, baseline: mid + CTFontGetCapHeight(nf) + s * 0.025)
        } else {
            p.draw(admit, x: x0, baseline: mid + CTFontGetCapHeight(af) / 2, width: qr.minX - x0 - s * 0.03)
        }
        p.unclip()
        p.edge(shape, color: Pen.rgb(0xE8C77B, 0.35))
    }

    // MARK: Brutalist

    /// Acid brutalist: grid paper, a black bar and an acid-green edge, the artist in heavy grotesque capitals (the
    /// last line on a blue block), a strip of boxed date cells, and a grey stub with the big day and a barcode.
    private static func brutalist(_ t: TicketInfo, _ p: Pen) {
        let s = p.s, ink = Pen.rgb(0x0C0C0C), acid = Pen.rgb(0xCCFF00), blue = Pen.rgb(0x2B3CF0), paper = Pen.rgb(0xF3F3EE)
        let sx = (s * 0.75).rounded()
        let shape = p.ticket(notches: [CGPoint(x: sx, y: 0), CGPoint(x: sx, y: s)], radius: s * 0.034)
        p.clip(shape)
        p.ctx.setFillColor(paper)
        p.ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        let grid = CGMutablePath(), step = s / 11.5
        for i in stride(from: step, to: s, by: step) {
            grid.addRect(CGRect(x: i, y: 0, width: 1 / p.scale, height: s))
            grid.addRect(CGRect(x: 0, y: i, width: s, height: 1 / p.scale))
        }
        p.ctx.addPath(grid)
        p.ctx.setFillColor(Pen.rgb(0x0C0C0C, 0.07))
        p.ctx.fillPath()
        p.ctx.setFillColor(Pen.rgb(0xE7E7E0))
        p.ctx.fill(CGRect(x: sx, y: 0, width: s - sx, height: s))
        p.ctx.setFillColor(ink)
        p.ctx.fill(CGRect(x: 0, y: 0, width: s * 0.045, height: s))
        p.ctx.setFillColor(acid)
        p.ctx.fill(CGRect(x: s - s * 0.025, y: 0, width: s * 0.025, height: s))
        p.dashed(from: CGPoint(x: sx, y: 0), to: CGPoint(x: sx, y: s), color: ink, width: max(1, s * 0.011), dash: s * 0.018)

        let x0 = s * 0.045 + s * 0.06, x1 = sx - s * 0.05, w = x1 - x0, top = s * 0.075
        // ADMIT ONE on a black tag.
        let tf = Face.monoBold.font(max(5, s * 0.03))
        let tag = p.first([("ADMIT ONE", 0.2), ("ADMIT", 0.2)], tf, acid, width: w - s * 0.04)
        let th = s * 0.068
        p.ctx.setFillColor(ink)
        p.ctx.fill(CGRect(x: x0, y: top, width: p.width(tag) + s * 0.04, height: th))
        p.draw(tag, x: x0 + s * 0.02, baseline: top + th / 2 + CTFontGetCapHeight(tf) / 2)

        // From the bottom: venue and city, the boxed date strip, then the artist.
        var bottom = s - s * 0.075
        let vf = Face.black.font(max(6, s * 0.044)), lf = Face.mono.font(max(4.5, s * 0.023))
        let cols: [(String, String)] = [("VENUE", t.venue), ("CITY", t.city)].compactMap { k, v in v.map { (k, $0) } }
        if !cols.isEmpty {
            let colW = cols.count == 2 ? [w * 0.55, w * 0.45] : [w]
            var cx = x0
            for (i, (k, v)) in cols.enumerated() {
                p.draw(p.line(v, vf, ink), x: cx, baseline: bottom, width: colW[i] - s * 0.02)
                if detailed(p) { p.draw(p.line(k, lf, Pen.rgb(0x5A5A56), kern: lf.size * 0.2), x: cx, baseline: bottom - CTFontGetCapHeight(vf) - s * 0.028) }
                cx += colW[i]
            }
            bottom -= CTFontGetCapHeight(vf) + (detailed(p) ? CTFontGetCapHeight(lf) + s * 0.07 : s * 0.05)
        }
        let cf = Face.mono.font(max(5, s * 0.032)), cfb = Face.monoBold.font(max(5, s * 0.032))
        let monthDay: String? = t.monthName.map { m in t.dayText.map { "\(m) \($0)" } ?? m }
        let options: [[(String, CGColor, CGColor, CTFont)]] = [
            [(t.weekdayShort, acid, ink, cfb), (monthDay, paper, ink, cf), (t.yearText, blue, paper, cf)],
            [(monthDay, paper, ink, cf), (t.yearText, blue, paper, cf)],
            [(t.yearText, blue, paper, cf)],
        ].map { $0.compactMap { text, bg, fg, f in text.map { ($0, bg, fg, f) } } }
        let border = max(1, s * 0.011), ch = s * 0.08, pad = s * 0.022
        for cells in options where !cells.isEmpty {
            let lines = cells.map { p.line($0.0, $0.3, $0.2, kern: $0.3.size * 0.12) }
            let total = lines.reduce(0) { $0 + p.width($1) + 2 * pad } + border * CGFloat(cells.count + 1)
            guard total <= w else { continue }
            var cx = x0 + border
            let y = bottom - ch
            p.ctx.setFillColor(ink)
            p.ctx.fill(CGRect(x: x0, y: y - border, width: total, height: ch + 2 * border))
            for (i, l) in lines.enumerated() {
                let cw = p.width(l) + 2 * pad
                p.ctx.setFillColor(cells[i].1)
                p.ctx.fill(CGRect(x: cx, y: y, width: cw, height: ch))
                p.draw(l, x: cx + pad, baseline: y + ch / 2 + CTFontGetCapHeight(cells[i].3) / 2)
                cx += cw + border
            }
            bottom = y - border - s * 0.05
            break
        }
        let artistTop = top + th + s * 0.05
        let block = p.fit(t.artist.uppercased(), .black, color: ink, width: w, height: bottom - artistTop,
                          maxSize: s * 0.15, minSize: 7, lines: 3, kern: -0.04)
        // The last of several lines on a blue block, in paper color.
        if block.lines.count > 1, let last = block.lines.last {
            let origins = p.origins(block, x: x0, top: artistTop, width: w, align: .left)
            let o = origins.last!, lw = p.width(last) - CGFloat(CTLineGetTrailingWhitespaceWidth(last))
            p.ctx.setFillColor(blue)
            p.ctx.fill(CGRect(x: o.x - s * 0.012, y: o.y - block.cap - s * 0.012, width: lw + s * 0.024, height: block.cap + s * 0.024))
            var rest = block
            rest.lines.removeLast()
            p.draw(rest, x: x0, top: artistTop, width: w, align: .left)
            p.fill(last, at: o, color: paper)
        } else {
            p.draw(block, x: x0, top: artistTop, width: w, align: .left)
        }
        if detailed(p) {
            // A registration cross, level with the tag.
            let c = CGPoint(x: x1 - s * 0.022, y: top + th / 2), a = s * 0.022, lw = max(1, s * 0.006)
            p.ctx.setFillColor(ink)
            p.ctx.fill(CGRect(x: c.x - a, y: c.y - lw / 2, width: 2 * a, height: lw))
            p.ctx.fill(CGRect(x: c.x - lw / 2, y: c.y - a, width: lw, height: 2 * a))
        }

        // The stub: ADMIT on black, the weekday, the big day, month and year, a barcode.
        let stubX = sx + s * 0.022, stubW = s - s * 0.025 - sx - s * 0.044
        let af = Face.black.font(max(5, s * 0.03))
        let admit = p.first([("ADMIT", 0.06)], af, acid, width: stubW)
        let ah = s * 0.06, aw = min(stubW, p.width(admit) + s * 0.03)
        p.ctx.setFillColor(ink)
        p.ctx.fill(CGRect(x: stubX + (stubW - aw) / 2, y: top, width: aw, height: ah))
        p.draw(admit, x: stubX, baseline: top + ah / 2 + CTFontGetCapHeight(af) / 2, width: stubW, align: .center)
        let mf = Face.mono.font(max(5, s * 0.028))
        var y = s * 0.33
        if let d = t.weekdayShort {
            p.draw(p.line(d, mf, ink, kern: mf.size * 0.2), x: stubX, baseline: y, width: stubW, align: .center)
            y += s * 0.03
        }
        let big = p.fit(t.dayText ?? t.yearText ?? "LIVE", .black, color: ink, width: stubW, height: s * 0.12, maxSize: s * 0.13, minSize: 7, lines: 1, kern: -0.02)
        p.draw(big, x: stubX, top: y, width: stubW, align: .center)
        y += big.height + s * 0.035
        for line in (t.day != nil ? [t.monthName, t.yearText] : [t.monthName]).compactMap({ $0 }) {
            p.draw(p.line(line, mf, ink, kern: mf.size * 0.26), x: stubX, baseline: y + CTFontGetCapHeight(mf), width: stubW, align: .center)
            y += CTFontGetCapHeight(mf) + s * 0.022
        }
        let barH = s * 0.075
        p.barcode(t, in: CGRect(x: stubX, y: s * 0.925 - barH, width: stubW, height: barH), color: ink)
        p.unclip()
        p.edge(shape, color: Pen.rgb(0x000000, 0.25))
    }

    // MARK: Small

    /// Thumbnails (the lists' 40-point covers): the style's stock, stub and notches, and the year big ("’77").
    private static func mini(_ t: TicketInfo, _ style: TicketStyle, _ p: Pen) {
        let s = p.s
        let year = t.year.map { String(format: "’%02d", $0 % 100) } ?? "LIVE"
        // Where the tear-off is: along the bottom, or down the right.
        let bottomStub = style == .letterpress || style == .holographic
        let cut = (s * (bottomStub ? 0.74 : 0.74)).rounded()
        let notches = bottomStub ? [CGPoint(x: 0, y: cut), CGPoint(x: s, y: cut)] : [CGPoint(x: cut, y: 0), CGPoint(x: cut, y: s)]
        let shape = p.ticket(notches: notches, radius: s * 0.07)
        p.clip(shape)
        var main = bottomStub ? CGRect(x: 0, y: 0, width: s, height: cut) : CGRect(x: 0, y: 0, width: cut, height: s)
        let stub = bottomStub ? CGRect(x: 0, y: cut, width: s, height: s - cut) : CGRect(x: cut, y: 0, width: s - cut, height: s)
        var face = Face.compressedBlack, ink = Pen.rgb(0x1D1714), gradient: [CGColor]?, shadow: (CGSize, CGColor)?
        var perf = Pen.rgb(0x7A6E60, 0.8)
        switch style {
        case .letterpress:
            p.linear([Pen.rgb(0xFAF3E6), Pen.rgb(0xF0E3CC)], from: .zero, to: CGPoint(x: 0, y: s))
            p.ctx.setFillColor(Pen.rgb(0xE8589A))
            p.ctx.fill(CGRect(x: 0, y: 0, width: s * 0.09, height: s))
            main.origin.x = s * 0.09
            main.size.width -= s * 0.09
        case .neon:
            p.ctx.setFillColor(Pen.rgb(0x0E0B18))
            p.ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            p.glow(Pen.rgb(0x7A4DFF, 0.7), at: CGPoint(x: s * 0.1, y: 0), radius: s * 0.9)
            p.glow(Pen.rgb(0x22D3EE, 0.5), at: CGPoint(x: s * 0.7, y: s * 1.05), radius: s * 0.75)
            p.ctx.saveGState()
            p.ctx.addPath(CGPath(roundedRect: stub.insetBy(dx: stub.width * 0.3, dy: s * 0.18), cornerWidth: stub.width * 0.2, cornerHeight: stub.width * 0.2, transform: nil))
            p.ctx.clip()
            p.linear([Pen.rgb(0x29D3F0), Pen.rgb(0xFF4FB0)], from: CGPoint(x: 0, y: s), to: .zero)
            p.ctx.restoreGState()
            face = .heavy
            ink = Pen.rgb(0xFFFFFF)
            gradient = [Pen.rgb(0xFFFFFF), Pen.rgb(0xD2BFFF), Pen.rgb(0x7DF3FF)]
            perf = Pen.rgb(0xFFFFFF, 0.3)
        case .editorial:
            p.linear([Pen.rgb(0xFDFBF7), Pen.rgb(0xF5F1E9)], from: .zero, to: CGPoint(x: 0, y: s))
            p.ctx.setFillColor(Pen.rgb(0xEFE9DD))
            p.ctx.fill(stub)
            p.ctx.setFillColor(Pen.rgb(0xC2402A))
            p.ctx.fill(CGRect(x: s * 0.1, y: 0, width: s * 0.18, height: max(1.5, s * 0.04)))
            face = .didot
            ink = Pen.rgb(0x12100E)
            perf = Pen.rgb(0x12100E, 0.3)
        case .festival:
            p.ctx.setFillColor(Pen.rgb(0xF4E2B8))
            p.ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            p.rays(from: CGPoint(x: s * 0.3, y: s * 1.2), color: Pen.rgb(0xE9A227, 0.45), wedge: 9)
            p.waves([(Pen.rgb(0x1F7A6C), s * 0.8), (Pen.rgb(0xE4572E), s * 0.88), (Pen.rgb(0x3F1D3D), s * 0.95)], width: cut, amplitude: s * 0.03)
            p.ctx.setFillColor(Pen.rgb(0xE9A227))
            p.ctx.fill(stub)
            face = .rockwell
            ink = Pen.rgb(0x2B1220)
            shadow = (CGSize(width: s * 0.025, height: s * 0.025), Pen.rgb(0xE9A227))
            perf = Pen.rgb(0x2B1220, 0.45)
            main.size.height = s * 0.8
        case .holographic:
            p.foil(s)
            face = .expandedBlack
            ink = Pen.rgb(0xFFF8E6)
            gradient = [Pen.rgb(0xFFF8E6), Pen.rgb(0xE8C77B), Pen.rgb(0xB9A7FF), Pen.rgb(0x6FE7DD)]
            perf = Pen.rgb(0xE8C77B, 0.5)
        case .brutalist:
            p.ctx.setFillColor(Pen.rgb(0xF3F3EE))
            p.ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            p.ctx.setFillColor(Pen.rgb(0xE7E7E0))
            p.ctx.fill(stub)
            p.ctx.setFillColor(Pen.rgb(0x0C0C0C))
            p.ctx.fill(CGRect(x: 0, y: 0, width: s * 0.08, height: s))
            p.ctx.setFillColor(Pen.rgb(0xCCFF00))
            p.ctx.fill(CGRect(x: s - s * 0.05, y: 0, width: s * 0.05, height: s))
            main.origin.x = s * 0.08
            main.size.width -= s * 0.08
            face = .black
            ink = Pen.rgb(0x0C0C0C)
            perf = Pen.rgb(0x0C0C0C)
        }
        let a = bottomStub ? CGPoint(x: main.minX, y: cut) : CGPoint(x: cut, y: 0)
        let b = bottomStub ? CGPoint(x: s, y: cut) : CGPoint(x: cut, y: s)
        p.dashed(from: a, to: b, color: perf, width: max(0.5, s * 0.02), dash: s * 0.05)
        let box = main.insetBy(dx: main.width * 0.1, dy: main.height * 0.14)
        let block = p.fit(year, face, color: ink, width: box.width, height: box.height, maxSize: s * 0.5, minSize: 6, lines: 1)
        p.draw(block, x: box.minX, top: box.midY - block.height / 2, width: box.width, align: .center, gradient: gradient, shadow: shadow)
        p.unclip()
        p.edge(shape, color: style == .neon || style == .holographic ? Pen.rgb(0xFFFFFF, 0.2) : Pen.rgb(0x000000, 0.22))
    }
}

// MARK: - Drawing helpers

/// The ticket faces: macOS's own fonts (nothing bundled), created as CoreText fonts so they work off the main thread.
enum Face {
    case compressedBlack, compressedBold, compressedSemibold, black, heavy, bold, semibold, medium, regular, mono, monoBold
    case expandedBlack, expandedHeavy, didot, rockwell

    func font(_ size: CGFloat) -> CTFont {
        let f: NSFont = switch self {
        case .compressedBlack: .systemFont(ofSize: size, weight: .black, width: .compressed)
        case .compressedBold: .systemFont(ofSize: size, weight: .bold, width: .compressed)
        case .compressedSemibold: .systemFont(ofSize: size, weight: .semibold, width: .compressed)
        case .heavy: .systemFont(ofSize: size, weight: .heavy)
        case .bold: .systemFont(ofSize: size, weight: .bold)
        case .semibold: .systemFont(ofSize: size, weight: .semibold)
        case .medium: .systemFont(ofSize: size, weight: .medium)
        case .regular: .systemFont(ofSize: size, weight: .regular)
        case .mono: .monospacedSystemFont(ofSize: size, weight: .medium)
        case .monoBold: .monospacedSystemFont(ofSize: size, weight: .bold)
        case .black: .systemFont(ofSize: size, weight: .black)
        case .expandedBlack: .systemFont(ofSize: size, weight: .black, width: .expanded)
        case .expandedHeavy: .systemFont(ofSize: size, weight: .heavy, width: .expanded)
        // Both ship with macOS (/System/Library/Fonts/Supplemental); a system face if they ever don't.
        case .didot: NSFont(name: "Didot", size: size) ?? .systemFont(ofSize: size, weight: .regular)
        case .rockwell: NSFont(name: "Rockwell-Bold", size: size) ?? .systemFont(ofSize: size, weight: .heavy)
        }
        return f as CTFont
    }
}

private extension CTFont {
    var size: CGFloat { CTFontGetSize(self) }
}

/// A bitmap being drawn in points, y down, with the ticket's side `s`.
struct Pen {
    let ctx: CGContext
    let s: CGFloat
    let scale: CGFloat

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    // Shape

    struct Shape { let body: CGPath; let holes: [CGRect] }

    /// The ticket: a rounded square with half-circle notches punched where the perforation meets the edge.
    func ticket(notches: [CGPoint], radius: CGFloat) -> Shape {
        let r = CGRect(x: 0, y: 0, width: s, height: s)
        return Shape(body: CGPath(roundedRect: r, cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil),
                     holes: notches.map { CGRect(x: $0.x - radius, y: $0.y - radius, width: 2 * radius, height: 2 * radius) })
    }

    /// Everything after this is inside the ticket, the notches left transparent.
    func clip(_ shape: Shape) {
        ctx.saveGState()
        ctx.addPath(shape.body)
        ctx.clip()
        let outside = CGMutablePath()
        outside.addRect(CGRect(x: -1, y: -1, width: s + 2, height: s + 2))
        for h in shape.holes { outside.addEllipse(in: h) }
        ctx.addPath(outside)
        ctx.clip(using: .evenOdd)
    }

    func unclip() { ctx.restoreGState() }

    /// The ticket's outline, around the notches too.
    func edge(_ shape: Shape, color: CGColor) {
        let lw = max(1 / scale, 0.5)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lw)
        ctx.saveGState()
        let outside = CGMutablePath()
        outside.addRect(CGRect(x: -1, y: -1, width: s + 2, height: s + 2))
        for h in shape.holes { outside.addEllipse(in: h) }
        ctx.addPath(outside)
        ctx.clip(using: .evenOdd)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: lw / 2, dy: lw / 2),
                           cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape.body)
        ctx.clip()
        for h in shape.holes { ctx.strokeEllipse(in: h.insetBy(dx: -lw / 2, dy: -lw / 2)) }
        ctx.restoreGState()
    }

    // Paint

    func linear(_ colors: [CGColor], from a: CGPoint, to b: CGPoint) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil) else { return }
        ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    func glow(_ color: CGColor, at c: CGPoint, radius: CGFloat) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [color, color.copy(alpha: 0)!] as CFArray, locations: nil) else { return }
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
    }

    /// Sunburst: every other `wedge` degrees filled, from a point (usually below the ticket).
    func rays(from c: CGPoint, color: CGColor, wedge: CGFloat) {
        let path = CGMutablePath(), r = s * 3
        var a: CGFloat = 0
        while a < 360 {
            let a0 = a * .pi / 180, a1 = (a + wedge) * .pi / 180
            path.move(to: c)
            path.addLine(to: CGPoint(x: c.x + r * cos(a0), y: c.y + r * sin(a0)))
            path.addLine(to: CGPoint(x: c.x + r * cos(a1), y: c.y + r * sin(a1)))
            path.closeSubpath()
            a += 2 * wedge
        }
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    /// Bands of rolling hills to the bottom, each from its height, back to front.
    func waves(_ bands: [(CGColor, CGFloat)], width: CGFloat, amplitude: CGFloat) {
        for (i, (color, y)) in bands.enumerated() {
            let path = CGMutablePath(), phase = CGFloat(i) * 1.7
            path.move(to: CGPoint(x: 0, y: s))
            for x in stride(from: 0, through: width, by: max(1, width / 40)) {
                path.addLine(to: CGPoint(x: x, y: y + amplitude * sin(x / width * 2.2 * .pi + phase)))
            }
            path.addLine(to: CGPoint(x: width, y: s))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(color)
            ctx.fillPath()
        }
    }

    /// Holographic foil: soft iridescent glows under a dark glaze, and a diagonal sheen.
    func foil(_ s: CGFloat) {
        ctx.setFillColor(Self.rgb(0x0D0B12))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        glow(Self.rgb(0xB9A7FF, 0.55), at: CGPoint(x: s * 0.15, y: s * 0.2), radius: s * 0.7)
        glow(Self.rgb(0x6FE7DD, 0.4), at: CGPoint(x: s * 0.8, y: s * 0.3), radius: s * 0.55)
        glow(Self.rgb(0xFFB6E1, 0.35), at: CGPoint(x: s * 0.35, y: s * 0.9), radius: s * 0.6)
        glow(Self.rgb(0xFFD79A, 0.3), at: CGPoint(x: s * 0.95, y: s * 0.95), radius: s * 0.5)
        linear([Self.rgb(0x0C0A12, 0.62), Self.rgb(0x0C0A12, 0.85)], from: .zero, to: CGPoint(x: s * 0.5, y: s))
        let clear = Self.rgb(0xFFFFFF, 0)
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [clear, Self.rgb(0xFFFFFF, 0.2), clear, Self.rgb(0xFFFFFF, 0.12), clear] as CFArray,
                                 locations: [0.18, 0.34, 0.46, 0.62, 0.74]) else { return }
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: s, y: s * 0.7), options: [])
    }

    func dashed(from a: CGPoint, to b: CGPoint, color: CGColor, width: CGFloat, dash: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineDash(phase: 0, lengths: [dash, dash])
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Bars that look like a Code 128, made up from the seed: guard bars, then bars and gaps one to three wide.
    func barcode(_ t: TicketInfo, in r: CGRect, color: CGColor) {
        var widths = [2, 1, 1, 1]
        var i: UInt64 = 10
        while widths.reduce(0, +) < 70 { widths.append(t.number(i, 1...3)); i += 1 }
        widths += [1, 1, 2]
        if widths.count % 2 == 0 { widths.append(1) }   // ends on a bar
        let unit = r.width / CGFloat(widths.reduce(0, +))
        var x = r.minX
        ctx.setFillColor(color)
        for (n, w) in widths.enumerated() {
            let bw = CGFloat(w) * unit
            if n % 2 == 0 { ctx.fill(CGRect(x: x, y: r.minY, width: bw, height: r.height)) }
            x += bw
        }
    }

    /// Something that looks like a QR code: three finder squares and modules from the seed, on a white card.
    func code(_ t: TicketInfo, in r: CGRect) {
        ctx.setFillColor(Self.rgb(0xFFFFFF))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.width * 0.12, cornerHeight: r.width * 0.12, transform: nil))
        ctx.fillPath()
        let n = 13, inner = r.insetBy(dx: r.width * 0.1, dy: r.width * 0.1), m = inner.width / CGFloat(n)
        ctx.setFillColor(Self.rgb(0x120E1C))
        for y in 0..<n {
            for x in 0..<n {
                // Distance into a finder corner (5 modules and a blank one), -1 outside; no finder bottom right.
                let fx = x < 6 ? x : x > n - 7 ? n - 1 - x : -1
                let fy = y < 6 ? y : y > n - 7 ? n - 1 - y : -1
                let on: Bool
                if fx >= 0, fy >= 0, !(x > n - 7 && y > n - 7) {
                    on = fx < 5 && fy < 5 && max(abs(fx - 2), abs(fy - 2)) != 1   // a ring around a dot
                } else {
                    on = t.number(UInt64(100 + y * n + x), 0...1) == 1
                }
                if on { ctx.fill(CGRect(x: inner.minX + CGFloat(x) * m, y: inner.minY + CGFloat(y) * m, width: m, height: m)) }
            }
        }
    }

    // Text

    func line(_ s: String, _ font: CTFont, _ color: CGColor, kern: CGFloat = 0) -> CTLine {
        let a = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
        ])
        return CTLineCreateWithAttributedString(a)
    }

    func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

    /// The first of these (text, kerning in ems) that fits `width`; else the last, to be cut short.
    func first(_ options: [(String, CGFloat)], _ font: CTFont, _ color: CGColor, width w: CGFloat) -> CTLine {
        var l = line("", font, color)
        for (text, kern) in options {
            l = line(text, font, color, kern: CTFontGetSize(font) * kern)
            if width(l) <= w { break }
        }
        return l
    }

    enum Align { case left, center, right }

    /// A line on a baseline; cut short with "…" when wider than `width`.
    func draw(_ l: CTLine, x: CGFloat, baseline: CGFloat, width: CGFloat? = nil, align: Align = .left) {
        var l = l
        if let width, self.width(l) > width, let cut = truncated(l, width) { l = cut }
        let lw = self.width(l)
        let dx: CGFloat = switch align {
        case .left: 0
        case .center: ((width ?? lw) - lw) / 2
        case .right: (width ?? lw) - lw
        }
        ctx.textPosition = CGPoint(x: x + dx, y: baseline)
        CTLineDraw(l, ctx)
    }

    private func truncated(_ l: CTLine, _ width: CGFloat) -> CTLine? {
        let runs = CTLineGetGlyphRuns(l) as! [CTRun]
        guard let first = runs.first else { return nil }
        let attrs = CTRunGetAttributes(first) as NSDictionary as! [NSAttributedString.Key: Any]
        let dots = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
        return CTLineCreateTruncatedLine(l, Double(width), .end, dots)
    }

    /// Up the stub: a line turned a quarter left, centered on `center`.
    func rotated(_ l: CTLine, center: CGPoint, font: CTFont) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: -.pi / 2)
        draw(l, x: -width(l) / 2, baseline: CTFontGetCapHeight(font) / 2)
        ctx.restoreGState()
    }

    /// Capitals set to fill a box: lines, the size they're set at, and how much of the box they take.
    struct Block {
        var lines: [CTLine] = []
        var cap: CGFloat = 0, gap: CGFloat = 0, width: CGFloat = 0
        var height: CGFloat { lines.isEmpty ? 0 : CGFloat(lines.count) * cap + CGFloat(lines.count - 1) * gap }
    }

    /// The largest size (up to `maxSize`) at which `text` fits `width` × `height` in at most `lines` lines, a word
    /// never split unless it can't fit alone; below `minSize` the last line is cut short. Measured once and scaled
    /// (a line's width grows with its size), so there's no open-ended loop.
    func fit(_ text: String, _ face: Face, color: CGColor, width: CGFloat, height: CGFloat, maxSize: CGFloat, minSize: CGFloat,
             lines most: Int, kern: CGFloat = 0) -> Block {
        guard !text.isEmpty, width > 0 else { return Block() }
        // Measured at the largest size: the system font's letters change shape with the size (optical sizes), so
        // this is close, and the typesetting below checks it.
        let ref = face.font(maxSize), capRatio = CTFontGetCapHeight(ref) / maxSize, gapRatio: CGFloat = 0.2
        let whole = self.width(line(text, ref, color, kern: kern * maxSize)) / maxSize
        let longest = text.split(separator: " ").map { self.width(line(String($0), ref, color, kern: kern * maxSize)) / maxSize }.max() ?? whole
        var best: (size: CGFloat, n: Int) = (0, 1)
        for n in 1...max(1, most) {
            let tall = height / (CGFloat(n) * capRatio + CGFloat(n - 1) * gapRatio)
            // Several lines are never filled evenly: leave some slack.
            let wide = n == 1 ? width / whole : min(width * CGFloat(n) * 0.84 / whole, width / longest)
            let size = min(maxSize, tall, wide)
            // One more line only for a clearly bigger name.
            if size > best.size * 1.12 { best = (size, n) }
        }
        var size = max(minSize, best.size)
        var result = Block()
        let chars = Array(text.utf16)
        for _ in 0..<4 {
            let font = face.font(size)
            result = Block(cap: CTFontGetCapHeight(font), gap: size * gapRatio)
            let a = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTKernAttributeName as String): kern * size,
            ])
            let setter = CTTypesetterCreateWithAttributedString(a)
            var start = 0, n = 0
            let length = a.length
            var broken: [CTLine] = []
            while start < length, n < 50 {
                let count = CTTypesetterSuggestLineBreak(setter, start, Double(width))
                guard count > 0 else { break }
                broken.append(CTTypesetterCreateLine(setter, CFRange(location: start, length: count)))
                start += count
                n += 1
            }
            // A line may only end inside a word when that word can't fit on a line of its own.
            var inWord = false
            var at = 0
            for l in broken.dropLast() {
                at += CTLineGetStringRange(l).length
                if at > 0, at < chars.count, chars[at - 1] != 32, chars[at] != 32, chars[at - 1] != 45 { inWord = true }
            }
            if (broken.count <= most && !inWord) || size <= minSize {
                if broken.count > most {
                    // Too long even at the smallest size: the last line takes the rest, cut short.
                    let rest = CTTypesetterCreateLine(setter, CFRange(location: broken[..<(most - 1)].reduce(0) { $0 + CTLineGetStringRange($1).length }, length: 0))
                    broken = Array(broken.prefix(most - 1)) + [truncated(rest, width) ?? rest]
                }
                result.lines = broken.map { l in
                    // Trailing spaces don't count toward the width (centering).
                    self.width(l) > width ? (truncated(l, width) ?? l) : l
                }
                result.width = result.lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth($0)) }.max() ?? 0
                return result
            }
            size = max(minSize, size * 0.9)
        }
        return result
    }

    /// Where each of a block's lines starts (its baseline).
    func origins(_ b: Block, x: CGFloat, top: CGFloat, width: CGFloat, align: Align) -> [CGPoint] {
        var baseline = top + b.cap
        return b.lines.map { l in
            let lw = self.width(l) - CGFloat(CTLineGetTrailingWhitespaceWidth(l))
            let lx = align == .center ? x + (width - lw) / 2 : align == .right ? x + width - lw : x
            defer { baseline += b.cap + b.gap }
            return CGPoint(x: lx, y: baseline)
        }
    }

    /// A block's lines from `top`; with `gradient`, the glyphs are filled with it left to right (emoji, which have
    /// no outline, keep their own colors); with `shadow`, a hard offset copy behind them (screen-print style).
    func draw(_ b: Block, x: CGFloat, top: CGFloat, width: CGFloat, align: Align, gradient: [CGColor]? = nil,
              shadow: (offset: CGSize, color: CGColor)? = nil) {
        let glyphs = CGMutablePath()
        ctx.saveGState()
        // Shadow offsets are in device pixels, y up.
        if let shadow { ctx.setShadow(offset: CGSize(width: shadow.offset.width * scale, height: -shadow.offset.height * scale), blur: 0, color: shadow.color) }
        for (l, o) in zip(b.lines, origins(b, x: x, top: top, width: width, align: align)) {
            ctx.textPosition = o
            CTLineDraw(l, ctx)
            if gradient != nil { addOutlines(l, at: o, to: glyphs) }
        }
        ctx.restoreGState()
        if let gradient, !glyphs.isEmpty {
            ctx.saveGState()
            ctx.addPath(glyphs)
            ctx.clip()
            linear(gradient, from: CGPoint(x: x, y: 0), to: CGPoint(x: x + max(b.width, 1), y: 0))
            ctx.restoreGState()
        }
    }

    /// A line's glyphs filled with a color, over whatever is drawn there.
    func fill(_ l: CTLine, at origin: CGPoint, color: CGColor) {
        let path = CGMutablePath()
        addOutlines(l, at: origin, to: path)
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    private func addOutlines(_ l: CTLine, at origin: CGPoint, to path: CGMutablePath) {
        for run in CTLineGetGlyphRuns(l) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let fontRef = attrs[kCTFontAttributeName as String] else { continue }
            let font = fontRef as! CTFont
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            for i in 0..<n {
                var t = CGAffineTransform(translationX: origin.x + positions[i].x, y: origin.y).scaledBy(x: 1, y: -1)
                if let g = CTFontCreatePathForGlyph(font, glyphs[i], &t) { path.addPath(g) }
            }
        }
    }
}

// MARK: - The cache

/// Tickets wherever a show has no cover (the grid, the open album, the lists, Stats): drawn in the background, kept
/// in memory (a few screens of the largest tiles), handed back on the main queue. Mirrors `LibraryArt`: `cached`,
/// `load` with a token, `cancel`.
@MainActor
final class Tickets {
    static let shared = Tickets()

    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    private let memory = NSCache<NSString, Box>()
    private var waiting: [String: [Int: (CGImage?) -> Void]] = [:]
    private var operations: [String: Operation] = [:]
    private var nextToken = 0
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "omniamp.tickets"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 2
        return q
    }()

    private init() { memory.totalCostLimit = 48 << 20 }

    /// Tiles are drawn at their size rounded up to 24 points: a window being resized doesn't redraw every ticket
    /// for every point it grows (the grid scales the ticket down a little).
    static func side(for width: CGFloat) -> CGFloat { max(24, (width / 24).rounded(.up) * 24) }

    /// Everything the ticket shows is in the key, so a retagged show gets a new one.
    private static func key(_ a: LibraryAlbum, side: CGFloat, scale: CGFloat) -> String {
        [a.key, a.artist, a.title, a.showDate ?? "", a.venue ?? "", a.year.map(String.init) ?? "", "\(Int(side * scale))"].joined(separator: "\u{1}")
    }

    func cached(_ a: LibraryAlbum, side: CGFloat, scale: CGFloat) -> CGImage? {
        memory.object(forKey: Self.key(a, side: side, scale: scale) as NSString)?.image
    }

    /// Calls back on the main queue (right away when in memory). Returns a token for `cancel`.
    @discardableResult
    func load(_ a: LibraryAlbum, side: CGFloat, scale: CGFloat, completion: @escaping (CGImage?) -> Void) -> Int {
        let key = Self.key(a, side: side, scale: scale)
        if let box = memory.object(forKey: key as NSString) { completion(box.image); return -1 }
        nextToken += 1
        let token = nextToken
        if waiting[key] != nil { waiting[key]![token] = completion; return token }
        waiting[key] = [token: completion]
        let album = a
        let op = BlockOperation {
            let img = autoreleasepool { TicketArt.render(TicketInfo(album), side: side, scale: scale) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(key, img) } }
        }
        operations[key] = op
        queue.addOperation(op)
        return token
    }

    func cancel(_ a: LibraryAlbum, token: Int, side: CGFloat, scale: CGFloat) {
        let key = Self.key(a, side: side, scale: scale)
        guard token >= 0, waiting[key]?.removeValue(forKey: token) != nil else { return }
        if waiting[key]?.isEmpty == true {
            waiting[key] = nil
            operations.removeValue(forKey: key)?.cancel()   // not started yet: never drawn
        }
    }

    private func finish(_ key: String, _ img: CGImage?) {
        operations[key] = nil
        if let img { memory.setObject(Box(img), forKey: key as NSString, cost: img.bytesPerRow * img.height) }
        for (_, done) in waiting.removeValue(forKey: key) ?? [:] { done(img) }
    }
}

// MARK: - Contact sheet (test hook)

extension TicketArt {
    /// OMNIAMP_TICKETS=<file.png>: every style with a few sample shows, on a light and a dark page, to compare
    /// designs without a library of cover-less shows. OMNIAMP_TICKET_SIZE picks the tile size (158).
    static func writeSheet(to path: String, side: CGFloat) {
        let samples = [
            TicketInfo(key: "a", artist: "Grateful Dead", title: "", showDate: "1977-05-08", year: nil, venue: "Barton Hall, Cornell University, Ithaca, NY"),
            TicketInfo(key: "b", artist: "The Allman Brothers Band", title: "", showDate: "1971-03-13", year: nil, venue: "Fillmore East, New York"),
            TicketInfo(key: "c", artist: "Phish", title: "", showDate: "1997-12-31", year: nil, venue: "Madison Square Garden"),
            TicketInfo(key: "d", artist: "shannon wright", title: "", showDate: "2004-04-30", year: nil, venue: "café de la danse, paris"),
            TicketInfo(key: "e", artist: "Godspeed You! Black Emperor", title: "", showDate: "2013-10", year: nil, venue: nil),
            TicketInfo(key: "f", artist: "Radiohead", title: "gd", showDate: nil, year: nil, venue: nil),
        ]
        let styles = TicketStyle.allCases, scale: CGFloat = 2, gap: CGFloat = 16
        let cols = samples.count, rows = styles.count * 2
        let w = CGFloat(cols) * (side + gap) + gap, h = CGFloat(rows) * (side + gap) + gap
        guard let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        for (i, style) in styles.enumerated() {
            for dark in [false, true] {
                let row = i * 2 + (dark ? 1 : 0)
                let y = h - CGFloat(row + 1) * (side + gap)
                ctx.setFillColor(dark ? Pen.rgb(0x1B1B1F) : Pen.rgb(0xF4F4F6))
                ctx.fill(CGRect(x: 0, y: y - gap / 2, width: w, height: side + gap))
                for (j, t) in samples.enumerated() {
                    guard let img = render(t, style: style, side: side, scale: scale) else { continue }
                    ctx.draw(img, in: CGRect(x: gap + CGFloat(j) * (side + gap), y: y, width: side, height: side))
                }
            }
        }
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
