import AppKit
import UniformTypeIdentifiers

/// A look the app can show: the modern window or the classic skinned windows.
@MainActor
protocol LookController: PlayerUI {
    func show()
    func dismantle()
    /// Always on top.
    func setFloating(_ on: Bool)
    /// One of this look's own windows (the Winamp keys only apply there).
    func owns(_ window: NSWindow) -> Bool
    /// L: select the playing track in the playlist and scroll to it.
    func showCurrentTrack()
    /// I / E: the INFO drawer (modern) and the equalizer.
    func toggleInfo()
    func toggleEQ()
}

extension ModernWindowController: LookController {
    func show() { showWindow(nil) }
    func setFloating(_ on: Bool) { window?.level = on ? .floating : .normal }
    func owns(_ window: NSWindow) -> Bool { window === self.window }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controller: PlayerController!
    private var look: LookController?
    private var winampKeys: WinampKeys?
    private var signalSources: [DispatchSourceSignal] = []
    private var viewMenu: NSMenu!

    enum Mode: String { case modern, classic }

    private var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: Pref.uiMode) ?? "") ?? .modern }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Pref.uiMode) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.registerBundled()
        controller = PlayerController()
        controller.startServices()
        buildMenu()
        // OMNIAMP_MODE (tests) picks a look for this run only; it must not overwrite the user's choice.
        if let forced = ProcessInfo.processInfo.environment["OMNIAMP_MODE"].flatMap(Mode.init(rawValue:)) {
            showLook(forced, persist: false)
        } else {
            showLook(mode)
        }
        // Test hook: OMNIAMP_BACKGROUND=1 leaves the app in the background (screenshots without taking the keyboard).
        if ProcessInfo.processInfo.environment["OMNIAMP_BACKGROUND"] == nil { NSApp.activate(ignoringOtherApps: true) }
        // Test hook: OMNIAMP_SETTINGS=1 opens the Settings window at launch.
        if ProcessInfo.processInfo.environment["OMNIAMP_SETTINGS"] != nil { showSettings(nil) }
        if ProcessInfo.processInfo.environment["OMNIAMP_ABOUT"] != nil { showAbout(nil) }
        // Test hook: OMNIAMP_PLAY=<row> plays that playlist row (from 1) at launch, e.g. for screenshots.
        if let row = ProcessInfo.processInfo.environment["OMNIAMP_PLAY"].flatMap(Int.init), row > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.controller.play(index: row - 1) }
        }
        if ProcessInfo.processInfo.environment["OMNIAMP_RADIO"] != nil { showRadio(nil) }
        if ProcessInfo.processInfo.environment["OMNIAMP_PODCASTS"] != nil { showPodcasts(nil) }
        if ProcessInfo.processInfo.environment["OMNIAMP_LIBRARY"] != nil { showLibrary(nil) }
        // The music library catches up in the background, once the playlist has loaded.
        if MusicCollection.hasFolders {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MusicCollection.shared.start() }
        }
        // Test hook: OMNIAMP_HIDE=1 hides the app after launch (for measuring background playback).
        if ProcessInfo.processInfo.environment["OMNIAMP_HIDE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.hide(nil) }
        }
        winampKeys = WinampKeys(controller: controller, look: { [weak self] in self?.look },
                                queueSelected: { [weak self] in self?.queueSelected(nil) })
        // Quit cleanly on SIGTERM/SIGINT too, so the audio device gets its sample rate and access back.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.quitBySignal = true   // no one to ask: downloads just stay paused
                NSApp.terminate(nil)
            }
            src.resume()
            signalSources.append(src)
        }

        // Files passed on the command line (useful for testing: OmniAmp /path/to/folder).
        // Handled like files opened from Finder (skins, OPML subscriptions, media).
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if !args.isEmpty { application(NSApp, open: args.map { URL(exactPath: $0) }) }
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
        open(urls)
    }

    /// Every way files arrive (Finder, the command line, drops on either look) ends here: skins load,
    /// OPML subscriptions go to Podcasts, everything else joins the playlist (at `position` for a drop).
    func open(_ urls: [URL], at position: Int? = nil) {
        if let s = urls.first(where: { $0.pathExtension.lowercased() == "wsz" }) { loadSkin(s) }
        for o in urls where o.pathExtension.lowercased() == "opml" {   // podcast subscriptions from another app
            showPodcasts(nil)
            podcasts?.importOPML(o)
        }
        let media = urls.filter { !["wsz", "opml"].contains($0.pathExtension.lowercased()) }
        if !media.isEmpty { controller.add(media, at: position) }
    }

    private var quitBySignal = false

    /// Live Music Archive downloads still running: ask first (quitting pauses them; Resume carries on later).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = LiveArchiveDownloads.shared.running
        guard !running.isEmpty, !quitBySignal else { return .terminateNow }
        let a = NSAlert()
        a.messageText = running.count == 1 ? "A download is still running" : "\(running.count) downloads are still running"
        a.informativeText = "Quit anyway? The files downloaded so far are kept: Resume in the Music Library carries on with the rest."
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Keep Downloading")
        return a.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
            w.onLibrary = { [weak self] in self?.showLibrary(nil) }
            w.addMenuProvider = { [weak self] in self?.makeAddMenu() ?? NSMenu() }
            w.onOpenFiles = { [weak self] urls, row in self?.open(urls, at: row) }
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
        look.onOpenFiles = { [weak self] urls in self?.open(urls) }
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
    private var shortcuts: ShortcutsWindowController?

    @objc private func showShortcuts(_ sender: Any?) {
        if shortcuts == nil { shortcuts = ShortcutsWindowController() }
        shortcuts?.showWindow(nil)
        shortcuts?.window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘M: the classic look's docked playlist/EQ go down with their main window (they're its children).
    @objc private func minimizeWindow(_ sender: Any?) {
        guard let w = NSApp.keyWindow ?? NSApp.mainWindow else { NSSound.beep(); return }
        (w.parent ?? w).miniaturize(nil)
    }

    /// ⌘1: the main window of whichever look is on.
    @objc private func showPlayer(_ sender: Any?) {
        look?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    private var podcasts: PodcastWindowController?
    private var library: LibraryWindowController?

    @objc private func showLibrary(_ sender: Any?) {
        let wasOpen = library?.window?.isVisible == true
        if library == nil {
            library = LibraryWindowController(controller: controller)
            // Closing frees the window and its lists (the library itself keeps watching its folders).
            library?.onClose = { [weak self] in
                DispatchQueue.main.async { self?.library = nil; MemoryTrim.soon() }
            }
        }
        library?.showWindow(nil)
        library?.window?.makeKeyAndOrderFront(nil)
        if !wasOpen { library?.focusList() }
    }

    @objc private func toggleLibrary(_ sender: Any?) {
        if let w = library?.window, w.isVisible, w.isKeyWindow { w.performClose(nil) } else { showLibrary(nil) }
    }

    @objc private func showPodcasts(_ sender: Any?) {
        let wasOpen = podcasts?.window?.isVisible == true
        if podcasts == nil {
            podcasts = PodcastWindowController(controller: controller)
            // Closing frees the window and its lists: they're rebuilt (from caches) when it opens again.
            podcasts?.onClose = { [weak self] in
                DispatchQueue.main.async { self?.podcasts = nil; MemoryTrim.soon() }
            }
        }
        podcasts?.showWindow(nil)
        podcasts?.window?.makeKeyAndOrderFront(nil)
        if !wasOpen { podcasts?.focusList() }   // already open: keep your place (search, episodes…)
    }

    /// ⌘D keeps the selected thing: a station as a favorite (Radio), an episode as a download (Podcasts).
    /// The menu item's title follows the window in front (validateMenuItem).
    @objc private func keepSelection(_ sender: Any?) {
        if let p = podcasts, NSApp.keyWindow === p.window { p.downloadFromMenu() } else { radio?.toggleFavoriteFromMenu() }
    }
    @objc private func toggleEpisodeNotes(_ sender: Any?) { podcasts?.toggleNotesFromMenu() }
    @objc private func toggleUnplayedOnly(_ sender: Any?) { podcasts?.toggleUnplayedFromMenu() }

    @objc private func toggleRadio(_ sender: Any?) {
        if let w = radio?.window, w.isVisible, w.isKeyWindow { w.performClose(nil) } else { showRadio(nil) }
    }

    @objc private func togglePodcasts(_ sender: Any?) {
        if let w = podcasts?.window, w.isVisible, w.isKeyWindow { w.performClose(nil) } else { showPodcasts(nil) }
    }

    /// ⌃Tab in Radio (POPULAR ⇄ FAVORITES) or Podcasts (TOP ⇄ SUBSCRIBED).
    @objc private func switchView(_ sender: Any?) {
        if let p = podcasts, NSApp.keyWindow === p.window { p.toggleView() }
        else if let r = radio, NSApp.keyWindow === r.window { r.toggleView() }
        else { NSSound.beep() }
    }

    @objc private func showRadio(_ sender: Any?) {
        let wasOpen = radio?.window?.isVisible == true
        if radio == nil {
            radio = RadioWindowController(controller: controller)
            radio?.onClose = { [weak self] in
                DispatchQueue.main.async { self?.radio = nil; MemoryTrim.soon() }
            }
        }
        radio?.showWindow(nil)
        radio?.window?.makeKeyAndOrderFront(nil)
        if !wasOpen { radio?.focusList() }
    }

    /// The standard About panel with the crew's message and greetings under the version.
    @objc private func showAbout(_ sender: Any?) {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
                                                   .paragraphStyle: center]
        let credits = NSMutableAttributedString()
        func add(_ s: String, _ extra: [NSAttributedString.Key: Any] = [:]) {
            credits.append(NSAttributedString(string: s, attributes: base.merging(extra) { $1 }))
        }
        add("Made by Pirates. For Pirates!\n", [.font: NSFont.boldSystemFont(ofSize: 12)])
        add("© 2026 OMNIKORP KOLLEKTIV\n")
        add("www.microbot.ch", [.link: URL(string: "https://www.microbot.ch")!])
        add("\n\nGreetings: rarz, jesar, wes21, Hiroshi Takeda, hund, rtz23, daeil kim, paul, seth, noriko, lgr, popolon",
            [.foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindowController() }
        settings?.refresh()
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Quick wins

    private var alwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: Pref.alwaysOnTop) }
        set { UserDefaults.standard.set(newValue, forKey: Pref.alwaysOnTop) }
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
        rebuildModern()
    }

    @objc private func pickFinish(_ sender: NSMenuItem) {
        guard let f = Finish(rawValue: sender.representedObject as? String ?? ""), f != Theme.finish else { return }
        Theme.selectFinish(f)
        rebuildModern()
    }

    private func rebuildModern() {
        guard mode == .modern, let old = look as? ModernWindowController else { return }
        // The rebuilt window picks up where you were: the same rows selected, the list focused.
        let picked = old.selectedTrackIndices
        showLook(.modern)
        (look as? ModernWindowController)?.restoreSelection(picked)
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
        m.addItem(withTitle: "Music Library…", action: #selector(showLibrary(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        addPlaylistItems(to: m)
        m.addItem(eqMenuItem())
        let outItem = NSMenuItem(title: "Output", action: nil, keyEquivalent: "")
        let outMenu = NSMenu(title: "Output")
        outMenu.identifier = MenuID.output
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
        // ⌃⌘1 / ⌃⌘2: plain ⌘1–3 open the windows (Window menu).
        let modern = m.addItem(withTitle: "Modern Look", action: #selector(showModern(_:)), keyEquivalent: m === viewMenu ? "1" : "")
        let classic = m.addItem(withTitle: "Classic Skin", action: #selector(showClassic(_:)), keyEquivalent: m === viewMenu ? "2" : "")
        for it in [modern, classic] {
            it.target = self
            it.keyEquivalentModifierMask = [.command, .control]
        }
        m.addItem(.separator())
        // The display's color, then the finish of the windows around it.
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themes = NSMenu(title: "Theme")
        for t in ThemePalette.all {
            let it = themes.addItem(withTitle: t.name, action: #selector(pickTheme(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = t.id
        }
        themes.addItem(.separator())
        for f in Finish.allCases {
            let it = themes.addItem(withTitle: f.name, action: #selector(pickFinish(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = f.rawValue
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
        if item.action == #selector(keepSelection(_:)) {
            if let p = podcasts, NSApp.keyWindow === p.window {
                item.title = "Download Episode"
                return p.canDownloadSelection
            }
            item.title = "Favorite Station"
            guard let r = radio, NSApp.keyWindow === r.window else { return false }
            return r.canToggleFavorite
        }
        if item.action == #selector(toggleEpisodeNotes(_:)) || item.action == #selector(toggleUnplayedOnly(_:)) {
            if item.action == #selector(toggleUnplayedOnly(_:)) { item.state = UserDefaults.standard.bool(forKey: Pref.podcastUnplayedOnly) ? .on : .off }
            return podcasts != nil && NSApp.keyWindow === podcasts?.window
        }
        if item.action == #selector(switchView(_:)) {
            let key = NSApp.keyWindow
            return key != nil && (key === podcasts?.window || key === radio?.window)
        }
        if item.action == #selector(showModern(_:)) { item.state = mode == .modern ? .on : .off }
        if item.action == #selector(showClassic(_:)) { item.state = mode == .classic ? .on : .off }
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
        if item.action == #selector(pickFinish(_:)) { item.state = (item.representedObject as? String) == Theme.finish.rawValue ? .on : .off }
        if item.action == #selector(setScale(_:)) { item.state = Int(SkinLibrary.scale) == item.tag ? .on : .off }
        if item.action == #selector(pickInstalledSkin(_:)) {
            item.state = (item.representedObject as? URL)?.standardizedFileURL.path == SkinLibrary.active?.standardizedFileURL.path ? .on : .off
        }
        return true
    }

    // MARK: Playlists

    private func addPlaylistItems(to m: NSMenu) {
        let isMain = m.identifier == MenuID.file
        m.addItem(withTitle: "Open Playlist…", action: #selector(openPlaylist(_:)), keyEquivalent: isMain ? "O" : "").target = self
        m.addItem(withTitle: "Save Playlist As…", action: #selector(savePlaylist(_:)), keyEquivalent: isMain ? "s" : "").target = self
        let item = NSMenuItem(title: "Saved Playlists", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Saved Playlists")
        sub.identifier = MenuID.savedPlaylists
        sub.delegate = self // rebuilt each time it opens
        item.submenu = sub
        m.addItem(item)
        let wItem = NSMenuItem(title: "Watched Folders", action: nil, keyEquivalent: "")
        let wMenu = NSMenu(title: "Watched Folders")
        wMenu.identifier = MenuID.watched
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
    @objc private func showInLibraryArtist(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? [String] else { return }
        showLibrary(nil)
        library?.revealArtist(p[0])
    }
    @objc private func showInLibrarySong(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? [String] else { return }
        showLibrary(nil)
        library?.revealSong(artist: p[0], titleKey: p[1])
    }
    @objc private func showInLibraryAlbum(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? [String] else { return }
        showLibrary(nil)
        library?.revealAlbum(artist: p[0], album: p[2])
    }

    @objc private func revealSelected(_ sender: Any?) {
        // Files, and podcast episodes that were downloaded.
        let urls = (look?.selectedTrackIndices ?? []).compactMap { i -> URL? in
            let t = controller.tracks[i]
            return t.isEpisode ? PodcastDownloads.shared.localFile(t.path) : (t.url.isFileURL ? t.url : nil)
        }
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
        // A track that's in the music library: its artist, song or release there.
        if sel.count == 1, MusicCollection.hasFolders, let i = sel.first, i < controller.tracks.count,
           let place = try? MusicCollection.shared.reader?.place(ofTrack: controller.tracks[i].key) {
            let sub = NSMenu(title: "Show in Music Library")
            func add(_ title: String, _ action: Selector) {
                let it = sub.addItem(withTitle: title, action: action, keyEquivalent: "")
                it.target = self
                it.representedObject = [place.artist, place.song, place.album]
            }
            add("Artist Page (\(place.artistName))", #selector(showInLibraryArtist(_:)))
            add("All Versions of This Song", #selector(showInLibrarySong(_:)))
            add("Album", #selector(showInLibraryAlbum(_:)))
            let entry = NSMenuItem(title: "Show in Music Library", action: nil, keyEquivalent: "")
            entry.submenu = sub
            m.addItem(entry)
        }
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
        item.submenu = EQMenu.make(controller)
        return item
    }

    // MARK: Menu

    @objc private func filterEpisodes(_ sender: Any?) {
        showPodcasts(nil)
        podcasts?.focusEpisodeFilter()
    }

    @objc private func find(_ sender: Any?) {
        // ⌘F searches in whichever window is in front.
        if let p = podcasts, NSApp.keyWindow === p.window { p.focusSearch(); return }
        if let r = radio, NSApp.keyWindow === r.window { r.focusSearch(); return }
        if let l = library, NSApp.keyWindow === l.window { l.focusSearch(); return }
        // From Settings, the shortcuts list…: bring the player forward first (its field would be invisible).
        if let k = NSApp.keyWindow, look?.owns(k) != true { look?.show() }
        look?.focusFilter()
    }
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
        appMenu.addItem(withTitle: "About OmniAmp", action: #selector(showAbout(_:)), keyEquivalent: "").target = self
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
        fileMenu.identifier = MenuID.file
        fileMenu.addItem(withTitle: "Add Files or Folder…", action: #selector(openDoc(_:)), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Add URL…", action: #selector(addURL(_:)), keyEquivalent: "l").target = self
        let radio = fileMenu.addItem(withTitle: "Internet Radio…", action: #selector(showRadio(_:)), keyEquivalent: "r")
        radio.keyEquivalentModifierMask = [.command, .option]
        radio.target = self
        // A menu item, so it works from the station list and while typing in the Radio search alike.
        // ⌘D is "keep this": favorite in Radio, download in Podcasts (the title follows the window in front).
        fileMenu.addItem(withTitle: "Favorite Station", action: #selector(keepSelection(_:)), keyEquivalent: "d").target = self
        fileMenu.addItem(withTitle: "Show Episode Notes", action: #selector(toggleEpisodeNotes(_:)), keyEquivalent: "i").target = self
        let unplayed = fileMenu.addItem(withTitle: "Unplayed Episodes Only", action: #selector(toggleUnplayedOnly(_:)), keyEquivalent: "u")
        unplayed.keyEquivalentModifierMask = [.command, .shift]
        unplayed.target = self
        let pods = fileMenu.addItem(withTitle: "Podcasts…", action: #selector(showPodcasts(_:)), keyEquivalent: "p")
        pods.keyEquivalentModifierMask = [.command, .option]
        pods.target = self
        let lib = fileMenu.addItem(withTitle: "Music Library…", action: #selector(showLibrary(_:)), keyEquivalent: "l")
        lib.keyEquivalentModifierMask = [.command, .option]
        lib.target = self
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
        let filterItem = editMenu.addItem(withTitle: "Filter Podcast Episodes", action: #selector(filterEpisodes(_:)), keyEquivalent: "f")
        filterItem.keyEquivalentModifierMask = [.command, .shift]
        filterItem.target = self
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
        plMenu.identifier = MenuID.playlist
        plMenu.delegate = self // rebuilt when opened
        plItem.submenu = plMenu
        bar.addItem(plItem)

        let outItem = NSMenuItem()
        let outMenu = NSMenu(title: "Output")
        outMenu.identifier = MenuID.output
        outMenu.delegate = self
        outItem.submenu = outMenu
        bar.addItem(outItem)

        let ctlItem = NSMenuItem()
        let ctlMenu = NSMenu(title: "Controls")
        // + and − work in the player windows (the key monitor); ⌘↑/⌘↓ now move through the playlist.
        ctlMenu.addItem(withTitle: "Volume Up  (+)", action: #selector(volUp(_:)), keyEquivalent: "").target = self
        ctlMenu.addItem(withTitle: "Volume Down  (−)", action: #selector(volDown(_:)), keyEquivalent: "").target = self
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

        // Window: jump between OmniAmp's windows without the mouse.
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Player", action: #selector(showPlayer(_:)), keyEquivalent: "1").target = self
        // ⌘2 / ⌘3 toggle: open the window, or close it when it's the one in front.
        winMenu.addItem(withTitle: "Internet Radio", action: #selector(toggleRadio(_:)), keyEquivalent: "2").target = self
        winMenu.addItem(withTitle: "Podcasts", action: #selector(togglePodcasts(_:)), keyEquivalent: "3").target = self
        winMenu.addItem(withTitle: "Music Library", action: #selector(toggleLibrary(_:)), keyEquivalent: "4").target = self
        let switchView = winMenu.addItem(withTitle: "Switch View", action: #selector(switchView(_:)), keyEquivalent: "\t")
        switchView.keyEquivalentModifierMask = [.control]
        switchView.target = self
        winMenu.addItem(.separator())
        // Our own action: the classic look's borderless windows can't performMiniaturize.
        winMenu.addItem(withTitle: "Minimize", action: #selector(minimizeWindow(_:)), keyEquivalent: "m").target = self
        winItem.submenu = winMenu
        bar.addItem(winItem)
        // (Not NSApp.windowsMenu: AppKit would add every window again below the entries above.)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showShortcuts(_:)), keyEquivalent: "/").target = self
        helpItem.submenu = helpMenu
        bar.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = bar
    }

    private func rebuildViewMenu() {
        viewMenu.removeAllItems()
        addLookItems(to: viewMenu)
    }
}

/// The menus the app fills or answers for itself (by identity, not by their titles).
enum MenuID {
    static let file = NSUserInterfaceItemIdentifier("omniamp.file")
    static let playlist = NSUserInterfaceItemIdentifier("omniamp.playlist")
    static let output = NSUserInterfaceItemIdentifier("omniamp.output")
    static let savedPlaylists = NSUserInterfaceItemIdentifier("omniamp.savedPlaylists")
    static let watched = NSUserInterfaceItemIdentifier("omniamp.watched")
}

extension AppDelegate: NSMenuDelegate {
    /// Asked on every shortcut press, before AppKit would rebuild each of these menus just to search them
    /// (the device list comes from Core Audio, the playlist menus from disk). Answer without rebuilding:
    /// only the Playlist menu has a shortcut, ⌘R.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        // Only ⌘ (Caps Lock or fn don't matter), and only for the player's playlist: Podcasts has its own
        // Show in Finder for downloads.
        guard menu.identifier == MenuID.playlist, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "r",
              let k = NSApp.keyWindow, look?.owns(k) == true else { return false }
        target.pointee = self
        action.pointee = #selector(revealSelected(_:))
        return true
    }

    /// Fills "Saved Playlists" with the files in the playlists folder.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier == MenuID.watched {
            fillWatchedMenu(menu)
            return
        }
        if menu.identifier == MenuID.output {
            fillOutputMenu(menu)
            return
        }
        if menu.identifier == MenuID.playlist {
            menu.removeAllItems()
            fillTrackItems(menu, withKeys: true)
            return
        }
        guard menu.identifier == MenuID.savedPlaylists else { return }
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
