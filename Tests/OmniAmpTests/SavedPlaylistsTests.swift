import XCTest
@testable import OmniAmp

/// Saved playlists edited from the library: lossless edits of the .m3u8, the folder model, and the drag types.
@MainActor
final class SavedPlaylistsTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-saved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func track(_ path: String, title: String? = nil, artist: String? = nil, album: String? = nil) -> Track {
        var t = Track(path: path, size: 1, mtime: 1)
        t.title = title
        t.artist = artist
        t.album = album
        t.duration = 200
        return t
    }

    // MARK: Document

    private let sample = "\u{FEFF}#EXTM3U\r\n#PLAYLIST:Mix\r\n#EXTINF:200,A - One\r\n#EXTGRP:Side A\r\n/m/one.flac\r\n"
        + "#EXTINF:-1 tvg-logo=\"http://x/logo.png\",Radio X\r\nhttp://radio.example/stream\r\n"
        + "#EXTINF:1800 omniamp-podcast=\"Show\",Show - Ep 1\r\nhttps://pod.example/ep1.mp3\r\n"
        + "relative/two.mp3\r\nrtsp://old.example/thing\r\n"
        + "#EXTINF:120 omniamp-cue=\"30.5,150.5,2\",Cue Two\r\n/m/image.flac\r\n#trailing comment\r\n"

    func testUntouchedEntriesKeepTheirLines() {
        let doc = PlaylistDocument.parse(sample)
        XCTAssertEqual(doc.header, ["#EXTM3U", "#PLAYLIST:Mix"])
        XCTAssertEqual(doc.items.map(\.ref), ["/m/one.flac", "http://radio.example/stream", "https://pod.example/ep1.mp3",
                                              "relative/two.mp3", "rtsp://old.example/thing", "/m/image.flac"])
        XCTAssertEqual(doc.items[0].lines, ["#EXTINF:200,A - One", "#EXTGRP:Side A"])
        XCTAssertEqual(doc.trailer, ["#trailing comment"])
        // Parsed and written unchanged: the same lines (line breaks and the BOM normalized).
        let normalized = String(sample.dropFirst()).replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(doc.text(), normalized)

        var edited = doc
        edited.move([4], to: 0)   // the rtsp line first
        edited.remove([3])        // the episode out
        edited.insert([track("/m/new.mp3", title: "New", artist: "B")], at: 1)
        XCTAssertEqual(edited.items.map(\.ref), ["rtsp://old.example/thing", "/m/new.mp3", "/m/one.flac", "http://radio.example/stream",
                                                 "relative/two.mp3", "/m/image.flac"])
        let text = edited.text()
        XCTAssertTrue(text.hasPrefix("#EXTM3U\n#PLAYLIST:Mix\nrtsp://old.example/thing\n#EXTINF:200,B - New\n/m/new.mp3\n"
                                     + "#EXTINF:200,A - One\n#EXTGRP:Side A\n/m/one.flac\n"), text)
        XCTAssertTrue(text.contains("#EXTINF:120 omniamp-cue=\"30.5,150.5,2\",Cue Two\n/m/image.flac\n#trailing comment\n"))
    }

    func testEntriesReadLikePlaying() throws {
        let url = tmp.appendingPathComponent("p.m3u8")
        try sample.write(to: url, atomically: true, encoding: .utf8)
        let doc = PlaylistDocument.parse(sample)
        let base = tmp!
        let viaDoc = doc.items.indices.compactMap { doc.entry($0, base: base) }
        let viaFile = PlaylistFile.entries(url)
        XCTAssertEqual(viaDoc.map(\.url), viaFile.map(\.url))
        XCTAssertEqual(viaDoc.map(\.title), viaFile.map(\.title))
        XCTAssertEqual(viaDoc.last?.cueStart, 30.5)
        XCTAssertEqual(viaDoc.last?.cueNumber, 2)
    }

    func testMoveIsAboveSemantics() {
        var doc = PlaylistDocument()
        doc.insert((0..<5).map { track("/m/\($0).mp3") })
        // Rows 0 and 1 dropped above row 4: they land just before the old row 4.
        XCTAssertEqual(doc.move([0, 1], to: 4), IndexSet(2..<4))
        XCTAssertEqual(doc.items.map(\.ref), ["/m/2.mp3", "/m/3.mp3", "/m/0.mp3", "/m/1.mp3", "/m/4.mp3"])
        // Moving down past the end and up to the top.
        XCTAssertEqual(doc.move([0], to: 5), IndexSet([4]))
        XCTAssertEqual(doc.move([4], to: 0), IndexSet([0]))
        XCTAssertEqual(doc.items.map(\.ref), ["/m/2.mp3", "/m/3.mp3", "/m/0.mp3", "/m/1.mp3", "/m/4.mp3"])
    }

    func testPlaylistsWrittenFromTheLibraryPlayTheSame() throws {
        // A station, an episode, a CUE slice and a file: what playing the saved file gives back.
        var cue = track("/m/image.flac", title: "Cue Two")
        cue.cueStart = 30.5
        cue.cueEnd = 150.5
        cue.cueNumber = 2
        let tracks = [Track.stream("http://radio.example/s", name: "Radio X", logo: "http://x/l.png"),
                      Track.episode("https://pod.example/e.mp3", title: "Ep", show: "Show", artwork: nil, duration: 60, published: nil, summary: nil),
                      cue]
        var doc = PlaylistDocument()
        doc.insert(tracks)
        let url = tmp.appendingPathComponent("w.m3u8")
        try doc.text().write(to: url, atomically: true, encoding: .utf8)
        let back = PlaylistFile.entries(url).map { PlaylistFile.remoteTrack($0) }
        XCTAssertEqual(back[0]?.isStream, true)
        XCTAssertEqual(back[0]?.logo, "http://x/l.png")
        XCTAssertEqual(back[1]?.podcast, "Show")
        XCTAssertEqual(back[1]?.title, "Ep")
        XCTAssertNil(back[2])
        XCTAssertEqual(PlaylistFile.entries(url)[2].cueStart, 30.5)
    }

    // MARK: Model

    func testCreateAppendRenameTrash() throws {
        let lists = SavedPlaylists(directory: tmp, watch: false)
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: SavedPlaylists.changed, object: lists, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let a = try lists.create(named: "Road Trip", tracks: [track("/m/1.mp3", title: "One")])
        let b = try lists.create(named: "road trip")
        XCTAssertEqual(SavedPlaylists.name(a), "Road Trip")
        XCTAssertEqual(SavedPlaylists.name(b), "road trip 2")
        XCTAssertEqual(lists.urls.map(SavedPlaylists.name), ["Road Trip", "road trip 2"])
        XCTAssertEqual(posted, 2)

        try lists.append([track("/m/2.mp3", title: "Two")], to: a)
        XCTAssertEqual(lists.document(a).items.map(\.ref), ["/m/1.mp3", "/m/2.mp3"])
        XCTAssertEqual(posted, 3)

        XCTAssertThrowsError(try lists.rename(b, to: "ROAD TRIP"))   // another playlist's name, in other case
        let renamed = try lists.rename(a, to: "AC/DC: Live")
        XCTAssertEqual(SavedPlaylists.name(renamed), "AC-DC- Live")
        let cased = try lists.rename(renamed, to: "ac-dc- live")   // only the case
        XCTAssertEqual(SavedPlaylists.name(cased), "ac-dc- live")
        XCTAssertEqual(lists.urls.map(SavedPlaylists.name), ["ac-dc- live", "road trip 2"])
        XCTAssertEqual(lists.document(cased).items.count, 2)

        XCTAssertThrowsError(try lists.create(named: "  ..  "))
        try lists.trash(b)
        XCTAssertEqual(lists.urls.map(SavedPlaylists.name), ["ac-dc- live"])
        // Songs arriving for a playlist that went meanwhile (a slow drop) don't bring it back.
        XCTAssertThrowsError(try lists.append([track("/m/3.mp3")], to: b))
        XCTAssertFalse(ExactPath.exists(b.path))
    }

    func testGroups() throws {
        let lists = SavedPlaylists(directory: tmp, watch: false)
        let rock = try lists.createGroup(named: "Rock")
        let jazz = try lists.createGroup(named: "jazz")
        XCTAssertEqual(SavedPlaylists.name(try lists.createGroup(named: "rock")), "rock 2")
        XCTAssertEqual(lists.groups.map(\.name), ["jazz", "Rock", "rock 2"])

        // Names are unique per group: the same name in a group and outside is fine.
        let inRock = try lists.create(named: "Mix", tracks: [track("/m/1.mp3")], in: rock)
        let loose = try lists.create(named: "Mix")
        XCTAssertEqual(SavedPlaylists.name(try lists.create(named: "Mix", in: rock)), "Mix 2")
        XCTAssertEqual(lists.group(of: inRock)?.name, "Rock")
        XCTAssertNil(lists.group(of: loose))
        XCTAssertEqual(lists.ungrouped.map(SavedPlaylists.name), ["Mix"])
        XCTAssertEqual(lists.urls.count, 3)

        // Into a group that has the name already: numbered. Out again.
        let moved = try lists.move(loose, toGroup: rock)
        XCTAssertEqual(SavedPlaylists.name(moved), "Mix 3")
        XCTAssertEqual(lists.groups.first { $0.name == "Rock" }?.playlists.map(SavedPlaylists.name), ["Mix", "Mix 2", "Mix 3"])
        let out = try lists.move(moved, toGroup: nil)
        XCTAssertEqual(SavedPlaylists.name(out), "Mix 3")
        XCTAssertNil(lists.group(of: out))
        XCTAssertEqual(try lists.move(out, toGroup: nil), out)   // already there

        // A color: Finder's tag on the folder, read back.
        try lists.setColor(.blue, of: rock)
        XCTAssertEqual(lists.groups.first { $0.name == "Rock" }?.color, .blue)
        try lists.setColor(nil, of: rock)
        XCTAssertNil(lists.groups.first { $0.name == "Rock" }?.color)

        // Renamed: its playlists go along. Another group's name (in another case) is refused; only the case is fine.
        XCTAssertThrowsError(try lists.renameGroup(jazz, to: "ROCK"))
        let rock2 = try lists.renameGroup(rock, to: "Classic Rock")
        XCTAssertEqual(lists.groups.first { $0.name == "Classic Rock" }?.playlists.count, 2)
        let cased = try lists.renameGroup(jazz, to: "Jazz")
        XCTAssertTrue(lists.groups.contains { $0.name == "Jazz" })

        // Deleted: its playlists stay, out of any group (renumbered where the name is taken).
        let where_ = try lists.deleteGroup(rock2)
        XCTAssertEqual(where_.values.map(SavedPlaylists.name).sorted(), ["Mix", "Mix 2"])
        XCTAssertEqual(lists.ungrouped.map(SavedPlaylists.name), ["Mix", "Mix 2", "Mix 3"])
        XCTAssertEqual(lists.groups.map(\.name), ["Jazz", "rock 2"])
        XCTAssertTrue(ExactPath.exists(cased.path))
    }

    func testNamesAreNFC() throws {
        let lists = SavedPlaylists(directory: tmp, watch: false)
        let decomposed = "Bjo\u{308}rk"
        let url = try lists.create(named: decomposed, tracks: [track("/m/Bj\u{F6}rk/J\u{F3}ga.flac")])
        XCTAssertEqual(SavedPlaylists.name(url).unicodeScalars.count, 5)   // ö as one character
        // The path's bytes are written as given (the NAS file is found by them).
        XCTAssertEqual(lists.document(url).items.first?.ref.utf8.count, "/m/Bj\u{F6}rk/J\u{F3}ga.flac".utf8.count)
    }

    func testPlsIsReadOnly() throws {
        let lists = SavedPlaylists(directory: tmp, watch: false)
        let pls = tmp.appendingPathComponent("Old.pls")
        try "[playlist]\nFile1=/m/a.mp3\nTitle1=A\nNumberOfEntries=1\n".write(to: pls, atomically: true, encoding: .utf8)
        lists.refresh()
        XCTAssertEqual(lists.document(pls).items.map(\.ref), ["/m/a.mp3"])
        XCTAssertThrowsError(try lists.append([track("/m/b.mp3")], to: pls))
        XCTAssertEqual(try String(contentsOf: pls, encoding: .utf8), "[playlist]\nFile1=/m/a.mp3\nTitle1=A\nNumberOfEntries=1\n")
    }

    func testSuggestedName() {
        XCTAssertEqual(SavedPlaylists.suggestedName(for: [track("/1", artist: "A", album: "X"), track("/2", artist: "B", album: "X")]), "X")
        XCTAssertEqual(SavedPlaylists.suggestedName(for: [track("/1", artist: "A", album: "X"), track("/2", artist: "A", album: "Y")]), "A")
        XCTAssertEqual(SavedPlaylists.suggestedName(for: [track("/1", artist: "A"), track("/2", artist: "B")]), "New Playlist")
        XCTAssertEqual(SavedPlaylists.suggestedName(for: []), "New Playlist")
    }

    // MARK: Rows

    private func file(_ key: String, path: String, title: String, cue: Double? = nil) -> LibraryFile {
        var info = TagInfo()
        info.duration = 200
        return LibraryFile(key: key, path: path, root: "/m", size: 1, mtime: 1, cueStart: cue, cueEnd: nil, cueNumber: cue == nil ? nil : 1,
                           info: info, result: .init(kind: .album, artist: "Artist", album: "Album", year: 2001, showDate: nil, venue: nil,
                                                     albumFolder: "/m"),
                           title: title)
    }

    func testRowsTakeTheLibrarysTags() throws {
        let db = try CollectionDB(url: tmp.appendingPathComponent("lib.sqlite"))
        // More keys than one query takes, a CUE track, and a file the library doesn't have.
        var files = (0..<620).map { file("/m/\($0).flac", path: "/m/\($0).flac", title: "Song \($0)") }
        files.append(file("/m/image.flac#30.5", path: "/m/image.flac", title: "Cue Song", cue: 30.5))
        try db.upsert(files)
        let keys = files.map(\.key) + ["/m/unknown.flac"]
        let found = try db.tracks(keys: keys)
        XCTAssertEqual(found.count, 621)
        XCTAssertEqual(found["/m/image.flac#30.5"]?.title, "Cue Song")

        let real = tmp.appendingPathComponent("here.mp3")
        try Data([0]).write(to: real)
        let text = "#EXTM3U\n/m/5.flac\n#EXTINF:120 omniamp-cue=\"30.5,,1\",X\n/m/image.flac\n#EXTINF:90,Gone Song\n/m/gone.mp3\n\(real.path)\n"
        let rows = PlaylistRow.resolve(PlaylistDocument.parse(text), base: tmp, db: db, checkFiles: true)
        XCTAssertEqual(rows.map(\.title), ["Song 5", "Cue Song", "Gone Song", "here.mp3"])
        XCTAssertEqual(rows.map(\.missing), [false, false, true, false])
        XCTAssertEqual(rows[2].duration, 90)
        XCTAssertNil(rows[2].track)
        XCTAssertEqual(rows[1].track?.cueStart, 30.5)
        XCTAssertEqual(rows[3].track?.path, real.path)
    }

    // MARK: Dragging

    func testSongsDragWithTheirTags() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("omniamp-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let station = Track.stream("http://radio.example/s", name: "Radio X")
        pb.writeObjects([LibraryDrag.item(for: track("/m/a.flac", title: "A")), LibraryDrag.item(for: station)])
        let back = try XCTUnwrap(LibraryDrag.tracks(from: pb))
        XCTAssertEqual(back.map(\.path), ["/m/a.flac", "http://radio.example/s"])
        XCTAssertEqual(back[0].title, "A")
        // Finder sees the file (not the station).
        XCTAssertEqual(LibraryDrag.urls(from: pb).map(\.path), ["/m/a.flac"])

        // A plain file drag (Finder) has no songs: read as files.
        pb.clearContents()
        pb.writeObjects([URL(exactPath: "/m/b.flac") as NSURL])
        XCTAssertNil(LibraryDrag.tracks(from: pb))
    }
}
