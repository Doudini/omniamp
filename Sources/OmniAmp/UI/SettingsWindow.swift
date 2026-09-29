import AppKit

/// Settings (⌘,): scrobbling to Last.fm and ListenBrainz, and where podcast downloads go.
final class SettingsWindowController: NSWindowController {
    private let lfmStatus = NSTextField(labelWithString: "")
    private var lfmButton: NSButton!
    private let lbStatus = NSTextField(labelWithString: "")
    private let lbToken = NSSecureTextField()
    private var lbButton: NSButton!
    private let queueLabel = NSTextField(wrappingLabelWithString: "")
    // Own Last.fm API key (instead of the one built into the app).
    private var ownKeyBox: NSButton!
    private let ownKey = NSTextField()
    private let ownSecret = NSSecureTextField()
    private var ownKeyRows: NSStackView!
    private var stack: NSStackView!
    private let folderLabel = NSTextField(labelWithString: "")
    private var folderButtons: [NSButton] = []
    private var authTask: Task<Void, Never>?

    override func cancelOperation(_ sender: Any?) { window?.close() }   // Esc

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "OmniAmp Settings"
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Dash.page
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
        refresh()
        Scrobbler.shared.onChange = { [weak self] in self?.refresh() }
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func header(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: 13)
        return l
    }

    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func build() {
        lfmButton = NSButton(title: "Connect…", target: self, action: #selector(lastfmTapped))
        lbButton = NSButton(title: "Connect", target: self, action: #selector(listenbrainzTapped))
        lbToken.placeholderString = "Paste your ListenBrainz user token"
        let getToken = NSButton(title: "Get token…", target: self, action: #selector(openLBSettings))
        getToken.bezelStyle = .inline
        let sendNow = NSButton(title: "Send Now", target: self, action: #selector(sendNow))

        let lfmRow = NSStackView(views: [lfmStatus, NSView(), lfmButton])
        ownKeyBox = NSButton(checkboxWithTitle: "Use my own Last.fm API key", target: self, action: #selector(ownKeyToggled))
        ownKey.placeholderString = "API key"
        ownSecret.placeholderString = "Shared secret"
        let saveKey = NSButton(title: "Save", target: self, action: #selector(saveOwnKey))
        let getKey = NSButton(title: "Get a key…", target: self, action: #selector(openLastfmAPI))
        getKey.bezelStyle = .inline
        let keyRow = NSStackView(views: [ownKey, ownSecret, saveKey])
        keyRow.distribution = .fillEqually
        ownKeyRows = NSStackView(views: [keyRow, NSStackView(views: [note("Free at last.fm/api/account/create (any app name). Switching keys signs you out of Last.fm; connect again after saving."), getKey])])
        ownKeyRows.orientation = .vertical
        ownKeyRows.alignment = .leading
        ownKeyRows.spacing = 6
        keyRow.widthAnchor.constraint(equalTo: ownKeyRows.widthAnchor).isActive = true
        let lbRow = NSStackView(views: [lbStatus, NSView(), lbButton])
        let tokenRow = NSStackView(views: [lbToken, getToken])
        let queueRow = NSStackView(views: [queueLabel, NSView(), sendNow])
        for r in [lfmRow, lbRow, tokenRow, queueRow] { r.orientation = .horizontal; r.distribution = .fill }
        lbToken.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealDownloads))
        let change = NSButton(title: "Change…", target: self, action: #selector(changeDownloads))
        folderButtons = [reveal, change]
        let folderRow = NSStackView(views: [folderLabel, NSView(), reveal, change])
        folderRow.orientation = .horizontal
        folderRow.distribution = .fill

        let stack = NSStackView(views: [
            header("Last.fm"), lfmRow,
            note("Connecting opens last.fm in your browser; approve OmniAmp there and come back."),
            ownKeyBox, ownKeyRows,
            header("ListenBrainz"), lbRow, tokenRow,
            note("Your token is on listenbrainz.org → Settings. Tokens and sessions are stored in your Keychain."),
            header("Queue"), queueRow,
            note("Plays count after half the track or 4 minutes (tracks over 30 s). Scrobbles made offline are kept and sent later."),
            header("Podcast Downloads"), folderRow,
            note("Episodes you download are saved here as “Show - Episode” and deleted once you’ve listened to the end. Changing the folder moves the downloads already there."),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        for v in stack.arrangedSubviews where v is NSStackView || v.isKind(of: NSTextField.self) && (v as! NSTextField).isEditable == false {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.setCustomSpacing(18, after: ownKeyRows)
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[8])
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[11])
        self.stack = stack
        window?.contentView = stack
        let lfm = LastFM.shared
        ownKeyBox.state = lfm.usesCustomKey || !lfm.hasBuiltInKey ? .on : .off
        ownKey.stringValue = lfm.customKey ?? ""
        ownKeyRows.isHidden = ownKeyBox.state == .off
        fitWindow()
    }

    private func fitWindow() {
        guard let w = window, let stack else { return }
        // The section gap follows whichever is last: the checkbox, or the key fields under it.
        stack.setCustomSpacing(ownKeyRows.isHidden ? 18 : 8, after: ownKeyBox)
        stack.layoutSubtreeIfNeeded()
        var f = w.frame
        let h = stack.fittingSize.height
        let content = w.contentRect(forFrameRect: f)
        f.origin.y += content.height - h
        f.size.height += h - content.height
        w.setFrame(f, display: true, animate: w.isVisible)
    }

    @objc private func ownKeyToggled() {
        ownKeyRows.isHidden = ownKeyBox.state == .off
        // Unticking goes back to the built-in key.
        if ownKeyBox.state == .off, LastFM.shared.usesCustomKey {
            LastFM.shared.setCustomKey(nil, secret: nil)   // queued scrobbles stay; they go out once reconnected
            ownKey.stringValue = ""
            ownSecret.stringValue = ""
        }
        fitWindow()
        refresh()
    }

    @objc private func saveOwnKey() {
        guard !ownKey.stringValue.isEmpty, !ownSecret.stringValue.isEmpty else {
            window?.makeFirstResponder(ownKey.stringValue.isEmpty ? ownKey : ownSecret)
            return
        }
        LastFM.shared.setCustomKey(ownKey.stringValue, secret: ownSecret.stringValue)
        ownSecret.stringValue = ""
        refresh()
    }

    @objc private func openLastfmAPI() { NSWorkspace.shared.open(URL(string: "https://www.last.fm/api/account/create")!) }

    @objc private func revealDownloads() {
        let d = PodcastDownloads.shared.dir
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        NSWorkspace.shared.open(d)
    }

    @objc private func changeDownloads() {
        guard let w = window else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Use This Folder"
        p.message = "Choose where downloaded podcast episodes are saved."
        p.directoryURL = PodcastDownloads.shared.dir.deletingLastPathComponent()
        p.beginSheetModal(for: w) { [weak self] r in
            guard let self, r == .OK, let url = p.url else { return }
            // Moving to another disk copies every file: done in the background, with the buttons held meanwhile.
            self.folderLabel.stringValue = "Moving downloads…"
            self.folderButtons.forEach { $0.isEnabled = false }
            PodcastDownloads.shared.setFolder(url) { [weak self] problem in
                self?.folderButtons.forEach { $0.isEnabled = true }
                self?.refresh()
                guard let problem else { return }
                let a = NSAlert()
                a.messageText = "Some downloads weren't moved"
                a.informativeText = problem
                a.beginSheetModal(for: w)
            }
        }
    }

    func refresh() {
        if !PodcastDownloads.shared.isMoving {
            folderLabel.stringValue = (PodcastDownloads.shared.dir.path as NSString).abbreviatingWithTildeInPath
        }
        folderLabel.toolTip = PodcastDownloads.shared.dir.path
        let lfm = LastFM.shared, lb = ListenBrainz.shared
        let keyNote = lfm.usesCustomKey ? " (your API key)" : ""
        if !lfm.isAvailable {
            lfmStatus.stringValue = "Needs an API key: add your own below"
            lfmButton.isEnabled = false
        } else if lfm.isConnected {
            lfmStatus.stringValue = "✓ Scrobbling as \(lfm.username ?? "your account")" + keyNote
            lfmButton.title = "Disconnect"
            lfmButton.isEnabled = true
        } else if authTask != nil {
            lfmStatus.stringValue = "Waiting for you to approve OmniAmp in the browser…"
            lfmButton.title = "Cancel"
        } else if lfm.needsReconnect {
            lfmStatus.stringValue = "Login expired: reconnect to send what's waiting" + keyNote
            lfmButton.title = "Reconnect…"
            lfmButton.isEnabled = true
        } else {
            lfmStatus.stringValue = "Not connected" + keyNote
            lfmButton.title = "Connect…"
            lfmButton.isEnabled = true
        }
        lbStatus.stringValue = lb.isConnected ? "✓ Scrobbling as \(lb.username ?? "your account")"
            : (lb.needsReconnect ? "Token no longer valid: paste a new one to send what's waiting" : "Not connected")
        lbButton.title = lb.isConnected ? "Disconnect" : "Connect"
        lbToken.isHidden = lb.isConnected
        let s = Scrobbler.shared
        var q = "Waiting to send: Last.fm \(s.pendingCount(lfm.id)) · ListenBrainz \(s.pendingCount(lb.id))"
        for (svc, err) in s.lastError { q += "\n\(svc == lfm.id ? "Last.fm" : "ListenBrainz"): \(err)" }
        queueLabel.stringValue = q
    }

    private func alert(_ title: String, _ error: Error) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = error.localizedDescription
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    @objc private func lastfmTapped() {
        let lfm = LastFM.shared
        if lfm.isConnected { lfm.disconnect(); Scrobbler.shared.clearQueue(lfm.id); refresh(); return }
        if let t = authTask { t.cancel(); authTask = nil; refresh(); return }
        authTask = Task { @MainActor in
            do {
                let (token, url) = try await lfm.beginAuth()
                NSWorkspace.shared.open(url)
                refresh()
                // Poll until approved (the user is in the browser), up to 5 minutes.
                for _ in 0..<100 {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    if (try? await lfm.finishAuth(token: token)) != nil { break }
                }
                if !lfm.isConnected { throw ScrobbleError.auth("Approval timed out. Try again.") }
                Scrobbler.shared.flushAll()
            } catch is CancellationError {
            } catch {
                alert("Couldn't connect to Last.fm", error)
            }
            authTask = nil
            refresh()
        }
        refresh()
    }

    @objc private func listenbrainzTapped() {
        let lb = ListenBrainz.shared
        if lb.isConnected { lb.disconnect(); Scrobbler.shared.clearQueue(lb.id); refresh(); return }
        let token = lbToken.stringValue
        guard !token.isEmpty else { window?.makeFirstResponder(lbToken); return }
        lbButton.isEnabled = false
        Task { @MainActor in
            do {
                try await lb.connect(token: token)
                lbToken.stringValue = ""
                Scrobbler.shared.flushAll()
            } catch {
                alert("Couldn't connect to ListenBrainz", error)
            }
            lbButton.isEnabled = true
            refresh()
        }
    }

    @objc private func openLBSettings() { NSWorkspace.shared.open(URL(string: "https://listenbrainz.org/settings/")!) }
    @objc private func sendNow() { Scrobbler.shared.flushAll() }
}
