import Foundation
@preconcurrency import UserNotifications

/// A notification when a plan window crosses 80% and 100% — once per crossing, and again only after the
/// window has reset. macOS asks for permission on the first real alert, not at launch.
@MainActor
enum UsageAlerts {
    /// "claude.5-hour" -> "level|resetEpoch": what was last announced for which window, kept across launches.
    private static var notified: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "usageAlertsNotified") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "usageAlertsNotified") }
    }

    /// `label` names the account in the notification ("Claude", "Claude (work)"); `key` identifies it.
    static func check(_ label: String, key accountKey: String, _ usage: UsageStore.Usage) {
        guard Settings.shared.usageAlerts else { return }
        for (windowName, window) in [("5-hour", usage.short), ("weekly", usage.weekly)] {
            guard let w = window, !w.estimated else { continue }
            let key = "\(accountKey).\(windowName)"
            let level = w.usedPercent >= 100 ? 100 : (w.usedPercent >= 80 ? 80 : 0)
            // A window is identified by when it resets (rounded, since it can wobble by a second).
            let windowID = w.resetsAt.map { String(Int($0.timeIntervalSince1970 / 600)) } ?? "?"
            let parts = (notified[key] ?? "0|").split(separator: "|", omittingEmptySubsequences: false)
            let previous = parts.first.flatMap { Int($0) } ?? 0
            let sameWindow = parts.count > 1 && String(parts[1]) == windowID
            guard level > 0, !(sameWindow && level <= previous) else { continue }
            notified[key] = "\(level)|\(windowID)"
            send(account: label, key: accountKey, window: windowName, level: level, resetsAt: w.resetsAt)
        }
    }

    private static func send(account: String, key: String, window: String, level: Int, resetsAt: Date?) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = level >= 100 ? "\(account): \(window) limit reached" : "\(account): \(level)% of the \(window) limit used"
            if let r = resetsAt {
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .full
                content.body = "Resets \(f.localizedString(for: r, relativeTo: Date()))."
            }
            content.sound = nil // Lintel plays its own sounds
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lintel.usage.\(key).\(window).\(level)", content: content, trigger: nil))
        }
    }
}
