import Foundation
import Observation
import ServiceManagement

enum DisplayChoice: String, CaseIterable, Identifiable {
    case auto, builtIn, main
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Automatic (notch if available)"
        case .builtIn: "Built-in display"
        case .main: "Main display"
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor @Observable
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var display: DisplayChoice { didSet { d.set(display.rawValue, forKey: "display"); onDisplayChange?() } }
    /// Seconds the "Finished" card keeps the Claude turn open so you can send a follow-up. 0 disables.
    var quickReplySeconds: Int { didSet { d.set(quickReplySeconds, forKey: "quickReplySeconds") } }
    /// Seconds to wait for a decision in the notch before handing the prompt back to the terminal.
    var permissionTimeout: Int { didSet { d.set(permissionTimeout, forKey: "permissionTimeout") } }
    var autoExpandOnAttention: Bool { didSet { d.set(autoExpandOnAttention, forKey: "autoExpand") } }
    var playSounds: Bool { didSet { d.set(playSounds, forKey: "playSounds") } }
    var codexEnabled: Bool { didSet { d.set(codexEnabled, forKey: "codexEnabled"); onCodexChange?() } }
    var appleMusicEnabled: Bool { didSet { d.set(appleMusicEnabled, forKey: "appleMusic") } }
    var youTubeMusicEnabled: Bool { didSet { d.set(youTubeMusicEnabled, forKey: "youTubeMusic") } }
    var hideMusicWhenIdle: Bool { didSet { d.set(hideMusicWhenIdle, forKey: "hideMusicWhenIdle") } }
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
    @ObservationIgnored var onCodexChange: (() -> Void)?

    private init() {
        d.register(defaults: [
            "display": DisplayChoice.auto.rawValue,
            "quickReplySeconds": 25,
            "permissionTimeout": 600,
            "autoExpand": true,
            "playSounds": true,
            "codexEnabled": true,
            "appleMusic": true,
            "youTubeMusic": true,
            "hideMusicWhenIdle": false,
            "showUpNext": true,
        ])
        display = DisplayChoice(rawValue: d.string(forKey: "display") ?? "") ?? .auto
        quickReplySeconds = d.integer(forKey: "quickReplySeconds")
        permissionTimeout = d.integer(forKey: "permissionTimeout")
        autoExpandOnAttention = d.bool(forKey: "autoExpand")
        playSounds = d.bool(forKey: "playSounds")
        codexEnabled = d.bool(forKey: "codexEnabled")
        appleMusicEnabled = d.bool(forKey: "appleMusic")
        youTubeMusicEnabled = d.bool(forKey: "youTubeMusic")
        hideMusicWhenIdle = d.bool(forKey: "hideMusicWhenIdle")
        showUpNext = d.bool(forKey: "showUpNext")
    }
}
