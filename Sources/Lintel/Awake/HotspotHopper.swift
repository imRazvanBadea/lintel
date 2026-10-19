import CoreLocation
import CoreWLAN
import Foundation
import Network
import Security

/// While agents run with the lid closed: if the network drops, join your iPhone's hotspot so their API calls keep
/// going. Waits a few seconds (macOS may rejoin another known network by itself), then tries every 5, 10, 20 and
/// 30 s until the network is back. The timing and the CoreWLAN join follow Insomnia (github.com/krishhgg/Insomnia, MIT).
@MainActor
final class HotspotHopper {
    static let shared = HotspotHopper()

    static let firstTry: TimeInterval = 8
    static let backoff: [TimeInterval] = [5, 10, 20, 30]

    private var monitor: NWPathMonitor?
    private var outageSince: Date?
    private var attempts = 0
    private var retry: Timer?
    private var joining = false
    /// Read from the Keychain while you're at the Mac (macOS may ask once after an update), used with the lid closed.
    private var password: String?
    private let queue = DispatchQueue(label: "lintel.hotspot")
    /// Its own queue: a Keychain read can wait on a macOS dialog, which must not hold up the network monitor.
    private let keychainQueue = DispatchQueue(label: "lintel.hotspot.keychain")

    var isConfigured: Bool { Settings.shared.hotspotEnabled && !Settings.shared.hotspotSSID.isEmpty }

    /// Called when agents start keeping the Mac awake, with the lid still open.
    func prepare() {
        guard isConfigured, password == nil else { return }
        let ssid = Settings.shared.hotspotSSID
        keychainQueue.async {
            let pw = HotspotKeychain.read(ssid: ssid)
            DispatchQueue.main.async { if Settings.shared.hotspotSSID == ssid { self.password = pw } }
        }
    }

    func start() {
        guard isConfigured, monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            DispatchQueue.main.async { self?.pathChanged(up: up) }
        }
        m.start(queue: queue)
        monitor = m
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        retry?.invalidate()
        retry = nil
        outageSince = nil
        attempts = 0
    }

    /// The saved password changed.
    func forgetPassword() { password = nil }

    private func pathChanged(up: Bool) {
        if up {
            if let since = outageSince { NSLog("Lintel: network back after \(Int(Date().timeIntervalSince(since)))s") }
            outageSince = nil
            attempts = 0
            retry?.invalidate()
            retry = nil
        } else if outageSince == nil {
            outageSince = Date()
            schedule(after: Self.firstTry)
        }
    }

    private func schedule(after delay: TimeInterval) {
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.attempt() }
        }
    }

    private func attempt() {
        guard outageSince != nil else { return }
        attempts += 1
        schedule(after: Self.backoff[min(attempts - 1, Self.backoff.count - 1)])
        guard !joining, let password, !password.isEmpty else { return }
        joining = true
        let ssid = Settings.shared.hotspotSSID
        queue.async {
            let ok = Self.join(ssid: ssid, password: password)
            DispatchQueue.main.async {
                self.joining = false
                NSLog("Lintel: hotspot \(ssid) \(ok ? "joined" : "not found")")
            }
        }
    }

    /// Scans for that one network and joins it. The scan is filtered by name, so it works even when macOS hides
    /// network names from apps without Location access.
    nonisolated static func join(ssid: String, password: String) -> Bool {
        guard let wifi = CWWiFiClient.shared().interface(), let name = ssid.data(using: .utf8) else { return false }
        do {
            guard wifi.powerOn() else { return false } // Wi-Fi switched off on purpose: leave it off
            // Only a password-protected network: an open one with your hotspot's name is someone else's.
            let secured: [CWSecurity] = [.wpa2Personal, .wpa3Personal, .wpa3Transition]
            guard let network = try wifi.scanForNetworks(withSSID: name)
                .first(where: { n in secured.contains { n.supportsSecurity($0) } }) else { return false }
            try wifi.associate(to: network, password: password)
            return true
        } catch {
            NSLog("Lintel: hotspot join failed: \(error)")
            return false
        }
    }
}

/// The hotspot password, in your login Keychain.
enum HotspotKeychain {
    static let service = "Lintel Hotspot"

    static func read(ssid: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: ssid, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(ssid: String, password: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: ssid]
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "Lintel Hotspot (\(ssid))"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func has(ssid: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: ssid]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
}

/// macOS hides Wi-Fi names from apps without Location Services access. Lintel never asks where you are.
@MainActor
final class WiFiLocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = WiFiLocationAccess()
    private let manager = CLLocationManager()
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var granted: Bool { [.authorizedAlways, .authorized].contains(manager.authorizationStatus) }
    var denied: Bool { [.denied, .restricted].contains(manager.authorizationStatus) }

    func request() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { self.onChange?() }
    }
}
