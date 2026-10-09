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
        didSet { for (k, u) in usage where u != oldValue[k] { UsageAlerts.check(k.label, key: k.rawValue, u) } }
    }

    @ObservationIgnored private var lastExact = Date.distantPast
    @ObservationIgnored private var lastProbe = Date.distantPast
    @ObservationIgnored private var probing = false
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

    /// Asks Claude Code for the default account's plan usage (throttled).
    func probeClaude(minInterval: TimeInterval = 60) {
        guard !probing, Date().timeIntervalSince(lastProbe) > minInterval else { return }
        lastProbe = Date()
        probing = true
        Self.askClaudeCode(configDir: nil) { [weak self] resp in
            guard let self else { return }
            self.probing = false
            if let resp, let limits = resp["rate_limits"] as? [String: Any] {
                self.probeFailures = 0
                self.applyClaudeStatusLine(["rate_limits": limits])
                if let plan = resp["subscription_type"] as? String { self.usage[.claude]?.plan = plan.capitalized }
            } else {
                self.probeFailures += 1
                self.refreshLocal()
            }
            self.probeExtraAccounts()
        }
    }

    /// Runs `claude -p` in stream-json mode, sends one `get_usage` control request (the data behind /usage —
    /// no model call), with hooks disabled and nothing saved. `configDir` selects another login (CLAUDE_CONFIG_DIR).
    static func askClaudeCode(configDir: URL?, completion: @escaping @MainActor ([String: Any]?) -> Void) {
        guard let exe = claudeExecutable() else { completion(nil); return }
        let dir = AgentHooks.dir.appendingPathComponent("probe")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--no-session-persistence", "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#]
        // A clean environment: if Lintel was started from inside a Claude Code session it inherits variables
        // (CLAUDECODE, CLAUDE_CODE_ENTRYPOINT, …) that make this child wait on a host app that isn't there.
        var env = ProcessInfo.processInfo.environment.filter { k, _ in
            !(k.hasPrefix("CLAUDE") || k.hasPrefix("ANTHROPIC_") || k == "AI_AGENT" || k.hasPrefix("MCP_"))
        }
        if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir.path }

        let buffer = LineBuffer()
        let done = OnceFlag()
        let box = ChildBox()
        let finish: @Sendable ([String: Any]?) -> Void = { resp in
            guard done.claim() else { return }
            if let child = box.child {
                child.stdout.readabilityHandler = nil
                try? child.stdin.close()
                // Claude Code may ignore SIGTERM while a request is in flight; don't leave it behind.
                child.kill()
            }
            nonisolated(unsafe) let r = resp
            DispatchQueue.main.async { completion(r) }
        }
        guard let child = Spawn.run(exe, args, environment: env, directory: dir.path, onExit: { finish(nil) }) else {
            completion(nil); return
        }
        box.child = child
        child.stdout.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            for line in buffer.append(chunk) {
                guard let d = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      d["type"] as? String == "control_response",
                      let resp = (d["response"] as? [String: Any])?["response"] as? [String: Any] else { continue }
                finish(resp)
            }
        }
        let req = #"{"type":"control_request","request_id":"lintel","request":{"subtype":"get_usage","skip_behaviors":true}}"#
        try? child.stdin.write(contentsOf: Data((req + "\n").utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { finish(nil) }
    }

    // MARK: Extra accounts (~/.claude-work, ~/.codex-work, …)

    /// Accounts beyond the default ones, discovered from ~/.claude-* and ~/.codex-* folders.
    private(set) var extraUsage: [Account: Usage] = [:] {
        didSet { for (a, u) in extraUsage where u != oldValue[a] { UsageAlerts.check(a.label, key: a.id, u) } }
    }
    @ObservationIgnored private var lastExtraProbe = Date.distantPast

    func probeExtraAccounts(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastExtraProbe) > 150 else { return }
        lastExtraProbe = Date()
        let accounts = Account.discover()
        func next(_ rest: ArraySlice<Account>) {
            guard let a = rest.first else { return }
            switch a.kind {
            case .claude:
                Self.askClaudeCode(configDir: a.dir) { resp in
                    if let limits = resp?["rate_limits"] as? [String: Any] {
                        var u = Self.claudeUsage(from: limits)
                        u.plan = (resp?["subscription_type"] as? String)?.capitalized
                        self.extraUsage[a] = u
                    }
                    next(rest.dropFirst())
                }
            case .codex:
                let home = a.dir
                DispatchQueue.global(qos: .utility).async {
                    let limits = Self.latestCodexRateLimits(home: home)
                    nonisolated(unsafe) let l = limits
                    DispatchQueue.main.async {
                        if let l { self.extraUsage[a] = Self.codexUsage(from: l, previous: self.extraUsage[a]) }
                        next(rest.dropFirst())
                    }
                }
            case .cursor:
                next(rest.dropFirst())
            }
        }
        next(accounts[...])
    }

    nonisolated static func claudeUsage(from limits: [String: Any]) -> Usage {
        func window(_ key: String) -> Window? {
            guard let w = limits[key] as? [String: Any] else { return nil }
            let used = (w["used_percentage"] as? NSNumber)?.doubleValue ?? (w["utilization"] as? NSNumber)?.doubleValue ?? 0
            return Window(usedPercent: used, resetsAt: date(w["resets_at"]))
        }
        return Usage(short: window("five_hour"), weekly: window("seven_day"))
    }

    nonisolated static func codexUsage(from limits: [String: Any], previous: Usage?) -> Usage {
        func window(_ key: String) -> Window? {
            guard let w = limits[key] as? [String: Any] else { return nil }
            return Window(usedPercent: (w["used_percent"] as? NSNumber)?.doubleValue ?? 0, resetsAt: date(w["resets_at"]))
        }
        var u = previous ?? Usage()
        let p = window("primary"), s = window("secondary")
        let pMin = ((limits["primary"] as? [String: Any])?["window_minutes"] as? NSNumber)?.intValue ?? 300
        if pMin <= 600 { u.short = p; u.weekly = s } else { u.short = s; u.weekly = p }
        if let plan = limits["plan_type"] as? String { u.plan = plan.capitalized }
        u.updatedAt = Date()
        return u
    }

    /// The newest `rate_limits` Codex wrote in a home's session logs (tail of the most recent rollout).
    nonisolated static func latestCodexRateLimits(home: URL) -> [String: Any]? {
        let root = home.appendingPathComponent("sessions")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: (URL, Date)?
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if newest == nil || m > newest!.1 { newest = (url, m) }
        }
        guard let file = newest?.0, let fh = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? fh.readToEnd() else { return nil }
        for line in data.split(separator: 10).reversed() {
            guard let d = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let p = d["payload"] as? [String: Any], let rl = p["rate_limits"] as? [String: Any] else { continue }
            return rl
        }
        return nil
    }

    nonisolated static func claudeExecutable() -> String? {
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

/// Guards a completion that several paths may race to call.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// The probe's child, set once it has started (the exit callback can race the assignment).
final class ChildBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Spawn.Child?
    var child: Spawn.Child? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// A login beyond the default one: ~/.claude-work (Claude Code, via CLAUDE_CONFIG_DIR) or ~/.codex-work (CODEX_HOME).
struct Account: Hashable, Identifiable {
    let kind: AgentKind
    let dir: URL
    var slug: String { String(dir.lastPathComponent.split(separator: "-", maxSplits: 1).last ?? "") }
    var id: String { "\(kind.rawValue)-\(slug)" }
    var label: String { "\(kind.label) (\(slug))" }

    /// Folders the tools have actually used, in alphabetical order (the default accounts aren't included).
    static func discover() -> [Account] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []).sorted()
        return names.compactMap { name in
            let url = home.appendingPathComponent(name)
            if name.hasPrefix(".claude-"), FileManager.default.fileExists(atPath: url.appendingPathComponent("projects").path) {
                return Account(kind: .claude, dir: url)
            }
            if name.hasPrefix(".codex-"), FileManager.default.fileExists(atPath: url.appendingPathComponent("sessions").path) {
                return Account(kind: .codex, dir: url)
            }
            return nil
        }
    }
}
