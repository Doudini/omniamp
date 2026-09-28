import AppKit

/// A concert on the Live Music Archive (archive.org's etree collection): tapes and soundboards that the
/// artists allow to be shared.
struct LiveRecording: Codable, Sendable, Equatable {
    let id: String          // archive.org identifier
    let date: String?       // "2008-06-06"
    let venue: String?
    let city: String?
    let source: String?     // "SBD", "AUD", "Matrix"

    var url: URL { URL(string: "https://archive.org/details/\(id)")! }

    /// What kind of tape: "SBD", "AUD", "FM", "Matrix" (the source field is often the whole chain of gear).
    var kind: String? {
        guard let s = source?.lowercased(), !s.isEmpty else { return nil }
        let words = Set(s.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if s.contains("matrix") { return "Matrix" }
        if words.contains("sbd") || s.contains("soundboard") || words.contains("board") { return "SBD" }
        if words.contains("fm") || s.contains("broadcast") || s.contains("stream") || s.contains("radio") || words.contains("webcast") { return "FM" }
        if words.contains("aud") || s.contains("audience") || s.contains("mic") { return "AUD" }
        return (source?.count ?? 99) <= 12 ? source : nil
    }

    /// "2008-06-06 Piano's, New York, NY [AUD]": etree style, which the library reads the date and venue from.
    var folderName: String {
        var s = [date, [venue, city].compactMap { $0 }.joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        if let k = kind { s += " [\(k)]" }
        return LiveArchiveDownloads.safeName(s.isEmpty ? id : s)
    }
}

extension MetadataLookup {
    /// At most this many recordings are listed (a link covers the rest).
    static let liveArchiveLimit = 300

    /// Their recordings on the Live Music Archive, oldest first, and how many there are. nil: unreachable.
    func liveArchive(_ artist: String) async -> (recordings: [LiveRecording], total: Int)? {
        guard let json = await get(Self.url("https://archive.org/advancedsearch.php", [
            "q": "collection:etree AND creator:\(Self.lucene(artist))", "fl[]": "identifier,date,venue,coverage,source",
            "sort[]": "date asc", "rows": String(Self.liveArchiveLimit), "output": "json"])) as? [String: Any],
              let response = json["response"] as? [String: Any] else { return nil }
        let docs = (response["docs"] as? [[String: Any]]) ?? []
        func text(_ v: Any?) -> String? { (v as? String) ?? (v as? [String])?.first }
        let list = docs.compactMap { d -> LiveRecording? in
            guard let id = d["identifier"] as? String else { return nil }
            return LiveRecording(id: id, date: text(d["date"]).map { String($0.prefix(10)) }, venue: text(d["venue"]),
                                 city: text(d["coverage"]), source: text(d["source"]))
        }
        return (list, response["numFound"] as? Int ?? list.count)
    }

    static func liveArchiveURL(_ artist: String) -> URL {
        url("https://archive.org/search", ["query": "collection:etree AND creator:\(lucene(artist))"])
    }
}

/// Downloads from the Live Music Archive into a library folder, one recording at a time per click; the
/// library picks them up when they're done. Nothing starts without a click.
@MainActor
final class LiveArchiveDownloads {
    static let shared = LiveArchiveDownloads()
    static let changed = Notification.Name("OmniAmpLiveArchiveDownloads")

    enum Format: Sendable { case lossless, mp3 }
    enum State: Equatable {
        case running(done: Int, total: Int)
        case finished
        case failed(String)
    }
    private(set) var states: [String: State] = [:]

    /// Where downloads go; asks the first time (a library folder, so they show up in the library).
    var folder: String? { UserDefaults.standard.string(forKey: Pref.liveArchiveFolder) }

    @discardableResult
    func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        panel.message = "Where should Live Music Archive downloads go? Each artist gets a folder inside. "
            + "Pick a folder in your music library so they show up there."
        if let f = folder ?? MusicCollection.shared.roots.first { panel.directoryURL = URL(exactPath: f, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: Pref.liveArchiveFolder)
        return url.path
    }

    func start(_ r: LiveRecording, artist: String, format: Format) {
        if case .running = states[r.id] { return }
        guard let base = folder ?? chooseFolder() else { return }
        let dest = base + "/" + Self.safeName(artist) + "/" + r.folderName
        set(r.id, .running(done: 0, total: 0))
        Task {
            do {
                let files = try await Self.files(r.id, format)
                try FileManager.default.createDirectory(at: URL(exactPath: dest, isDirectory: true), withIntermediateDirectories: true)
                for (i, name) in files.enumerated() {
                    set(r.id, .running(done: i, total: files.count))
                    try await Self.download(r.id, name, into: dest)
                }
                set(r.id, .finished)
                if MusicCollection.shared.roots.contains(where: { dest.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) {
                    MusicCollection.shared.rescan(folder: dest)
                }
            } catch {
                NSLog("OmniAmp: Live Music Archive download of %@ failed: %@", r.id, "\(error)")
                set(r.id, .failed((error as? Failure)?.message ?? error.localizedDescription))
            }
        }
    }

    private func set(_ id: String, _ s: State) {
        states[id] = s
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    struct Failure: Error { let message: String }

    /// The item's audio in that format (its info text too), by name.
    private static func files(_ id: String, _ format: Format) async throws -> [String] {
        var req = URLRequest(url: URL(string: "https://archive.org/metadata/\(id)")!, timeoutInterval: 20)
        req.setValue(MetadataLookup.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let files = json["files"] as? [[String: Any]]
        else { throw Failure(message: "archive.org didn't answer") }
        let picked = pick(files, format)
        if picked.isEmpty { throw Failure(message: "no downloadable audio") }
        return picked
    }

    /// Lossless: the FLAC originals (else the MP3s); MP3: the VBR copies archive.org makes. Plus the taper's notes.
    nonisolated static func pick(_ files: [[String: Any]], _ format: Format) -> [String] {
        func named(_ formats: [String]) -> [String] {
            for f in formats {
                let n = files.filter { ($0["format"] as? String) == f }.compactMap { $0["name"] as? String }
                if !n.isEmpty { return n.sorted() }
            }
            return []
        }
        let mp3 = ["VBR MP3", "MP3", "64Kbps MP3"]
        let audio = format == .lossless ? named(["24bit Flac", "Flac"] + mp3) : named(mp3)
        guard !audio.isEmpty else { return [] }
        let notes = files.filter { ($0["format"] as? String) == "Text" && ($0["source"] as? String) == "original" }.compactMap { $0["name"] as? String }
        return audio + notes.sorted()
    }

    private static func download(_ id: String, _ name: String, into folder: String) async throws {
        let path = name.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        guard let url = URL(string: "https://archive.org/download/\(id)/\(path)") else { throw Failure(message: "bad file name") }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue(MetadataLookup.userAgent, forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw Failure(message: status == 401 || status == 403 ? "stream only (the artist doesn't allow downloads)" : "archive.org answered \(status)")
        }
        let dest = URL(exactPath: folder, isDirectory: true).appendingExact(safeName(String(name.split(separator: "/").last ?? "")))
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// A name that's safe as one folder or file name on a NAS: no slashes or colons, precomposed accents.
    nonisolated static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(s.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return (cleaned.isEmpty ? "Unknown" : cleaned).precomposedStringWithCanonicalMapping
    }
}
