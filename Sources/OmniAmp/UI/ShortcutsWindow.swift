import AppKit

/// Help → Keyboard Shortcuts (⌘/): every key in one place, in the app's own look.
enum Shortcuts {
    static let sections: [(String, [(String, String)])] = [
        ("Playback", [
            ("X", "Play"), ("C", "Pause"), ("Space", "Play / pause"), ("V", "Stop"), ("⇧V", "Stop after current track"),
            ("Z  B", "Previous / next track"), ("←  →", "Seek 5 seconds"), ("⇧←  ⇧→", "Seek 30 seconds"),
            ("+  −", "Volume"), ("S", "Shuffle on / off"), ("R", "Repeat on / off"),
        ]),
        ("Playlist", [
            ("↑  ↓", "Previous / next row (hold to scroll)"), ("⌘↑  ⌘↓", "Move 10 rows"), ("⌘⇧↑  ⌘⇧↓", "Move 100 rows"),
            ("fn↑  fn↓", "Page up / down"), ("fn←  fn→", "First / last row"), ("Return", "Play the selected track"),
            ("⌫", "Remove the selected tracks"), ("⌥↑  ⌥↓", "Move the selected tracks up / down"), ("Q", "Queue next"),
            ("J  ⌘F", "Jump to a track (type to search)"), ("L", "Show the playing track"), ("⌘R", "Show in Finder"),
        ]),
        ("Windows", [
            ("I", "INFO drawer (modern look)"), ("E", "Equalizer"), ("⌘1", "Player"), ("⌘2", "Internet Radio (again: close)"),
            ("⌘3", "Podcasts (again: close)"), ("⌃⌘1  ⌃⌘2", "Modern / classic look"), ("⌘O", "Add files or folder"), ("⌘L", "Add a URL"), ("⌘,", "Settings"),
            ("⌘/", "This list"), ("⌘W  ⌘M", "Close / minimize a window"), ("⌘S  ⇧⌘O", "Save / open a playlist"),
        ]),
        ("Radio and Podcasts", [
            ("⌘F", "Search"), ("Return  ↓", "From the search to the results"), ("Esc", "Clear search · back a step · close"), ("Tab", "Search ↔ lists"), ("⌃Tab", "Top ⇄ Subscribed, Popular ⇄ Favorites"), ("↑  ↓", "Move through the list"), ("⌘↑  ⌘⇧↑ …", "Jump 10 / 100 rows, page, first / last (as in the playlist)"), ("←  →", "Shows ↔ episodes (Podcasts)"),
            ("Return", "Play (shows: open the episodes)"), ("Space", "Play / pause"), ("Type", "Search stations / filter episodes"),
            ("⇧⌘F", "Filter episodes"), ("⌘D", "Favorite station · download episode"), ("⌘I  ⇧⌘U", "Episode notes · unplayed only"), ("⌃Return", "Menu for the selected row"),
        ]),
    ]
}

final class ShortcutsWindowController: NSWindowController {
    init() {
        // A normal window, not a panel: it stays open next to other apps while you learn the keys.
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Keyboard Shortcuts"
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func cancelOperation(_ sender: Any?) { window?.close() }   // Esc

    private func build() {
        func column(_ sections: ArraySlice<(String, [(String, String)])>) -> NSStackView {
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 14
            for (title, keys) in sections {
                let head = NSTextField(labelWithString: title.uppercased())
                head.font = Fonts.hack(10, bold: true)
                head.textColor = Theme.phosphorDim
                let rows = keys.map { k, d -> [NSView] in
                    let key = NSTextField(labelWithString: k)
                    key.font = Fonts.hack(11, bold: true)
                    key.textColor = Theme.phosphor
                    let desc = NSTextField(labelWithString: d)
                    desc.font = Fonts.hack(11)
                    desc.textColor = Theme.playlistText
                    return [key, desc]
                }
                let grid = NSGridView(views: rows)
                grid.columnSpacing = 12
                grid.rowSpacing = 4
                grid.column(at: 0).width = 86
                let block = NSStackView(views: [head, grid])
                block.orientation = .vertical
                block.alignment = .leading
                block.spacing = 6
                block.setHuggingPriority(.required, for: .vertical)
                col.addArrangedSubview(block)
            }
            // The shorter column keeps its sections together at the top; the spare height goes below.
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
            col.addArrangedSubview(spacer)
            col.distribution = .fill
            return col
        }
        let s = Shortcuts.sections
        let columns = NSStackView(views: [column(s[0..<2]), column(s[2..<4])])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 28
        columns.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = Theme.lcd.cgColor
        columns.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: bg.topAnchor), columns.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: bg.trailingAnchor), columns.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        window?.contentView = bg
        window?.setContentSize(columns.fittingSize)
    }
}
