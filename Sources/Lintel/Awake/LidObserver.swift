import Foundation
import IOKit

/// Tells Lintel when the lid opens or closes: an IOKit interest notification on IOPMrootDomain, so nothing runs
/// between events. A change counts only if it still holds 2 s later. Adapted from Insomnia's LidObserver
/// (github.com/krishhgg/Insomnia, MIT).
@MainActor
final class LidObserver {
    static let debounce: TimeInterval = 2

    /// Called after the debounce, with `true` for closed.
    var onChange: ((Bool) -> Void)?

    private(set) var isClosed = false
    private var pending: Bool?
    private var debounceTimer: Timer?
    private var port: IONotificationPortRef?
    private var service: io_service_t = 0
    private var notification: io_object_t = 0

    /// true = closed, false = open, nil = no lid (a desktop Mac).
    nonisolated static func readClamshell() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }

    func start() {
        guard port == nil else { return }
        isClosed = Self.readClamshell() ?? false
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .commonModes)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if IOServiceAddInterestNotification(p, service, kIOGeneralInterest, Self.callback, refcon, &notification) != KERN_SUCCESS {
            stop()
        }
    }

    func stop() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        pending = nil
        if notification != 0 { IOObjectRelease(notification); notification = 0 }
        if let p = port {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .commonModes)
            IONotificationPortDestroy(p)
            port = nil
        }
        if service != 0 { IOObjectRelease(service); service = 0 }
    }

    private static let callback: IOServiceInterestCallback = { refcon, _, _, _ in
        guard let refcon else { return }
        let observer = Unmanaged<LidObserver>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { observer.changed() }
    }

    /// Any message from IOPMrootDomain: re-read the lid and wait out the debounce.
    private func changed() {
        guard let now = Self.readClamshell() else { return }
        guard now != isClosed else {
            pending = nil // flapped back
            debounceTimer?.invalidate()
            return
        }
        guard pending != now else { return }
        pending = now
        debounceTimer?.invalidate()
        let t = Timer(timeInterval: Self.debounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settle() }
        }
        RunLoop.main.add(t, forMode: .common)
        debounceTimer = t
    }

    private func settle() {
        guard let candidate = pending else { return }
        pending = nil
        guard Self.readClamshell() == candidate, candidate != isClosed else { return }
        isClosed = candidate
        onChange?(candidate)
    }
}
