import AppKit
import CryptoKit

/// Updates from the GitHub releases of this repo, without a framework: check the latest release, download its
/// DMG, verify the SHA-256 GitHub publishes for it, swap the app in place and relaunch. An app that downloads
/// its own update doesn't get macOS's quarantine flag, so Gatekeeper only asks about the very first download.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let repo = "imRazvanBadea/lintel"

    struct Release: Equatable {
        let version: String
        let dmg: URL
        let sha256: String?
        let page: URL
    }

    enum State: Equatable { case idle, checking, upToDate, available, downloading, installing, failed(String) }

    private(set) var state: State = .idle
    private(set) var latest: Release?
    @ObservationIgnored private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks shortly after launch and then once a day, if automatic checks are on.
    func start() {
        timer?.invalidate()
        guard Settings.shared.checkForUpdates else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.check() }
        }
    }

    func check() {
        guard state != .checking, state != .downloading, state != .installing else { return }
        state = .checking
        // `defaults write com.razvanbadea.lintel updateFeedURL file:///…/release.json` tests updates locally.
        let feed = UserDefaults.standard.string(forKey: "updateFeedURL").flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var req = URLRequest(url: feed)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let release = data.flatMap(Self.parse)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                let u = Updater.shared
                guard let release else {
                    // 404: no published release yet. Anything else: try again tomorrow.
                    u.state = status == 404 ? .upToDate : .failed("Couldn't reach GitHub.")
                    return
                }
                u.latest = release
                u.state = Self.isNewer(release.version, than: Self.currentVersion) ? .available : .upToDate
            }
        }.resume()
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let page = (j["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = j["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let url = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let digest = (dmg["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, dmg: url, sha256: digest, page: page)
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Install

    func install() {
        guard let r = latest, state == .available || isFailed else { return }
        let target = Bundle.main.bundleURL
        // Run from a disk image or a quarantined download, the app lives at a read-only random path.
        if target.path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) {
            NSWorkspace.shared.open(r.page)
            state = .failed("Move Lintel to Applications first, or install the update from the release page.")
            return
        }
        state = .downloading
        URLSession.shared.downloadTask(with: r.dmg) { tmp, _, error in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lintel-update-\(UUID().uuidString)")
            var dmg: URL?
            if let tmp {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent("Lintel.dmg")
                if (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil { dmg = dest }
            }
            let problem: String? = {
                guard let dmg, error == nil else { return "Download failed." }
                if let expected = r.sha256 {
                    guard let data = try? Data(contentsOf: dmg, options: .mappedIfSafe) else { return "Download failed." }
                    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    if actual != expected.lowercased() { return "The download didn't match its checksum." }
                }
                return nil
            }()
            DispatchQueue.main.async {
                if let problem { Updater.shared.state = .failed(problem); return }
                Updater.shared.swap(dmg: dmg!, workDir: dir, target: target, version: r.version)
            }
        }.resume()
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    /// Mounts the DMG, checks it holds Lintel, then hands off to a small script that waits for this process to
    /// quit, replaces the app and opens the new one.
    private func swap(dmg: URL, workDir: URL, target: URL, version: String) {
        state = .installing
        let mount = workDir.appendingPathComponent("mnt")
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) else {
            state = .failed("Couldn't open the update."); return
        }
        let newApp = mount.appendingPathComponent("Lintel.app")
        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == version else {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            state = .failed("The update doesn't look like Lintel \(version)."); return
        }
        let staged = workDir.appendingPathComponent("Lintel.app")
        guard run("/usr/bin/ditto", [newApp.path, staged.path]) else {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            state = .failed("Couldn't copy the update."); return
        }
        _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        // Paths travel as arguments, never spliced into the script.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2" && /usr/bin/ditto "$3" "$2" && /usr/bin/open "$2"
        rm -rf "$4"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "lintel-update", String(getpid()), target.path, staged.path, workDir.path]
        do { try p.run() } catch { state = .failed("Couldn't start the installer."); return }
        NSApp.terminate(nil)
    }

    private func run(_ exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
