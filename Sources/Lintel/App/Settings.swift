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
    var codexEnabled: Bool { didSet { d.set(codexEnabled, forKey: "codexEnabled"); onCodexChange?() } }
    /// Hold Cursor's shell commands until you approve them in the notch (Cursor's own allowlist still applies after).
    var cursorShellApprovals: Bool { didSet { d.set(cursorShellApprovals, forKey: "cursorShellApprovals") } }
    var musicEnabled: Bool { didSet { d.set(musicEnabled, forKey: "musicEnabled") } }
    /// How the notch looks at rest on a notched display. Minimal keeps the menu bar beside the notch free.
    var notchStyle: NotchStyle { didSet { d.set(notchStyle.rawValue, forKey: "notchStyle") } }
    var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon"); onMenuBarIconChange?() } }
    var showUpNext: Bool { didSet { d.set(showUpNext, forKey: "showUpNext") } }

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
            "codexEnabled": true,
            "musicEnabled": true,
            "cursorShellApprovals": false,
            "showUpNext": true,
            "showMenuBarIcon": true,
            "notchStyle": NotchStyle.minimal.rawValue,
        ])
        appearance = AppearanceChoice(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        display = DisplayChoice(rawValue: d.string(forKey: "display2") ?? "") ?? .follow
        quickReplySeconds = d.integer(forKey: "quickReplySeconds")
        permissionTimeout = d.integer(forKey: "permissionTimeout")
        autoExpandOnAttention = d.bool(forKey: "autoExpand")
        playSounds = d.bool(forKey: "playSounds")
        codexEnabled = d.bool(forKey: "codexEnabled")
        musicEnabled = d.bool(forKey: "musicEnabled")
        cursorShellApprovals = d.bool(forKey: "cursorShellApprovals")
        showUpNext = d.bool(forKey: "showUpNext")
        showMenuBarIcon = d.bool(forKey: "showMenuBarIcon")
        notchStyle = NotchStyle(rawValue: d.string(forKey: "notchStyle") ?? "") ?? .minimal
    }
}
