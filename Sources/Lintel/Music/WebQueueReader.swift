import AppKit

/// Reads "up next" from a YouTube Music tab, because browsers only publish the current track
/// to the system. Only runs while a browser is the active player.
/// Needs "Allow JavaScript from Apple Events" (Chromium: View › Developer; Safari: Develop menu).
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
    static func isBrowser(_ id: String) -> Bool { safari.contains(id) || chromium.contains(id) }

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
}
