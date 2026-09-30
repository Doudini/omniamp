import XCTest
@testable import OmniAmp

final class TicketArtTests: XCTestCase {
    private func info(_ artist: String = "Grateful Dead", date: String? = "1977-05-08", venue: String? = "Barton Hall, Ithaca",
                      title: String = "", year: Int? = nil, key: String = "k") -> TicketInfo {
        TicketInfo(key: key, artist: artist, title: title, showDate: date, year: year, venue: venue)
    }

    func testDate() {
        let t = info()
        XCTAssertEqual([t.year, t.month, t.day], [1977, 5, 8])
        XCTAssertEqual(t.weekdayName, "SUNDAY")
        XCTAssertEqual(t.monthName, "MAY")
        XCTAssertEqual(t.dayText, "08")
        // A month without a day, a year only, an impossible day, no date (the album's year).
        let month = info(date: "2013-10")
        XCTAssertEqual([month.year, month.month], [2013, 10])
        XCTAssertNil(month.day)
        XCTAssertNil(month.weekday)
        XCTAssertNil(info(date: "1977").month)
        let bad = info(date: "1977-02-30")
        XCTAssertNil(bad.day)
        XCTAssertNil(bad.weekday)
        XCTAssertEqual(info(date: nil, year: 1994).year, 1994)
    }

    func testVenueAndCity() {
        XCTAssertEqual(info().venue, "Barton Hall")
        XCTAssertEqual(info().city, "Ithaca")
        // A state or country code takes the place before it along.
        let ny = info(venue: "Barton Hall, Cornell University, Ithaca, NY")
        XCTAssertEqual(ny.venue, "Barton Hall, Cornell University")
        XCTAssertEqual(ny.city, "Ithaca, NY")
        XCTAssertNil(info(venue: "Madison Square Garden").city)
        // Folder names in lower case are printed in title case; the rest as they are.
        XCTAssertEqual(info(venue: "café de la danse, paris").venue, "Café De La Danse")
        XCTAssertEqual(info("shannon wright").artist, "Shannon Wright")
        XCTAssertEqual(info("dEUS").artist, "dEUS")
        // No venue: the title, unless it's only the date again.
        XCTAssertEqual(info(venue: nil, title: "Live at the Roxy").venue, "The Roxy")
        XCTAssertNil(info(venue: nil, title: "94-02-27").venue)
        // The artist again and "live" aren't a place.
        XCTAssertNil(info("Cat Power", venue: "Cat Power Live").venue)
        XCTAssertEqual(info("Nirvana", venue: "Nirvana - Live at the Paramount, Seattle").venue, "The Paramount")
        XCTAssertEqual(info("Nirvana", venue: "Nirvana - Live at the Paramount, Seattle").city, "Seattle")
        XCTAssertEqual(info("Mazzy Star", venue: "New York").venue, "New York")
    }

    func testSeedIsStable() {
        // The same every launch (hashValue isn't): the ticket number, seat and style never change.
        XCTAssertEqual(TicketInfo.fnv("a"), 0xaf63_dc4c_8601_ec8c)
        let a = info(key: "/m/gd/1977-05-08"), b = info(key: "/m/gd/1977-05-08")
        XCTAssertEqual(a.ticketNumber, b.ticketNumber)
        XCTAssertEqual(a.ticketNumber.count, 5)
        XCTAssertTrue((1...30).contains(a.row))
        XCTAssertTrue(("A"..."L").contains(a.section))
    }

    func testStyleByEra() {
        for key in (0..<40).map({ "show \($0)" }) {
            XCTAssertEqual(TicketStyle.style(for: info(key: key)), TicketStyle.style(for: info(key: key)))
            XCTAssertTrue([.neon, .holographic, .brutalist, .editorial].contains(TicketStyle.style(for: info(date: "2015-01-01", key: key))))
            XCTAssertTrue([.festival, .letterpress].contains(TicketStyle.style(for: info(date: "1977-05-08", key: key))))
        }
        // Different shows of an era don't all look the same.
        let styles = Set((0..<40).map { TicketStyle.style(for: info(date: "1985-06-01", key: "s\($0)")) })
        XCTAssertGreaterThan(styles.count, 1)
    }

    func testRendersEveryStyleAndSize() {
        let names = ["Grateful Dead", "Phish", "The Allman Brothers Band", "Godspeed You! Black Emperor",
                     "Supercalifragilisticexpialidociousandthensome", "坂本龍一", "🎸 Band", ""]
        for style in TicketStyle.allCases {
            for side in [40.0, 118, 158, 208] {
                for (i, name) in names.enumerated() {
                    let t = info(name, date: i % 3 == 0 ? nil : "1977-05-08", venue: i % 2 == 0 ? nil : "Barton Hall, Ithaca, NY")
                    let img = TicketArt.render(t, style: style, side: side, scale: 2)
                    XCTAssertEqual(img?.width, Int(side * 2), "\(style) \(side) \(name)")
                }
            }
        }
    }

    func testNotchesAreTransparent() throws {
        // The punched notches show the page behind the ticket, whatever its color.
        let img = try XCTUnwrap(TicketArt.render(info(), style: .letterpress, side: 158, scale: 1))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        func alpha(_ x: Int, _ yFromTop: Int) -> UInt8 { px[(yFromTop * img.width + x) * 4 + 3] }
        let perf = Int((158 * 0.77).rounded())
        XCTAssertEqual(alpha(1, perf), 0)                 // in the notch
        XCTAssertEqual(alpha(79, 79), 255)               // on the ticket
    }

    func testRendersOffTheMainThread() {
        let done = expectation(description: "rendered")
        let t = info()
        DispatchQueue.global(qos: .userInitiated).async {
            for style in TicketStyle.allCases { XCTAssertNotNil(TicketArt.render(t, style: style, side: 208, scale: 2)) }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
    }

    func testRenderTime() {
        // The largest tile on a Retina screen, all six styles: a few milliseconds each, in the background.
        let t = info("The Allman Brothers Band")
        measure {
            for style in TicketStyle.allCases { _ = TicketArt.render(t, style: style, side: 208, scale: 2) }
        }
    }
}

@MainActor
final class TicketCacheTests: XCTestCase {
    private func album(_ key: String) -> LibraryAlbum {
        LibraryAlbum(key: key, artistKey: "gd", artist: "Grateful Dead", title: "1977-05-08 Barton Hall", year: 1977, kind: .show,
                     folder: "/m/\(key)", tracks: 10, duration: 2400, firstPath: "/m/\(key)/01.flac", lossless: true, added: 0,
                     showDate: "1977-05-08", venue: "Barton Hall, Ithaca, NY")
    }

    func testLoadCachesAndCancelDropsTheResult() async throws {
        let a = album("cache-\(UUID().uuidString)")
        XCTAssertNil(Tickets.shared.cached(a, side: 120, scale: 2))
        let loaded = expectation(description: "loaded")
        Tickets.shared.load(a, side: 120, scale: 2) { img in
            XCTAssertEqual(img?.width, 240)
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 10)
        XCTAssertNotNil(Tickets.shared.cached(a, side: 120, scale: 2))
        // Another size is another ticket; a cancelled request never calls back.
        let b = album("cancel-\(UUID().uuidString)")
        let token = Tickets.shared.load(b, side: 144, scale: 2) { _ in XCTFail("called back after cancel") }
        Tickets.shared.cancel(b, token: token, side: 144, scale: 2)
        let other = expectation(description: "other")
        Tickets.shared.load(album("other-\(UUID().uuidString)"), side: 144, scale: 2) { _ in other.fulfill() }
        await fulfillment(of: [other], timeout: 10)
    }

    func testSideIsRounded() {
        XCTAssertEqual(Tickets.side(for: 118), 120)
        XCTAssertEqual(Tickets.side(for: 120), 120)
        XCTAssertEqual(Tickets.side(for: 121), 144)
        XCTAssertEqual(Tickets.side(for: 208), 216)
    }
}
