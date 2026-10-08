import AppKit

// Lintel lives in the notch / top edge of the screen. Lives in the menu bar (no Dock icon).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
