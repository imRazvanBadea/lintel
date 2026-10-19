import AppKit
import Darwin

/// Pauses the apps your agents don't need while the lid is closed (SIGSTOP on the app and every process under it)
/// and resumes them when it opens (SIGCONT, only to processes it can prove it paused).
/// Everything hosting a session Lintel shows is left running, and so is a fixed list of apps agents depend on.
/// The protected list and the stop/verify approach come from Insomnia (github.com/krishhgg/Insomnia, MIT).
@MainActor
enum AppFreezer {
    /// Never paused: editors and agent hosts, terminals, browsers agents drive, VPN, local models, password
    /// managers, local databases and containers, and meeting, recording and dictation apps.
    static let protected: Set<String> = [
        // Editors and agent hosts
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "com.google.antigravity", "com.google.antigravity-ide",
        "com.google.android.studio", "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova",
        "com.anthropic.claudefordesktop", "com.openai.codex", "com.openai.chat", "com.conductor.app",
        "com.t3tools.t3code", "com.t3tools.t3code.reasoning",
        // Terminals
        "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "com.googlecode.iterm2", "org.alacritty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "org.tabby", "co.zeit.hyper",
        // Browsers
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.google.Chrome", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "app.zen-browser.zen",
        // VPN, local models, containers, databases, password managers
        "io.tailscale.ipn.macsys", "io.tailscale.ipn.macos", "ai.elementlabs.lmstudio", "com.electron.ollama",
        "com.docker.docker", "com.electron.dockerdesktop", "dev.kdrag0n.MacVirt", "com.postgresapp.Postgres2",
        "com.1password.1password", "com.bitwarden.desktop",
        // Meetings, recording, dictation: pausing one ends the call or the recording
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp",
        "com.electron.wispr-flow", "com.granola.app", "com.otterai.desktop", "com.obsproject.obs-studio", "com.loom.desktop",
    ]
    static let protectedPrefixes = ["com.jetbrains.", "us.zoom.", "com.cisco.webex.", "com.electron.wispr-flow."]

    /// Apple's apps are left alone (Finder, Terminal, Xcode, System Settings…), except these, which only cost battery.
    static let pausableApple: Set<String> = [
        "com.apple.MobileSMS", "com.apple.mail", "com.apple.Music", "com.apple.podcasts", "com.apple.TV",
        "com.apple.news", "com.apple.Photos", "com.apple.iBooksX", "com.apple.stocks", "com.apple.freeform", "com.apple.Maps",
    ]

    static func isProtected(_ bundleID: String) -> Bool {
        if bundleID.hasPrefix("com.apple.") { return !pausableApple.contains(bundleID) }
        return protected.contains(bundleID) || protectedPrefixes.contains { bundleID.hasPrefix($0) }
    }

    // MARK: Processes

    struct ProcInfo { let pid: pid_t; let ppid: pid_t; let start: Int64; let stopped: Bool }

    /// Every process of this user (the only ones we could signal anyway).
    static func snapshot() -> [pid_t: ProcInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [:] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = buf.count * stride
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return [:] }
        var out: [pid_t: ProcInfo] = [:]
        for k in buf.prefix(size / stride) {
            let tv = k.kp_proc.p_un.__p_starttime
            out[k.kp_proc.p_pid] = ProcInfo(pid: k.kp_proc.p_pid, ppid: k.kp_eproc.e_ppid,
                                            start: Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec),
                                            stopped: k.kp_proc.p_stat == SSTOP)
        }
        return out
    }

    static func startTime(of pid: pid_t) -> Int64? {
        var k = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &k, &size, nil, 0) == 0, size > 0, k.kp_proc.p_pid == pid else { return nil }
        let tv = k.kp_proc.p_un.__p_starttime
        return Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec)
    }

    // MARK: Freeze

    /// An app about to be paused: its main process first, then everything under it.
    struct Group { let name: String; let bundleID: String; let procs: [ProcInfo] }

    /// What would be paused right now. `keepBundles` are the apps hosting sessions; `agentPIDs` are the agents'
    /// own processes: nothing above or below one of them is ever touched, whichever app it belongs to.
    static func plan(keepBundles: Set<String>, agentPIDs: [pid_t]) -> [Group] {
        let procs = snapshot()
        var children: [pid_t: [pid_t]] = [:]
        for p in procs.values { children[p.ppid, default: []].append(p.pid) }
        func descendants(_ pid: pid_t) -> [pid_t] {
            var out: [pid_t] = [], queue = children[pid] ?? []
            while let p = queue.popLast() {
                out.append(p)
                queue += children[p] ?? []
            }
            return out
        }
        // The agents, everything they started, and every process above them.
        var untouchable: Set<pid_t> = [getpid()]
        for a in agentPIDs where procs[a] != nil {
            untouchable.formUnion(descendants(a))
            var p = a
            while p > 1, let info = procs[p] { untouchable.insert(p); p = info.ppid }
        }

        let me = Bundle.main.bundleIdentifier
        var groups: [Group] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != me, !isProtected(id), !keepBundles.contains(id),
                  !app.isTerminated, !untouchable.contains(app.processIdentifier),
                  let main = procs[app.processIdentifier], !main.stopped else { continue }
            let rest = descendants(main.pid).filter { !untouchable.contains($0) }.compactMap { procs[$0] }.filter { !$0.stopped }
            groups.append(Group(name: app.localizedName ?? id, bundleID: id, procs: [main] + rest))
        }
        return groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The entries to journal for `groups`, before anything is stopped.
    static func journalEntries(_ groups: [Group]) -> [AwakeJournal.Frozen] {
        groups.flatMap { g in g.procs.map { AwakeJournal.Frozen(pid: $0.pid, start: $0.start, app: g.name) } }
    }

    /// Stops each journaled process that is still the one planned. Returns the ones actually stopped.
    static func freeze(_ entries: [AwakeJournal.Frozen]) -> [AwakeJournal.Frozen] {
        // pid > 1 always: kill(0) and kill(-1) would signal whole process groups.
        entries.filter { e in e.pid > 1 && startTime(of: e.pid) == e.start && kill(e.pid, SIGSTOP) == 0 }
    }

    /// Resumes processes we stopped, children before parents. Returns any that couldn't be resumed (still stopped).
    @discardableResult
    static func resume(_ entries: [AwakeJournal.Frozen]) -> [AwakeJournal.Frozen] {
        entries.reversed().filter { e in
            guard e.pid > 1, startTime(of: e.pid) == e.start else { return false } // gone, or the pid now belongs to someone else
            return kill(e.pid, SIGCONT) != 0 && errno != ESRCH
        }
    }
}
