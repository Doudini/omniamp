import Foundation

// Paths exactly as the file system spells them.
//
// Foundation rewrites accented names into decomposed form ("é" → "e" + combining accent) when it makes a URL from
// a path string (`URL(fileURLWithPath:)`, `appendingPathComponent`, `standardizedFileURL`) and in FileManager's
// path-string methods. APFS and HFS+ don't mind, but a Linux NFS or SMB server compares bytes: a folder named
// "café" in precomposed form then "doesn't exist", its tracks skip, Show in Finder finds nothing, and a rescan
// would take it for deleted. Paths OmniAmp stores are the bytes the directory listing gave; these helpers keep them.

extension URL {
    /// A file URL for exactly these path bytes.
    init(exactPath path: String, isDirectory: Bool = false) {
        self = path.withCString { URL(fileURLWithFileSystemRepresentation: $0, isDirectory: isDirectory, relativeTo: nil) }
    }

    /// A child of this folder, keeping the bytes of both.
    func appendingExact(_ name: String, isDirectory: Bool = false) -> URL {
        URL(exactPath: path.hasSuffix("/") ? path + name : path + "/" + name, isDirectory: isDirectory)
    }
}

enum ExactPath {
    /// nil when nothing is there; otherwise whether it's a folder (links followed).
    static func kind(_ path: String) -> Bool? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT == S_IFDIR
    }

    static func exists(_ path: String) -> Bool { kind(path) != nil }

    static func isDirectory(_ path: String) -> Bool { kind(path) == true }

    /// Names in a folder (no hidden-file filtering), or nil when it can't be listed.
    static func contents(ofDirectory path: String) -> [String]? {
        (try? FileManager.default.contentsOfDirectory(at: URL(exactPath: path, isDirectory: true), includingPropertiesForKeys: nil))?
            .map(\.lastPathComponent)
    }

    /// Links resolved (realpath), the bytes kept; the path itself when it can't be resolved.
    static func resolved(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    static func read(_ path: String) -> Data? { try? Data(contentsOf: URL(exactPath: path)) }
}
