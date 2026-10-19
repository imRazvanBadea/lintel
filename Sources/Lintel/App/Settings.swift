import AppKit
import Observation
import ServiceManagement

enum DisplayChoice: String, CaseIterable, Identifiable {
    case follow, main, builtIn
    var id: String { rawValue }
    var label: String {
        switch self {
        case .follow: "Follow the display I'm using"
        case .main: "Main display only"
        case .builtIn: "Built-in display only"
        }
    }
}

enum NotchStyle: String, CaseIterable, Identifiable {
    case minimal, wings
    var id: String { rawValue }
    var label: String { self == .minimal ? "Minimal (pops out on hover)" : "Always show wings" }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// User preferences, persisted in UserDefaults.
@MainActor @Observable
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var appearance: AppearanceChoice { didSet { d.set(appearance.rawValue, forKey: "appearance"); onAppearanceChange?() } }
    var display: DisplayChoice { didSet { d.set(display.rawValue, forKey: "display2"); onDisplayChange?() } }
    /// Seconds the "Finished" card keeps the Claude turn open so you can send a follow-up. 0 disables.
    var quickReplySeconds: Int { didSet { d.set(quickReplySeconds, forKey: "quickReplySeconds") } }
    /// Seconds to wait for a decision in the notch before handing the prompt back to the terminal.
    var permissionTimeout: Int { didSet { d.set(permissionTimeout, forKey: "permissionTimeout") } }
    var autoExpandOnAttention: Bool { didSet { d.set(autoExpandOnAttention, forKey: "autoExpand") } }
    var playSounds: Bool { didSet { d.set(playSounds, forKey: "playSounds") } }
    var needsYouSound: String { didSet { d.set(needsYouSound, forKey: "needsYouSound") } }
    var finishedSound: String { didSet { d.set(finishedSound, forKey: "finishedSound") } }
    /// No sound when the app running that session is already in front.
    var muteWhenFocused: Bool { didSet { d.set(muteWhenFocused, forKey: "muteWhenFocused") } }
    /// Notify when a plan window crosses 80% and 100%.
    var usageAlerts: Bool { didSet { d.set(usageAlerts, forKey: "usageAlerts") } }
    var codexEnabled: Bool { didSet { d.set(codexEnabled, forKey: "codexEnabled"); onCodexChange?() } }
    /// Hold Cursor's shell commands until you approve them in the notch (Cursor's own allowlist still applies after).
    var cursorShellApprovals: Bool { didSet { d.set(cursorShellApprovals, forKey: "cursorShellApprovals") } }
    /// The music player (wing, capsule and card). Off leaves Lintel as just the agents notch.
    var musicEnabled: Bool { didSet { d.set(musicEnabled, forKey: "musicEnabled"); NowPlaying.shared.musicSettingChanged() } }
    /// How the notch looks at rest on a notched display. Minimal keeps the menu bar beside the notch free.
    var notchStyle: NotchStyle { didSet { d.set(notchStyle.rawValue, forKey: "notchStyle") } }
    var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon"); onMenuBarIconChange?() } }
    var showUpNext: Bool { didSet { d.set(showUpNext, forKey: "showUpNext") } }
    /// Look for a new release on GitHub once a day.
    /// Where sessions started from the notch run, and the tool picked last time.
    var launchTerminal: LaunchTerminal { didSet { d.set(launchTerminal.rawValue, forKey: "launchTerminal") } }
    var launchAgent: AgentKind { didSet { d.set(launchAgent.rawValue, forKey: "launchAgent") } }
    /// Start sessions in the tool's own app (Claude, Cursor) rather than the terminal, when it has one.
    var launchInApp: Bool { didSet { d.set(launchInApp, forKey: "launchInApp") } }
    var checkForUpdates: Bool { didSet { d.set(checkForUpdates, forKey: "checkForUpdates"); Updater.shared.start() } }
    /// Keep the Mac awake while agents run, so the lid can close (needs the one-time setup).
    var keepAgentsAwake: Bool { didSet { d.set(keepAgentsAwake, forKey: "keepAgentsAwake") } }
    /// With the lid closed, pause the apps agents don't need.
    var pauseAppsWhenLidClosed: Bool { didSet { d.set(pauseAppsWhenLidClosed, forKey: "pauseAppsWhenLidClosed") } }
    var lowPowerWhenLidClosed: Bool { didSet { d.set(lowPowerWhenLidClosed, forKey: "lowPowerWhenLidClosed") } }
    /// Hotspot Hopper: join this network (your iPhone's hotspot) if the Wi-Fi drops with the lid closed.
    var hotspotEnabled: Bool { didSet { d.set(hotspotEnabled, forKey: "hotspotEnabled") } }
    var hotspotSSID: String { didSet { d.set(hotspotSSID, forKey: "hotspotSSID"); HotspotHopper.shared.forgetPassword() } }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { NSLog("Lintel: launch at login failed: \(error)") }
        }
    }

    @ObservationIgnored var onDisplayChange: (() -> Void)?
    @ObservationIgnored var onAppearanceChange: (() -> Void)?
    @ObservationIgnored var onMenuBarIconChange: (() -> Void)?

    var nsAppearance: NSAppearance? {
        switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    @ObservationIgnored var onCodexChange: (() -> Void)?

    private init() {
        d.register(defaults: [
            "display2": DisplayChoice.follow.rawValue,
            "appearance": AppearanceChoice.system.rawValue,
            "quickReplySeconds": 25,
            "permissionTimeout": 600,
            "autoExpand": true,
            "playSounds": true,
            "needsYouSound": "Tink",
            "finishedSound": "Glass",
            "muteWhenFocused": true,
            "usageAlerts": true,
            "codexEnabled": true,
            "musicEnabled": true,
            "cursorShellApprovals": false,
            "showUpNext": true,
            "checkForUpdates": true,
            "launchInApp": true,
            "showMenuBarIcon": true,
            "notchStyle": NotchStyle.minimal.rawValue,
            "keepAgentsAwake": true,
            "pauseAppsWhenLidClosed": true,
            "lowPowerWhenLidClosed": true,
            "hotspotEnabled": false,
        ])
        appearance = AppearanceChoice(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        display = DisplayChoice(rawValue: d.string(forKey: "display2") ?? "") ?? .follow
        quickReplySeconds = d.integer(forKey: "quickReplySeconds")
        permissionTimeout = d.integer(forKey: "permissionTimeout")
        autoExpandOnAttention = d.bool(forKey: "autoExpand")
        playSounds = d.bool(forKey: "playSounds")
        needsYouSound = d.string(forKey: "needsYouSound") ?? "Tink"
        finishedSound = d.string(forKey: "finishedSound") ?? "Glass"
        muteWhenFocused = d.bool(forKey: "muteWhenFocused")
        usageAlerts = d.bool(forKey: "usageAlerts")
        codexEnabled = d.bool(forKey: "codexEnabled")
        musicEnabled = d.bool(forKey: "musicEnabled")
        cursorShellApprovals = d.bool(forKey: "cursorShellApprovals")
        showUpNext = d.bool(forKey: "showUpNext")
        checkForUpdates = d.bool(forKey: "checkForUpdates")
        showMenuBarIcon = d.bool(forKey: "showMenuBarIcon")
        launchTerminal = LaunchTerminal(rawValue: d.string(forKey: "launchTerminal") ?? "")
            ?? [.iterm, .ghostty].first(where: \.isInstalled) ?? .terminal
        launchInApp = d.bool(forKey: "launchInApp")
        launchAgent = AgentKind(rawValue: d.string(forKey: "launchAgent") ?? "") ?? .claude
        notchStyle = NotchStyle(rawValue: d.string(forKey: "notchStyle") ?? "") ?? .minimal
        keepAgentsAwake = d.bool(forKey: "keepAgentsAwake")
        pauseAppsWhenLidClosed = d.bool(forKey: "pauseAppsWhenLidClosed")
        lowPowerWhenLidClosed = d.bool(forKey: "lowPowerWhenLidClosed")
        hotspotEnabled = d.bool(forKey: "hotspotEnabled")
        hotspotSSID = d.string(forKey: "hotspotSSID") ?? ""
    }
}
