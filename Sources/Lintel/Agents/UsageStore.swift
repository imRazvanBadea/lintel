import Foundation
import Observation
import SQLite3

/// Plan usage per tool — how much of the short (5-hour) and weekly windows is used, and when they reset.
///  - Claude: exact numbers from Claude Code's status line feed (`rate_limits`); otherwise the Claude app's
///    own usage log (percentages, sampled every ~15 min; the reset time is then estimated).
///  - Codex: `rate_limits` from its session logs (exact, with reset times).
///  - Cursor: only the plan is stored locally; usage itself lives behind Cursor's login.
@MainActor @Observable
final class UsageStore {
    static let shared = UsageStore()

    struct Window: Equatable {
        var usedPercent: Double
        var resetsAt: Date?
        var estimated = false
    }

    struct Usage: Equatable {
        var short: Window?          // 5-hour window
        var weekly: Window?
        var plan: String?
        var updatedAt = Date()
        var note: String?
    }

    private(set) var usage: [AgentKind: Usage] = [:]

    @ObservationIgnored private var lastStatusLine = Date.distantPast
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let claudeLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    @ObservationIgnored private var claudeLogModified = Date.distantPast

    func start() {
        refreshLocal()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLocal() }
        }
        timer?.tolerance = 15
    }

    private func refreshLocal() {
        // The status line feed is exact; only fall back to the app log when it's gone quiet.
        if Date().timeIntervalSince(lastStatusLine) > 10 * 60 { readClaudeAppLog() }
        if usage[.cursor]?.plan == nil, let plan = Self.cursorPlan() {
            usage[.cursor] = Usage(plan: plan.capitalized, note: "Usage is shown in Cursor's dashboard")
        }
        expireResetWindows()
    }

    /// Once a window's reset time passes, it's back at zero.
    private func expireResetWindows() {
        let now = Date()
        for (k, var u) in usage {
            var changed = false
            if let r = u.short?.resetsAt, r < now { u.short = Window(usedPercent: 0, resetsAt: nil); changed = true }
            if let r = u.weekly?.resetsAt, r < now { u.weekly = Window(usedPercent: 0, resetsAt: nil); changed = true }
            if changed { usage[k] = u }
        }
    }

    // MARK: Claude

    /// From Claude Code's status line JSON: rate_limits.{five_hour, seven_day}.{used_percentage, resets_at}
    func applyClaudeStatusLine(_ json: [String: Any]) {
        guard let limits = json["rate_limits"] as? [String: Any] else { return }
        func window(_ key: String) -> Window? {
            guard let w = limits[key] as? [String: Any] else { return nil }
            let used = (w["used_percentage"] as? NSNumber)?.doubleValue ?? (w["utilization"] as? NSNumber)?.doubleValue ?? 0
            return Window(usedPercent: used, resetsAt: Self.date(w["resets_at"]))
        }
        var u = usage[.claude] ?? Usage()
        u.short = window("five_hour") ?? u.short
        u.weekly = window("seven_day") ?? u.weekly
        u.updatedAt = Date()
        u.note = nil
        lastStatusLine = Date()
        if u != usage[.claude] { usage[.claude] = u }
    }

    private func readClaudeAppLog() {
        let url = claudeLog
        guard let mod = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date,
              mod > claudeLogModified else { return }
        claudeLogModified = mod
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let samples = obj["samples"] as? [[String: Any]] else { return }
            let points: [(t: Date, fh: Double, sd: Double)] = samples.compactMap {
                guard let t = ($0["t"] as? NSNumber)?.doubleValue, let u = $0["u"] as? [String: Any] else { return nil }
                return (Date(timeIntervalSince1970: t / 1000),
                        (u["fh"] as? NSNumber)?.doubleValue ?? 0, (u["sd"] as? NSNumber)?.doubleValue ?? 0)
            }
            guard let last = points.last else { return }
            // Estimate the 5-hour reset: the window opened at the first sample after the last drop to zero.
            var start: Date?
            if last.fh > 0 {
                for (i, p) in points.enumerated().reversed() {
                    if i == 0 || points[i - 1].fh > p.fh || points[i - 1].fh == 0 { start = p.t; break }
                }
            }
            let reset = start.map { $0.addingTimeInterval(5 * 3600) }
            let stale = Date().timeIntervalSince(last.t) > 5 * 3600
            await MainActor.run {
                var u = UsageStore.shared.usage[.claude] ?? Usage()
                u.short = Window(usedPercent: stale ? 0 : last.fh, resetsAt: (reset ?? .distantPast) > Date() ? reset : nil, estimated: true)
                u.weekly = Window(usedPercent: last.sd, resetsAt: nil, estimated: true)
                u.updatedAt = last.t
                u.note = nil
                UsageStore.shared.usage[.claude] = u
            }
        }
    }

    // MARK: Codex

    /// From a Codex `token_count` event's `rate_limits`.
    func applyCodex(_ limits: [String: Any]) {
        func window(_ key: String) -> Window? {
            guard let w = limits[key] as? [String: Any] else { return nil }
            return Window(usedPercent: (w["used_percent"] as? NSNumber)?.doubleValue ?? 0, resetsAt: Self.date(w["resets_at"]))
        }
        var u = usage[.codex] ?? Usage()
        // Codex labels windows by length; the shorter one is the 5-hour window.
        let p = window("primary"), s = window("secondary")
        let pMin = ((limits["primary"] as? [String: Any])?["window_minutes"] as? NSNumber)?.intValue ?? 300
        if pMin <= 600 { u.short = p; u.weekly = s } else { u.short = s; u.weekly = p }
        if let plan = limits["plan_type"] as? String { u.plan = plan.capitalized }
        u.updatedAt = Date()
        if u != usage[.codex] { usage[.codex] = u }
        expireResetWindows()
    }

    // MARK: Cursor

    nonisolated private static func cursorPlan() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/stripeMembershipType'", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    // MARK: Helpers

    /// Accepts epoch seconds, epoch milliseconds or ISO-8601 strings.
    nonisolated static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber {
            let d = n.doubleValue
            return Date(timeIntervalSince1970: d > 10_000_000_000 ? d / 1000 : d)
        }
        if let s = v as? String {
            if let d = Double(s) { return date(NSNumber(value: d)) }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
        return nil
    }
}
