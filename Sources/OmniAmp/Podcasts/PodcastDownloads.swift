import Foundation

/// Episodes saved for offline listening, as "Show - Episode.mp3" in a folder the user can pick in Settings
/// (default ~/Music/OmniAmp Podcasts). Two download at a time, the rest wait their turn. A downloaded episode
/// plays from disk (also from the playlist) and is deleted once it has been played to the end. Main-thread only.
final class PodcastDownloads: NSObject, URLSessionDownloadDelegate {
    static let shared = PodcastDownloads()
    /// Something was queued, progressed, finished, failed or was removed. `object`: the episode URL.
    static let changed = Notification.Name("OmniAmp.podcastDownloadsChanged")

    struct Entry: Codable {
        var episode: PodcastEpisode
        var show: PodcastShow
        var file: String        // name inside the downloads folder
        var bytes: Int64
        var date: Double        // when it finished
        /// Set when the file isn't in the downloads folder (it couldn't be moved along when the folder changed).
        var folder: String?
    }

    /// Where an entry's file is.
    private func path(of e: Entry) -> URL { URL(fileURLWithPath: e.folder ?? dir.path, isDirectory: true).appendingPathComponent(e.file) }
    /// A folder change is moving files right now.
    private(set) var isMoving = false

    enum State: Equatable {
        case none
        case queued
        case downloading(Double)   // 0…1 (0 while the size isn't known yet)
        case done
    }

    /// Where the episode files go.
    private(set) var dir: URL
    /// The list of downloads (kept apart from the files, so the folder holds only episodes).
    private let indexURL: URL
    private(set) var entries: [String: Entry] = [:]
    private var waiting: [(PodcastEpisode, PodcastShow)] = []
    private var active: [String: (task: URLSessionDownloadTask, episode: PodcastEpisode, show: PodcastShow, progress: Double)] = [:]
    /// The running downloads in the order they started (a dictionary's order changes: rows would jump).
    private var activeOrder: [String] = []
    /// Why the last attempt for an episode failed (shown until it's tried again).
    private(set) var failures: [String: String] = [:]
    private let maxActive = 2
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpAdditionalHeaders = ["User-Agent": "OmniAmp/1.0"]
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()

    static let folderKey = "podcastDownloadFolder"
    static var defaultFolder: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("OmniAmp Podcasts", isDirectory: true)
    }

    /// `directory` (tests): files and list both there. Otherwise the folder from Settings and the list in
    /// Application Support.
    init(directory: URL? = nil) {
        let support = LibraryCache.fileURL.deletingLastPathComponent().appendingPathComponent("Podcasts", isDirectory: true)
        if let directory {
            dir = directory
            indexURL = directory.appendingPathComponent("downloads.json")
        } else {
            dir = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
            indexURL = support.appendingPathComponent("downloads.json")
        }
        super.init()
        if let d = try? Data(contentsOf: indexURL), let e = try? JSONDecoder().decode([String: Entry].self, from: d) {
            entries = e
            // Forget files deleted in Finder, but only when the folder is there: a drive that isn't mounted yet
            // must not wipe the list (localFile checks each file when it's played anyway).
            if FileManager.default.fileExists(atPath: dir.path) {
                entries = e.filter { entry in
                    let p = path(of: entry.value)
                    return FileManager.default.fileExists(atPath: p.path) || !FileManager.default.fileExists(atPath: p.deletingLastPathComponent().path)
                }
            }
        }
        if directory == nil { adoptEarlyDownloads(from: support.appendingPathComponent("Downloads", isDirectory: true)) }
    }

    /// Downloads made by an early build lived hidden in Application Support under hashed names: move them into
    /// the folder, named properly.
    private func adoptEarlyDownloads(from old: URL) {
        let oldIndex = old.appendingPathComponent("downloads.json")
        guard let d = try? Data(contentsOf: oldIndex), let e = try? JSONDecoder().decode([String: Entry].self, from: d) else { return }
        var left: [String: Entry] = [:]   // couldn't be moved now (folder unavailable…): try again next launch
        for (url, var entry) in e where entries[url] == nil {
            let src = old.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let name = uniqueName(Self.fileName(for: entry.episode, show: entry.show, ext: src.pathExtension))
            guard ensureFolder(), (try? FileManager.default.moveItem(at: src, to: dir.appendingPathComponent(name))) != nil else {
                left[url] = entry
                continue
            }
            entry.file = name
            entries[url] = entry
        }
        save()
        if left.isEmpty {
            try? FileManager.default.removeItem(at: old)
        } else {
            try? JSONEncoder().encode(left).write(to: oldIndex, options: .atomic)
        }
    }

    @discardableResult
    private func ensureFolder() -> Bool {
        (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
    }

    /// The same folder under another spelling (case, a symlink, a trailing slash)?
    static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        // Resource values describe a symlink itself: compare the folders they lead to.
        if let x = try? a.resolvingSymlinksInPath().resourceValues(forKeys: key).fileResourceIdentifier,
           let y = try? b.resolvingSymlinksInPath().resourceValues(forKeys: key).fileResourceIdentifier {
            return x.isEqual(y)
        }
        return a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Use another folder: the downloads already there move along, in the background (across disks that's a
    /// copy). A file that can't be moved stays listed where it is. `completion` (main thread) gets a problem to
    /// show, if there was one.
    func setFolder(_ newFolder: URL, completion: @escaping (String?) -> Void) {
        let new = newFolder.standardizedFileURL
        guard !isMoving else { completion("The downloads are still being moved."); return }
        do { try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true) } catch {
            completion(error.localizedDescription)
            return
        }
        let old = dir
        guard !Self.sameFolder(new, old) else { completion(nil); return }
        isMoving = true
        let jobs = entries.map { ($0.key, path(of: $0.value), $0.value.file) }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var moved: [String: String] = [:], failed: [String] = []
            for (url, src, file) in jobs where fm.fileExists(atPath: src.path) {
                var name = file, n = 2
                while fm.fileExists(atPath: new.appendingPathComponent(name).path) {
                    name = "\((file as NSString).deletingPathExtension) (\(n)).\((file as NSString).pathExtension)"
                    n += 1
                }
                if (try? fm.moveItem(at: src, to: new.appendingPathComponent(name))) != nil { moved[url] = name } else { failed.append(url) }
            }
            DispatchQueue.main.async {
                for (url, name) in moved { self.entries[url]?.file = name; self.entries[url]?.folder = nil }
                // Not moved (or finished downloading while moving): they stay in the old folder, still listed.
                for (url, e) in self.entries where moved[url] == nil && e.folder == nil { self.entries[url]?.folder = old.path }
                self.dir = new
                UserDefaults.standard.set(new.path, forKey: Self.folderKey)
                self.isMoving = false
                self.save()
                NotificationCenter.default.post(name: Self.changed, object: nil)
                completion(failed.isEmpty ? nil : "\(failed.count) episode\(failed.count == 1 ? "" : "s") couldn't be moved: "
                           + "they stay in \((old.path as NSString).abbreviatingWithTildeInPath) and still play.")
            }
        }
    }
    private func save() { try? JSONEncoder().encode(entries).write(to: indexURL, options: .atomic) }
    private func changed(_ url: String) { NotificationCenter.default.post(name: Self.changed, object: url) }

    // MARK: Queries

    func state(_ url: String) -> State {
        if entries[url] != nil { return .done }
        if let a = active[url] { return .downloading(a.progress) }
        if waiting.contains(where: { $0.0.url == url }) { return .queued }
        return .none
    }

    /// The downloaded file, if there is one.
    func localFile(_ url: String) -> URL? {
        guard let e = entries[url] else { return nil }
        let f = path(of: e)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// Newest download first.
    var all: [Entry] { entries.values.sorted { $0.date > $1.date } }
    var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.bytes } }
    var isBusy: Bool { !active.isEmpty || !waiting.isEmpty }
    /// Running, then waiting downloads (for the Downloads list).
    var pending: [(episode: PodcastEpisode, show: PodcastShow)] {
        activeOrder.compactMap { active[$0].map { ($0.episode, $0.show) } } + waiting.map { ($0.0, $0.1) }
    }
    func failure(_ url: String) -> String? { failures[url] }

    // MARK: Actions

    func download(_ e: PodcastEpisode, show: PodcastShow) {
        guard state(e.url) == .none else { return }
        failures.removeValue(forKey: e.url)
        waiting.append((e, show))
        changed(e.url)
        startNext()
    }

    /// Stop a queued or running download.
    func cancel(_ url: String) {
        if let a = active.removeValue(forKey: url) { a.task.cancel() }
        activeOrder.removeAll { $0 == url }
        waiting.removeAll { $0.0.url == url }
        changed(url)
        startNext()
    }

    /// Delete a downloaded episode (or stop it, if it's still coming in).
    func remove(_ url: String) {
        cancel(url)
        guard let e = entries.removeValue(forKey: url) else { return }
        try? FileManager.default.removeItem(at: path(of: e))
        save()
        changed(url)
    }

    private func startNext() {
        while active.count < maxActive, !waiting.isEmpty {
            let (e, show) = waiting.removeFirst()
            guard let u = URL(string: e.url) else { failures[e.url] = "bad address"; changed(e.url); continue }
            let task = session.downloadTask(with: u)
            task.taskDescription = e.url
            active[e.url] = (task, e, show, 0)
            activeOrder.append(e.url)
            task.resume()
            changed(e.url)
        }
    }

    // MARK: URLSessionDownloadDelegate (main queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let url = downloadTask.taskDescription, var a = active[url], totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard p - a.progress >= 0.01 || p >= 1 else { return }   // redraw every percent, not every packet
        a.progress = p
        active[url] = a
        changed(url)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone after this returns: move it now.
        guard let url = downloadTask.taskDescription, let a = active[url] else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failures[url] = "the server answered \(http.statusCode)"
            return
        }
        // A paywall, a login or an expired private link can answer 200 with a web page: not an episode.
        if let mime = downloadTask.response?.mimeType?.lowercased(), mime.hasPrefix("text/") {
            failures[url] = "the server sent a web page, not audio (a login or an expired link?)"
            return
        }
        ensureFolder()
        let name = uniqueName(Self.fileName(for: a.episode, show: a.show, ext: Self.fileExtension(for: url, response: downloadTask.response)))
        let dest = dir.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            failures[url] = error.localizedDescription
            return
        }
        let bytes = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        entries[url] = Entry(episode: a.episode, show: a.show, file: name, bytes: bytes, date: Date().timeIntervalSince1970)
        save()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let url = task.taskDescription, active.removeValue(forKey: url) != nil else { return }
        activeOrder.removeAll { $0 == url }
        if let error, (error as? URLError)?.code != .cancelled {
            failures[url] = AudioPlayer.friendly(error)
            NSLog("OmniAmp: episode download failed: %@", error.localizedDescription)
        }
        changed(url)
        startNext()
    }

    /// "Show - Episode.ext", safe for any file system and not too long.
    static func fileName(for e: PodcastEpisode, show: PodcastShow, ext: String) -> String {
        var base = "\(show.title) - \(e.title)"
            .replacingOccurrences(of: "[/:\\\\?%*|\"<>\\n\\r\\t]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if base.count > 120 { base = String(base.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return (base.isEmpty ? "Episode" : base) + "." + ext
    }

    /// A name not taken in the folder yet: "Name (2).mp3" and so on.
    private func uniqueName(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name, n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(stem) (\(n)).\(ext)"
            n += 1
        }
        return candidate
    }

    /// The extension from the final address or the MIME type (players need it); mp3 if neither says.
    static func fileExtension(for url: String, response: URLResponse?) -> String {
        let fromURL = [response?.url, URL(string: url)].compactMap { $0?.pathExtension.lowercased() }
            .first { ["mp3", "m4a", "aac", "mp4", "ogg", "opus", "wav"].contains($0) }
        let fromType: String? = switch response?.mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/aac": "m4a"
        default: nil
        }
        return fromURL ?? fromType ?? "mp3"
    }
}
