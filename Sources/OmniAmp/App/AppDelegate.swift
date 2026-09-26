import AppKit
import UniformTypeIdentifiers

/// A look the app can show: the modern window or the classic skinned windows.
protocol LookController: PlayerUI {
    func show()
    func dismantle()
}

extension ModernWindowController: LookController {
    func show() { showWindow(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controller: PlayerController!
    private var look: LookController?
    private var keyMonitor: Any?
    private var viewMenu: NSMenu!

    enum Mode: String { case modern, classic }

    private var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "uiMode") ?? "") ?? .modern }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "uiMode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.registerBundled()
        controller = PlayerController()
        buildMenu()
        showLook(ProcessInfo.processInfo.environment["OMNIAMP_MODE"].flatMap(Mode.init(rawValue:)) ?? mode)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()

        // Files passed on the command line (useful for testing: OmniAmp /path/to/folder).
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let urls = args.map { URL(fileURLWithPath: $0) }
        let skins = urls.filter { $0.pathExtension.lowercased() == "wsz" }
        let media = urls.filter { $0.pathExtension.lowercased() != "wsz" }
        if let s = skins.first { loadSkin(s) }
        if !media.isEmpty { controller.add(media) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let s = urls.first(where: { $0.pathExtension.lowercased() == "wsz" }) { loadSkin(s) }
        let media = urls.filter { $0.pathExtension.lowercased() != "wsz" }
        if !media.isEmpty { controller?.add(media) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Looks

    private func showLook(_ m: Mode) {
        look?.dismantle()
        look = nil
        switch m {
        case .modern:
            let w = ModernWindowController(controller: controller)
            w.onClose = { NSApp.terminate(nil) }
            look = w
        case .classic:
            look = makeClassicLook()
            if look == nil { return showLook(.modern) }
        }
        mode = m
        look?.show()
    }

    /// Classic look with the last used skin; asks for one if there is none yet.
    private func makeClassicLook() -> LookController? {
        guard let url = SkinLibrary.current ?? SkinLibrary.installed.first ?? chooseSkinFile() else { return nil }
        let skin: Skin
        do { skin = try Skin(url: url) } catch {
            showSkinError(url, error)
            return nil
        }
        SkinLibrary.current = url
        let look = ClassicLookController(controller: controller, skin: skin, scale: SkinLibrary.scale)
        look.menuProvider = { [weak self] in self?.makeOptionsMenu() ?? NSMenu() }
        look.onSkinDropped = { [weak self] u in self?.loadSkin(u) }
        return look
    }

    /// Install a .wsz and switch to it (entering classic mode if needed).
    func loadSkin(_ url: URL) {
        let installed = SkinLibrary.install(url)
        do {
            let skin = try Skin(url: installed)
            SkinLibrary.current = installed
            if let classic = look as? ClassicLookController {
                classic.apply(skin: skin)
            } else {
                showLook(.classic)
            }
            rebuildViewMenu()
        } catch {
            showSkinError(url, error)
        }
    }

    private func chooseSkinFile() -> URL? {
        let p = NSOpenPanel()
        p.title = "Choose a Winamp skin (.wsz)"
        p.allowedContentTypes = [.init(filenameExtension: "wsz") ?? .zip, .zip]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let u = p.url else { return nil }
        return SkinLibrary.install(u)
    }

    private func showSkinError(_ url: URL, _ error: Error) {
        let a = NSAlert()
        a.messageText = "Couldn't load skin \"\(url.lastPathComponent)\""
        a.informativeText = error.localizedDescription
        a.runModal()
    }

    @objc private func loadSkinMenu(_ sender: Any?) {
        if let u = chooseSkinFile() { loadSkin(u) }
    }

    @objc private func pickInstalledSkin(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { loadSkin(u) }
    }

    @objc private func setScale(_ sender: NSMenuItem) {
        SkinLibrary.scale = CGFloat(sender.tag)
        (look as? ClassicLookController)?.apply(scale: CGFloat(sender.tag))
    }

    /// Menu for the classic options button / right-click.
    private func makeOptionsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Add Files or Folder…", action: #selector(openDoc(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Jump to File…", action: #selector(find(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        addPlaylistItems(to: m)
        m.addItem(eqMenuItem())
        m.addItem(.separator())
        addLookItems(to: m)
        m.addItem(.separator())
        m.addItem(withTitle: "Quit OmniAmp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return m
    }

    private func addLookItems(to m: NSMenu) {
        m.addItem(withTitle: "Modern Look", action: #selector(showModern(_:)), keyEquivalent: m === viewMenu ? "1" : "").target = self
        m.addItem(withTitle: "Classic Skin", action: #selector(showClassic(_:)), keyEquivalent: m === viewMenu ? "2" : "").target = self
        m.addItem(.separator())
        let skinsItem = NSMenuItem(title: "Skins", action: nil, keyEquivalent: "")
        let skins = NSMenu(title: "Skins")
        for u in SkinLibrary.installed {
            let it = skins.addItem(withTitle: u.deletingPathExtension().lastPathComponent, action: #selector(pickInstalledSkin(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = u
            it.state = SkinLibrary.current?.lastPathComponent == u.lastPathComponent ? .on : .off
        }
        if !SkinLibrary.installed.isEmpty { skins.addItem(.separator()) }
        skins.addItem(withTitle: "Load Skin…", action: #selector(loadSkinMenu(_:)), keyEquivalent: "").target = self
        skinsItem.submenu = skins
        m.addItem(skinsItem)
        let scaleItem = NSMenuItem(title: "Classic Size", action: nil, keyEquivalent: "")
        let sm = NSMenu(title: "Classic Size")
        for k in 1...4 {
            let it = sm.addItem(withTitle: "\(k)×", action: #selector(setScale(_:)), keyEquivalent: "")
            it.target = self
            it.tag = k
            it.state = Int(SkinLibrary.scale) == k ? .on : .off
        }
        scaleItem.submenu = sm
        m.addItem(scaleItem)
    }

    @objc private func showModern(_ sender: Any?) { if mode != .modern || look == nil { showLook(.modern) } }
    @objc private func showClassic(_ sender: Any?) { if mode != .classic || look == nil { showLook(.classic) } }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showModern(_:)) { item.state = mode == .modern ? .on : .off }
        if item.action == #selector(showClassic(_:)) { item.state = mode == .classic ? .on : .off }
        if item.action == #selector(toggleEQ(_:)) { item.state = controller.eqSettings.enabled ? .on : .off }
        if item.action == #selector(setScale(_:)) { item.state = Int(SkinLibrary.scale) == item.tag ? .on : .off }
        if item.action == #selector(pickInstalledSkin(_:)) {
            item.state = (item.representedObject as? URL)?.lastPathComponent == SkinLibrary.current?.lastPathComponent ? .on : .off
        }
        return true
    }

    /// Winamp keys, active unless a text field is being edited.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, let c = self.controller else { return ev }
            if ev.window?.firstResponder is NSText { return ev } // typing in the filter
            let mods = ev.modifierFlags.intersection([.command, .control, .option])
            guard mods.isEmpty else { return ev }
            switch ev.charactersIgnoringModifiers?.lowercased() {
            case "z": c.previous()
            case "x": c.playOrResume()
            case "c": c.pause()
            case "v": c.stop()
            case "b": c.next()
            case "j": self.look?.focusFilter()
            case " ": c.togglePlayPause()
            default:
                switch ev.keyCode {
                case 123: c.seek(by: -5)          // ←
                case 124: c.seek(by: 5)           // →
                default: return ev
                }
            }
            return nil
        }
    }

    // MARK: Playlists

    private func addPlaylistItems(to m: NSMenu) {
        let isMain = m.title == "File"
        m.addItem(withTitle: "Open Playlist…", action: #selector(openPlaylist(_:)), keyEquivalent: isMain ? "O" : "").target = self
        m.addItem(withTitle: "Save Playlist As…", action: #selector(savePlaylist(_:)), keyEquivalent: isMain ? "s" : "").target = self
        let item = NSMenuItem(title: "Saved Playlists", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Saved Playlists")
        sub.delegate = self // rebuilt each time it opens
        item.submenu = sub
        m.addItem(item)
    }

    @objc private func openPlaylist(_ sender: Any?) {
        let p = NSOpenPanel()
        p.title = "Open Playlist"
        p.directoryURL = PlaylistFile.directory
        p.allowedContentTypes = PlaylistFile.extensions.compactMap { UTType(filenameExtension: $0) }
        guard p.runModal() == .OK, let u = p.url else { return }
        controller.loadPlaylist(u)
    }

    @objc private func savePlaylist(_ sender: Any?) {
        let p = NSSavePanel()
        p.title = "Save Playlist"
        p.directoryURL = PlaylistFile.directory
        p.nameFieldStringValue = "Playlist.m3u8"
        p.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .m3uPlaylist]
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try controller.savePlaylist(to: u) } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func loadSavedPlaylist(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { controller.loadPlaylist(u) }
    }

    // MARK: Equalizer

    private func eqMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Equalizer", action: nil, keyEquivalent: "")
        let m = NSMenu(title: "Equalizer")
        m.addItem(withTitle: "Equalizer On", action: #selector(toggleEQ(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        for p in Equalizer.presets {
            let it = m.addItem(withTitle: p.name, action: #selector(pickEQPreset(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p.name
        }
        item.submenu = m
        return item
    }

    @objc private func toggleEQ(_ sender: Any?) {
        var s = controller.eqSettings
        s.enabled.toggle()
        controller.setEQ(s)
    }

    @objc private func pickEQPreset(_ sender: NSMenuItem) {
        if let p = Equalizer.presets.first(where: { $0.name == sender.representedObject as? String }) { controller.applyPreset(p) }
    }

    // MARK: Menu

    @objc private func find(_ sender: Any?) { look?.focusFilter() }
    @objc private func openDoc(_ sender: Any?) { controller.showOpenPanel(for: NSApp.keyWindow) }
    @objc private func clear(_ sender: Any?) { controller.clear() }
    @objc private func volUp(_ sender: Any?) { controller.changeVolume(by: 0.05) }
    @objc private func volDown(_ sender: Any?) { controller.changeVolume(by: -0.05) }

    private func buildMenu() {
        let bar = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About OmniAmp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide OmniAmp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit OmniAmp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        bar.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Add Files or Folder…", action: #selector(openDoc(_:)), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Clear Playlist", action: #selector(clear(_:)), keyEquivalent: "\u{8}").target = self
        fileMenu.addItem(.separator())
        addPlaylistItems(to: fileMenu)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        bar.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Jump to Track…", action: #selector(find(_:)), keyEquivalent: "f").target = self
        editItem.submenu = editMenu
        bar.addItem(editItem)

        let viewItem = NSMenuItem()
        viewMenu = NSMenu(title: "View")
        viewMenu.autoenablesItems = true
        viewItem.submenu = viewMenu
        bar.addItem(viewItem)
        rebuildViewMenu()

        let ctlItem = NSMenuItem()
        let ctlMenu = NSMenu(title: "Controls")
        ctlMenu.addItem(withTitle: "Volume Up", action: #selector(volUp(_:)), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!)).target = self
        ctlMenu.addItem(withTitle: "Volume Down", action: #selector(volDown(_:)), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!)).target = self
        ctlMenu.addItem(.separator())
        ctlMenu.addItem(eqMenuItem())
        ctlItem.submenu = ctlMenu
        bar.addItem(ctlItem)

        NSApp.mainMenu = bar
    }

    private func rebuildViewMenu() {
        viewMenu.removeAllItems()
        addLookItems(to: viewMenu)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Fills "Saved Playlists" with the files in the playlists folder.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Saved Playlists" else { return }
        menu.removeAllItems()
        let saved = PlaylistFile.saved
        if saved.isEmpty {
            menu.addItem(withTitle: "No saved playlists", action: nil, keyEquivalent: "").isEnabled = false
        }
        for u in saved {
            let it = menu.addItem(withTitle: u.deletingPathExtension().lastPathComponent, action: #selector(loadSavedPlaylist(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = u
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show in Finder", action: #selector(showPlaylistsFolder(_:)), keyEquivalent: "").target = self
    }

    @objc private func showPlaylistsFolder(_ sender: Any?) {
        NSWorkspace.shared.open(PlaylistFile.directory)
    }
}
