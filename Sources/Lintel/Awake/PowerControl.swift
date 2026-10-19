import Foundation

/// The root half of keeping agents running with the lid closed. macOS has no public way to stop a laptop on
/// battery from sleeping when its lid shuts; `pmset -a disablesleep 1` (root) is the one switch. Set up installs,
/// once and with your admin password, a sudoers rule that allows exactly four pmset commands without a password,
/// plus a launchd watchdog that puts sleep back if Lintel quits or crashes while it's off.
/// The approach follows Insomnia (github.com/krishhgg/Insomnia, MIT).
enum PowerControl {
    static let sudoersPath = "/etc/sudoers.d/lintel"
    static let pmset = "/usr/bin/pmset"
    static let sudo = "/usr/bin/sudo"
    /// Everything Lintel ever runs as root.
    static let allowedCommands = ["-a disablesleep 1", "-a disablesleep 0", "-b lowpowermode 1", "-b lowpowermode 0"]

    static let backstopLabel = "com.razvanbadea.lintel.backstop"

    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Lintel")
    }
    static var journalURL: URL { supportDir.appendingPathComponent("awake.json") }
    static var backstopScript: URL { supportDir.appendingPathComponent("backstop.sh") }
    static var backstopPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(backstopLabel).plist")
    }

    // MARK: Commands

    struct Result { let status: Int32; let out: String; let err: String; var ok: Bool { status == 0 } }

    /// Runs a command and waits for it (call off the main thread). A command still going after `timeout` is stopped.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return Result(status: -1, out: "", err: error.localizedDescription) }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 3)
        }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(status: p.isRunning ? -1 : p.terminationStatus, out: o, err: e)
    }

    /// `sudo -n` never prompts: without the rule it fails at once instead of hanging on a password.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        let r = run(sudo, ["-n", pmset, "-a", "disablesleep", disabled ? "1" : "0"])
        if !r.ok { NSLog("Lintel: pmset disablesleep \(disabled) failed: \(r.err)") }
        return r.ok
    }

    @discardableResult
    static func setLowPowerMode(_ on: Bool) -> Bool {
        let r = run(sudo, ["-n", pmset, "-b", "lowpowermode", on ? "1" : "0"])
        if !r.ok { NSLog("Lintel: pmset lowpowermode \(on) failed: \(r.err)") }
        return r.ok
    }

    /// Neither needs root.
    static func sleepNow() { run(pmset, ["sleepnow"]) }
    static func displaySleepNow() { run(pmset, ["displaysleepnow"]) }

    // MARK: Setup

    /// The rule is in place and allows our commands, and the watchdog is installed.
    static func isSetUp() -> Bool {
        guard FileManager.default.fileExists(atPath: sudoersPath),
              FileManager.default.fileExists(atPath: backstopPlist.path) else { return false }
        // `sudo -l <command>` only checks; it runs nothing.
        return run(sudo, ["-n", "-l", pmset, "-a", "disablesleep", "0"], timeout: 5).ok
    }

    enum SetupError: LocalizedError {
        case unsupportedUser, cancelled, failed(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedUser: "Your account name has characters the sudoers rule can't hold."
            case .cancelled: "Setup was cancelled."
            case .failed(let why): why
            }
        }
    }

    /// Installs the watchdog, then asks for your admin password once to install the sudoers rule.
    static func setUp() throws {
        let user = NSUserName()
        guard !user.isEmpty, user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw SetupError.unsupportedUser
        }
        try installBackstop()
        try runAsAdmin(installRuleCommand(user: user))
        guard isSetUp() else { throw SetupError.failed("The rule was installed, but sudo doesn't accept it yet.") }
    }

    /// The root shell command that installs the rule. The rule is written by root into a folder only root can write
    /// (`mktemp -d`, mode 0700), never into a file in your home folder: anything running as you could swap such a file
    /// between visudo's check and the install, and turn your password into full root. visudo then checks it, since a
    /// broken sudoers file would lock sudo for everyone. Its only inputs are constants and the checked account name.
    static func installRuleCommand(user: String) -> String {
        let rule = "\(user) ALL=(root) NOPASSWD: " + allowedCommands.map { "\(pmset) \($0)" }.joined(separator: ", ")
        return "umask 077; T=$(/usr/bin/mktemp -d /tmp/lintel.XXXXXX) || exit 1; "
            + "/usr/bin/printf '%s\\n' '# Lintel: keeps the Mac awake while your agents run with the lid closed.' '\(rule)' > \"$T/rule\" "
            + "&& /usr/sbin/visudo -cf \"$T/rule\" "
            + "&& /usr/bin/install -m 0440 -o root -g wheel \"$T/rule\" \(sudoersPath); S=$?; /bin/rm -rf \"$T\"; exit $S"
    }

    /// `SleepDisabled` from `pmset -g` (nil if it can't be read).
    static func isSleepDisabled() -> Bool? {
        let r = run(pmset, ["-g"], timeout: 10)
        guard r.ok else { return nil }
        for line in r.out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return false
    }

    /// Removes the rule (admin password again) and the watchdog. Refuses while sleep is still off: without the rule
    /// nothing could turn it back on.
    static func remove() throws {
        if isSleepDisabled() != false, !setSleepDisabled(false) || isSleepDisabled() != false {
            throw SetupError.failed("Sleep is still off and couldn't be turned back on, so the rule was kept. Try again in a moment.")
        }
        if FileManager.default.fileExists(atPath: sudoersPath) {
            try runAsAdmin("/bin/rm -f \(sudoersPath)")
        }
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(backstopLabel)"])
        try? FileManager.default.removeItem(at: backstopPlist)
        try? FileManager.default.removeItem(at: backstopScript)
    }

    /// macOS's own password dialog, through osascript.
    private static func runAsAdmin(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with prompt \"Lintel needs your password once, so your agents can keep running with the lid closed.\" with administrator privileges"
        let r = run("/usr/bin/osascript", ["-e", script], timeout: 300)
        if r.ok { return }
        if r.err.contains("-128") { throw SetupError.cancelled }
        throw SetupError.failed(r.err.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Watchdog

    /// launchd runs this every minute. While Lintel is running (and its heartbeat is fresh) it does nothing; otherwise,
    /// if the journal says sleep is off, it resumes the apps Lintel paused and turns sleep back on.
    static let backstopSource = #"""
    #!/bin/sh
    # Lintel's watchdog. If Lintel kept the Mac awake for your agents and then quit or crashed,
    # this resumes the apps it paused and turns sleep back on. Installed by Lintel's Settings.
    export LC_ALL=C
    J="$HOME/Library/Application Support/Lintel/awake.json"
    [ -f "$J" ] || exit 0
    num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
    get() { /usr/bin/plutil -extract "$1" raw -o - "$J" 2>/dev/null; }
    HB=$(get heartbeat); num "$HB" || HB=0
    NOW=$(/bin/date +%s)
    if /usr/bin/pgrep -x Lintel >/dev/null && [ $((NOW - HB)) -lt 300 ]; then exit 0; fi
    i=0
    while P=$(get "frozen.$i.pid"); do
      i=$((i + 1))
      ST=$(get "frozen.$((i - 1)).start")
      num "$P" && num "$ST" && [ "$P" -gt 1 ] || continue
      # Only a process that is still the one Lintel paused: same pid, same start second, still stopped.
      L=$(/bin/ps -o lstart= -p "$P" 2>/dev/null | /usr/bin/sed 's/ *$//')
      [ -n "$L" ] || continue
      [ "$(/bin/date -j -f '%a %b %e %T %Y' "$L" +%s 2>/dev/null)" = "$((ST / 1000000))" ] || continue
      case "$(/bin/ps -o stat= -p "$P" 2>/dev/null)" in *T*) /bin/kill -CONT "$P" ;; esac
    done
    # Sleep first: nothing else may stand in its way. Each step is safe to repeat next minute.
    if [ "$(get sleepDisabled)" = "true" ]; then
      /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 || exit 1
      # Lid closed on battery (so no external display in use): sleep now rather than wait for macOS to notice.
      if /usr/sbin/ioreg -r -k AppleClamshellState -d 1 | /usr/bin/grep -q '"AppleClamshellState" = Yes' \
         && /usr/bin/pmset -g batt | /usr/bin/grep -q "'Battery Power'"; then
        SLEEP_NOW=1
      fi
    fi
    if [ "$(get lowPower)" = "true" ]; then
      /usr/bin/sudo -n /usr/bin/pmset -b lowpowermode 0 || exit 1
    fi
    /bin/rm -f "$J"
    [ -n "$SLEEP_NOW" ] && /usr/bin/pmset sleepnow
    exit 0
    """#

    private static func installBackstop() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: backstopPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try backstopSource.write(to: backstopScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backstopScript.path)
        let plist: [String: Any] = [
            "Label": backstopLabel,
            "ProgramArguments": ["/bin/sh", backstopScript.path],
            "StartInterval": 60,
            "RunAtLoad": true,
            "ProcessType": "Background",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: backstopPlist, options: .atomic)
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(backstopLabel)"])
        let r = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", backstopPlist.path])
        if !r.ok { throw SetupError.failed("Couldn't start the watchdog: \(r.err)") }
    }
}

/// What Lintel has changed and must undo, on disk before each change, so the watchdog (or the next launch) can
/// undo it if Lintel dies. Deleted once everything is back.
struct AwakeJournal: Codable, Equatable {
    struct Frozen: Codable, Equatable, Hashable {
        let pid: Int32
        /// Process start time (µs since 1970), so a pid reused by another process is never resumed by mistake.
        let start: Int64
        let app: String
    }

    var sleepDisabled = false
    var lowPower = false
    var frozen: [Frozen] = []
    /// Unix seconds; refreshed every minute while sleep is off, so the watchdog can tell a hung Lintel.
    var heartbeat = Int(Date().timeIntervalSince1970)

    var isEmpty: Bool { !sleepDisabled && !lowPower && frozen.isEmpty }

    static func load() -> AwakeJournal? {
        guard let data = try? Data(contentsOf: PowerControl.journalURL) else { return nil }
        return try? JSONDecoder().decode(AwakeJournal.self, from: data)
    }

    func save() {
        var j = self
        j.heartbeat = Int(Date().timeIntervalSince1970)
        let url = PowerControl.journalURL
        if j.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: PowerControl.supportDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(j) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
