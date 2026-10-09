import SwiftUI

struct SettingsView: View {
    @Environment(Settings.self) private var settings
    @State private var installed: [AgentHooks.Target: Bool] = Dictionary(uniqueKeysWithValues: AgentHooks.Target.allCases.map { ($0, AgentHooks.isInstalled($0)) })
    @State private var error: String?
    @State private var launchAtLogin = Settings.shared.launchAtLogin
    @State private var codexReadiness: AgentHooks.CodexReadiness = .unknown

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lintel").font(.system(size: 20, weight: .semibold))
                    Text("Your agents and your music, at the top of the screen.").foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Agents") {
                ForEach(AgentHooks.Target.allCases, id: \.self) { t in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(t.name)
                            Spacer()
                            if installed[t] == true {
                                if t == .codex && codexReadiness == .needsApproval {
                                    Label("Needs approval", systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.amber)
                                } else {
                                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green)
                                }
                            }
                            Button(installed[t] == true ? "Disconnect" : "Connect") { toggle(t) }
                        }
                        if t == .codex, installed[t] == true, codexReadiness == .needsApproval {
                            HStack(alignment: .top) {
                                Text("Codex runs new hooks only after you approve them. Open Codex, type /hooks, approve Lintel's four hooks, then start a new chat.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Approve in Codex…") { AgentHooks.openCodexForApproval() }
                            }
                        }
                    }
                }
                Toggle("Show Codex sessions (from ~/.codex/sessions)", isOn: $s.codexEnabled)
                Text("Connecting adds Lintel's hooks to ~/.claude/settings.json, ~/.cursor/hooks.json or ~/.codex/hooks.json (a backup is saved next to each). New sessions report to Lintel, and you can answer prompts and reply from the notch. If Lintel isn't running, the agents behave exactly as before.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }

            Section("Prompts & replies") {
                Toggle("Approve Cursor's terminal commands from the notch", isOn: $s.cursorShellApprovals)
                Picker("Hand undecided prompts back after", selection: $s.permissionTimeout) {
                    Text("2 minutes").tag(120)
                    Text("10 minutes").tag(600)
                    Text("1 hour").tag(3600)
                    Text("Never").tag(0)
                }
                Picker("Quick reply after a turn finishes", selection: $s.quickReplySeconds) {
                    Text("Off").tag(0)
                    Text("15 seconds").tag(15)
                    Text("25 seconds").tag(25)
                    Text("60 seconds").tag(60)
                    Text("2 minutes").tag(120)
                }
                Text("Keeps a finished Claude Code or Cursor turn open briefly, so a reply typed in the notch continues the same session.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notch") {
                Picker("Appearance", selection: $s.appearance) {
                    ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("On a notched display", selection: $s.notchStyle) {
                    ForEach(NotchStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Show on", selection: $s.display) {
                    ForEach(DisplayChoice.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Open automatically when an agent needs you", isOn: $s.autoExpandOnAttention)
                Toggle("Play sounds", isOn: $s.playSounds)
                if settings.playSounds {
                    soundPicker("When an agent needs you", selection: $s.needsYouSound)
                    soundPicker("When a turn finishes", selection: $s.finishedSound)
                    Toggle("Stay quiet when that session's app is already in front", isOn: $s.muteWhenFocused)
                }
                Toggle("Notify me at 80% and 100% of a plan limit", isOn: $s.usageAlerts)
            }

            Section("Music") {
                Toggle("Show what's playing", isOn: $s.musicEnabled)
                Toggle("Show up next", isOn: $s.showUpNext)
                Text("Works with any player (Apple Music, Spotify, YouTube Music in any browser…). For YouTube Music's up next, turn on Allow JavaScript from Apple Events in your browser (Chromium browsers: View › Developer; Safari: Develop).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Show icon in the menu bar", isOn: $s.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("To get back here, open Lintel again (Spotlight or Finder) or press ⌃⌥, (Control-Option-comma).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in settings.launchAtLogin = v }
                LabeledContent("Agents", value: "⌃⌥Space")
                LabeledContent("Music", value: "⌃⌥M")
                LabeledContent("Settings", value: "⌃⌥,")
                LabeledContent("Jump to session (card open)", value: "⌘1 … ⌘9")
            }

            Section("Updates") {
                UpdatesRow()
                Toggle("Check for updates automatically", isOn: $s.checkForUpdates)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: checkCodex)
        .frame(width: 520, height: 720)
    }

    private func soundPicker(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Picker(title, selection: selection) {
                ForEach(Sounds.choices, id: \.self) { Text($0).tag($0) }
            }
            Button { Sounds.play(selection.wrappedValue) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .help("Preview")
                .disabled(selection.wrappedValue == "None")
        }
    }

    private func checkCodex() {
        guard AgentHooks.isInstalled(.codex) else { return }
        AgentHooks.codexReadiness { r in DispatchQueue.main.async { codexReadiness = r } }
    }

    private func toggle(_ t: AgentHooks.Target) {
        do {
            if installed[t] == true { try AgentHooks.uninstall(t) } else { try AgentHooks.install(t) }
            error = nil
        } catch let e { error = e.localizedDescription }
        installed[t] = AgentHooks.isInstalled(t)
        if t == .codex { checkCodex() }
    }
}

/// Version, update status and the button that installs a new release.
private struct UpdatesRow: View {
    @State private var updater = Updater.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lintel \(Updater.currentVersion)")
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if [.checking, .downloading, .installing].contains(updater.state) {
                ProgressView().controlSize(.small)
            } else if let v = updater.latest?.version, Updater.isNewer(v, than: Updater.currentVersion) {
                Button("Update to \(v)") { updater.install() }
            } else {
                Button("Check Now") { updater.check() }
            }
        }
    }

    private var status: String {
        switch updater.state {
        case .idle: "Updates come from the GitHub releases."
        case .checking: "Checking…"
        case .upToDate: "You're up to date."
        case .available: "Version \(updater.latest?.version ?? "") is available."
        case .downloading: "Downloading…"
        case .installing: "Installing, Lintel will reopen…"
        case .failed(let why): why
        }
    }
}
