import AppKit

// Start decoding the playlist while AppKit starts up (tens of thousands of tracks take a while).
LibraryCache.preload()
// The app starts on the main thread: say so, so the main-actor classes can be made here.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
