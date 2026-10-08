import AppKit
import Observation

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String = ""
}

struct PlayerState: Equatable {
    var track: Track
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var upNext: [Track]
    var appBundleID: String
    var updatedAt = Date()
}

/// What's playing anywhere on the Mac (Music, Spotify, any browser tab…), via the system
/// Now Playing service. Up next comes from the app's real playback queue, or — for YouTube Music,
/// which doesn't publish one — from the page itself.
@MainActor @Observable
final class NowPlaying {
    static let shared = NowPlaying()

    private(set) var state: PlayerState?
    private(set) var artwork: NSImage?
    private(set) var tint: NSColor = .systemGray
    private(set) var appName = ""
    /// e.g. "YouTube Music" when we recognise the page; otherwise the app name.
    private(set) var sourceLabel = ""
    /// Setup hint, e.g. when a browser blocks JavaScript from Apple Events.
    private(set) var hint: String?

    @ObservationIgnored private let bridge = NowPlayingBridge()
    @ObservationIgnored private let web = WebQueueReader()
    @ObservationIgnored private var bridgeQueue: [Track] = []
    @ObservationIgnored private var webQueue: [Track] = []
    @ObservationIgnored private var artworkKey = ""
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var webTimer: Timer?

    func start() {
        bridge.onState = { [weak self] s in self?.apply(s) }
        bridge.start()
        web.onResult = { [weak self] r in self?.applyWeb(r) }
    }

    var currentPosition: Double {
        guard let s = state else { return 0 }
        guard s.isPlaying else { return s.position }
        return min(s.duration, s.position + Date().timeIntervalSince(s.updatedAt))
    }

    @ObservationIgnored private var queueTimer: Timer?

    func setVisible(_ v: Bool) {
        visible = v
        updateWebPolling()
        queueTimer?.invalidate()
        queueTimer = nil
        if v {
            web.read(bundleID: state?.appBundleID)
            bridge.send("refresh")
            // Keep the queue current while you're looking at it (reorders, "Play Next", AutoPlay).
            queueTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.bridge.send("refresh") }
            }
        }
    }

    /// Jump to an upcoming track (index into `upNext`).
    func play(upNextIndex i: Int) {
        guard let s = state else { return }
        if bridgeQueue.isEmpty, WebQueueReader.isBrowser(s.appBundleID) {
            web.playQueueItem(bundleID: s.appBundleID, offset: i + 1)
        } else {
            bridge.send("skip \(i + 1)")
        }
    }

    // MARK: Controls (sent through the system, so they work for any player)

    func playPause() {
        bridge.send("toggle")
        guard var s = state else { return }
        s.position = currentPosition
        s.isPlaying.toggle()
        s.updatedAt = Date()
        state = s
    }
    func next() { bridge.send("next") }

    /// Jump to a point in the current track (seconds).
    func seek(to seconds: Double) {
        guard var s = state, s.duration > 0 else { return }
        let t = min(max(0, seconds), s.duration - 0.5)
        bridge.send(String(format: "seek %.2f", t))
        s.position = t
        s.updatedAt = Date()
        state = s
    }
    func previous() { bridge.send("prev") }

    func openSource() {
        guard let id = state?.appBundleID, !id.isEmpty else { return }
        if WebQueueReader.isBrowser(id) { web.reveal(bundleID: id) } else { Self.activate(bundleID: id) }
        IslandModel.shared.collapse()
    }

    /// Brings an app to the front (launching it if needed) — reliable even from a menu-bar app.
    static func activate(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    // MARK: Updates

    private func apply(_ s: NowPlayingBridge.Snapshot?) {
        guard Settings.shared.musicEnabled, let s, !s.title.isEmpty else {
            if state != nil { state = nil; artwork = nil }
            updateWebPolling()
            return
        }
        let trackChanged = state?.track.title != s.title || state?.appBundleID != s.bundleID
        bridgeQueue = s.queue
        if trackChanged { webQueue = [] }

        var new = PlayerState(track: Track(title: s.title, artist: s.artist, album: s.album),
                              isPlaying: s.playing, position: s.elapsed, duration: s.duration,
                              upNext: [], appBundleID: s.bundleID, updatedAt: s.timestamp)
        new.upNext = mergedQueue()
        if new != state { state = new }

        if s.bundleID != "", appName.isEmpty || trackChanged {
            appName = Self.appName(for: s.bundleID)
            if !WebQueueReader.isBrowser(s.bundleID) { sourceLabel = appName; hint = nil }
            else if sourceLabel.isEmpty { sourceLabel = appName }
        }
        if let data = s.artwork, s.artworkKey != artworkKey, let img = NSImage(data: data) {
            artworkKey = s.artworkKey
            artwork = img
            tint = img.averageColor?.vivid ?? .systemGray
        } else if s.artworkKey != artworkKey, s.artwork == nil, trackChanged {
            // New track without artwork yet; ask the bridge to resend once it's available.
            artwork = nil
        }
        if trackChanged { web.read(bundleID: s.bundleID) }
        updateWebPolling()
    }

    private func applyWeb(_ r: WebQueueReader.Result) {
        switch r {
        case .queue(let label, let tracks):
            sourceLabel = "\(label) · \(appName)"
            hint = nil
            webQueue = tracks
        case .blocked(let h):
            hint = h
            webQueue = []
        case .none:
            webQueue = []
        }
        if var s = state {
            s.upNext = mergedQueue()
            if s != state { state = s }
        }
    }

    private func mergedQueue() -> [Track] { bridgeQueue.isEmpty ? webQueue : bridgeQueue }

    /// While a browser is the player we re-read the page queue every few seconds (only then).
    private func updateWebPolling() {
        let needs = state.map { WebQueueReader.isBrowser($0.appBundleID) } ?? false
        let interval: TimeInterval = visible ? 3 : 15
        if !needs { webTimer?.invalidate(); webTimer = nil; return }
        if let t = webTimer, t.timeInterval == interval { return }
        webTimer?.invalidate()
        webTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.web.read(bundleID: self?.state?.appBundleID) }
        }
        webTimer?.tolerance = interval * 0.3
    }

    static func appName(for bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let n = app.localizedName { return n }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

extension NSImage {
    /// Average colour of the image (via a 1×1 redraw), used to tint the visualiser.
    var averageColor: NSColor? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .medium
        draw(in: NSRect(x: 0, y: 0, width: 1, height: 1), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: 0, y: 0)
    }
}

extension NSColor {
    /// A saturated, mid-brightness version of the colour that reads on white and on black.
    var vivid: NSColor {
        guard let c = usingColorSpace(.deviceRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { return NSColor(white: 0.45, alpha: 1) }
        return NSColor(hue: h, saturation: min(1, max(s, 0.55)), brightness: min(max(b, 0.6), 0.8), alpha: 1)
    }
}
