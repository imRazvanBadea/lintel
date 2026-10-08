import AppKit
import Darwin

/// Small helpers around the BSD process table (no permissions needed).
enum Proc {
    static func info(_ pid: pid_t) -> (ppid: pid_t, name: String)? {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafePointer(to: &kinfo.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        return (kinfo.kp_eproc.e_ppid, name)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// Walks up from the hook's parent to find the long-lived agent process (claude / node).
    static func agentProcess(from pid: pid_t) -> pid_t? {
        var p = pid
        for _ in 0..<6 {
            guard p > 1, let i = info(p) else { return nil }
            let n = i.name.lowercased()
            if n.contains("claude") || n == "node" || n == "bun" { return p }
            p = i.ppid
        }
        return nil
    }

    /// The GUI app (terminal, editor, Claude desktop…) hosting a process.
    static func hostingApp(of pid: pid_t) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<20 {
            guard p > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            guard let i = info(p) else { return nil }
            p = i.ppid
        }
        return nil
    }
}
