import Foundation
import Observation
import SQLite3

/// Plan usage per tool — how much of the short (5-hour) and weekly windows is used, and when they reset.
///  - Claude: exact numbers by asking Claude Code itself (`get_usage`, the request its /usage screen uses —
///    no model call, hooks off, nothing saved) or from its status line feed; the Claude app's usage log
///    (sampled every ~15 min) is only a fallback.
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

    private(set) var usage: [AgentKind: Usage] = [:] {
        didSet { for (k, u) in usage where u != oldValue[k] { UsageAlerts.check(k, u) } }
    }

    @ObservationIgnored private var lastExact = Date.distantPast
    @ObservationIgnored private var lastProbe = Date.distantPast
    @ObservationIgnored private var probe: Process?
    @ObservationIgnored private var probeAnswered = false
    @ObservationIgnored private var probeFailures = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let claudeLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    @ObservationIgnored private var claudeLogModified = Date.distantPast

    func start() {
        probeClaude(minInterval: 0)
        refreshLocal()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLocal() }
        }
        timer?.tolerance = 15
    }

    private func refreshLocal() {
        // Exact numbers while Claude is in use; the app's log only when we have nothing better.
        if AgentStore.shared.sessions.contains(where: { $0.kind == .claude }) { probeClaude(minInterval: 170) }
        // The app's 15-minute log is only a fallback for when Claude Code can't be asked.
        if (Self.claudeExecutable() == nil || probeFailures > 0), Date().timeIntervalSince(lastExact) > 15 * 60 { readClaudeAppLog() }
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
        guard Date() > demoUntil else { return }
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
        lastExact = Date()
        if u != usage[.claude] { usage[.claude] = u }
    }

    @ObservationIgnored private var demoUntil = Date.distantPast

    /// Developer demo: plausible numbers for screenshots.
    func showDemo() {
        demoUntil = Date().addingTimeInterval(30)
        usage[.claude] = Usage(short: Window(usedPercent: 38, resetsAt: Date().addingTimeInterval(2 * 3600 + 14 * 60)),
                               weekly: Window(usedPercent: 21, resetsAt: nil), plan: "Pro")
        usage[.cursor] = Usage(plan: "Pro")
        usage[.codex] = Usage(short: Window(usedPercent: 12, resetsAt: Date().addingTimeInterval(4 * 3600)),
                              weekly: Window(usedPercent: 9, resetsAt: nil), plan: "Plus")
        lastExact = Date().addingTimeInterval(3600)
    }

    // MARK: Claude — ask Claude Code

    /// Runs `claude -p` in stream-json mode and sends one `get_usage` control request.
    func probeClaude(minInterval: TimeInterval = 60) {
        guard probe == nil, Date().timeIntervalSince(lastProbe) > minInterval, let exe = Self.claudeExecutable() else { return }
        lastProbe = Date()
        probeAnswered = false
        let dir = AgentHooks.dir.appendingPathComponent("probe")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#]
        p.currentDirectoryURL = dir
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            for line in buffer.append(chunk) {
                guard let d = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      d["type"] as? String == "control_response",
                      let resp = (d["response"] as? [String: Any])?["response"] as? [String: Any] else { continue }
                h.readabilityHandler = nil
                DispatchQueue.main.async {
                    self?.probeAnswered = true
                    self?.probeFailures = 0
                    self?.applyClaudeUsage(resp)
                    self?.finishProbe()
                }
            }
        }
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.probe = nil } }
        do {
            try p.run()
            probe = p
            let req = #"{"type":"control_request","request_id":"lintel","request":{"subtype":"get_usage","skip_behaviors":true}}"#
            try input.fileHandleForWriting.write(contentsOf: Data((req + "\n").utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.finishProbe() }
        } catch {
            probe = nil
        }
    }

    private func finishProbe() {
        guard let p = probe else { return }
        if !probeAnswered { probeFailures += 1; refreshLocal() }
        if p.isRunning { p.terminate() }
        probe = nil
    }

    private func applyClaudeUsage(_ resp: [String: Any]) {
        guard let limits = resp["rate_limits"] as? [String: Any] else { return }
        applyClaudeStatusLine(["rate_limits": limits])
        if let plan = resp["subscription_type"] as? String {
            usage[.claude]?.plan = plan.capitalized
        }
    }

    nonisolated private static func claudeExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
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

/// Accumulates bytes from a pipe and hands back complete lines (used from the pipe's own queue only).
final class LineBuffer: @unchecked Sendable {
    private var data = Data()

    func append(_ chunk: Data) -> [Data] {
        data.append(chunk)
        var lines: [Data] = []
        while let nl = data.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(Data(data[data.startIndex..<nl]))
            data.removeSubrange(data.startIndex...nl)
        }
        return lines
    }
}
