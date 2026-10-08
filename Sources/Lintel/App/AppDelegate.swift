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
            default:
                if cmd.hasPrefix("select-") { IslandModel.shared.selectedSessionID = String(cmd.dropFirst(7)) }
            }
            if cmd == "state" {
                let st = AgentStore.shared
                let obj: [String: Any] = [
                    "expanded": "\(String(describing: IslandModel.shared.expanded))",
                    "selected": IslandModel.shared.selectedSessionID ?? "",
                    "finishedFlash": st.finishedFlash ?? "",
                    "sessions": st.sessions.map { ["id": $0.id, "status": "\($0.status)", "title": $0.displayTitle, "phase": $0.phase.label] },
                    "pending": st.pending.map { ["session": $0.sessionID, "blocking": $0.isBlocking] },
                    "music": NowPlaying.shared.state.map { "\($0.track.title) — \($0.track.artist) playing=\($0.isPlaying) next=\($0.upNext.count)" } ?? "none",
                    "musicHint": NowPlaying.shared.hint ?? "",
                ]
                let data = (try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)) ?? Data()
                responder.respond(String(data: data, encoding: .utf8) ?? "")
                return
            }
            responder.respond(NSTemporaryDirectory() + "lintel-snapshot.png")
        }

        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            showSettings()
        }
    }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Lintel")
            img?.isTemplate = true
            button.image = img
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let installed = ClaudeHooks.isInstalled
        menu.addItem(withTitle: installed ? "Claude Code connected" : "Connect Claude Code…",
                     action: installed ? nil : #selector(installHooks), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Agents   ⌃⌥Space", action: #selector(showAgents), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Music   ⌃⌥M", action: #selector(showMusic), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Lintel", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func installHooks() {
        do { try ClaudeHooks.install() } catch { showError(error) }
    }
    @objc private func showAgents() { IslandModel.shared.expand(.agents, pinned: true) }
    @objc private func showMusic() { IslandModel.shared.expand(.music, pinned: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environment(Settings.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "Lintel"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApp.activate()
        alert.runModal()
    }
}
