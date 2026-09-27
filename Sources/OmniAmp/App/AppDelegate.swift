import AppKit
import UniformTypeIdentifiers

/// A look the app can show: the modern window or the classic skinned windows.
protocol LookController: PlayerUI {
    func show()
    func dismantle()
    /// Always on top.
    func setFloating(_ on: Bool)
    /// One of this look's own windows (the Winamp keys only apply there).
    func owns(_ window: NSWindow) -> Bool
}

extension ModernWindowController: LookController {
    func show() { showWindow(nil) }
    func setFloating(_ on: Bool) { window?.level = on ? .floating : .normal }
    func owns(_ window: NSWindow) -> Bool { window === self.window }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controller: PlayerController!
    private var look: LookController?
    private var keyMonitor: Any?
    private var signalSources: [DispatchSourceSignal] = []
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
        // OMNIAMP_MODE (tests) picks a look for this run only; it must not overwrite the user's choice.
        if let forced = ProcessInfo.processInfo.environment["OMNIAMP_MODE"].flatMap(Mode.init(rawValue:)) {
            showLook(forced, persist: false)
        } else {
            showLook(mode)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Test hook: OMNIAMP_SETTINGS=1 opens the Settings window at launch.
        if ProcessInfo.processInfo.environment["OMNIAMP_SETTINGS"] != nil { showSettings(nil) }
        if ProcessInfo.processInfo.environment["OMNIAMP_RADIO"] != nil { showRadio(nil) }
        if ProcessInfo.processInfo.environment["OMNIAMP_PODCASTS"] != nil { showPodcasts(nil) }
        // Test hook: OMNIAMP_HIDE=1 hides the app after launch (for measuring background playback).
        if ProcessInfo.processInfo.environment["OMNIAMP_HIDE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.hide(nil) }
        }
        installKeyMonitor()
        // Quit cleanly on SIGTERM/SIGINT too, so the audio device gets its sample rate and access back.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }

        // Files passed on the command line (useful for testing: OmniAmp /path/to/folder).
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let urls = args.map { URL(fileURLWithPath: $0) }
        let skins = urls.filter { $0.pathExtension.lowercased() == "wsz" }
        let media = urls.filter { $0.pathExtension.lowercased() != "wsz" }
        if let s = skins.first { loadSkin(s) }
        if !media.isEmpty { controller.add(media) }
        if !openedBeforeLaunch.isEmpty {
            let pending = openedBeforeLaunch
            openedBeforeLaunch = []
            application(NSApp, open: pending)
        }
    }

    /// Files opened before launch finished (double-clicking a file while OmniAmp isn't running): AppKit
    /// delivers them before applicationDidFinishLaunching, when there's no player or window yet.
    private var openedBeforeLaunch: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        guard controller != nil, viewMenu != nil else { openedBeforeLaunch += urls; return }
        if let s = urls.first(where: { $0.pathExtension.lowercased() == "wsz" }) { loadSkin(s) }
        let media = urls.filter { $0.pathExtension.lowercased() != "wsz" }
        if !media.isEmpty { controller.add(media) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Looks

    private func showLook(_ m: Mode, persist: Bool = true) {
        look?.dismantle()
        look = nil
        if !controller.filterQuery.isEmpty { controller.setFilter("") }   // the new look has no field showing it
        MemoryTrim.soon(after: 3)   // launch, or the old look's windows and images
        switch m {
        case .modern:
            let w = ModernWindowController(controller: controller)
            w.onClose = { NSApp.terminate(nil) }
            w.playlistMenu = { [weak self] in self?.makePlaylistContextMenu() ?? NSMenu() }
            w.onRadio = { [weak self] in self?.showRadio(nil) }
            w.onPodcasts = { [weak self] in self?.showPodcasts(nil) }
            w.addMenuProvider = { [weak self] in self?.makeAddMenu() ?? NSMenu() }
            look = w
        case .classic:
            look = makeClassicLook()
            if look == nil { return showLook(.modern) }
        }
        if persist { mode = m }
        look?.show()
        look?.setFloating(alwaysOnTop)
    }

    /// Classic look with the last used skin, else the built-in Winamp base skin.
    private func makeClassicLook() -> LookController? {
        guard let url = SkinLibrary.active ?? chooseSkinFile() else { return nil }
        let skin: Skin
        do { skin = try Skin(url: url) } catch {
            showSkinError(url, error)
            return nil
        }
        SkinLibrary.current = url
        let look = ClassicLookController(controller: controller, skin: skin, scale: SkinLibrary.scale)
        look.menuProvider = { [weak self] in self?.makeOptionsMenu() ?? NSMenu() }
        look.onSkinDropped = { [weak self] u in self?.loadSkin(u) }
        look.setPlaylistMenus(add: { [weak self] in self?.makeAddMenu() ?? NSMenu() },
                              context: { [weak self] in self?.makePlaylistContextMenu() ?? NSMenu() },
                              misc: { [weak self] in self?.makeSortMenu() ?? NSMenu() },
                              list: { [weak self] in self?.makeListMenu() ?? NSMenu() })
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

    private var settings: SettingsWindowController?
    private var radio: RadioWindowController?

    private var podcasts: PodcastWindowController?

    @objc private func showPodcasts(_ sender: Any?) {
        if podcasts == nil { podcasts = PodcastWindowController(controller: controller) }
        podcasts?.showWindow(nil)
        podcasts?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showRadio(_ sender: Any?) {
        if radio == nil { radio = RadioWindowController(controller: controller) }
        radio?.showWindow(nil)
        radio?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindowController() }
        settings?.refresh()
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Quick wins

    private var alwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: "alwaysOnTop") }
        set { UserDefaults.standard.set(newValue, forKey: "alwaysOnTop") }
    }

    @objc private func toggleOnTop(_ sender: Any?) {
        alwaysOnTop.toggle()
        look?.setFloating(alwaysOnTop)
    }
    @objc private func toggleStopAfter(_ sender: Any?) { controller.stopAfterCurrent.toggle() }
    @objc private func setSleep(_ sender: NSMenuItem) { controller.setSleepTimer(minutes: sender.tag == 0 ? nil : sender.tag) }
    @objc private func toggleResume(_ sender: Any?) { controller.resumeLongTracks.toggle() }
    @objc private func setSpeed(_ sender: NSMenuItem) { controller.setSpeed(Float(sender.representedObject as? Double ?? 1)) }
    @objc private func setReplayGain(_ sender: NSMenuItem) {
        if let m = PlayerController.ReplayGainMode(rawValue: sender.representedObject as? String ?? "") { controller.replayGainMode = m }
    }
    @objc private func setAnalyzer(_ sender: NSMenuItem) {
        if let m = Analyzer.Mode(rawValue: sender.representedObject as? String ?? "") { Analyzer.mode = m }
    }
    @objc private func removeDuplicates(_ sender: Any?) {
        let n = controller.removeDuplicates()
        let a = NSAlert()
        a.messageText = n == 0 ? "No duplicates found." : "Removed \(n) duplicate\(n == 1 ? "" : "s")."
        a.runModal()
    }

    @objc private func pickPlaylistFont(_ sender: NSMenuItem) {
        if let f = PlaylistStyle.Font(rawValue: sender.representedObject as? String ?? "") { PlaylistStyle.font = f }
    }
    @objc private func toggleNumbers(_ sender: Any?) { PlaylistStyle.showNumbers.toggle() }

    /// Themes apply to the modern look; rebuilding its window picks up every color at once.
    @objc private func pickTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != Theme.palette.id else { return }
        Theme.select(id)
        if mode == .modern, look is ModernWindowController { showLook(.modern) }
    }

    @objc private func setScale(_ sender: NSMenuItem) {
        SkinLibrary.scale = CGFloat(sender.tag)
        (look as? ClassicLookController)?.apply(scale: CGFloat(sender.tag))
    }

    /// Menu for the classic options button / right-click.
    private func makeOptionsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Add Files or Folder…", action: #selector(openDoc(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Add URL…", action: #selector(addURL(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Jump to File…", action: #selector(find(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Internet Radio…", action: #selector(showRadio(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Podcasts…", action: #selector(showPodcasts(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        addPlaylistItems(to: m)
        m.addItem(eqMenuItem())
        let outItem = NSMenuItem(title: "Output", action: nil, keyEquivalent: "")
        let outMenu = NSMenu(title: "Output")
        fillOutputMenu(outMenu)
        outItem.submenu = outMenu
        m.addItem(outItem)
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
        let themeItem = NSMenuItem(title: "Modern Theme", action: nil, keyEquivalent: "")
        let themes = NSMenu(title: "Modern Theme")
        for t in ThemePalette.all {
            let it = themes.addItem(withTitle: t.name, action: #selector(pickTheme(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = t.id
        }
        themeItem.submenu = themes
        m.addItem(themeItem)
        let anItem = NSMenuItem(title: "Visualizer", action: nil, keyEquivalent: "")
        let an = NSMenu(title: "Visualizer")
        for mode in Analyzer.Mode.allCases {
            let it = an.addItem(withTitle: mode.title, action: #selector(setAnalyzer(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
        }
        anItem.submenu = an
        m.addItem(anItem)
        m.addItem(withTitle: "Always on Top", action: #selector(toggleOnTop(_:)), keyEquivalent: "").target = self
        let fontItem = NSMenuItem(title: "Playlist Font", action: nil, keyEquivalent: "")
        let fonts = NSMenu(title: "Playlist Font")
        for f in PlaylistStyle.Font.allCases {
            let it = fonts.addItem(withTitle: f.title, action: #selector(pickPlaylistFont(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = f.rawValue
        }
        fonts.addItem(.separator())
        fonts.addItem(withTitle: "Show Track Numbers", action: #selector(toggleNumbers(_:)), keyEquivalent: "").target = self
        fontItem.submenu = fonts
        m.addItem(fontItem)
        let skinsItem = NSMenuItem(title: "Skins", action: nil, keyEquivalent: "")
        let skins = NSMenu(title: "Skins")
        if let b = SkinLibrary.bundled {
            let it = skins.addItem(withTitle: SkinLibrary.bundledTitle, action: #selector(pickInstalledSkin(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = b
            if !SkinLibrary.installed.isEmpty { skins.addItem(.separator()) }
        }
        for u in SkinLibrary.installed {
            let it = skins.addItem(withTitle: u.deletingPathExtension().lastPathComponent, action: #selector(pickInstalledSkin(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = u
        }
        if SkinLibrary.bundled != nil || !SkinLibrary.installed.isEmpty { skins.addItem(.separator()) }
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
        if item.action == #selector(toggleOnTop(_:)) { item.state = alwaysOnTop ? .on : .off }
        if item.action == #selector(toggleStopAfter(_:)) { item.state = controller.stopAfterCurrent ? .on : .off }
        if item.action == #selector(toggleResume(_:)) { item.state = controller.resumeLongTracks ? .on : .off }
        if item.action == #selector(setSleep(_:)) {
            let left = controller.sleepAt.map { Int(ceil($0.timeIntervalSinceNow / 60)) }
            item.state = (item.tag == 0 && left == nil) ? .on : .off
            if item.tag == 0, let l = left { item.title = "Off  (\(l) min left)" } else if item.tag == 0 { item.title = "Off" }
        }
        if item.action == #selector(setReplayGain(_:)) {
            item.state = (item.representedObject as? String) == controller.replayGainMode.rawValue ? .on : .off
            item.toolTip = controller.player.bitPerfect ? "Bypassed in bit-perfect mode." : nil
        }
        if item.action == #selector(setSpeed(_:)) {
            // Only for podcast episodes and web files; remembered per show.
            item.state = abs(Float(item.representedObject as? Double ?? 0) - controller.currentSpeed) < 0.01 ? .on : .off
            return controller.currentTrack?.isEpisode == true
        }
        if item.action == #selector(setAnalyzer(_:)) { item.state = (item.representedObject as? String) == Analyzer.mode.rawValue ? .on : .off }
        if item.action == #selector(pickPlaylistFont(_:)) { item.state = (item.representedObject as? String) == PlaylistStyle.font.rawValue ? .on : .off }
        if item.action == #selector(toggleNumbers(_:)) { item.state = PlaylistStyle.showNumbers ? .on : .off }
        if item.action == #selector(pickTheme(_:)) { item.state = (item.representedObject as? String) == Theme.palette.id ? .on : .off }
        if item.action == #selector(setScale(_:)) { item.state = Int(SkinLibrary.scale) == item.tag ? .on : .off }
        if item.action == #selector(pickInstalledSkin(_:)) {
            item.state = (item.representedObject as? URL)?.standardizedFileURL.path == SkinLibrary.active?.standardizedFileURL.path ? .on : .off
        }
        return true
    }

    /// Winamp keys, in the player's own windows (not the radio/podcast lists or open panels), unless a text
    /// field is being edited. Held keys don't repeat, except the seek arrows.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, let c = self.controller, let w = ev.window, self.look?.owns(w) == true else { return ev }
            if w.firstResponder is NSText { return ev } // typing in the filter
            if ev.isARepeat, ev.keyCode != 123, ev.keyCode != 124 { return nil }
            let mods = ev.modifierFlags.intersection([.command, .control, .option])
            guard mods.isEmpty else { return ev }
            switch ev.charactersIgnoringModifiers?.lowercased() {
            case "z": c.previous()
            case "x": c.playOrResume()
            case "c": c.pause()
            case "v":
                if ev.modifierFlags.contains(.shift) { c.stopAfterCurrent.toggle() } else { c.stop() }
            case "b": c.next()
            case "j": self.look?.focusFilter()
            case "q": self.queueSelected(nil)
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
        let wItem = NSMenuItem(title: "Watched Folders", action: nil, keyEquivalent: "")
        let wMenu = NSMenu(title: "Watched Folders")
        wMenu.delegate = self
        wItem.submenu = wMenu
        m.addItem(wItem)
    }

    // MARK: Watched folders

    private func fillWatchedMenu(_ m: NSMenu) {
        m.removeAllItems()
        let roots = controller.folders.roots
        if roots.isEmpty {
            m.addItem(withTitle: "No watched folders", action: nil, keyEquivalent: "").isEnabled = false
        }
        for r in roots {
            let it = NSMenuItem(title: (r as NSString).abbreviatingWithTildeInPath, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, sel) in [("Show in Finder", #selector(revealWatched(_:))),
                                 ("Stop Watching", #selector(unwatch(_:))),
                                 ("Stop Watching and Remove Its Tracks", #selector(unwatchAndRemove(_:)))] {
                let s = sub.addItem(withTitle: title, action: sel, keyEquivalent: "")
                s.target = self
                s.representedObject = r
            }
            it.submenu = sub
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Watch a Folder…", action: #selector(watchFolder(_:)), keyEquivalent: "").target = self
        let rescan = m.addItem(withTitle: "Rescan Now", action: roots.isEmpty ? nil : #selector(rescanWatched(_:)), keyEquivalent: "")
        rescan.target = self
    }

    @objc private func watchFolder(_ sender: Any?) {
        let p = NSOpenPanel()
        p.title = "Watch a Folder"
        p.message = "OmniAmp adds this folder's music and keeps the playlist in sync when files are added, changed or deleted."
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        p.urls.forEach(controller.folders.add)
    }

    @objc private func revealWatched(_ sender: NSMenuItem) {
        if let r = sender.representedObject as? String { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: r) }
    }
    @objc private func unwatch(_ sender: NSMenuItem) {
        if let r = sender.representedObject as? String { controller.folders.remove(r, removeTracks: false) }
    }
    @objc private func unwatchAndRemove(_ sender: NSMenuItem) {
        if let r = sender.representedObject as? String { controller.folders.remove(r, removeTracks: true) }
    }
    @objc private func rescanWatched(_ sender: Any?) { controller.folders.rescanAll() }

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

    // MARK: Playlist editing

    @objc private func playSelectedTrack(_ sender: Any?) {
        if let i = look?.selectedTrackIndex { controller.play(index: i) }
    }
    @objc private func queueSelected(_ sender: Any?) { controller.toggleQueue(trackIndices: look?.selectedTrackIndices ?? []) }
    @objc private func clearQueue(_ sender: Any?) { controller.clearQueue() }
    @objc private func removeSelected(_ sender: Any?) { controller.remove(trackIndices: look?.selectedTrackIndices ?? []) }
    @objc private func reversePlaylist(_ sender: Any?) { controller.reverse() }
    @objc private func randomizePlaylist(_ sender: Any?) { controller.randomize() }
    @objc private func sortPlaylist(_ sender: NSMenuItem) {
        if let k = PlayerController.SortKey(rawValue: sender.representedObject as? String ?? "") { controller.sort(by: k) }
    }
    @objc private func revealSelected(_ sender: Any?) {
        let urls = (look?.selectedTrackIndices ?? []).map { controller.tracks[$0].url }.filter(\.isFileURL)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    @objc private func removeDeadFiles(_ sender: Any?) {
        controller.removeDeadFiles { n in
            let a = NSAlert()
            a.messageText = n == 0 ? "No missing files found." : "Removed \(n) missing file\(n == 1 ? "" : "s") from the playlist."
            a.runModal()
        }
    }

    private func item(_ title: String, _ action: Selector, _ m: NSMenu, key: String = "", mods: NSEvent.ModifierFlags = .command) {
        let it = m.addItem(withTitle: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = self
    }

    /// Sort / reverse / randomize (also the classic MISC button).
    private func makeSortMenu() -> NSMenu {
        let m = NSMenu(title: "Sort")
        for k in PlayerController.SortKey.allCases {
            let it = m.addItem(withTitle: "Sort by \(k.rawValue)", action: #selector(sortPlaylist(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = k.rawValue
        }
        m.addItem(.separator())
        item("Reverse List", #selector(reversePlaylist(_:)), m)
        item("Randomize List", #selector(randomizePlaylist(_:)), m)
        return m
    }

    /// New / open / save (the classic LIST button).
    private func makeListMenu() -> NSMenu {
        let m = NSMenu(title: "List")
        item("New Playlist (Clear)", #selector(clear(_:)), m)
        addPlaylistItems(to: m)
        m.addItem(.separator())
        item("Remove Missing Files", #selector(removeDeadFiles(_:)), m)
        return m
    }

    /// Right-click on playlist rows.
    private func makePlaylistContextMenu() -> NSMenu {
        let m = NSMenu(title: "Track")
        fillTrackItems(m, withKeys: false)
        return m
    }

    private func fillTrackItems(_ m: NSMenu, withKeys: Bool) {
        let sel = look?.selectedTrackIndices ?? []
        let allQueued = !sel.isEmpty && sel.allSatisfy { controller.queuePosition(of: $0) != nil }
        item("Play", #selector(playSelectedTrack(_:)), m)
        item(allQueued ? "Unqueue  (Q)" : "Queue Next  (Q)", #selector(queueSelected(_:)), m)
        if !controller.playQueue.isEmpty { item("Clear Queue (\(controller.playQueue.count))", #selector(clearQueue(_:)), m) }
        item("Remove", #selector(removeSelected(_:)), m)
        item("Show in Finder", #selector(revealSelected(_:)), m, key: withKeys ? "r" : "")
        m.addItem(.separator())
        let sortItem = NSMenuItem(title: "Sort", action: nil, keyEquivalent: "")
        sortItem.submenu = makeSortMenu()
        m.addItem(sortItem)
        item("Remove Missing Files", #selector(removeDeadFiles(_:)), m)
        item("Remove Duplicates", #selector(removeDuplicates(_:)), m)
    }

    // MARK: Output

    private func fillOutputMenu(_ m: NSMenu) {
        m.removeAllItems()
        let p = controller.player
        let def = m.addItem(withTitle: "System Default", action: #selector(pickOutput(_:)), keyEquivalent: "")
        def.target = self
        def.state = p.selectedOutputUID == nil ? .on : .off
        for d in AudioDevices.outputDevices() {
            let it = m.addItem(withTitle: d.name, action: #selector(pickOutput(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = d.uid
            it.state = p.selectedOutputUID == d.uid ? .on : .off
            let rates = d.rates.map { $0.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int($0 / 1000))" : String(format: "%.1f", $0 / 1000) }
            it.toolTip = rates.isEmpty ? nil : "Supports " + rates.joined(separator: ", ") + " kHz"
        }
        m.addItem(.separator())
        let bp = m.addItem(withTitle: "Bit-Perfect Mode", action: #selector(toggleBitPerfect(_:)), keyEquivalent: "")
        bp.target = self
        bp.state = p.bitPerfect ? .on : .off
        bp.toolTip = "Switch the device to each file's sample rate and bypass EQ and software volume."
        let ex = m.addItem(withTitle: "Exclusive Access", action: p.bitPerfect ? #selector(toggleExclusive(_:)) : nil, keyEquivalent: "")
        ex.target = self
        ex.state = p.exclusive ? .on : .off
        ex.toolTip = "Keep other apps and system sounds off the device while OmniAmp plays (bit-perfect mode only)."
        m.addItem(.separator())
        let rate = p.deviceRate
        let info = m.addItem(withTitle: "\(p.deviceName) · \(rate > 0 ? String(format: rate.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0f kHz" : "%.1f kHz", rate / 1000) : "—")",
                             action: nil, keyEquivalent: "")
        info.isEnabled = false
    }

    @objc private func pickOutput(_ sender: NSMenuItem) { controller.setOutputDevice(uid: sender.representedObject as? String) }
    @objc private func toggleBitPerfect(_ sender: Any?) { controller.setBitPerfect(!controller.player.bitPerfect) }
    @objc private func toggleExclusive(_ sender: Any?) { controller.setExclusive(!controller.player.exclusive) }

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
    /// Only when asked: there are no automatic update checks.
    @objc private func checkForUpdates(_ sender: Any?) { UpdateUI.shared.check() }

    @objc private func openDoc(_ sender: Any?) { controller.showOpenPanel(for: NSApp.keyWindow) }
    @objc private func openFiles(_ sender: Any?) { controller.showOpenPanel(for: NSApp.keyWindow, kind: .files) }
    @objc private func openFolder(_ sender: Any?) { controller.showOpenPanel(for: NSApp.keyWindow, kind: .folder) }

    /// The ADD button's menu (both looks), like Winamp's ADD FILE / ADD DIR / ADD URL.
    func makeAddMenu() -> NSMenu {
        let m = NSMenu(title: "Add")
        m.addItem(withTitle: "Add Files…", action: #selector(openFiles(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Add Folder…", action: #selector(openFolder(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Add URL…", action: #selector(addURL(_:)), keyEquivalent: "").target = self
        return m
    }

    /// Add URL: a stream, a station playlist, a podcast feed / Apple Podcasts link, or a web audio file.
    @objc func addURL(_ sender: Any?) {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        AddURL.ask(title: "Add URL",
                   message: "A radio stream, a .pls / .m3u playlist, a podcast feed or Apple Podcasts link, or an audio file on the web.",
                   in: window) { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                do {
                    self.handle(try await URLProbe.probe(text))
                } catch {
                    AddURL.show(error, in: window)
                }
            }
        }
    }

    private func handle(_ result: URLProbe.Result) {
        var added: Int?
        switch result {
        case .station(let url, let name):
            added = controller.addStation(url: url, name: name ?? AddURL.fallbackName(url))
        case .stations(let list):
            for s in list {
                let i = controller.addStation(url: s.url, name: s.name ?? AddURL.fallbackName(s.url))
                if added == nil { added = i }
            }
        case .file(let url, let title):
            added = controller.addEpisode(.webFile(url, title: title))
        case .podcast(let show):
            showPodcasts(nil)
            podcasts?.present(show, subscribe: false)
        }
        // Like Winamp's Open Location: start it if nothing is playing.
        if let i = added, controller.player.state == .stopped { controller.play(index: i) }
    }
    @objc private func clear(_ sender: Any?) { controller.clear() }
    @objc private func volUp(_ sender: Any?) { controller.changeVolume(by: 0.05) }
    @objc private func volDown(_ sender: Any?) { controller.changeVolume(by: -0.05) }

    private func buildMenu() {
        let bar = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About OmniAmp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide OmniAmp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit OmniAmp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        bar.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Add Files or Folder…", action: #selector(openDoc(_:)), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Add URL…", action: #selector(addURL(_:)), keyEquivalent: "l").target = self
        let radio = fileMenu.addItem(withTitle: "Internet Radio…", action: #selector(showRadio(_:)), keyEquivalent: "r")
        radio.keyEquivalentModifierMask = [.command, .option]
        radio.target = self
        let pods = fileMenu.addItem(withTitle: "Podcasts…", action: #selector(showPodcasts(_:)), keyEquivalent: "p")
        pods.keyEquivalentModifierMask = [.command, .option]
        pods.target = self
        fileMenu.addItem(withTitle: "Clear Playlist", action: #selector(clear(_:)), keyEquivalent: "").target = self
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

        let plItem = NSMenuItem()
        let plMenu = NSMenu(title: "Playlist")
        plMenu.delegate = self // rebuilt when opened
        plItem.submenu = plMenu
        bar.addItem(plItem)

        let outItem = NSMenuItem()
        let outMenu = NSMenu(title: "Output")
        outMenu.delegate = self
        outItem.submenu = outMenu
        bar.addItem(outItem)

        let ctlItem = NSMenuItem()
        let ctlMenu = NSMenu(title: "Controls")
        ctlMenu.addItem(withTitle: "Volume Up", action: #selector(volUp(_:)), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!)).target = self
        ctlMenu.addItem(withTitle: "Volume Down", action: #selector(volDown(_:)), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!)).target = self
        ctlMenu.addItem(.separator())
        let sac = ctlMenu.addItem(withTitle: "Stop After Current  (⇧V)", action: #selector(toggleStopAfter(_:)), keyEquivalent: "")
        sac.target = self
        let sleepItem = NSMenuItem(title: "Sleep Timer", action: nil, keyEquivalent: "")
        let sleep = NSMenu(title: "Sleep Timer")
        for m in [0, 15, 30, 45, 60, 90] {
            let it = sleep.addItem(withTitle: m == 0 ? "Off" : "\(m) minutes", action: #selector(setSleep(_:)), keyEquivalent: "")
            it.target = self
            it.tag = m
        }
        sleepItem.submenu = sleep
        ctlMenu.addItem(sleepItem)
        ctlMenu.addItem(withTitle: "Resume Long Tracks", action: #selector(toggleResume(_:)), keyEquivalent: "").target = self
        let speedItem = NSMenuItem(title: "Podcast Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu(title: "Podcast Speed")
        for sp in PlayerController.speeds {
            let it = speedMenu.addItem(withTitle: String(format: "%g×", sp), action: #selector(setSpeed(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = Double(sp)
        }
        speedItem.submenu = speedMenu
        ctlMenu.addItem(speedItem)
        ctlMenu.addItem(.separator())
        let rgItem = NSMenuItem(title: "ReplayGain", action: nil, keyEquivalent: "")
        let rg = NSMenu(title: "ReplayGain")
        for mode in PlayerController.ReplayGainMode.allCases {
            let it = rg.addItem(withTitle: mode.title, action: #selector(setReplayGain(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
        }
        rgItem.submenu = rg
        ctlMenu.addItem(rgItem)
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
    /// Asked on every shortcut press, before AppKit would rebuild each of these menus just to search them
    /// (the device list comes from Core Audio, the playlist menus from disk). Answer without rebuilding:
    /// only the Playlist menu has a shortcut, ⌘R.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        guard menu.title == "Playlist", event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "r" else { return false }
        target.pointee = self
        action.pointee = #selector(revealSelected(_:))
        return true
    }

    /// Fills "Saved Playlists" with the files in the playlists folder.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Watched Folders" {
            fillWatchedMenu(menu)
            return
        }
        if menu.title == "Output" {
            fillOutputMenu(menu)
            return
        }
        if menu.title == "Playlist" {
            menu.removeAllItems()
            fillTrackItems(menu, withKeys: true)
            return
        }
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
