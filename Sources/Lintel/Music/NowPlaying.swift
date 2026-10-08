import AppKit
import Observation

enum MusicSource: String {
    case appleMusic, youTubeMusic
    var label: String { self == .appleMusic ? "Apple Music" : "YouTube Music" }
}

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
    var shuffle: Bool = false
    var artworkKey: String = ""   // identifies the artwork so we only reload on change
    var artworkURL: String = ""
    var updatedAt = Date()
}

/// Merges the sources and exposes what's playing (and what's next).
@MainActor @Observable
final class NowPlaying {
    static let shared = NowPlaying()

    private(set) var source: MusicSource?
    private(set) var state: PlayerState?
    private(set) var artwork: NSImage?
    private(set) var tint: NSColor = .white
    /// Setup hint, e.g. when the browser blocks JavaScript from Apple Events.
    private(set) var hint: String?

    @ObservationIgnored private var states: [MusicSource: PlayerState] = [:]
    @ObservationIgnored private var lastPlaying: [MusicSource: Date] = [:]
    @ObservationIgnored private var artworkCache: [String: NSImage] = [:]
    @ObservationIgnored private var hints: [MusicSource: String] = [:]
    @ObservationIgnored private let apple = AppleMusicSource()
    @ObservationIgnored private let youtube = YouTubeMusicSource()

    func start() {
        apple.onUpdate = { [weak self] s in self?.update(.appleMusic, s) }
        youtube.onUpdate = { [weak self] s in self?.update(.youTubeMusic, s) }
        youtube.onHint = { [weak self] h in self?.hints[.youTubeMusic] = h; self?.recompute() }
        apple.start()
        youtube.start()
    }

    var currentPosition: Double {
        guard let s = state else { return 0 }
        guard s.isPlaying else { return s.position }
        return min(s.duration, s.position + Date().timeIntervalSince(s.updatedAt))
    }

    /// Faster refresh while the music card is open (progress + queue).
    func setVisible(_ visible: Bool) {
        youtube.setFast(visible)
        if visible { apple.refresh(full: true) }
    }

    // MARK: Controls

    func playPause() { controller?.playPause(); nudge(toggle: true) }
    func next() { controller?.next() }
    func previous() { controller?.previous() }

    func openSource() {
        switch source {
        case .appleMusic: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
        case .youTubeMusic: youtube.reveal()
        case nil: break
        }
    }

    private var controller: MusicController? {
        switch source {
        case .appleMusic: apple
        case .youTubeMusic: youtube
        case nil: nil
        }
    }

    /// Optimistic UI for play/pause; the source confirms shortly after.
    private func nudge(toggle: Bool) {
        guard var s = state, let src = source else { return }
        s.position = currentPosition
        s.isPlaying.toggle()
        s.updatedAt = Date()
        states[src] = s
        state = s
    }

    // MARK: Merge

    private func update(_ src: MusicSource, _ s: PlayerState?) {
        let enabled = src == .appleMusic ? Settings.shared.appleMusicEnabled : Settings.shared.youTubeMusicEnabled
        states[src] = enabled ? s : nil
        if s?.isPlaying == true { lastPlaying[src] = Date() }
        recompute()
    }

    private func recompute() {
        // Prefer whatever is playing; otherwise whatever played most recently.
        let playing = states.filter { $0.value.isPlaying }.map(\.key)
        let pick: MusicSource? = playing.max { (lastPlaying[$0] ?? .distantPast) < (lastPlaying[$1] ?? .distantPast) }
            ?? states.keys.max { (lastPlaying[$0] ?? .distantPast) < (lastPlaying[$1] ?? .distantPast) }
        hint = hints[.youTubeMusic]
        let newState = pick.flatMap { states[$0] }
        if source != pick { source = pick }
        if state != newState { state = newState }
        loadArtwork()
    }

    private func loadArtwork() {
        guard let src = source, let s = state, !s.artworkKey.isEmpty else {
            if state == nil { artwork = nil }
            return
        }
        if let img = artworkCache[s.artworkKey] {
            if artwork !== img { setArtwork(img) }
            return
        }
        let key = s.artworkKey
        let done: (NSImage?) -> Void = { [weak self] img in
            guard let self, let img else { return }
            if self.artworkCache.count > 20 { self.artworkCache.removeAll() }
            self.artworkCache[key] = img
            if self.state?.artworkKey == key { self.setArtwork(img) }
        }
        switch src {
        case .appleMusic: apple.fetchArtwork(done)
        case .youTubeMusic:
            guard let url = URL(string: s.artworkURL) else { return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let img = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { done(img) }
            }.resume()
        }
    }

    private func setArtwork(_ img: NSImage) {
        artwork = img
        tint = img.averageColor?.vivid ?? .white
    }
}

@MainActor protocol MusicController: AnyObject {
    func playPause()
    func next()
    func previous()
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
    /// Lifts dull colours so they read on black.
    var vivid: NSColor {
        guard let c = usingColorSpace(.deviceRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { return NSColor(white: 0.92, alpha: 1) }
        return NSColor(hue: h, saturation: min(1, max(s, 0.45)), brightness: max(b, 0.85), alpha: 1)
    }
}
