import XCTest
@testable import OmniAmp

/// Canned answers by address part (the ARD GraphQL requests by what they ask for), so nothing goes online.
private final class BookStub: HTTPTransport, @unchecked Sendable {
    let answers: [String: String]
    private let lock = NSLock()
    private var _requests: [String] = []
    var requests: [String] { lock.withLock { _requests } }
    init(_ answers: [String: String]) { self.answers = answers }

    func send(_ req: URLRequest) async throws -> (Data, Int) {
        XCTAssertTrue(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("OmniAmp/") ?? false)
        var key = req.url!.absoluteString
        if let body = req.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let q = json["query"] as? String {
            // "editorialCategory", "search" or "programSet", plus the variables.
            let what = ["editorialCategory", "search", "programSet"].first { q.contains($0 + "(") } ?? "?"
            key = "ard:" + what + ":" + ((json["variables"] as? [String: String])?.values.sorted().joined() ?? "")
        }
        lock.withLock { _requests.append(key) }
        guard let body = answers.first(where: { key.contains($0.key) })?.value else { return (Data(), 404) }
        return (Data(body.utf8), 200)
    }
}

@MainActor
final class BookSourceTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-books-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func audio(_ url: String, download: Bool = true, mime: String = "audio/mp3") -> String {
        #"{"url":"\#(url)","downloadUrl":\#(download ? "\"\(url)\"" : "null"),"allowDownload":\#(download),"mimeType":"\#(mime)"}"#
    }

    private func item(_ id: String, _ title: String, date: String, set: String = "100", audios: [String]) -> String {
        #"{"id":"\#(id)","title":"\#(title)","synopsis":"<p>Notes</p>","duration":3000,"publishDate":"\#(date)","endDate":null,"#
            + #""image":{"url":"https://img/\#(id)?w={width}"},"programSet":{"id":"\#(set)","title":"Krimi"},"#
            + #""audios":[\#(audios.joined(separator: ","))]}"#
    }

    // MARK: Addresses

    func testBookAddressesSayWhereTheyComeFrom() {
        XCTAssertEqual(PodcastShow(feedURL: "ard:123", title: "", author: "").bookSource, .ard)
        XCTAssertEqual(PodcastShow(feedURL: "ard-search:drei", title: "", author: "").bookSource, .ardSearch)
        XCTAssertEqual(PodcastShow(feedURL: "librivox:verwandlung_x", title: "", author: "").bookID, "verwandlung_x")
        XCTAssertTrue(PodcastShow(feedURL: "archive:a:b", title: "", author: "").isFixedBook)
        XCTAssertEqual(PodcastShow(feedURL: "archive:a:b", title: "", author: "").bookID, "a:b", "only the first colon")
        for podcast in ["https://example.com/feed", "omniamp:continue", ""] {
            XCTAssertFalse(PodcastShow(feedURL: podcast, title: "", author: "").isBook, podcast)
        }
    }

    // MARK: ARD

    func testARDSeriesStaysNewestFirstButASerialIsInStoryOrder() {
        let series = #"{"data":{"programSet":{"items":{"nodes":["#
            + [item("1", "Der Fall Moor", date: "2026-01-02T10:00:00+01:00", audios: [audio("https://a/1.mp3")]),
               item("2", "Gone", date: "2026-02-02T10:00:00+01:00", audios: []),   // taken offline, still listed
               item("3", "Die Brücke", date: "2026-03-02T10:00:00+01:00",
                    audios: [audio("https://a/3.mp4", mime: "audio/aac"), audio("https://a/3-od.mp3", download: false), audio("https://a/3.mp3")])]
                .joined(separator: ",") + "]}}}}"
        let eps = BookDirectory.decodeARDSet(Data(series.utf8))
        XCTAssertEqual(eps.map(\.title), ["Die Brücke", "Der Fall Moor"], "newest first, no audio left out")
        XCTAssertEqual(eps[0].url, "https://a/3.mp3", "the MP3 that may be downloaded")
        XCTAssertEqual(eps[0].downloadable, true)
        XCTAssertEqual(eps[0].image, "https://img/3?w=400")
        XCTAssertEqual(eps[0].summary, "Notes")
        XCTAssertNil(eps[0].number, "not a serial: no part numbers")

        let serial = #"{"data":{"programSet":{"items":{"nodes":["#
            + [item("7", "Der Zauberberg (2/3)", date: "2026-01-03T10:00:00+01:00", audios: [audio("https://a/b.mp3", download: false)]),
               item("8", "Der Zauberberg (3/3)", date: "2026-01-04T10:00:00+01:00", audios: [audio("https://a/c.mp3")]),
               item("9", "Der Zauberberg (1/3)", date: "2026-01-02T10:00:00+01:00", audios: [audio("https://a/a.mp3")])]
                .joined(separator: ",") + "]}}}}"
        let parts = BookDirectory.decodeARDSet(Data(serial.utf8))
        XCTAssertEqual(parts.map(\.url), ["https://a/a.mp3", "https://a/b.mp3", "https://a/c.mp3"])
        XCTAssertEqual(parts.map(\.number), [1, 2, 3])
        XCTAssertEqual(parts[1].downloadable, false, "only streaming allowed")
        XCTAssertTrue(PodcastWindowController.inStoryOrder(parts))
        XCTAssertFalse(PodcastWindowController.inStoryOrder(eps))
    }

    func testPartNumbers() {
        XCTAssertEqual(BookDirectory.partNumber("Sherlock Holmes – Teil 3: Der Hund"), 3)
        XCTAssertEqual(BookDirectory.partNumber("Professor van Dusen, Folge 12"), 12)
        XCTAssertEqual(BookDirectory.partNumber("Der Zauberberg (2/14)"), 2)
        XCTAssertEqual(BookDirectory.partNumber("07 - Kapitel sieben"), 7)
        XCTAssertNil(BookDirectory.partNumber("Blitzlichter – ein Leben in Filmen"))
        XCTAssertNil(BookDirectory.partNumber("1984"), "a year-like title isn't a part")
        // Numbered, but two "Teil 1"s: not a clean serial.
        let a = PodcastEpisode(title: "A Teil 1", url: "a", published: 2, duration: nil, summary: nil)
        let b = PodcastEpisode(title: "B Teil 1", url: "b", published: 1, duration: nil, summary: nil)
        XCTAssertNil(BookDirectory.storyOrder([a, b]))
    }

    func testARDCategoryListsFeaturedFirstWithoutEmptyOnes() {
        let json = #"{"data":{"editorialCategory":{"sections":["#
            + #"{"type":"STAGE","nodes":[]},{"type":"banner","nodes":[{"__typename":"SophoraTeaser"}]},"#
            + #"{"type":"featured_programset","nodes":[{"__typename":"ProgramSet","id":"2","title":"Krimi Hörspiel","numberOfElements":101,"#
            + #""image":{"url":"https://img/2?w={width}"},"publicationService":{"title":"Deutschlandfunk Kultur"}}]},"#
            + #"{"type":"program_sets","nodes":[{"__typename":"ProgramSet","id":"1","title":"1001 Nacht","numberOfElements":5},"#
            + #"{"__typename":"ProgramSet","id":"2","title":"Krimi Hörspiel","numberOfElements":101},"#
            + #"{"__typename":"ProgramSet","id":"3","title":"Leer","numberOfElements":0}]}]}}}"#
        let shows = BookDirectory.decodeARDCategory(Data(json.utf8))
        XCTAssertEqual(shows.map(\.feedURL), ["ard:2", "ard:1"])
        XCTAssertEqual(shows[0].author, "Deutschlandfunk Kultur")
        XCTAssertEqual(shows[0].artwork, "https://img/2?w=400")
        XCTAssertEqual(shows[1].author, "ARD")
    }

    func testARDSearchKeepsToRadioPlaysAndBooks() async throws {
        let category = #"{"data":{"editorialCategory":{"sections":[{"type":"program_sets","nodes":["#
            + #"{"__typename":"ProgramSet","id":"100","title":"Krimi","numberOfElements":9}]}]}}}"#
        let search = #"{"data":{"search":{"programSets":{"nodes":[{"id":"100","title":"Krimi","synopsis":"Dracula und andere"},"#
            + #"{"id":"555","title":"Dracula-Nachrichten"}]},"#
            + #""items":{"nodes":["# + item("1", "Dracula (WDR 1995)", date: "2020-01-01T00:00:00Z", audios: [audio("https://a/d.mp3")]) + ","
            + item("2", "Dracula in den Nachrichten", date: "2020-01-01T00:00:00Z", set: "555", audios: [audio("https://a/n.mp3")]) + ","
            + item("3", "Frankenstein", date: "2020-01-01T00:00:00Z", audios: [audio("https://a/f.mp3")]) + "]}}}}"
        let net = BookStub(["ard:editorialCategory:42914712": category, "ard:search": search])
        let books = BookDirectory(transport: net, cacheDir: dir)
        let shows = try await books.searchARD("Dracula")
        XCTAssertEqual(shows.map(\.feedURL), ["ard-search:Dracula", "ard:100"], "the matching plays first, then series from the categories only")
        let plays = try await books.episodes(for: shows[0])
        XCTAssertEqual(plays.map(\.title), ["Dracula (WDR 1995)"], "another category's and one without the word are left out")
        XCTAssertEqual(plays[0].summary, "Krimi\n\nNotes", "says which series it's from")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ardRadioPlays.json").path), "category kept on disk")
    }

    func testARDSearchWithoutAnyCategoryListFailsInsteadOfFindingNothing() async throws {
        let search = #"{"data":{"search":{"programSets":{"nodes":[{"id":"100","title":"Krimi"}]},"items":{"nodes":[]}}}}"#
        let net = BookStub(["ard:search": search])   // every category list fails
        let books = BookDirectory(transport: net, cacheDir: dir)
        do {
            _ = try await books.searchARD("Krimi")
            XCTFail("an empty answer would read as \"nothing found\" and be kept for 30 minutes")
        } catch {}
        let asked = net.requests.count
        _ = try? await books.searchARD("Krimi")
        XCTAssertGreaterThan(net.requests.count, asked, "nothing was kept: the next search asks again")
    }

    // MARK: archive.org

    func testArchiveSearchResults() {
        let json = #"{"response":{"numFound":2,"docs":["#
            + #"{"identifier":"verwandlung_mw_0811_librivox","title":"Die Verwandlung","creator":"Franz Kafka","#
            + #""collection":["librivoxaudio","audio_bookspoetry"],"language":"deu","licenseurl":"http://creativecommons.org/licenses/publicdomain/"},"#
            + #"{"identifier":"die-drei-fragezeichen","title":["Die drei ???"],"creator":["Europa","Someone","Third"],"#
            + #""collection":"opensource_audio"},"#
            + #"{"title":"no identifier"}]}}"#
        let shows = BookDirectory.decodeArchiveSearch(Data(json.utf8))
        XCTAssertEqual(shows.map(\.feedURL), ["librivox:verwandlung_mw_0811_librivox", "archive:die-drei-fragezeichen"])
        XCTAssertEqual(shows[0].genre, "LibriVox · public domain · German")
        XCTAssertEqual(shows[0].artwork, "https://archive.org/services/img/verwandlung_mw_0811_librivox")
        XCTAssertEqual(shows[1].title, "Die drei ???", "a list where a string is expected")
        XCTAssertEqual(shows[1].author, "Europa, Someone")
        XCTAssertEqual(shows[1].genre, "archive.org · no licence stated")
        XCTAssertEqual(shows[1].sourceLabel, "archive.org")
    }

    func testLicences() {
        XCTAssertEqual(BookDirectory.licence("https://creativecommons.org/licenses/by-nc-sa/4.0/"), "CC BY-NC-SA")
        XCTAssertEqual(BookDirectory.licence("http://creativecommons.org/publicdomain/zero/1.0/"), "public domain")
        XCTAssertEqual(BookDirectory.licence(nil), "no licence stated")
        XCTAssertEqual(BookDirectory.licence("https://example.org/terms"), "licence: example.org")
    }

    func testSearchWordsAreEscaped() {
        let q = BookDirectory.archiveQuery(for: "drei ???  c++")
        XCTAssertEqual(q, #"(title:(drei AND \?\?\? AND c\+\+) OR creator:(drei AND \?\?\? AND c\+\+) OR subject:(drei AND \?\?\? AND c\+\+)) AND mediatype:audio AND NOT collection:etree"#)
    }

    func testArchiveItemPartsInOrder() throws {
        // LibriVox: VBR MP3 originals with "n/total" tracks; 64 kb copies with clock lengths and no tracks.
        let librivox = #"{"metadata":{"description":"<b>Kafka</b> liest"},"files":["#
            + #"{"name":"DieVerwandlung_librivox.m4b","format":"Audiobook","source":"original"},"#
            + #"{"name":"verwandlung_02_kafka.mp3","format":"VBR MP3","title":"Abschnitt 2","track":"2/3","length":"2663.84"},"#
            + #"{"name":"verwandlung_01_kafka.mp3","format":"VBR MP3","title":"Abschnitt 1","track":"1/3","length":"2465.8"},"#
            + #"{"name":"verwandlung_03_kafka.mp3","format":"VBR MP3","title":"","track":"3/3","length":"42:34"},"#
            + #"{"name":"verwandlung_01_kafka_64kb.mp3","format":"64Kbps MP3","title":"Abschnitt 1","length":"41:05"}]}"#
        let parts = try XCTUnwrap(BookDirectory.decodeArchiveItem(Data(librivox.utf8), id: "verwandlung"))
        XCTAssertEqual(parts.map(\.title), ["Abschnitt 1", "Abschnitt 2", "verwandlung_03_kafka"])
        XCTAssertEqual(parts.map(\.number), [1, 2, 3])
        XCTAssertEqual(parts[0].url, "https://archive.org/download/verwandlung/verwandlung_01_kafka.mp3")
        XCTAssertEqual(parts[2].duration, 2554, "mm:ss")
        XCTAssertEqual(parts[0].summary, "Kafka liest")
        XCTAssertTrue(PodcastWindowController.inStoryOrder(parts))

        // An upload with junk track numbers and names that only sort naturally ("2" before "10"); spaces in names.
        let upload = #"{"metadata":{},"files":["#
            + #"{"name":"Folge 10 - Der Super-Papagei.mp3","format":"VBR MP3","track":"-.--.--"},"#
            + #"{"name":"Folge 2 - Der Phantomsee.mp3","format":"VBR MP3","track":"01"},"#
            + #"{"name":"cover.jpg","format":"JPEG"}]}"#
        let folgen = try XCTUnwrap(BookDirectory.decodeArchiveItem(Data(upload.utf8), id: "ddf"))
        XCTAssertEqual(folgen.map(\.title), ["Folge 2 - Der Phantomsee", "Folge 10 - Der Super-Papagei"])
        XCTAssertEqual(folgen[0].url, "https://archive.org/download/ddf/Folge%202%20-%20Der%20Phantomsee.mp3")

        // Only an uploaded M4A (no MP3 copies): that, as macOS can play it.
        let m4a = #"{"files":[{"name":"show.m4a","format":"MPEG-4 Audio","source":"original"},{"name":"show.ogg","format":"Ogg Vorbis","source":"derivative"}]}"#
        XCTAssertEqual(BookDirectory.decodeArchiveItem(Data(m4a.utf8), id: "x")?.map(\.title), ["show"])

        XCTAssertNil(BookDirectory.decodeArchiveItem(Data("{}".utf8), id: "gone"), "a removed item answers {}")
    }

    /// Parts in different formats: a FLAC part with MP3 copies, an uploaded MP3 part with none. Both are listed,
    /// each once; a part uploaded twice (FLAC and MP3) and the whole book as one .m4b are not extra parts.
    func testArchiveItemWithMixedFormatsListsEveryPart() throws {
        let item = #"{"files":["#
            + #"{"name":"01.flac","format":"Flac","source":"original","track":"1"},"#
            + #"{"name":"01.mp3","format":"VBR MP3","source":"derivative","original":"01.flac","track":"1"},"#
            + #"{"name":"01_64kb.mp3","format":"64Kbps MP3","source":"derivative","original":"01.mp3","track":"1"},"#
            + #"{"name":"02.mp3","format":"MP3","source":"original","track":"2"},"#
            + #"{"name":"02_64kb.mp3","format":"64Kbps MP3","source":"derivative","original":"02.mp3","track":"2"},"#
            + #"{"name":"03.ogg","format":"Ogg Vorbis","source":"original","track":"3"},"#
            + #"{"name":"03_64kb.mp3","format":"64Kbps MP3","source":"derivative","original":"03.ogg","track":"3"},"#
            + #"{"name":"book.m4b","format":"Audiobook","source":"original"},"#
            + #"{"name":"cover.jpg","format":"JPEG","source":"original"}]}"#
        let parts = try XCTUnwrap(BookDirectory.decodeArchiveItem(Data(item.utf8), id: "mixed"))
        XCTAssertEqual(parts.map { ($0.url as NSString).lastPathComponent }, ["01.mp3", "02.mp3", "03_64kb.mp3"])

        // Each part uploaded as FLAC and as MP3: the MP3 uploads are the same parts, not more of them.
        let twice = #"{"files":["#
            + #"{"name":"a.flac","format":"Flac","source":"original"},"#
            + #"{"name":"a_vbr.mp3","format":"VBR MP3","source":"derivative","original":"a.flac"},"#
            + #"{"name":"a.mp3","format":"MP3","source":"original"}]}"#
        XCTAssertEqual(BookDirectory.decodeArchiveItem(Data(twice.utf8), id: "t")?.count, 1)
    }

    func testLengths() {
        XCTAssertEqual(BookDirectory.length("640.61"), 640.61)
        XCTAssertEqual(BookDirectory.length("10:40"), 640)
        XCTAssertEqual(BookDirectory.length("1:02:03"), 3723)
        XCTAssertNil(BookDirectory.length("--"))
        XCTAssertNil(BookDirectory.length(nil))
    }

    // MARK: Library

    func testABookIsReadFromItsSourceAndKeptInOrder() async throws {
        let item = #"{"metadata":{},"files":[{"name":"b.mp3","format":"VBR MP3","track":"2"},{"name":"a.mp3","format":"VBR MP3","track":"1"}]}"#
        let net = BookStub(["archive.org/metadata/some_book": item])
        let lib = PodcastLibrary(directory: dir.appendingPathComponent("lib"))
        lib.books = BookDirectory(transport: net, cacheDir: dir)
        let book = PodcastShow(feedURL: "archive:some_book", title: "Some Book", author: "A. Author")
        let parts = try await lib.episodes(book)
        XCTAssertEqual(parts.map(\.title), ["a", "b"], "story order, not by date")
        // Read once; asked again within the week, the saved copy answers.
        _ = try await lib.episodes(book)
        XCTAssertEqual(net.requests.filter { $0.contains("metadata") }.count, 1)

        lib.toggleSubscription(book)
        XCTAssertTrue(lib.isSubscribed(book))
        XCTAssertEqual(lib.newCount(book), 0, "parts without dates are never new")
        XCTAssertEqual(lib.lookup("https://archive.org/download/some_book/a.mp3")?.show.isBook, true)
    }

    func testBookPartsDownloadIntoTheirOwnFolder() throws {
        let book = PodcastShow(feedURL: "librivox:x", title: "Die Verwandlung: Kafka", author: "")
        var part = PodcastEpisode(title: "Abschnitt 1", url: "u", published: nil, duration: nil, summary: nil)
        part.number = 1
        XCTAssertEqual(PodcastDownloads.fileName(for: part, show: book, ext: "mp3"), "Die Verwandlung- Kafka/01 Abschnitt 1.mp3")

        let source = dir.appendingPathComponent("part.mp3")
        try Data(repeating: 1, count: 4000).write(to: source)
        part.url = source.absoluteString
        let d = PodcastDownloads(directory: dir.appendingPathComponent("dl"))
        let done = expectation(forNotification: PodcastDownloads.changed, object: part.url) { _ in MainActor.assumeIsolated { d.state(part.url) == .done } }
        d.download(part, show: book)
        wait(for: [done], timeout: 10)
        let file = try XCTUnwrap(d.localFile(part.url))
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "Die Verwandlung- Kafka")
        d.remove(part.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path), "the book's folder goes with its last part")
    }
}
