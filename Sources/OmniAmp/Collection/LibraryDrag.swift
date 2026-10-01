import AppKit

/// What a release carries when it's dragged out of the library, and how a drop reads it back.
///
/// A release with a folder of its own drags that folder (Finder copies it, the playlist adds what's in it). One that
/// shares its folder with other releases (loose downloads told apart by their tags) would bring all of them along, so
/// it drags its own files instead: listed in a private type the playlist reads, with its first file as the file Finder
/// and other apps see.
enum LibraryDrag {
    static let pathsType = NSPasteboard.PasteboardType("com.microbot.omniamp.paths")

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
