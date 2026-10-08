import AppKit

/// Apple Music via its playerInfo distributed notification (event-driven, no polling)
/// plus AppleScript for position, artwork and the rest of the current playlist.
@MainActor
final class AppleMusicSource: MusicController {
    static let bundleID = "com.apple.Music"
    var onUpdate: ((PlayerState?) -> Void)?
    private var refreshQueued = false

    func start() {
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"),
                                                            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if (note.userInfo?["Player State"] as? String) == "Stopped" { self?.onUpdate?(nil) } else { self?.refresh(full: true) }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if app?.bundleIdentifier == Self.bundleID { self?.onUpdate?(nil) } }
        }
        refresh(full: true)
    }

    private static let stateScript = """
    tell application "Music"
        if player state is stopped then return {"stopped"}
        set t to current track
        set pState to "paused"
        if player state is playing then set pState to "playing"
        set nextList to {}
        try
            set pl to current playlist
            set i to index of t
            set n to count of tracks of pl
            repeat with j from (i + 1) to (i + 5)
                if j > n then exit repeat
                set nt to track j of pl
                set end of nextList to {name of nt, artist of nt}
            end repeat
        end try
        return {pState, name of t, artist of t, album of t, duration of t, player position, shuffle enabled, nextList}
    end tell
    """

    func refresh(full: Bool) {
        guard ScriptRunner.isRunning(Self.bundleID) else { onUpdate?(nil); return }
        guard !refreshQueued else { return }
        refreshQueued = true
        ScriptRunner.shared.run(Self.stateScript) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshQueued = false
                guard case .success(let d) = result else { return }
                let items = d.items
                guard items.count >= 7, items[0].stringValue != "stopped" else { self.onUpdate?(nil); return }
                let title = items[1].stringValue ?? ""
                let artist = items[2].stringValue ?? ""
                let album = items[3].stringValue ?? ""
                let next = (items.count > 7 ? items[7].items : []).map {
                    let p = $0.items
                    return Track(title: p.first?.stringValue ?? "", artist: p.count > 1 ? (p[1].stringValue ?? "") : "")
                }
                let state = PlayerState(track: Track(title: title, artist: artist, album: album),
                                        isPlaying: items[0].stringValue == "playing",
                                        position: items[5].doubleValue, duration: items[4].doubleValue,
                                        upNext: next, shuffle: items[6].booleanValue,
                                        artworkKey: "am:\(title)|\(artist)|\(album)")
                self.onUpdate?(state)
            }
        }
    }

    func fetchArtwork(_ done: @escaping (NSImage?) -> Void) {
        ScriptRunner.shared.run("""
        tell application "Music"
            try
                return data of artwork 1 of current track
            end try
        end tell
        """) { result in
            if case .success(let d) = result, let img = NSImage(data: d.data) { done(img) } else { done(nil) }
        }
    }

    private func command(_ c: String) {
        guard ScriptRunner.isRunning(Self.bundleID) else { return }
        ScriptRunner.shared.run("tell application \"Music\" to \(c)") { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(full: true) }
        }
    }

    func playPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }
}
