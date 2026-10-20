import AppKit

/// Reads "up next" from a YouTube Music tab, because browsers only publish the current track
/// to the system. Only runs while a browser is the active player.
/// Needs "Allow JavaScript from Apple Events" (Chromium: View › Developer; Safari: Develop menu).
/// Safari web apps ("Add to Dock") can't be scripted at all, so for those we read the page
/// through the Accessibility API instead.
@MainActor
final class WebQueueReader {
    enum Result { case queue(label: String, tracks: [Track]), blocked(String), none }

    var onResult: ((Result) -> Void)?
    private var inFlight = false

    static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    static func isWebApp(_ id: String) -> Bool { id.hasPrefix("com.apple.Safari.WebApp.") }
    static func isBrowser(_ id: String) -> Bool { safari.contains(id) || chromium.contains(id) || isWebApp(id) }

    // Single-quoted JS only, so it can sit inside an AppleScript string.
    private static let js = """
    (function(){var q=Array.prototype.slice.call(document.querySelectorAll('ytmusic-player-queue-item'));\
    var i=-1;for(var k=0;k<q.length;k++){if(q[k].hasAttribute('selected')){i=k;break;}}\
    var nx=[];if(i>=0){q.slice(i+1,i+8).forEach(function(e){var t=e.querySelector('.song-title');var b=e.querySelector('.byline');\
    nx.push({t:t?t.textContent.trim():'',a:b?b.textContent.trim():''});});}\
    return JSON.stringify({nx:nx});})()
    """

    private func script(bundleID: String, js: String, findOnly: Bool = false) -> String {
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let run = Self.safari.contains(bundleID) ? "do JavaScript \"\(escaped)\" in t" : "execute t javascript \"\(escaped)\""
        let action = findOnly ? "return \"FOUND\"" : """
        try
            return "OK" & (\(run))
        on error errMsg
            return "ERR" & errMsg
        end try
        """
        return """
        tell application id "\(bundleID)"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t starts with "https://music.youtube.com" then
                        \(action)
                    end if
                end repeat
            end repeat
        end tell
        return "NONE"
        """
    }

    func read(bundleID: String?) {
        guard let id = bundleID, Self.isBrowser(id), !inFlight, ScriptRunner.isRunning(id) else { return }
        if Self.isWebApp(id) { return readWebApp(bundleID: id) }
        inFlight = true
        ScriptRunner.shared.run(script(bundleID: id, js: Self.js)) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inFlight = false
                let name = NowPlaying.appName(for: id)
                switch result {
                case .success(let d):
                    let out = d.stringValue ?? "NONE"
                    if out.hasPrefix("OK"), let data = out.dropFirst(2).data(using: .utf8),
                       let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        let tracks = (obj["nx"] as? [[String: Any]] ?? []).map {
                            Track(title: $0["t"] as? String ?? "", artist: $0["a"] as? String ?? "")
                        }
                        self.onResult?(.queue(label: "YouTube Music", tracks: tracks))
                    } else if out.hasPrefix("ERR") {
                        let how = Self.safari.contains(id) ? "Develop › Allow JavaScript from Apple Events"
                                                           : "View › Developer › Allow JavaScript from Apple Events"
                        self.onResult?(.blocked("To see YouTube Music's up next, turn on \(how) in \(name)."))
                    } else {
                        self.onResult?(.none)
                    }
                case .failure(let f):
                    if f.code == -1743 {
                        self.onResult?(.blocked("Allow Lintel to control \(name) in System Settings › Privacy & Security › Automation to see up next."))
                    } else {
                        self.onResult?(.none)
                    }
                }
            }
        }
    }

    /// Starts the queue item `offset` places after the current one, as if you clicked it on the page.
    func playQueueItem(bundleID: String, offset: Int) {
        if Self.isWebApp(bundleID) { return playWebAppItem(bundleID: bundleID, offset: offset) }
        let js = "(function(){var q=Array.prototype.slice.call(document.querySelectorAll('ytmusic-player-queue-item'));" +
            "var i=-1;for(var k=0;k<q.length;k++){if(q[k].hasAttribute('selected')){i=k;break;}}" +
            "var t=q[i+\(offset)];if(!t){return 'NO';}" +
            "var b=t.querySelector('ytmusic-play-button-renderer')||t.querySelector('.song-info')||t;b.click();return 'OK';})()"
        ScriptRunner.shared.run(script(bundleID: bundleID, js: js)) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.read(bundleID: bundleID) }
            }
        }
    }

    /// Brings the browser forward with the YouTube Music tab selected.
    func reveal(bundleID: String) {
        if Self.isWebApp(bundleID) { return NowPlaying.activate(bundleID: bundleID) }
        // Each browser names this differently, and AppleScript compiles against the app's own dictionary.
        let select: String
        switch bundleID {
        case _ where Self.safari.contains(bundleID): select = "set current tab of w to t"
        case "company.thebrowser.dia": select = "focus t"
        case "company.thebrowser.Browser": select = "select t"
        default: select = "set active tab index of w to i"
        }
        let script = """
        tell application id "\(bundleID)"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if URL of t starts with "https://music.youtube.com" then
                        \(select)
                        try
                            set index of w to 1
                        end try
                        activate
                        return "OK"
                    end if
                end repeat
            end repeat
            activate
        end tell
        """
        ScriptRunner.shared.run(script) { _ in }
        NowPlaying.activate(bundleID: bundleID)
    }

    // MARK: Safari web apps (Accessibility)

    private static let axQueue = DispatchQueue(label: "lintel.ax-queue", qos: .userInitiated)
    private var askedForAccess = false
    /// YouTube Music hides the queue from Accessibility while its player view is closed, so we keep
    /// the last full queue we saw and follow the current song through it.
    private var lastQueue: [Track] = []

    private func readWebApp(bundleID id: String) {
        guard AXIsProcessTrusted() else {
            if !askedForAccess {
                askedForAccess = true
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            // macOS 27 renamed the Accessibility pane.
            let pane = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
                ? "Device Control and Data Access" : "Accessibility"
            onResult?(.blocked("To see YouTube Music's up next, allow Lintel in System Settings › Privacy & Security › \(pane)."))
            return
        }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier else { return }
        let now = NowPlaying.shared.state?.track.title
        inFlight = true
        Self.axQueue.async {
            let items = AXQueue.items(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.inFlight = false
                    if let items, AXQueue.currentIndex(items, now: now) != nil {
                        self.lastQueue = items.map { Track(title: $0.title, artist: $0.artist) }
                        let tracks = AXQueue.upcoming(items, now: now).prefix(7).map { Track(title: $0.title, artist: $0.artist) }
                        self.onResult?(.queue(label: "YouTube Music", tracks: Array(tracks)))
                    } else if let i = self.lastQueue.firstIndex(where: { $0.title == now }) {
                        self.onResult?(.queue(label: "YouTube Music", tracks: Array(self.lastQueue[(i + 1)...].prefix(7))))
                    } else {
                        self.onResult?(.blocked("Open the player in YouTube Music once so Lintel can see what's up next."))
                    }
                }
            }
        }
    }

    private func playWebAppItem(bundleID id: String, offset: Int) {
        guard AXIsProcessTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier else { return }
        let now = NowPlaying.shared.state?.track.title
        Self.axQueue.async {
            if let items = AXQueue.items(pid: pid), let cur = AXQueue.currentIndex(items, now: now),
               items.indices.contains(cur + offset) {
                AXUIElementPerformAction(items[cur + offset].button, kAXPressAction as CFString)
            } else {
                // The queue isn't on screen (remembered list): skip forward to the song instead.
                for k in 0..<offset {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 * Double(k)) {
                        MainActor.assumeIsolated { NowPlaying.shared.next() }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { self.read(bundleID: id) }
            }
        }
    }
}

/// The YouTube Music queue as WebKit exposes it to Accessibility. Each `ytmusic-player-queue-item`
/// shows up as a thumbnail group holding a "Play <title>" (or "Pause <title>" for the current
/// song) button, followed by flat static texts: the title, then the byline pieces.
private enum AXQueue {
    struct Item { var title: String; var artist: String; var button: AXUIElement; var playing: Bool }

    /// nil when the window isn't YouTube Music or the queue isn't on the page.
    static func items(pid: pid_t) -> [Item]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var items: [Item] = []
        var current: Item?
        var texts: [String] = []
        var seen = 0

        func flush() {
            guard var it = current else { return }
            if let t = texts.first { it.title = t }
            it.artist = texts.dropFirst().joined().trimmingCharacters(in: .whitespaces)
            items.append(it)
            current = nil
            texts = []
        }
        func walk(_ e: AXUIElement) {
            seen += 1
            guard seen < 8000 else { return }
            let classes = (attr(e, "AXDOMClassList") as? [String]) ?? []
            let role = attr(e, kAXRoleAttribute) as? String
            if classes.contains("ytmusic-player-queue-item") {
                if classes.contains("left-items") {
                    flush()
                    if let b = firstButton(e) {
                        let label = (attr(b, kAXDescriptionAttribute) as? String) ?? ""
                        let playing = label.hasPrefix("Pause ")
                        let title = label.replacingOccurrences(of: playing ? "Pause " : "Play ", with: "", options: .anchored)
                        current = Item(title: title, artist: "", button: b, playing: playing)
                    }
                    return
                }
                // Action menu / duration close the item's text run.
                flush()
                return
            }
            if current != nil, role == kAXStaticTextRole as String,
               let v = attr(e, kAXValueAttribute) as? String, !v.isEmpty {
                texts.append(v)
            }
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c) }
        }
        for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            guard ((attr(w, kAXTitleAttribute) as? String) ?? "").contains("YouTube Music") else { continue }
            walk(w)
            flush()
        }
        return items.isEmpty ? nil : items
    }

    /// The playing row is the one whose button says "Pause"; while paused, match the title instead.
    static func currentIndex(_ items: [Item], now: String?) -> Int? {
        items.firstIndex { $0.playing } ?? now.flatMap { t in items.firstIndex { $0.title == t } }
    }

    static func upcoming(_ items: [Item], now: String?) -> ArraySlice<Item> {
        guard let i = currentIndex(items, now: now) else { return [] }
        return items[(i + 1)...]
    }

    private static func firstButton(_ e: AXUIElement) -> AXUIElement? {
        for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            if (attr(c, kAXRoleAttribute) as? String) == kAXButtonRole as String { return c }
            if let b = firstButton(c) { return b }
        }
        return nil
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
}
