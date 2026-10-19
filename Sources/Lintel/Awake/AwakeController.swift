import AppKit
import IOKit.ps
import Observation
@preconcurrency import UserNotifications

/// Keeps the Mac awake for exactly as long as the agents Lintel shows are running, so you can close the lid and
/// walk away. No timer: sleep goes off when an agent starts working and back on a couple of minutes after the
/// last one stops.
///
/// - **Armed** (an agent is running): `pmset disablesleep 1`. It has to be on *before* the lid closes; a normal Mac
///   is already asleep by the time any app hears about it.
/// - **Lid closed** while armed: pause the apps agents don't need, turn the display off, Low Power Mode on, and
///   watch for the Wi-Fi dropping (Hotspot Hopper). Opening the lid undoes all of it.
/// - **Done** (no running agents for `idleGrace`, battery low, or the Mac critically hot): undo everything, turn
///   sleep back on, and if the lid is closed, sleep now.
///
/// Every change is journaled first (`AwakeJournal`), so the launchd watchdog or the next launch can undo it if
/// Lintel dies halfway.
@MainActor @Observable
final class AwakeController {
    static let shared = AwakeController()

    enum Mode: Equatable { case off, armed, lidClosed }

    private(set) var mode: Mode = .off
    private(set) var isSetUp = false
    /// Why it isn't keeping the Mac awake although agents are running (low battery, heat, a failed command).
    private(set) var blockedReason: String?
    private(set) var pausedApps: [String] = []

    /// A working agent with no news for this long is treated as stuck, so it can't keep the Mac up all night.
    static let stallLimit: TimeInterval = 30 * 60
    /// How long to stay awake after the last agent stops (a follow-up turn, a subagent, a quick reply).
    static let idleGrace: TimeInterval = 2 * 60
    static let batteryFloor = 10
    static let batteryResume = 15

    @ObservationIgnored private var journal = AwakeJournal()
    @ObservationIgnored private let lid = LidObserver()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var idleSince: Date?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var lastHeartbeat = Date.distantPast
    @ObservationIgnored private var displayAsleepAt = Date.distantPast
    @ObservationIgnored private var batteryLow = false
    @ObservationIgnored private var blockedBySafety = false
    /// pmset runs here, in order, off the main thread.
    @ObservationIgnored private let queue = DispatchQueue(label: "lintel.awake")

    var hasLid: Bool { LidObserver.readClamshell() != nil }

    func start() {
        recoverFromLastRun()
        refreshSetup()
        lid.onChange = { [weak self] closed in self?.lidChanged(closed: closed) }
        lid.start()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common) // keeps ticking while a menu is open
        timer = t
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func refreshSetup() {
        queue.async {
            let ok = PowerControl.isSetUp()
            DispatchQueue.main.async { self.isSetUp = ok }
        }
    }

    // MARK: Setup

    func setUp(_ done: @escaping (Error?) -> Void) {
        queue.async {
            var failure: Error?
            do { try PowerControl.setUp() } catch { failure = error }
            let ok = PowerControl.isSetUp()
            DispatchQueue.main.async {
                self.isSetUp = ok
                self.blockedReason = nil
                done(failure)
                self.tick()
            }
        }
    }

    func removeSetup(_ done: @escaping (Error?) -> Void) {
        disarm(sleepIfClosed: false)
        queue.async {
            var failure: Error?
            do { try PowerControl.remove() } catch { failure = error }
            let ok = PowerControl.isSetUp()
            DispatchQueue.main.async { self.isSetUp = ok; done(failure) }
        }
    }

    // MARK: Deciding

    /// Agents that should keep the Mac awake: working (and not stuck), or waiting on you for up to your prompt
    /// timeout, in case you answer from elsewhere or open the lid.
    var runningAgents: [AgentSession] {
        let store = AgentStore.shared
        let now = Date()
        let waitLimit = TimeInterval(Settings.shared.permissionTimeout > 0 ? Settings.shared.permissionTimeout : 3600)
        return store.sessions.filter { s in
            if let pid = s.agentPID, !Proc.isAlive(pid) { return false }
            switch s.status {
            case .working:
                return now.timeIntervalSince(s.lastEventAt) < Self.stallLimit
            case .waiting:
                let since = store.pendingFor(s).filter(\.isBlocking).map(\.createdAt).min() ?? s.lastEventAt
                return now.timeIntervalSince(since) < waitLimit
            case .finished, .idle:
                return false
            }
        }
    }

    private func tick() {
        let enabled = Settings.shared.keepAgentsAwake && isSetUp
        let agentsRunning = !runningAgents.isEmpty
        let safety = safetyStop()
        if let safety, enabled, agentsRunning {
            blockedReason = safety
            blockedBySafety = true
        } else if blockedBySafety {
            blockedReason = nil
            blockedBySafety = false
        }

        if enabled && agentsRunning && safety == nil {
            idleSince = nil
            if mode == .off { arm() }
        } else if mode != .off {
            if let safety {
                notify("Your Mac can sleep again", safety)
                disarm(sleepIfClosed: true)
            } else if !enabled {
                disarm(sleepIfClosed: false)
            } else {
                let since = idleSince ?? Date()
                idleSince = since
                if Date().timeIntervalSince(since) >= Self.idleGrace {
                    if mode == .lidClosed { notify("Agents finished", "Your Mac is going to sleep.") }
                    disarm(sleepIfClosed: true)
                }
            }
        }

        if mode != .off {
            if Date().timeIntervalSince(lastHeartbeat) > 60 { journal.save(); lastHeartbeat = Date() }
            // The panel can wake by itself under a closed lid; keep it dark.
            if mode == .lidClosed, Date().timeIntervalSince(displayAsleepAt) > 300 {
                displayAsleepAt = Date()
                queue.async { PowerControl.displaySleepNow() }
            }
        }
    }

    /// Battery below the floor on battery power, critical heat, or serious heat with the lid closed (agents are light;
    /// a closed Mac getting that hot is likely somewhere it can't breathe, like a bag).
    private func safetyStop() -> String? {
        let heat = ProcessInfo.processInfo.thermalState
        if heat == .critical || (heat == .serious && lid.isClosed && !Self.externalDisplayConnected()) {
            return "Your Mac got too hot, so it's allowed to sleep."
        }
        if let b = Self.battery(), !b.onAC {
            if b.percent <= Self.batteryFloor { batteryLow = true }
            else if b.percent >= Self.batteryResume { batteryLow = false }
            if batteryLow { return "Battery is at \(b.percent)%, so your Mac is allowed to sleep." }
        } else {
            batteryLow = false
        }
        return nil
    }

    // MARK: Arm / disarm

    private func arm() {
        journal.sleepDisabled = true
        journal.save()
        lastHeartbeat = Date()
        mode = .armed
        blockedReason = nil
        // A hidden menu-bar app gets App Nap'd; with the lid closed that would slow the hook server agents talk to.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Agents are running")
        HotspotHopper.shared.prepare()
        queue.async {
            let ok = PowerControl.setSleepDisabled(true)
            DispatchQueue.main.async {
                guard !ok, self.mode != .off else { return }
                self.blockedReason = "Couldn't keep the Mac awake. Try Set Up again in Settings."
                self.disarm(sleepIfClosed: false)
                self.refreshSetup()
            }
        }
        // Started with the lid already shut (an external display in use), nothing else to do until it opens.
    }

    private func disarm(sleepIfClosed: Bool) {
        guard mode != .off || !journal.isEmpty else { return }
        if mode == .lidClosed { undoLidActions() }
        mode = .off
        idleSince = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        let sleep = sleepIfClosed && lid.isClosed && !Self.externalDisplayConnected()
        queue.async {
            let ok = PowerControl.setSleepDisabled(false)
            DispatchQueue.main.async {
                // Re-armed meanwhile: that arm owns the journal now.
                guard self.mode == .off else { return }
                if ok { self.journal.sleepDisabled = false }
                self.journal.save()
            }
            if ok && sleep { PowerControl.sleepNow() }
        }
    }

    // MARK: Lid

    private func lidChanged(closed: Bool) {
        if closed {
            guard mode == .armed else { return }
            // Lid shut with an external display: you're still using the Mac, don't pause anything.
            guard !Self.externalDisplayConnected() else { return }
            applyLidActions()
        } else if mode == .lidClosed {
            undoLidActions()
            mode = .armed
        }
    }

    private func applyLidActions() {
        mode = .lidClosed
        let s = Settings.shared
        if s.pauseAppsWhenLidClosed {
            let store = AgentStore.shared
            let keep = Set(store.sessions.compactMap { store.hostBundleID($0) })
            let agents = store.sessions.compactMap(\.agentPID)
            let groups = AppFreezer.plan(keepBundles: keep, agentPIDs: agents)
            journal.frozen = AppFreezer.journalEntries(groups)
            journal.save() // journaled before anything is stopped
            journal.frozen = AppFreezer.freeze(journal.frozen)
            journal.save()
            pausedApps = journal.frozen.map(\.app).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        }
        // Only on battery: that's the profile `pmset -b` writes, and the only one whose state we can read back.
        if s.lowPowerWhenLidClosed, Self.battery()?.onAC == false, !ProcessInfo.processInfo.isLowPowerModeEnabled {
            journal.lowPower = true
            journal.save()
            queue.async { PowerControl.setLowPowerMode(true) }
        }
        displayAsleepAt = Date()
        queue.async { PowerControl.displaySleepNow() }
        HotspotHopper.shared.start()
    }

    private func undoLidActions() {
        HotspotHopper.shared.stop()
        if !journal.frozen.isEmpty {
            let stuck = AppFreezer.resume(journal.frozen)
            if !stuck.isEmpty { NSLog("Lintel: couldn't resume \(stuck.map(\.pid))") }
            journal.frozen = []
            pausedApps = []
        }
        if journal.lowPower {
            journal.lowPower = false
            queue.async { PowerControl.setLowPowerMode(false) }
        }
        journal.save()
    }

    // MARK: Recovery

    /// Lintel quit or crashed with something still changed (and the watchdog hasn't run yet): undo it now.
    private func recoverFromLastRun() {
        guard var left = AwakeJournal.load(), !left.isEmpty else { return }
        AppFreezer.resume(left.frozen)
        left.frozen = []
        if left.sleepDisabled, PowerControl.setSleepDisabled(false) { left.sleepDisabled = false }
        if left.lowPower, PowerControl.setLowPowerMode(false) { left.lowPower = false }
        // Whatever couldn't be undone stays journaled, for the watchdog and the next try.
        journal = left
        journal.save()
    }

    /// Quitting: put everything back before Lintel goes (synchronously; the app is about to exit).
    func shutdown() {
        timer?.invalidate()
        lid.stop()
        HotspotHopper.shared.stop()
        AppFreezer.resume(journal.frozen)
        var j = journal
        j.frozen = []
        // On the pmset queue, so it runs after any command still queued or running (an arm's `disablesleep 1`
        // finishing after this would leave sleep off with nothing journaled).
        queue.sync {
            if j.sleepDisabled, PowerControl.setSleepDisabled(false) { j.sleepDisabled = false }
            if j.lowPower, PowerControl.setLowPowerMode(false) { j.lowPower = false }
        }
        journal = j
        journal.save()
        mode = .off
    }

    // MARK: Helpers

    static func externalDisplayConnected() -> Bool {
        NSScreen.screens.contains { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(n.uint32Value)) == 0
        }
    }

    /// The internal battery, or nil on a desktop.
    static func battery() -> (percent: Int, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (cur * 100 / max, onAC)
        }
        return nil
    }

    private func notify(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lintel.awake.\(UUID())", content: c, trigger: nil))
        }
    }
}
