import AppKit

/// Settings (⌘,). Currently: scrobbling to Last.fm and ListenBrainz.
final class SettingsWindowController: NSWindowController {
    private let lfmStatus = NSTextField(labelWithString: "")
    private var lfmButton: NSButton!
    private let lbStatus = NSTextField(labelWithString: "")
    private let lbToken = NSSecureTextField()
    private var lbButton: NSButton!
    private let queueLabel = NSTextField(wrappingLabelWithString: "")
    private var authTask: Task<Void, Never>?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "OmniAmp Settings"
        w.appearance = NSAppearance(named: .darkAqua)
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
        let lbRow = NSStackView(views: [lbStatus, NSView(), lbButton])
        let tokenRow = NSStackView(views: [lbToken, getToken])
        let queueRow = NSStackView(views: [queueLabel, NSView(), sendNow])
        for r in [lfmRow, lbRow, tokenRow, queueRow] { r.orientation = .horizontal; r.distribution = .fill }
        lbToken.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let stack = NSStackView(views: [
            header("Last.fm"), lfmRow,
            note("Connecting opens last.fm in your browser; approve OmniAmp there and come back."),
            header("ListenBrainz"), lbRow, tokenRow,
            note("Your token is on listenbrainz.org → Settings. Tokens and sessions are stored in your Keychain."),
            header("Queue"), queueRow,
            note("Plays count after half the track or 4 minutes (tracks over 30 s). Scrobbles made offline are kept and sent later."),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        for v in stack.arrangedSubviews where v is NSStackView || v.isKind(of: NSTextField.self) && (v as! NSTextField).isEditable == false {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[2])
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[6])
        window?.contentView = stack
    }

    func refresh() {
        let lfm = LastFM.shared, lb = ListenBrainz.shared
        if !lfm.isAvailable {
            lfmStatus.stringValue = "Not available in this build (no Last.fm API key)"
            lfmButton.isEnabled = false
        } else if lfm.isConnected {
            lfmStatus.stringValue = "✓ Scrobbling as \(lfm.username ?? "your account")"
            lfmButton.title = "Disconnect"
            lfmButton.isEnabled = true
        } else if authTask != nil {
            lfmStatus.stringValue = "Waiting for you to approve OmniAmp in the browser…"
            lfmButton.title = "Cancel"
        } else {
            lfmStatus.stringValue = "Not connected"
            lfmButton.title = "Connect…"
            lfmButton.isEnabled = true
        }
        lbStatus.stringValue = lb.isConnected ? "✓ Scrobbling as \(lb.username ?? "your account")" : "Not connected"
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
