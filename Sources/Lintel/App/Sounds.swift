import AppKit
import AVFoundation

/// Event sounds. Played as audio files on the normal output — not as system alerts, which macOS silently
/// drops when "Play user interface sound effects" is off.
@MainActor
enum Sounds {
    enum Event { case needsYou, finished }

    /// macOS's built-in alert sounds (always present in /System/Library/Sounds).
    static let choices = ["None", "Tink", "Glass", "Ping", "Pop", "Purr", "Hero", "Funk", "Submarine",
                          "Blow", "Bottle", "Frog", "Morse", "Sosumi", "Basso"]

    private static var players: [String: AVAudioPlayer] = [:]

    static func play(_ name: String) {
        guard name != "None" else { return }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        let player = players[name] ?? (try? AVAudioPlayer(contentsOf: url))
        guard let player else { return }
        players[name] = player
        player.currentTime = 0
        player.volume = 0.8
        player.play()
    }

    /// Plays the sound for an event — unless sounds are off, or you're already looking at that session's app.
    static func play(_ event: Event, for session: AgentSession?) {
        let s = Settings.shared
        guard s.playSounds else { return }
        if AwakeController.shared.mode == .lidClosed { return } // lid shut: the Mac may be in a bag or a meeting
        if s.muteWhenFocused, let session, AgentStore.shared.isHostAppFrontmost(session) { return }
        play(event == .needsYou ? s.needsYouSound : s.finishedSound)
    }
}
