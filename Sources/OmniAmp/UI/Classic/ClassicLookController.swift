import AppKit

/// Classic Winamp look: skinned main window with the EQ and playlist docked underneath.
final class ClassicLookController: NSObject, LookController, NSWindowDelegate {
    private let controller: PlayerController
    private(set) var skin: Skin
    private var scale: CGFloat
    private let mainWindow: ClassicWindow
    private let playlistWindow: ClassicWindow
    private let mainView: ClassicMainView
    private let playlistView: ClassicPlaylistView
    private let eqWindow: ClassicWindow
    private let eqView: ClassicEQView
    private var clock: DisplayClock!
    private var tick = 0
    private var jumpPanel: NSPanel?
    private var jumpField: NSSearchField?

    /// Builds the options/right-click menu (owned by the app delegate).
    var menuProvider: (() -> NSMenu)?
    /// Called with dropped .wsz files.
    var onSkinDropped: ((URL) -> Void)?

    private var eqVisible: Bool {
        get { UserDefaults.standard.bool(forKey: "classicEQVisible") }
        set { UserDefaults.standard.set(newValue, forKey: "classicEQVisible") }
    }

    private var playlistVisible: Bool {
        get { UserDefaults.standard.object(forKey: "classicPlaylistVisible") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "classicPlaylistVisible") }
    }

    init(controller: PlayerController, skin: Skin, scale: CGFloat) {
        self.controller = controller
        self.skin = skin
        self.scale = scale
        mainView = ClassicMainView(skin: skin, scale: scale)
        playlistView = ClassicPlaylistView(skin: skin, scale: scale)
        eqView = ClassicEQView(skin: skin, scale: scale)
        eqWindow = ClassicWindow(size: eqView.intrinsicContentSize)
        let savedH = UserDefaults.standard.double(forKey: "classicPlaylistHeight")
        let savedW = UserDefaults.standard.double(forKey: "classicPlaylistWidth")
        playlistView.skinSize = CGSize(width: savedW >= 275 ? savedW : 275, height: savedH >= 116 ? savedH : 232)
        mainWindow = ClassicWindow(size: mainView.intrinsicContentSize)
        playlistWindow = ClassicWindow(size: playlistView.intrinsicContentSize)
        super.init()

        mainView.controller = controller
        playlistView.controller = controller
        eqView.controller = controller
        eqWindow.contentView = eqView
        eqWindow.title = "OmniAmp Equalizer"
        eqWindow.delegate = self
        mainWindow.contentView = mainView
        playlistWindow.contentView = playlistView
        mainWindow.title = "OmniAmp"
        playlistWindow.title = "OmniAmp Playlist"
        mainWindow.delegate = self
        playlistWindow.delegate = self
        if !mainWindow.setFrameUsingName("OmniAmpClassicMain") {
            mainWindow.center()
            mainWindow.setFrameOrigin(NSPoint(x: mainWindow.frame.minX, y: mainWindow.frame.minY + 150))
        }
        mainWindow.setFrameAutosaveName("OmniAmpClassicMain")

        let drop: ([URL]) -> Void = { [weak self] urls in self?.handleDrop(urls) }
        mainView.onDrop = drop
        playlistView.onDrop = drop
        eqView.onDrop = drop
        mainView.onToggleEQ = { [weak self] in self?.toggleEQ() }
        eqView.onClose = { [weak self] in self?.toggleEQ() }
        eqView.onPresets = { [weak self] e, v in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.presetsMenu(), with: e, for: v)
        }
        mainView.onTogglePlaylist = { [weak self] in self?.togglePlaylist() }
        mainView.onMenu = { [weak self] e, v in self?.popMenu(e, in: v) }
        playlistView.onClose = { [weak self] in self?.togglePlaylist() }
        playlistView.onResize = { [weak self] size in self?.playlistResized(size) }

        controller.ui = self
        mainView.playlistVisible = playlistVisible
        mainView.eqVisible = eqVisible
        if let c = controller.currentIndex, let r = controller.row(forTrackIndex: c) { playlistView.select(row: r) }
    }

    // MARK: LookController

    func show() {
        layoutWindows()
        mainWindow.makeKeyAndOrderFront(nil)
        if eqVisible { attach(eqWindow) }
        if playlistVisible { attach(playlistWindow) }
        clock = DisplayClock(player: controller.player) { [weak self] in self?.uiTick() }
        clock.track([mainWindow, playlistWindow, eqWindow])
    }

    func dismantle() {
        clock?.stop()
        jumpPanel?.close()
        mainWindow.removeChildWindow(playlistWindow)
        mainWindow.removeChildWindow(eqWindow)
        playlistWindow.delegate = nil
        eqWindow.delegate = nil
        mainWindow.delegate = nil
        playlistWindow.orderOut(nil)
        eqWindow.orderOut(nil)
        mainWindow.orderOut(nil)
    }

    func setFloating(_ on: Bool) {
        for w in [mainWindow, eqWindow, playlistWindow] { w.level = on ? .floating : .normal }
    }

    func apply(skin: Skin) {
        self.skin = skin
        mainView.skin = skin
        playlistView.skin = skin
        eqView.skin = skin
    }

    func apply(scale: CGFloat) {
        self.scale = scale
        mainView.scale = scale
        playlistView.scale = scale
        eqView.scale = scale
        layoutWindows()
    }

    /// Resize the main window to the current scale, keeping its top-left corner.
    private func layoutWindows() {
        let f = mainWindow.frame
        let size = mainView.intrinsicContentSize
        mainWindow.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
        positionDocked()
    }

    /// Stack main → EQ → playlist, top to bottom (hidden windows take no space).
    private func positionDocked() {
        var y = mainWindow.frame.minY
        let x = mainWindow.frame.minX
        if eqVisible {
            let s = eqView.intrinsicContentSize
            eqWindow.setFrame(NSRect(x: x, y: y - s.height, width: s.width, height: s.height), display: true)
            y -= s.height
        }
        let s = playlistView.intrinsicContentSize
        playlistWindow.setFrame(NSRect(x: x, y: y - s.height, width: s.width, height: s.height), display: true)
    }

    func owns(_ window: NSWindow) -> Bool {
        window === mainWindow || window === playlistWindow || window === eqWindow || window === jumpPanel
    }

    private func attach(_ w: NSWindow) {
        positionDocked()
        mainWindow.addChildWindow(w, ordered: .above)
        w.orderFront(nil)
    }

    private func detach(_ w: NSWindow) {
        mainWindow.removeChildWindow(w)
        w.orderOut(nil)
        positionDocked()
    }

    private func togglePlaylist() {
        playlistVisible.toggle()
        mainView.playlistVisible = playlistVisible
        if playlistVisible { attach(playlistWindow) } else { detach(playlistWindow) }
    }

    /// Classic has no INFO drawer.
    func toggleInfo() { NSSound.beep() }

    func showCurrentTrack() {
        guard let i = controller.currentIndex, let r = controller.row(forTrackIndex: i) else { NSSound.beep(); return }
        if !playlistVisible { togglePlaylist() }
        playlistView.select(row: r)
    }

    func toggleEQ() {
        eqVisible.toggle()
        mainView.eqVisible = eqVisible
        if eqVisible { attach(eqWindow) } else { detach(eqWindow) }
    }

    private func presetsMenu() -> NSMenu {
        let m = NSMenu()
        let on = m.addItem(withTitle: "Equalizer On", action: #selector(toggleEQEnabled), keyEquivalent: "")
        on.target = self
        on.state = controller.eqSettings.enabled ? .on : .off
        m.addItem(.separator())
        for p in Equalizer.presets {
            let it = m.addItem(withTitle: p.name, action: #selector(pickPreset(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p.name
        }
        return m
    }

    @objc private func toggleEQEnabled() {
        var s = controller.eqSettings
        s.enabled.toggle()
        controller.setEQ(s)
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        if let p = Equalizer.presets.first(where: { $0.name == sender.representedObject as? String }) { controller.applyPreset(p) }
    }

    private func playlistResized(_ size: CGSize) {
        UserDefaults.standard.set(Double(size.width), forKey: "classicPlaylistWidth")
        UserDefaults.standard.set(Double(size.height), forKey: "classicPlaylistHeight")
        let top = playlistWindow.frame.maxY
        let px = playlistView.intrinsicContentSize
        playlistWindow.setFrame(NSRect(x: playlistWindow.frame.minX, y: top - px.height, width: px.width, height: px.height), display: true)
    }

    private func handleDrop(_ urls: [URL]) {
        if let s = urls.first(where: { $0.pathExtension.lowercased() == "wsz" }) { onSkinDropped?(s) }
        let media = urls.filter { $0.pathExtension.lowercased() != "wsz" }
        if !media.isEmpty { controller.add(media) }
    }

    private func popMenu(_ event: NSEvent, in view: NSView) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    // MARK: Timer

    private func uiTick() {
        tick += 1
        mainView.advance()
        if tick % 15 == 0, controller.store.isLoadingTags { playlistView.needsDisplay = true }
    }

    // MARK: Window delegate

    func windowDidBecomeKey(_ notification: Notification) { redrawAll() }
    func windowDidResignKey(_ notification: Notification) { redrawAll() }
    private func redrawAll() { [mainView, playlistView, eqView].forEach { $0.needsDisplay = true } }
}

// MARK: - PlayerUI

extension ClassicLookController: PlayerUI {
    func playlistDidReload() { playlistView.reload() }
    func playlistRowsDidUpdate(_ trackIndices: IndexSet) { playlistView.needsDisplay = true; mainView.needsDisplay = true }

    func currentTrackDidChange(old: Int?, new: Int?) {
        mainView.resetMarquee()
        if let n = new, let r = controller.row(forTrackIndex: n) { playlistView.scrollToVisible(r) }
        playlistView.needsDisplay = true
    }

    func playbackStateDidChange() {
        clock.update()
        mainView.stateChanged()
    }

    func optionsDidChange() { mainView.needsDisplay = true; playlistView.needsDisplay = true; eqView.needsDisplay = true }
    func mixDidChange() { mainView.needsDisplay = true; eqView.needsDisplay = true }

    var selectedTrackIndices: IndexSet { playlistView.selectedTrackIndices }

    /// Playlist menus, supplied by the app delegate.
    func setPlaylistMenus(add: @escaping () -> NSMenu, context: @escaping () -> NSMenu, misc: @escaping () -> NSMenu, list: @escaping () -> NSMenu) {
        playlistView.addMenu = add
        playlistView.contextMenu = context
        playlistView.miscMenu = misc
        playlistView.listMenu = list
    }

    var selectedTrackIndex: Int? {
        guard let r = playlistView.selectedRow, r < controller.rowCount else { return nil }
        return controller.trackIndex(forRow: r)
    }

    /// Winamp's "Jump to file": a small panel whose query filters the playlist.
    func focusFilter() {
        if jumpPanel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 44), styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
            p.title = "Jump to file"
            p.appearance = NSAppearance(named: .darkAqua)
            let f = NSSearchField(frame: NSRect(x: 10, y: 10, width: 300, height: 24))
            f.font = Fonts.hack(12)
            f.placeholderString = "Type to filter, ↩ to play, esc to close"
            f.sendsSearchStringImmediately = true
            f.target = self
            f.action = #selector(jumpChanged(_:))
            f.delegate = self
            p.contentView?.addSubview(f)
            p.isReleasedWhenClosed = false
            // Closed with its X button: drop the filter too (it would stay on with nothing showing it).
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
                guard let self, !self.controller.filterQuery.isEmpty else { return }
                self.jumpField?.stringValue = ""
                self.controller.setFilter("")
            }
            jumpPanel = p
            jumpField = f
        }
        guard let p = jumpPanel else { return }
        let m = mainWindow.frame
        p.setFrameTopLeftPoint(NSPoint(x: m.midX - p.frame.width / 2, y: m.maxY - 20))
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(jumpField)
    }

    @objc private func jumpChanged(_ sender: NSSearchField) {
        controller.setFilter(sender.stringValue)
        if controller.rowCount > 0 { playlistView.select(row: 0) }
    }

    private func closeJump(play: Bool) {
        var target: Int?
        if play, let r = playlistView.selectedRow, r < controller.rowCount { target = controller.trackIndex(forRow: r) }
        jumpField?.stringValue = ""
        controller.setFilter("")
        jumpPanel?.orderOut(nil)
        mainWindow.makeKeyAndOrderFront(nil)
        if let t = target {
            controller.play(index: t)
            if let r = controller.row(forTrackIndex: t) { playlistView.select(row: r) }
        }
    }
}

extension ClassicLookController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Shift+Enter plays but keeps the jump window and its results open.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false {
                if let r = playlistView.selectedRow, r < controller.rowCount { controller.play(index: controller.trackIndex(forRow: r)) }
            } else {
                closeJump(play: true)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)): closeJump(play: false); return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let n = controller.rowCount
            guard n > 0 else { return true }
            let cur = playlistView.selectedRow ?? -1
            playlistView.select(row: max(0, min(n - 1, cur + (sel == #selector(NSResponder.moveDown(_:)) ? 1 : -1))))
            return true
        default: return false
        }
    }
}
