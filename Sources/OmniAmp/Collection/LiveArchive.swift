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

    /// Their recordings on the Live Music Archive, oldest first (a page of `liveArchiveLimit`, from 1), and how
    /// many there are. nil: unreachable.
    func liveArchive(_ artist: String, page: Int = 1) async -> (recordings: [LiveRecording], total: Int)? {
        guard let json = await get(Self.url("https://archive.org/advancedsearch.php", [
            "q": "collection:etree AND creator:\(Self.lucene(artist))", "fl[]": "identifier,date,venue,coverage,source",
            "sort[]": "date asc", "rows": String(Self.liveArchiveLimit), "page": String(page), "output": "json"])) as? [String: Any],
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

/// Downloads from the Live Music Archive into a library folder. Nothing starts without a click; downloads
/// keep going when the page closes (the library window's status bar shows them), and can be cancelled.
/// Files gather in OmniAmp's cache folder and move into the library when the show is complete, so the
/// library never picks up half a show. Quitting pauses a download: the files so far and the list of
/// unfinished ones are kept, and Resume (a click, never on its own) fetches only what's missing.
@MainActor
final class LiveArchiveDownloads {
    static let shared = LiveArchiveDownloads()
    static let changed = Notification.Name("OmniAmpLiveArchiveDownloads")

    enum Format: String, Codable, Sendable { case lossless, mp3 }
    enum State: Equatable {
        case running(done: Int, total: Int)
        /// Stopped by quitting (or a lost connection): the files so far are kept.
        case paused(done: Int, total: Int)
        case finished
        case failed(String)
    }
    struct Job {
        let recording: LiveRecording
        let artist: String
        let format: Format
        var state: State
        var task: Task<Void, Never>?
    }
    /// What's kept between launches: the downloads not finished yet.
    struct Pending: Codable, Equatable {
        let recording: LiveRecording
        let artist: String
        let format: Format
        var total: Int
    }
    private(set) var jobs: [String: Job] = [:]
    private var order: [String] = []
    var states: [String: State] { jobs.mapValues(\.state) }

    /// OmniAmp's cache folder: the partial downloads, and pending.json listing them.
    nonisolated static var directory: URL {
        LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("LiveArchiveDownloads", isDirectory: true)
    }
    nonisolated static func staging(_ id: String) -> URL { directory.appendingPathComponent(safeName(id), isDirectory: true) }
    private static var pendingFile: URL { directory.appendingPathComponent("pending.json") }

    private init() {
        // Unfinished downloads from before: paused, with the files already here counted.
        guard let data = try? Data(contentsOf: Self.pendingFile),
              let pending = try? JSONDecoder().decode([Pending].self, from: data) else { return }
        for p in pending {
            let have = (try? FileManager.default.contentsOfDirectory(atPath: Self.staging(p.recording.id).path))?.count ?? 0
            jobs[p.recording.id] = Job(recording: p.recording, artist: p.artist, format: p.format,
                                       state: .paused(done: min(have, p.total), total: p.total))
            order.append(p.recording.id)
        }
    }

    private func savePending() {
        let pending = order.compactMap { id -> Pending? in
            guard let j = jobs[id] else { return nil }
            switch j.state {
            case .running(_, let total), .paused(_, let total): return Pending(recording: j.recording, artist: j.artist, format: j.format, total: total)
            case .failed: return Pending(recording: j.recording, artist: j.artist, format: j.format, total: 0)
            case .finished: return nil
            }
        }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if pending.isEmpty { try? FileManager.default.removeItem(at: Self.pendingFile) }
        else { try? JSONEncoder().encode(pending).write(to: Self.pendingFile, options: .atomic) }
    }

    var running: [Job] { order.compactMap { id in jobs[id].flatMap { if case .running = $0.state { $0 } else { nil } } } }
    var paused: [Job] { order.compactMap { id in jobs[id].flatMap { if case .paused = $0.state { $0 } else { nil } } } }

    /// For a status bar: what's downloading ("Sharon Van Etten, 2008-06-06 Piano's: 3 of 10 files · 1 more"),
    /// or what's paused; nil when neither.
    var summary: String? {
        func name(_ j: Job) -> String { "\(j.artist), \([j.recording.date, j.recording.venue].compactMap { $0 }.joined(separator: " "))" }
        let run = running, wait = paused
        if let first = run.first, case .running(let done, let total) = first.state {
            let progress = total == 0 ? "starting…" : done >= total ? "adding to your library…" : "\(done + 1) of \(total) files"
            return "⤓ Downloading \(name(first)): " + progress
                + (run.count > 1 ? " · \(run.count - 1) more" : "") + (wait.isEmpty ? "" : " · \(wait.count) paused")
        }
        guard let first = wait.first, case .paused(let done, let total) = first.state else { return nil }
        return wait.count == 1 ? "⏸ Download paused: \(name(first))" + (total > 0 ? ", \(done) of \(total) files" : "")
            : "⏸ \(wait.count) downloads paused"
    }

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

    func isRunning(_ id: String) -> Bool {
        if case .running = jobs[id]?.state { return true }
        return false
    }

    /// A paused or failed download again, in its format: only the missing files.
    func resume(_ id: String) {
        guard let j = jobs[id], !isRunning(id) else { return }
        start(j.recording, artist: j.artist, format: j.format)
    }

    func resumeAll() { paused.forEach { resume($0.recording.id) } }

    func start(_ r: LiveRecording, artist: String, format: Format) {
        guard !isRunning(r.id), let base = folder ?? chooseFolder() else { return }
        let dest = base + "/" + Self.safeName(artist) + "/" + r.folderName
        let staging = Self.staging(r.id)
        // Carrying on from what's already here only in the same format.
        let fresh = jobs[r.id].map { $0.format != format } ?? true
        jobs[r.id] = Job(recording: r, artist: artist, format: format, state: .running(done: 0, total: 0))
        order.removeAll { $0 == r.id }
        order.append(r.id)
        savePending()
        changed()
        jobs[r.id]?.task = Task { [weak self] in
            do {
                // Files and tags off the main thread; only the progress comes back to it.
                try await Task.detached {
                    if fresh { try? FileManager.default.removeItem(at: staging) }
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                }.value
                let item = try await Self.item(r.id, format)
                self?.set(r.id, .running(done: 0, total: item.files.count), save: true)
                for (i, f) in item.files.enumerated() {
                    try Task.checkCancellation()
                    self?.set(r.id, .running(done: i, total: item.files.count))
                    try await Self.download(r.id, f.name, into: staging)
                }
                try Task.checkCancellation()
                // Into the library: not stopped halfway (that would leave half a show there), so no Cancel now.
                self?.installing.insert(r.id)
                self?.set(r.id, .running(done: item.files.count, total: item.files.count))
                defer { self?.installing.remove(r.id) }
                try await Task.detached { try Self.install(item, r, artist: artist, from: staging, to: dest) }.value
                self?.set(r.id, .finished, save: true)
                // The artist's folder: the show may have gone into "… (2)" next to one already there.
                let artistFolder = (dest as NSString).deletingLastPathComponent
                if MusicCollection.shared.roots.contains(where: { artistFolder.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) {
                    MusicCollection.shared.rescan(folder: artistFolder)
                }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                    // Cancelled: nothing kept.
                    Task.detached { try? FileManager.default.removeItem(at: staging) }
                    self?.jobs[r.id] = nil
                    self?.order.removeAll { $0 == r.id }
                    self?.savePending()
                    self?.changed()
                    return
                }
                // Offline or the connection dropped: paused, Resume carries on. Anything else: failed (the files so far
                // stay, so Retry carries on too).
                if let u = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                                                .cannotFindHost, .dnsLookupFailed, .dataNotAllowed].contains(u.code) {
                    let (done, total): (Int, Int) = { if case .running(let d, let t)? = self?.jobs[r.id]?.state { return (d, t) }; return (0, 0) }()
                    self?.set(r.id, .paused(done: done, total: total), save: true)
                    return
                }
                NSLog("OmniAmp: Live Music Archive download of %@ failed: %@", r.id, "\(error)")
                self?.set(r.id, .failed((error as? Failure)?.message ?? error.localizedDescription), save: true)
            }
        }
    }

    /// Being moved into the library right now (can't be cancelled).
    private(set) var installing = Set<String>()

    func cancel(_ id: String) {
        guard !installing.contains(id) else { return }
        if let task = jobs[id]?.task, isRunning(id) { task.cancel(); return }
        // Paused or failed: forget it and its files.
        jobs[id] = nil
        order.removeAll { $0 == id }
        let staging = Self.staging(id)
        Task.detached { try? FileManager.default.removeItem(at: staging) }
        savePending()
        changed()
    }

    private func set(_ id: String, _ s: State, save: Bool = false) {
        jobs[id]?.state = s
        if save { savePending() }
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    struct Failure: Error { let message: String }

    /// One recording's files to fetch, and what archive.org says about them.
    struct Item: Sendable {
        struct File: Sendable { let name: String; var title: String?; var track: String? }
        var files: [File] = []
        var artist: String?
        static func isAudio(_ name: String) -> Bool { ["flac", "mp3"].contains((name as NSString).pathExtension.lowercased()) }
    }

    /// The item's audio in that format (its info text too), with each file's title and track number.
    nonisolated private static func item(_ id: String, _ format: Format) async throws -> Item {
        var req = URLRequest(url: URL(string: "https://archive.org/metadata/\(id)")!, timeoutInterval: 20)
        req.setValue(MetadataLookup.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let files = json["files"] as? [[String: Any]]
        else { throw Failure(message: "archive.org didn't answer") }
        let picked = pick(files, format)
        if picked.isEmpty { throw Failure(message: "no downloadable audio") }
        var item = Item()
        item.artist = (json["metadata"] as? [String: Any])?["creator"] as? String
        item.files = picked.map { name in
            let f = files.first { ($0["name"] as? String) == name }
            return Item.File(name: name, title: (f?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                             track: (f?["track"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return item
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

    nonisolated private static func download(_ id: String, _ name: String, into folder: URL) async throws {
        // Already here from before a pause: files only land here complete (moved in once downloaded).
        let dest = folder.appendingPathComponent(localName(name))
        let debug = ProcessInfo.processInfo.environment["OMNIAMP_DEBUG"] != nil
        if FileManager.default.fileExists(atPath: dest.path) {
            if debug { NSLog("OmniAmp: Live Music Archive: have %@", dest.lastPathComponent) }
            return
        }
        if debug { NSLog("OmniAmp: Live Music Archive: fetching %@", name) }
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
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// Tags each track (while it's still on the local disk), then moves the show into the library: off the main
    /// thread (moving onto a NAS copies every byte).
    nonisolated private static func install(_ item: Item, _ r: LiveRecording, artist: String, from staging: URL, to dest: String) throws {
        func local(_ name: String) -> URL { staging.appendingPathComponent(localName(name)) }
        let notes = item.files.filter { !Item.isAudio($0.name) }.compactMap { f -> String? in
            guard let data = try? Data(contentsOf: local(f.name)) else { return nil }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }.joined(separator: "\n")
        for (file, t) in tags(item, r, artist: artist, notes: notes) {
            _ = TagWriter.write(t, to: local(file).path, backupDir: nil)
        }
        // Never over files already there (your own copy of the show, an earlier download): a folder of its own.
        var folder = dest, n = 2
        while !(ExactPath.contents(ofDirectory: folder) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty {
            folder = dest + " (\(n))"
            n += 1
        }
        let target = URL(exactPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for f in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            try FileManager.default.moveItem(at: f, to: target.appendingExact(f.lastPathComponent))
        }
        try? FileManager.default.removeItem(at: staging)
    }

    /// Each audio file's tags: the artist, the show as the album ("2008-06-25 Zebulon, Brooklyn, NY"), the date,
    /// and the song and its number from archive.org, else from the setlist in the taper's notes.
    nonisolated static func tags(_ item: Item, _ r: LiveRecording, artist: String, notes: String) -> [(String, BasicTags)] {
        let audio = item.files.filter { Item.isAudio($0.name) }
        let setlist = setlist(notes, count: audio.count)
        let album = [r.date, [r.venue, r.city].compactMap { $0 }.joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return audio.enumerated().map { i, f in
            let flac = (f.name as NSString).pathExtension.lowercased() == "flac"
            return (f.name, BasicTags(artist: item.artist ?? artist, album: album.isEmpty ? nil : album,
                                      year: flac ? r.date : r.date.map { String($0.prefix(4)) }, genre: nil,
                                      title: f.title ?? setlist?[i], track: f.track ?? String(i + 1)))
        }
    }

    /// The songs in a taper's notes, in order ("01. I Wish I Knew", "d1t03 - Strong [4:12]"): numbered lines that
    /// count up from 1 (a second disc starting again at 1), as many as there are tracks; nil when they don't add up.
    nonisolated static func setlist(_ text: String, count: Int) -> [String]? {
        guard count > 0 else { return nil }
        let line = try! NSRegularExpression(pattern: #"^\s*(?:d\d+\s*)?t?(\d{1,3})\s*[.):\-]?\s+(.+?)\s*(?:[\[(]?\d{1,2}:\d{2}(?::\d{2})?[\])]?)?\s*$"#,
                                            options: [.caseInsensitive])
        var runs: [[String]] = [], current: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            guard let m = line.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
                  let n = Int(ns.substring(with: m.range(at: 1))) else { continue }
            let title = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty, title.count <= 120 else { continue }
            if n == current.count + 1 { current.append(title) }
            else if n == 1 { if !current.isEmpty { runs.append(current) }; current = [title] }
        }
        if !current.isEmpty { runs.append(current) }
        // One list of the right length, or discs that add up to it.
        if let one = runs.first(where: { $0.count == count }) { return one }
        let all = runs.flatMap { $0 }
        return all.count == count ? all : nil
    }

    /// A file's name in the show's folder: its subfolder kept ("d1/t01.flac" → "d1-t01.flac"), so discs don't collide.
    nonisolated static func localName(_ name: String) -> String { safeName(name) }

    /// A name that's safe as one folder or file name on a NAS: no slashes or colons, precomposed accents.
    nonisolated static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(s.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return (cleaned.isEmpty ? "Unknown" : cleaned).precomposedStringWithCanonicalMapping
    }
}
