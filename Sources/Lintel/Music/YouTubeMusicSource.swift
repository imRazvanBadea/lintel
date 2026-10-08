import AppKit

/// YouTube Music running in a browser tab (Chrome, Arc, Brave, Edge or Safari).
/// Reads the page's Media Session + queue via AppleScript-executed JavaScript.
/// Chromium browsers need: View › Developer › Allow JavaScript from Apple Events.
/// Safari needs: Develop › Allow JavaScript from Apple Events.
@MainActor
final class YouTubeMusicSource: MusicController {
    var onUpdate: ((PlayerState?) -> Void)?
    var onHint: ((String?) -> Void)?

    private struct Browser { let name: String; let bundleID: String; let safari: Bool }
    private static let browsers = [
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", safari: false),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", safari: false),
        Browser(name: "Brave Browser", bundleID: "com.brave.Browser", safari: false),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", safari: false),
        Browser(name: "Safari", bundleID: "com.apple.Safari", safari: true),
    ]

    private var timer: Timer?
    private var fast = false
    private var inFlight = false
    private var lastFound: Browser?
    private var playing = false

    func start() { schedule() }

    func setFast(_ f: Bool) {
        fast = f
        schedule()
        if f { poll() }
    }

    /// 1s while the card is open, 2s while playing, 5s otherwise. Nothing at all if no browser runs.
    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = fast ? 1 : (playing ? 2 : 5)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = interval * 0.3
    }

    // Single-quoted JS only, so it can sit inside an AppleScript string.
    private static let readJS = """
    (function(){var m=navigator.mediaSession&&navigator.mediaSession.metadata;var v=document.querySelector('video');\
    if(!m||!m.title){return '';}\
    var q=Array.prototype.slice.call(document.querySelectorAll('ytmusic-player-queue-item'));\
    var i=-1;for(var k=0;k<q.length;k++){if(q[k].hasAttribute('selected')){i=k;break;}}\
    var nx=[];if(i>=0){q.slice(i+1,i+6).forEach(function(e){var t=e.querySelector('.song-title');var b=e.querySelector('.byline');nx.push({t:t?t.textContent.trim():'',a:b?b.textContent.trim():''});});}\
    var art='';if(m.artwork&&m.artwork.length){art=m.artwork[m.artwork.length-1].src;}\
    return JSON.stringify({t:m.title,a:m.artist||'',al:m.album||'',art:art,p:v?!v.paused:false,pos:v?v.currentTime:0,dur:v&&isFinite(v.duration)?v.duration:0,nx:nx});})()
    """

    private func script(for b: Browser, js: String) -> String {
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        if b.safari {
            return """
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t starts with "https://music.youtube.com" then
                            try
                                return "OK" & (do JavaScript "\(escaped)" in t)
                            on error errMsg
                                return "ERR" & errMsg
                            end try
                        end if
                    end repeat
                end repeat
            end tell
            return "NONE"
            """
        }
        return """
        tell application "\(b.name)"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t starts with "https://music.youtube.com" then
                        try
                            return "OK" & (execute t javascript "\(escaped)")
                        on error errMsg
                            return "ERR" & errMsg
                        end try
                    end if
                end repeat
            end repeat
        end tell
        return "NONE"
        """
    }

    private func runningBrowsers() -> [Browser] {
        Self.browsers.filter { ScriptRunner.isRunning($0.bundleID) }
    }

    private func poll() {
        guard Settings.shared.youTubeMusicEnabled, !inFlight else { return }
        var candidates = runningBrowsers()
        guard !candidates.isEmpty else { report(nil, hint: nil); return }
        if let last = lastFound, let i = candidates.firstIndex(where: { $0.bundleID == last.bundleID }) {
            candidates.insert(candidates.remove(at: i), at: 0)
        }
        inFlight = true
        tryBrowsers(candidates, hint: nil)
    }

    private func tryBrowsers(_ list: [Browser], hint: String?) {
        guard let b = list.first else {
            inFlight = false
            lastFound = nil
            report(nil, hint: hint)
            return
        }
        ScriptRunner.shared.run(script(for: b, js: Self.readJS)) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                let out: String
                switch result {
                case .success(let d): out = d.stringValue ?? "NONE"
                case .failure(let f):
                    // -1743: Automation permission denied for this browser.
                    out = f.code == -1743 ? "ERRpermission" : "NONE"
                }
                if out.hasPrefix("OK") {
                    self.inFlight = false
                    self.lastFound = b
                    self.parse(String(out.dropFirst(2)))
                } else if out.hasPrefix("ERR") {
                    let msg = out.lowercased()
                    let h: String
                    if msg.contains("permission") {
                        h = "Allow Lintel to control \(b.name) in System Settings › Privacy & Security › Automation."
                    } else if b.safari {
                        h = "In Safari, turn on Develop › Allow JavaScript from Apple Events."
                    } else {
                        h = "In \(b.name), turn on View › Developer › Allow JavaScript from Apple Events."
                    }
                    self.tryBrowsers(Array(list.dropFirst()), hint: h)
                } else {
                    self.tryBrowsers(Array(list.dropFirst()), hint: hint)
                }
            }
        }
    }

    private func parse(_ json: String) {
        guard let d = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let title = d["t"] as? String, !title.isEmpty else { report(nil, hint: nil); return }
        let next = (d["nx"] as? [[String: Any]] ?? []).map { Track(title: $0["t"] as? String ?? "", artist: $0["a"] as? String ?? "") }
        let art = d["art"] as? String ?? ""
        let state = PlayerState(track: Track(title: title, artist: d["a"] as? String ?? "", album: d["al"] as? String ?? ""),
                                isPlaying: d["p"] as? Bool ?? false,
                                position: (d["pos"] as? NSNumber)?.doubleValue ?? 0,
                                duration: (d["dur"] as? NSNumber)?.doubleValue ?? 0,
                                upNext: next, artworkKey: "yt:" + art, artworkURL: art)
        report(state, hint: nil)
    }

    private func report(_ s: PlayerState?, hint: String?) {
        let isPlaying = s?.isPlaying ?? false
        if isPlaying != playing { playing = isPlaying; if !fast { schedule() } }
        onHint?(hint)
        onUpdate?(s)
    }

    private func run(js: String) {
        guard let b = lastFound else { return }
        ScriptRunner.shared.run(script(for: b, js: js)) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.poll() }
            }
        }
    }

    func playPause() { run(js: "(function(){var b=document.querySelector('#play-pause-button');if(b){b.click();}else{var v=document.querySelector('video');if(v){v.paused?v.play():v.pause();}}return '';})()") }
    func next() { run(js: "(function(){var b=document.querySelector('.next-button');if(b){b.click();}return '';})()") }
    func previous() { run(js: "(function(){var b=document.querySelector('.previous-button');if(b){b.click();}return '';})()") }

    func reveal() {
        guard let b = lastFound else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: b.bundleID).first?.activate()
    }
}
