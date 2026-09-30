import AppKit

// Test hook: OMNIAMP_TICKETS=<file.png> draws the concert tickets on a contact sheet and quits (no window, nothing
// read), to look at the designs without a library of shows that have no cover.
if let sheet = ProcessInfo.processInfo.environment["OMNIAMP_TICKETS"] {
    let side = ProcessInfo.processInfo.environment["OMNIAMP_TICKET_SIZE"].flatMap(Double.init) ?? 158
    TicketArt.writeSheet(to: sheet, side: side)
    exit(0)
}

// The app starts on the main thread: say so, so the main-actor classes can be made here.
MainActor.assumeIsolated {
    // Start decoding the playlist while AppKit starts up (tens of thousands of tracks take a while).
    LibraryCache.preload()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
