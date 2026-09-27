import XCTest
@testable import OmniAmp

final class RadioTests: XCTestCase {
    func testStreamTitleParsing() {
        XCTAssertEqual(StreamSource.streamTitle("StreamTitle='Air - La Femme d'Argent';StreamUrl='';"), "Air - La Femme d'Argent")
        XCTAssertNil(StreamSource.streamTitle("StreamTitle='';"))
        XCTAssertNil(StreamSource.streamTitle("garbage"))
    }

    /// Audio with ICY metadata blocks every 16 bytes, delivered in awkward chunk sizes.
    func testICYDemuxAcrossChunkBoundaries() {
        func meta(_ t: String) -> Data {
            var m = Data("StreamTitle='\(t)';".utf8)
            let blocks = (m.count + 15) / 16
            m.append(Data(repeating: 0, count: blocks * 16 - m.count))
            return Data([UInt8(blocks)]) + m
        }
        let audio = Data(repeating: 0xAA, count: 16)
        var stream = Data()
        stream += audio + meta("One - First")
        stream += audio + Data([0])                    // empty metadata block
        stream += audio + meta("Two - Second")
        stream += audio

        for chunk in [1, 3, 7, 16, 17, 1000] {
            let src = StreamSource(url: URL(string: "http://example.com")!)
            var titles: [String] = []
            src.onTitle = { titles.append($0) }
            var i = 0
            while i < stream.count {
                src.feedForTesting(stream[i..<min(i + chunk, stream.count)], metaInterval: 16)
                i += chunk
            }
            XCTAssertEqual(titles, ["One - First", "Two - Second"], "chunk size \(chunk)")
        }
    }

    func testDirectoryKeepsWorkingStationsIncludingHLSAndOgg() {
        let json = """
        [{"stationuuid":"1","name":" Good MP3 ","url_resolved":"http://a/stream","codec":"MP3","bitrate":128,"hls":0,"lastcheckok":1,"tags":"jazz,smooth,lounge,chill","country":"France","countrycode":"FR","favicon":"https://a/logo.png"},
         {"stationuuid":"2","name":"HLS","url_resolved":"https://b/live.m3u8","codec":"UNKNOWN","bitrate":0,"hls":1,"lastcheckok":1,"favicon":""},
         {"stationuuid":"3","name":"Ogg","url_resolved":"http://c/ogg","codec":"OGG","bitrate":96,"hls":0,"lastcheckok":1},
         {"stationuuid":"4","name":"Broken","url_resolved":"http://d/x","codec":"MP3","bitrate":128,"hls":0,"lastcheckok":0},
         {"stationuuid":"5","name":"No URL","url_resolved":"","url":"","codec":"MP3","bitrate":0,"hls":0,"lastcheckok":1}]
        """
        let s = RadioBrowser.decode(Data(json.utf8))
        XCTAssertEqual(s.map(\.name), ["Good MP3", "HLS", "Ogg"], "broken and URL-less stations are dropped")
        XCTAssertEqual(s[0].genreLabel, "jazz, smooth, lounge")
        XCTAssertEqual(s[0].formatLabel, "MP3 128")
        XCTAssertEqual(s[0].favicon, "https://a/logo.png")
        XCTAssertNil(s[1].favicon)
        XCTAssertEqual(s[1].formatLabel, "HLS")
    }

    func testSystemPlayerDetection() {
        XCTAssertTrue(StreamSource.isSystemPlayerURL(URL(string: "https://x/live/index.m3u8?t=1")!))
        XCTAssertTrue(StreamSource.isSystemPlayerURL(URL(string: "https://x/stream.opus")!))
        XCTAssertFalse(StreamSource.isSystemPlayerURL(URL(string: "http://x/stream")!))
        XCTAssertTrue(StreamSource.isSystemPlayerType("application/vnd.apple.mpegurl"))
        XCTAssertTrue(StreamSource.isSystemPlayerType("audio/ogg"))
        XCTAssertFalse(StreamSource.isSystemPlayerType("audio/mpeg"))
        XCTAssertFalse(StreamSource.isSystemPlayerType("audio/aacp"))
    }

    func testLogoAttributeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-logo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A comma inside the quoted logo URL must not end the attribute list.
        let m3u = dir.appendingPathComponent("r.m3u")
        try "#EXTM3U\n#EXTINF:-1 tvg-logo=\"https://img/x.png?a=1,2\",Station, With Comma\nhttps://s/stream\n".write(to: m3u, atomically: true, encoding: .utf8)
        let t = FolderScanner.scan([m3u])
        XCTAssertEqual(t.first?.title, "Station, With Comma")
        XCTAssertEqual(t.first?.logo, "https://img/x.png?a=1,2")
        let out = dir.appendingPathComponent("out.m3u8")
        try PlaylistFile.writeM3U(t, to: out)
        XCTAssertEqual(FolderScanner.scan([out]).first?.logo, "https://img/x.png?a=1,2")
    }

    func testPlaylistFilesCarryStations() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-radio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m3u = dir.appendingPathComponent("r.m3u")
        try "#EXTM3U\n#EXTINF:-1,Groove Salad\nhttps://ice1.somafm.com/groovesalad-128-mp3\n".write(to: m3u, atomically: true, encoding: .utf8)
        let pls = dir.appendingPathComponent("r.pls")
        try "[playlist]\nFile1=http://x.example/stream\nTitle1=Example FM\nNumberOfEntries=1\n".write(to: pls, atomically: true, encoding: .utf8)

        let tracks = FolderScanner.scan([m3u, pls])
        XCTAssertEqual(tracks.map(\.title), ["Groove Salad", "Example FM"])
        XCTAssertTrue(tracks.allSatisfy(\.isStream))
        XCTAssertEqual(tracks[0].url.absoluteString, "https://ice1.somafm.com/groovesalad-128-mp3")
        XCTAssertTrue(tracks[0].tagsLoaded, "no tag reading for streams")

        // Round trip through our own M3U writer.
        let out = dir.appendingPathComponent("out.m3u8")
        try PlaylistFile.writeM3U(tracks, to: out)
        XCTAssertEqual(FolderScanner.scan([out]).map(\.path), tracks.map(\.path))
    }
}

final class CacheUpgradeTests: XCTestCase {
    func testOlderCacheKeepsStationNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omniamp-cacheup-\(UUID().uuidString)")
        setenv("OMNIAMP_CACHE_DIR", dir.path, 1)
        defer { unsetenv("OMNIAMP_CACHE_DIR"); try? FileManager.default.removeItem(at: dir) }
        var file = Track(path: "/music/a.flac", size: 1, mtime: 0)
        file.title = "Song"
        file.tagsLoaded = true
        let station = Track.stream("https://example.com/live.mp3", name: "Llama FM", logo: nil)
        var old = LibraryCache.Payload(tracks: [file, station])
        old.version = LibraryCache.currentVersion - 1
        LibraryCache.save(old)
        let p = try XCTUnwrap(LibraryCache.load())
        XCTAssertFalse(p.tracks[0].tagsLoaded, "files are re-read after an upgrade")
        XCTAssertTrue(p.tracks[1].tagsLoaded, "stations have nothing to re-read")
        XCTAssertEqual(p.tracks[1].displayTitle, station.displayTitle)
    }
}
