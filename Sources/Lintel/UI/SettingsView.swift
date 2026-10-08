import SwiftUI

struct SettingsView: View {
    @Environment(Settings.self) private var settings
    @State private var installed: [AgentHooks.Target: Bool] = Dictionary(uniqueKeysWithValues: AgentHooks.Target.allCases.map { ($0, AgentHooks.isInstalled($0)) })
    @State private var error: String?
    @State private var launchAtLogin = Settings.shared.launchAtLogin

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
                    HStack {
                        Text(t.name)
                        Spacer()
                        if installed[t] == true {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green).labelStyle(.titleAndIcon)
                        }
                        Button(installed[t] == true ? "Disconnect" : "Connect") { toggle(t) }
                    }
                }
                HStack {
                    Text("Codex")
                    Spacer()
                    Toggle("", isOn: $s.codexEnabled).labelsHidden()
                }
                Text("Connecting adds Lintel's hooks to ~/.claude/settings.json or ~/.cursor/hooks.json (a backup is saved next to each). New sessions report to Lintel. If Lintel isn't running, the agents behave exactly as before. Codex is read from ~/.codex/sessions, so nothing needs installing.")
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
                Picker("Show on", selection: $s.display) {
                    ForEach(DisplayChoice.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Open automatically when an agent needs you", isOn: $s.autoExpandOnAttention)
                Toggle("Play sounds", isOn: $s.playSounds)
            }

            Section("Music") {
                Toggle("Show what's playing", isOn: $s.musicEnabled)
                Toggle("Show up next", isOn: $s.showUpNext)
                Text("Works with any player (Apple Music, Spotify, YouTube Music in any browser…). For YouTube Music's up next, turn on Allow JavaScript from Apple Events in your browser (Chromium browsers: View › Developer; Safari: Develop).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in settings.launchAtLogin = v }
                LabeledContent("Agents", value: "⌃⌥Space")
                LabeledContent("Music", value: "⌃⌥M")
                LabeledContent("Jump to session (card open)", value: "⌘1 … ⌘9")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
    }

    private func toggle(_ t: AgentHooks.Target) {
        do {
            if installed[t] == true { try AgentHooks.uninstall(t) } else { try AgentHooks.install(t) }
            error = nil
        } catch let e { error = e.localizedDescription }
        installed[t] = AgentHooks.isInstalled(t)
    }
}
