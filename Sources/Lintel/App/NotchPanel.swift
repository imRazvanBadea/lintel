import AppKit
import SwiftUI

/// Borderless, transparent, non-activating panel pinned to the top edge of a screen.
/// It ignores the mouse everywhere except over the pills / open card, so the menu bar
/// and windows underneath keep working.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchController {
    static let panelSize = CGSize(width: 1100, height: 600)

    let panel = NotchPanel()
    private let model = IslandModel.shared
    private var monitors: [Any] = []
    private var lastInside = false

    init() {
        let root = RootView()
            .environment(model)
            .environment(AgentStore.shared)
            .environment(NowPlaying.shared)
            .environment(Settings.shared)
            .environment(UsageStore.shared)
            .environment(UsageHistory.shared)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host

        reposition()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        Settings.shared.onDisplayChange = { [weak self] in self?.reposition() }
        panel.appearance = Settings.shared.nsAppearance
        Settings.shared.onAppearanceChange = { [weak self] in
            self?.panel.appearance = Settings.shared.nsAppearance
            NotificationCenter.default.post(name: .lintelAppearanceChanged, object: nil)
        }
        NotificationCenter.default.addObserver(forName: .lintelCollapsed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseKeyFocus() }
        }

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved(e) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved(e) }
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            nonisolated(unsafe) let event = e
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return consumed ? nil : e
        } as Any)
    }

    /// Renders the panel to a PNG (developer tool). `transparent` keeps the alpha for compositing.
    func snapshot(to path: String, transparent: Bool = false) {
        guard let view = panel.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        let png: Data?
        if transparent {
            png = rep.representation(using: .png, properties: [:])
        } else {
            // On a desktop-like background so the islands are visible.
            let out = NSImage(size: bounds.size)
            out.lockFocus()
            NSColor(white: 0.93, alpha: 1).setFill()
            bounds.fill()
            NSImage(cgImage: rep.cgImage!, size: bounds.size).draw(in: bounds)
            out.unlockFocus()
            png = out.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        }
        try? png?.write(to: URL(fileURLWithPath: path))
    }

    /// The display chosen by "follow": starts on the main display, then moves to whichever display you click on.
    private var followedScreenID: CGDirectDisplayID?
    private var currentScreenID: CGDirectDisplayID?

    private static func id(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let main = screens.first // the display with the menu bar ("main display" in System Settings)
        switch Settings.shared.display {
        case .main: return main
        case .builtIn:
            return screens.first { Self.id(of: $0).map { CGDisplayIsBuiltin($0) != 0 } ?? false } ?? main
        case .follow:
            if let id = followedScreenID, let s = screens.first(where: { Self.id(of: $0) == id }) { return s }
            return main
        }
    }

    /// Called on every click anywhere: if it landed on another display, move there.
    private func followClick(at p: NSPoint) {
        guard Settings.shared.display == .follow,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
              let id = Self.id(of: screen), id != currentScreenID else { return }
        followedScreenID = id
        if model.expanded != nil && !AgentStore.shared.hasPendingRequests { model.collapse() }
        reposition()
    }

    func reposition() {
        guard let screen = targetScreen() else { return }
        currentScreenID = Self.id(of: screen)
        let f = screen.frame
        let size = CGSize(width: min(Self.panelSize.width, f.width), height: Self.panelSize.height)
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height),
                       display: true)

        let topInset = screen.safeAreaInsets.top
        if topInset > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            model.notchWidth = max(0, f.width - l.width - r.width)
            model.menuBarHeight = topInset
        } else {
            model.notchWidth = 0
            let mb = f.maxY - screen.visibleFrame.maxY
            model.menuBarHeight = mb > 0 ? mb : 24
        }
    }

    // MARK: Mouse

    private func toScreen(_ r: CGRect) -> CGRect {
        let pf = panel.frame
        return CGRect(x: pf.minX + r.minX, y: pf.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func mouseMoved(_ event: NSEvent) {
        let p = NSEvent.mouseLocation
        let agent = toScreen(model.agentPillRect).insetBy(dx: -4, dy: -4)
        let music = toScreen(model.musicPillRect).insetBy(dx: -4, dy: -4)
        // The card hit area extends upward to the pill so moving between them never drops hover.
        var card = model.expanded != nil ? toScreen(model.cardRect).insetBy(dx: -6, dy: -6) : .zero
        if model.expanded != nil, !card.isEmpty {
            card = card.union(CGRect(x: card.minX, y: card.maxY, width: card.width, height: panel.frame.maxY - card.maxY))
        }

        let overAgent = model.agentPillRect != .zero && agent.contains(p)
        let overMusic = model.musicPillRect != .zero && music.contains(p)
        let overCard = !card.isEmpty && card.contains(p)
        let inside = overAgent || overMusic || overCard

        let overBar = overAgent || overMusic
        if overBar != model.hoveringBar {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.hoveringBar = overBar }
        }

        if inside != lastInside {
            panel.ignoresMouseEvents = !inside
            lastInside = inside
        }

        if event.type == .leftMouseDown && !inside { followClick(at: p) }
        if event.type == .leftMouseDown && !inside {
            // Clicking anywhere else dismisses an open card (unless something is waiting on you).
            if model.expanded != nil && !AgentStore.shared.hasPendingRequests { model.collapse() }
            return
        }
        let island: Island? = overAgent ? .agents : (overMusic ? .music : nil)
        // While over the card of an open island, don't switch islands.
        if overCard && island == nil {
            model.hoverChanged(over: nil, overCard: true)
        } else if let island, !(overCard && model.expanded != nil && island != model.expanded) {
            model.hoverChanged(over: island, overCard: false)
        } else if !inside {
            model.hoverChanged(over: nil, overCard: false)
        }
    }

    // MARK: Keyboard

    func focus() {
        panel.makeKeyAndOrderFront(nil)
        panel.ignoresMouseEvents = false
    }

    private func releaseKeyFocus() {
        guard panel.isKeyWindow else { return }
        panel.resignKey()
        NSWorkspace.shared.frontmostApplication?.activate()
    }

    /// Returns true when the key was handled here.
    private func handleKey(_ e: NSEvent) -> Bool {
        guard e.window === panel else { return false }
        if e.keyCode == 53 { // esc
            if model.selectedSessionID != nil { model.selectedSessionID = nil } else { model.collapse() }
            return true
        }
        if e.modifierFlags.contains(.command), let c = e.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) {
            let sessions = AgentStore.shared.sessions
            if n <= sessions.count {
                AgentStore.shared.reveal(sessions[n - 1])
                model.collapse()
            }
            return true
        }
        return false
    }
}
