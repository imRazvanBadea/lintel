import SwiftUI

/// Settings › When the lid closes: keep agents running, what to pause, and Hotspot Hopper.
struct AwakeSettingsSection: View {
    @Environment(Settings.self) private var settings
    @State private var awake = AwakeController.shared
    @State private var working = false
    @State private var error: String?

    var body: some View {
        @Bindable var s = settings
        Section("When the lid closes") {
            Toggle("Keep agents running with the lid closed", isOn: $s.keepAgentsAwake)
            if settings.keepAgentsAwake {
                HStack(alignment: .top) {
                    if awake.isSetUp {
                        Label("Set up", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    } else {
                        Text("Needs a one-time setup: macOS asks for your password so Lintel can switch sleep off and on.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if working {
                        ProgressView().controlSize(.small)
                    } else if awake.isSetUp {
                        Button("Remove…") { run(awake.removeSetup) }
                    } else {
                        Button("Set Up…") { run(awake.setUp) }
                    }
                }
                Toggle("Pause the other apps (Slack, Messages, Spotify…)", isOn: $s.pauseAppsWhenLidClosed)
                Toggle("Turn on Low Power Mode", isOn: $s.lowPowerWhenLidClosed)
                if let status { Text(status).font(.caption).foregroundStyle(awake.blockedReason == nil ? Theme.green : Theme.amber) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("While an agent is working or waiting on you, your Mac doesn't sleep, so you can close the lid. Lintel keeps running the apps those agents live in (terminals, editors, Claude, Codex, Cursor) plus browsers, meeting apps and password managers, pauses the rest and turns the display off. A couple of minutes after the last agent finishes, everything is resumed and the Mac goes to sleep. Below \(AwakeController.batteryFloor)% battery or when it gets too hot, it sleeps anyway. Use a well-ventilated surface, not a closed bag.")
                .font(.caption).foregroundStyle(.secondary)
        }
        HotspotSettingsSection()
    }

    private var status: String? {
        if let r = awake.blockedReason { return r }
        switch awake.mode {
        case .off: return nil
        case .armed: return "Active: agents are running, you can close the lid."
        case .lidClosed: return awake.pausedApps.isEmpty ? "Lid closed, agents running." : "Lid closed. Paused: \(awake.pausedApps.joined(separator: ", "))"
        }
    }

    private func run(_ action: @escaping (@escaping (Error?) -> Void) -> Void) {
        working = true
        error = nil
        action { e in
            working = false
            if let e, (e as? PowerControl.SetupError).map({ if case .cancelled = $0 { false } else { true } }) ?? true {
                error = e.localizedDescription
            }
        }
    }
}

private struct HotspotSettingsSection: View {
    @Environment(Settings.self) private var settings
    @State private var password = ""
    @State private var saved = false
    @State private var hasPassword = false
    @State private var locationDenied = WiFiLocationAccess.shared.denied

    var body: some View {
        @Bindable var s = settings
        Section("Hotspot Hopper") {
            Toggle("Join my iPhone's hotspot if the Wi-Fi drops", isOn: $s.hotspotEnabled)
            if settings.hotspotEnabled {
                TextField("Hotspot name", text: $s.hotspotSSID, prompt: Text("Your iPhone's name, e.g. Razvan's iPhone"))
                HStack {
                    SecureField("Password", text: $password, prompt: Text(hasPassword ? "Saved" : "Personal Hotspot password"))
                    Button(saved ? "Saved" : "Save") { save() }
                        .disabled(settings.hotspotSSID.isEmpty || password.isEmpty)
                }
                if locationDenied {
                    HStack {
                        Text("Location access is off, so macOS may hide network names from Lintel.").font(.caption).foregroundStyle(Theme.amber)
                        Spacer()
                        Button("Open Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                        }
                    }
                }
            }
            Text("Only while agents are running with the lid closed. On your iPhone keep Personal Hotspot available, and on your Mac set System Settings › Wi-Fi › Ask to join hotspots to Automatic. The password stays in your login Keychain; after an update macOS may ask once to let Lintel read it. Lintel asks for Location access only because macOS requires it to see Wi-Fi names, and never reads your location.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onChange(of: settings.hotspotSSID) { _, _ in saved = false; refresh() }
        .onChange(of: password) { _, _ in saved = false }
    }

    private func refresh() {
        hasPassword = !settings.hotspotSSID.isEmpty && HotspotKeychain.has(ssid: settings.hotspotSSID)
        WiFiLocationAccess.shared.onChange = {
            locationDenied = WiFiLocationAccess.shared.denied
        }
    }

    private func save() {
        let ssid = settings.hotspotSSID.trimmingCharacters(in: .whitespaces)
        guard HotspotKeychain.save(ssid: ssid, password: password) else { return }
        HotspotHopper.shared.forgetPassword()
        password = ""
        saved = true
        hasPassword = true
        WiFiLocationAccess.shared.request()
    }
}
