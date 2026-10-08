import SwiftUI

struct SettingsView: View {
    @Environment(Settings.self) private var settings
    @State private var hooksInstalled = ClaudeHooks.isInstalled
    @State private var error: String?
    @State private var launchAtLogin = Settings.shared.launchAtLogin

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                HStack(spacing: 14) {
                    Mascot(color: Theme.session[0], mood: .happy, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lintel").font(.system(size: 20, weight: .semibold))
                        Text("Your agents and your music, at the top of the screen.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Claude Code") {
                HStack {
                    Label(hooksInstalled ? "Connected" : "Not connected",
                          systemImage: hooksInstalled ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(hooksInstalled ? Color.green : Color.secondary)
                    Spacer()
                    Button(hooksInstalled ? "Disconnect" : "Connect") {
                        do {
                            if hooksInstalled { try ClaudeHooks.uninstall() } else { try ClaudeHooks.install() }
                            error = nil
                        } catch let e { error = e.localizedDescription }
                        hooksInstalled = ClaudeHooks.isInstalled
                    }
                }
                Text("Adds hooks to ~/.claude/settings.json (a backup is saved next to it). New Claude Code sessions report to Lintel, and permission prompts and questions can be answered from the notch. If Lintel isn't running, Claude Code behaves normally.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Picker("Hand prompts back to the terminal after", selection: $s.permissionTimeout) {
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
                }
                Text("Keeps the finished turn open briefly so a reply typed in the notch continues the same session.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Codex") {
                Toggle("Show Codex sessions", isOn: $s.codexEnabled)
                Text("Follows the Codex app and CLI through ~/.codex/sessions. Approvals are flagged with a jump-to-Codex button.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notch") {
                Toggle("Open automatically when an agent needs you", isOn: $s.autoExpandOnAttention)
                Toggle("Play sounds", isOn: $s.playSounds)
                Picker("Display", selection: $s.display) {
                    ForEach(DisplayChoice.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Music") {
                Toggle("Apple Music", isOn: $s.appleMusicEnabled)
                Toggle("YouTube Music (Chrome, Arc, Brave, Edge, Safari)", isOn: $s.youTubeMusicEnabled)
                Toggle("Show up next", isOn: $s.showUpNext)
                Toggle("Hide the music pill when nothing is playing", isOn: $s.hideMusicWhenIdle)
                Text("For YouTube Music in Chrome-based browsers turn on View › Developer › Allow JavaScript from Apple Events (Safari: Develop menu). macOS will ask once to let Lintel control each app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in settings.launchAtLogin = v }
                LabeledContent("Agents", value: "⌃⌥Space")
                LabeledContent("Music", value: "⌃⌥M")
                LabeledContent("Jump to session (when open)", value: "⌘1 … ⌘9")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 680)
    }
}
