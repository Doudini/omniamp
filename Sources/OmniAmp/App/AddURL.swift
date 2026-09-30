import AppKit

/// The "Add URL…" prompt shared by the main window, the radio browser and the podcast browser.
enum AddURL {
    /// Asks for a link in a small dark sheet. A web address on the clipboard is filled in already.
    @MainActor static func ask(title: String, message: String, button: String = "Add", in window: NSWindow?,
                               _ done: @escaping @MainActor (String) -> Void) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://…"
        field.font = Fonts.hack(11)
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           clip.count < 2000, clip.contains("://") || clip.lowercased().hasPrefix("www."), URLProbe.normalize(clip) != nil {
            field.stringValue = clip
        }
        a.accessoryView = field
        a.window.appearance = NSAppearance(named: .darkAqua)
        a.window.initialFirstResponder = field
        func handle(_ r: NSApplication.ModalResponse) {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if r == .alertFirstButtonReturn, !text.isEmpty { done(text) }
        }
        if let w = window { a.beginSheetModal(for: w) { handle($0) } } else { handle(a.runModal()) }
    }

    @MainActor static func show(_ error: Error, in window: NSWindow?) {
        let a = NSAlert()
        a.messageText = "Couldn't add that link"
        a.informativeText = error.localizedDescription
        a.window.appearance = NSAppearance(named: .darkAqua)
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    /// A readable name for a station without one: the host, without "www.".
    static func fallbackName(_ url: String) -> String {
        let host = URL(string: url)?.host ?? url
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
