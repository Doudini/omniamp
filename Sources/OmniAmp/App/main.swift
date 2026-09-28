import AppKit

// Start decoding the playlist while AppKit starts up (tens of thousands of tracks take a while).
LibraryCache.preload()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
