import AppKit
import CryptoKit
import Security

/// OmniAmp → Check for Updates…: only when the user asks (no background checks, ever).
///
/// Reads the latest GitHub release, downloads its DMG, checks it against the SHA-256 GitHub publishes for the
/// file, checks the new app's code signature (and, when this copy is signed with the OmniAmp certificate, that
/// the new one is signed with the same certificate), then swaps the app bundle and relaunches.
enum Updater {
    struct Release {
        var version: String
        var notes: String
        var dmg: URL
        var sha256: String?
        var page: URL
    }

    enum UpdateError: LocalizedError {
        case noRelease, noDMG, checksum, signature(String), notWritable(String), translocated, tool(String)
        var errorDescription: String? {
            switch self {
            case .noRelease: return "Couldn't read the latest release from GitHub."
            case .noDMG: return "The latest release has no OmniAmp DMG to install."
            case .checksum: return "The download doesn't match the checksum GitHub lists for it, so it wasn't installed."
            case .signature(let why): return "The downloaded app failed the signature check (\(why)), so it wasn't installed."
            case .notWritable(let path): return "OmniAmp can't replace itself in \(path). Install the update from the DMG instead."
            case .translocated: return "OmniAmp is running from a temporary location. Move it to the Applications folder first, then check again."
            case .tool(let msg): return msg
            }
        }
    }

    /// The release feed (OMNIAMP_UPDATE_FEED points tests at a local copy).
    static var feed: URL {
        ProcessInfo.processInfo.environment["OMNIAMP_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/Doudini/omniamp/releases/latest")!
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// "0.10" > "0.9"; "v1.2" = "1.2".
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    static func parseRelease(_ data: Data) -> Release? {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = r["tag_name"] as? String, r["draft"] as? Bool != true, r["prerelease"] as? Bool != true,
              let page = (r["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = r["assets"] as? [[String: Any]] ?? []
        guard let dmg = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }),
              let url = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
            return Release(version: tag, notes: r["body"] as? String ?? "", dmg: page, sha256: nil, page: page)
        }
        let digest = (dmg["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), notes: r["body"] as? String ?? "",
                       dmg: url, sha256: digest, page: page)
    }

    static func latest() async throws -> Release {
        var req = URLRequest(url: feed)
        req.setValue("OmniAmp/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 200 < 300, let r = parseRelease(data) else { throw UpdateError.noRelease }
        return r
    }

    // MARK: Install

    /// Download, verify and stage the new app; returns the staged OmniAmp.app.
    static func download(_ r: Release, progress: @escaping (Double) -> Void) async throws -> URL {
        guard r.dmg.pathExtension.lowercased() == "dmg" else { throw UpdateError.noDMG }
        let (bytes, resp) = try await URLSession.shared.bytes(from: r.dmg)
        let total = max(1, resp.expectedContentLength)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OmniAmp-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(r.dmg.lastPathComponent)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let out = try FileHandle(forWritingTo: file)
        var hasher = SHA256()
        var buf = Data(), done: Int64 = 0
        buf.reserveCapacity(1 << 16)
        for try await b in bytes {
            buf.append(b)
            if buf.count >= 1 << 16 {
                hasher.update(data: buf); try out.write(contentsOf: buf)
                done += Int64(buf.count); buf.removeAll(keepingCapacity: true)
                let f = Double(done) / Double(total)
                await MainActor.run { progress(f) }
            }
        }
        hasher.update(data: buf); try out.write(contentsOf: buf)
        try out.close()
        if let want = r.sha256 {
            let got = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard got == want.lowercased() else { throw UpdateError.checksum }
        }
        let app = try extractApp(from: file, into: dir)
        try verify(app)
        return app
    }

    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw UpdateError.tool("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text.prefix(300))") }
        return text
    }

    /// Mount the DMG read-only (hidden from the Finder), copy OmniAmp.app out, unmount.
    private static func extractApp(from dmg: URL, into dir: URL) throws -> URL {
        let mount = dir.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        _ = try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        let src = mount.appendingPathComponent("OmniAmp.app")
        guard FileManager.default.fileExists(atPath: src.path) else { throw UpdateError.noDMG }
        let staged = dir.appendingPathComponent("OmniAmp.app")
        _ = try run("/usr/bin/ditto", [src.path, staged.path])
        return staged
    }

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        return SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess ? code : nil
    }

    /// True when this copy is signed with a certificate (the OmniAmp one), not ad-hoc.
    private static func certificates(of code: SecStaticCode) -> [SecCertificate] {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return [] }
        return d[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
    }

    /// The new app must be a valid, intact OmniAmp; if we're signed with a certificate, it must be the same one.
    static func verify(_ app: URL) throws {
        guard let new = staticCode(app) else { throw UpdateError.signature("unreadable") }
        guard SecStaticCodeCheckValidity(new, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess else {
            throw UpdateError.signature("not validly signed")
        }
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier ?? "com.microbot.omniamp" else {
            throw UpdateError.signature("different app")
        }
        if let current = staticCode(Bundle.main.bundleURL), !certificates(of: current).isEmpty {
            var req: SecRequirement?
            guard SecCodeCopyDesignatedRequirement(current, [], &req) == errSecSuccess, let req,
                  SecStaticCodeCheckValidity(new, [], req) == errSecSuccess else {
                throw UpdateError.signature("not signed with the OmniAmp certificate")
            }
        }
    }

    /// Replace the running app with `newApp` once it has quit, then open the new one.
    static func installAndRelaunch(_ newApp: URL) throws {
        let target = Bundle.main.bundleURL
        if target.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
        let parent = target.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else { throw UpdateError.notWritable(parent) }
        let script = newApp.deletingLastPathComponent().appendingPathComponent("install.sh")
        let q: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        try """
        #!/bin/sh
        # Wait for OmniAmp to quit, swap the bundle (restoring the old one if anything fails), relaunch.
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        T=\(q(target.path)); N=\(q(newApp.path))
        rm -rf "$T.old"
        if mv "$T" "$T.old"; then
          # Only once the old bundle is safely aside: copy the new one, or put the old one back.
          if /usr/bin/ditto "$N" "$T"; then rm -rf "$T.old"; else rm -rf "$T"; mv "$T.old" "$T"; fi
        fi
        /usr/bin/open "$T"
        rm -rf \(q(newApp.deletingLastPathComponent().path))
        """.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        try p.run()
        NSApp.terminate(nil)
    }
}

/// The dialogs around it: checking, "up to date", "a new version", download progress, errors.
final class UpdateUI {
    static let shared = UpdateUI()
    private var busy = false
    private var progressPanel: NSPanel?
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    func check() {
        guard !busy else { progressPanel?.makeKeyAndOrderFront(nil); return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let r = try await Updater.latest()
                guard Updater.isNewer(r.version, than: Updater.currentVersion) else {
                    alert("You're up to date", "OmniAmp \(Updater.currentVersion) is the latest version.")
                    return
                }
                offer(r)
            } catch {
                alert("Couldn't check for updates", error.localizedDescription)
            }
        }
    }

    private func alert(_ title: String, _ text: String, page: URL? = nil) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        if page != nil { a.addButton(withTitle: "Open Download Page") }
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn, let page { NSWorkspace.shared.open(page) }
    }

    private func offer(_ r: Release) {
        let a = NSAlert()
        a.messageText = "OmniAmp \(r.version) is available"
        var notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 900 { notes = String(notes.prefix(900)) + "…" }
        a.informativeText = "You have \(Updater.currentVersion).\(notes.isEmpty ? "" : "\n\n" + notes)"
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Release Notes…")
        a.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: install(r)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(r.page)
        default: break
        }
    }

    typealias Release = Updater.Release

    private func install(_ r: Release) {
        showProgress("Downloading OmniAmp \(r.version)…")
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let app = try await Updater.download(r) { [weak self] f in self?.bar.doubleValue = f }
                label.stringValue = "Installing…"
                bar.isIndeterminate = true
                bar.startAnimation(nil)
                try Updater.installAndRelaunch(app)
            } catch {
                progressPanel?.close()
                progressPanel = nil
                alert("The update wasn't installed", error.localizedDescription, page: r.page)
            }
        }
    }

    private func showProgress(_ text: String) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 86), styleMask: [.titled], backing: .buffered, defer: false)
        p.title = "Updating OmniAmp"
        label.stringValue = text
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 300).isActive = true
        p.contentView = stack
        p.center()
        p.makeKeyAndOrderFront(nil)
        progressPanel = p
    }
}
