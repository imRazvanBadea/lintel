import AppKit

// Lintel lives in the notch / top edge of the screen. No Dock icon (accessory app).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
