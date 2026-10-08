import AppKit

/// What a release carries when it's dragged out of the library, and how a drop reads it back.
///
/// A release with a folder of its own drags that folder (Finder copies it, the playlist adds what's in it). One that
/// shares its folder with other releases (loose downloads told apart by their tags) would bring all of them along, so
/// it drags its own files instead: listed in a private type the playlist reads, with its first file as the file Finder
/// and other apps see.
enum LibraryDrag {
    static let pathsType = NSPasteboard.PasteboardType("com.microbot.omniamp.paths")
    /// A song as OmniAmp has it (tags, a CUE slice, a station or an episode), for drops inside the app: nothing has to
    /// be read again, and what isn't a file (radio, podcasts) can be dragged too.
    static let tracksType = NSPasteboard.PasteboardType("com.microbot.omniamp.track")
    /// Rows of the player's playlist (their row numbers), for reordering it.
    static let playerRowsType = NSPasteboard.PasteboardType("com.omniamp.rows")

    /// One song for a drag: the file (Finder and other apps) and the song itself (OmniAmp).
    static func item(for t: Track) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if !t.isRemote { item.setString(URL(exactPath: t.path).absoluteString, forType: .fileURL) }
        if let data = try? JSONEncoder().encode(t) { item.setData(data, forType: tracksType) }
        return item
    }

    /// The songs dropped, when every item carries one (a drag from OmniAmp's own lists); nil otherwise.
    static func tracks(from pb: NSPasteboard) -> [Track]? {
        let items = pb.pasteboardItems ?? []
        guard !items.isEmpty else { return nil }
        var out: [Track] = []
        for item in items {
            guard let data = item.data(forType: tracksType), let t = try? JSONDecoder().decode(Track.self, from: data) else { return nil }
            out.append(t)
        }
        return out
    }

    @MainActor static func writer(for a: LibraryAlbum, db: CollectionDB?) -> NSPasteboardWriting {
        guard a.sharedFolder, let tracks = try? db?.tracks(album: a.key), !tracks.isEmpty else {
            return URL(exactPath: a.folder, isDirectory: true) as NSURL
        }
        var seen = Set<String>()
        let paths = tracks.map(\.path).filter { seen.insert($0).inserted }   // a CUE image's tracks are one file
        let item = NSPasteboardItem()
        item.setString(URL(exactPath: paths[0]).absoluteString, forType: .fileURL)
        item.setPropertyList(paths, forType: pathsType)
        return item
    }

    /// The songs a drop brings, for adding to a saved playlist: OmniAmp's own as they are; files and folders read off
    /// the main thread (folders and playlists opened, in order) with the library's tags where it has them.
    @MainActor static func droppedTracks(_ pb: NSPasteboard, done: @escaping @MainActor @Sendable ([Track]) -> Void) {
        if let t = tracks(from: pb) { done(t); return }
        let urls = urls(from: pb)
        guard !urls.isEmpty else { done([]); return }
        let library = MusicCollection.hasFolders
        DispatchQueue.global(qos: .userInitiated).async {
            var found = FolderScanner.scan(urls)
            if library, let db = try? CollectionDB(), let known = try? db.tracks(keys: found.map(\.key)) {
                found = found.map { known[$0.key]?.track ?? $0 }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(found) } }
        }
    }

    /// The files dropped, in order: a release's own files where it lists them. A drop without any (Finder, other
    /// apps, a release with a folder of its own) is read exactly as before.
    static func urls(from pb: NSPasteboard) -> [URL] {
        let items = pb.pasteboardItems ?? []
        guard items.contains(where: { $0.types.contains(pathsType) }) else {
            return pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }
        var out: [URL] = []
        for item in items {
            if let paths = item.propertyList(forType: pathsType) as? [String] {
                out += paths.map { URL(exactPath: $0) }
            } else if let s = item.string(forType: .fileURL), let u = URL(string: s), u.isFileURL {
                out.append(u)   // another release in the same drag, written by the library as a plain file URL
            }
        }
        return out
    }
}
