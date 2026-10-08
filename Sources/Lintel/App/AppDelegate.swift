import AppKit
import Carbon
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var notch: NotchController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AgentStore.shared.start()
        NowPlaying.shared.start()
        notch = NotchController()

        setUpStatusItem()
        setUpMainMenu() // hidden for a menu-bar app, but gives text fields ⌘C / ⌘V

        // ⌃⌥Space: agents · ⌃⌥M: music
        Hotkeys.shared.register(keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in
            IslandModel.shared.toggle(.agents)
            if IslandModel.shared.expanded != nil { self?.notch.focus() }
        }
        Hotkeys.shared.register(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey) { [weak self] in
            IslandModel.shared.toggle(.music)
            if IslandModel.shared.expanded != nil { self?.notch.focus() }
        }

        AgentStore.shared.onAttention = { [weak self] in
            guard Settings.shared.autoExpandOnAttention else { return }
            IslandModel.shared.expand(.agents, pinned: true)
            _ = self
        }

        AgentStore.shared.debugHandler = { [weak self] cmd, responder in
            switch cmd {
            case "agents": IslandModel.shared.expand(.agents, pinned: true)
            case "music": IslandModel.shared.expand(.music, pinned: true)
            case "collapse": IslandModel.shared.collapse()
            case "snapshot": self?.notch.snapshot(to: NSTemporaryDirectory() + "lintel-snapshot.png")
            case "allow", "always", "deny", "answer", "reply":
                let store = AgentStore.shared
                if let p = store.pending.first(where: { cmd == "reply" ? !$0.isBlocking : $0.isBlocking }) {
                    switch (cmd, p.kind) {
                    case ("allow", _): store.allow(p)
                    case ("always", _): store.allow(p, always: true)
                    case ("deny", _): store.deny(p)
                    case ("answer", .question(let qs)): store.answer(p, answers: Dictionary(uniqueKeysWithValues: qs.map { ($0.question, $0.options.first?.label ?? "") }))
                    case ("reply", _): store.reply(p, text: "also add a changelog entry")
                    default: break
                    }
                }
            case _ where cmd.hasPrefix("theme-"):
                Settings.shared.appearance = AppearanceChoice(rawValue: String(cmd.dropFirst(6))) ?? .system
            case _ where cmd.hasPrefix("display-"):
                Settings.shared.display = DisplayChoice(rawValue: String(cmd.dropFirst(8))) ?? .follow
            default:
                if cmd.hasPrefix("select-") { IslandModel.shared.selectedSessionID = String(cmd.dropFirst(7)) }
            }
            if cmd == "state" {
                let st = AgentStore.shared
                let obj: [String: Any] = [
                    "expanded": "\(String(describing: IslandModel.shared.expanded))",
                    "selected": IslandModel.shared.selectedSessionID ?? "",
                    "cardRect": "\(IslandModel.shared.cardRect)", "agentRect": "\(IslandModel.shared.agentPillRect)",
                    "finishedFlash": st.finishedFlash ?? "",
                    "sessions": st.sessions.map { ["id": $0.id, "status": "\($0.status)", "title": $0.displayTitle, "phase": $0.phase.label] },
                    "pending": st.pending.map { ["session": $0.sessionID, "blocking": $0.isBlocking] },
                    "music": NowPlaying.shared.state.map { "\($0.track.title) — \($0.track.artist) playing=\($0.isPlaying) app=\($0.appBundleID) next=\($0.upNext.map(\.title))" } ?? "none",
                    "musicSource": NowPlaying.shared.sourceLabel,
                    "musicHint": NowPlaying.shared.hint ?? "",
                ]
                let data = (try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)) ?? Data()
                responder.respond(String(data: data, encoding: .utf8) ?? "")
                return
            }
            responder.respond(NSTemporaryDirectory() + "lintel-snapshot.png")
        }

        NotificationCenter.default.addObserver(forName: .lintelAppearanceChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsWindow?.appearance = Settings.shared.nsAppearance }
        }

        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            showSettings()
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// A tiny notch with two wings — drawn as a template so it follows the menu bar's colour.
    private static func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 14), flipped: true) { r in
            NSColor.black.setFill()
            // The notch bar
            let bar = NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 16, height: 6), xRadius: 3, yRadius: 3)
            bar.fill()
            // Two "islands" hanging below it
            NSBezierPath(ovalIn: NSRect(x: 3, y: 9.5, width: 3.5, height: 3.5)).fill()
            NSBezierPath(roundedRect: NSRect(x: 9, y: 10, width: 6, height: 2.5), xRadius: 1.25, yRadius: 1.25).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Show Agents", action: #selector(showAgents), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Music", action: #selector(showMusic), keyEquivalent: "").target = self
        menu.addItem(.separator())
        for t in AgentHooks.Target.allCases {
            if AgentHooks.isInstalled(t) {
                let item = menu.addItem(withTitle: "\(t.name) connected", action: nil, keyEquivalent: "")
                item.state = .on
            } else {
                let item = menu.addItem(withTitle: "Connect \(t.name)…", action: #selector(connect(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = t.rawValue
            }
        }
        menu.addItem(.separator())
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for a in AppearanceChoice.allCases {
            let item = sub.addItem(withTitle: a.label, action: #selector(setAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = a.rawValue
            item.state = Settings.shared.appearance == a ? .on : .off
        }
        appearance.submenu = sub
        menu.addItem(appearance)
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Lintel", action: #selector(quit), keyEquivalent: "q").target = self
    }

    private func setUpMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    @objc private func setAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = AppearanceChoice(rawValue: raw) else { return }
        Settings.shared.appearance = a
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func connect(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let t = AgentHooks.Target(rawValue: raw) else { return }
        do { try AgentHooks.install(t) } catch { showError(error) }
    }
    @objc private func showAgents() { IslandModel.shared.expand(.agents, pinned: true) }
    @objc private func showMusic() { IslandModel.shared.expand(.music, pinned: true) }

    @objc func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environment(Settings.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "Lintel"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.appearance = Settings.shared.nsAppearance
            w.center()
            settingsWindow = w
        }
        settingsWindow?.appearance = Settings.shared.nsAppearance
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApp.activate()
        alert.runModal()
    }
}
