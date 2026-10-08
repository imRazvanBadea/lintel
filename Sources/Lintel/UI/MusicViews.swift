import SwiftUI

struct MusicPill: View {
    @Environment(NowPlaying.self) private var music
    var height: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if let s = music.state {
                Artwork(image: music.artwork, size: height * 0.66, radius: 5)
                Text(s.track.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: 140, alignment: .leading)
                Equalizer(color: music.tint, playing: s.isPlaying)
                    .frame(width: 16, height: height * 0.42)
            } else {
                Image(systemName: "music.note").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .frame(width: height * 0.66)
            }
        }
        .padding(.horizontal, music.state == nil ? 6 : 8)
        .frame(height: height)
        .background(PillBackground())
        .contentShape(Capsule())
        .onTapGesture { IslandModel.shared.toggle(.music) }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: music.state?.track)
    }
}

struct Artwork: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.08))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(Theme.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct MusicCard: View {
    @Environment(NowPlaying.self) private var music
    @Environment(Settings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let s = music.state {
                nowPlaying(s)
                if settings.showUpNext { upNext(s) }
            } else {
                empty
            }
            if let hint = music.hint {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.amber)
                    Text("YouTube Music: \(hint)").foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5))
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(
            // A soft wash of the album colour behind everything.
            RadialGradient(colors: [Color(nsColor: music.tint).opacity(0.22), .clear],
                           center: .topLeading, startRadius: 10, endRadius: 320)
        )
        .card()
        .animation(.easeInOut(duration: 0.4), value: music.tint)
    }

    private func nowPlaying(_ s: PlayerState) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Button { music.openSource() } label: {
                    Artwork(image: music.artwork, size: 68, radius: 14)
                        .shadow(color: Color(nsColor: music.tint).opacity(0.35), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.track.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(s.track.artist).font(.system(size: 13.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                    HStack(spacing: 5) {
                        Image(systemName: music.source == .appleMusic ? "music.note" : "play.rectangle.fill")
                        Text(music.source?.label ?? "")
                        if s.shuffle { Image(systemName: "shuffle") }
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Equalizer(color: music.tint, playing: s.isPlaying, bars: 5)
                    .frame(width: 26, height: 22)
            }

            if s.duration > 0 {
                TimelineView(.periodic(from: .now, by: s.isPlaying ? 0.5 : 60)) { _ in
                    let pos = music.currentPosition
                    VStack(spacing: 5) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.12))
                                Capsule().fill(Color.white.opacity(0.85))
                                    .frame(width: g.size.width * min(1, pos / max(1, s.duration)))
                            }
                        }
                        .frame(height: 4)
                        HStack {
                            Text(timeString(pos))
                            Spacer()
                            Text("-" + timeString(max(0, s.duration - pos)))
                        }
                        .font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(Theme.tertiary)
                    }
                }
            }

            HStack(spacing: 36) {
                control("backward.fill", 17) { music.previous() }
                control(s.isPlaying ? "pause.fill" : "play.fill", 24) { music.playPause() }
                control("forward.fill", 17) { music.next() }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func upNext(_ s: PlayerState) -> some View {
        if !s.upNext.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.shuffle ? "Next in playlist · shuffle on" : "Up next").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary).padding(.bottom, 4)
                ForEach(Array(s.upNext.prefix(4).enumerated()), id: \.offset) { i, t in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.tertiary).frame(width: 14)
                        Text(t.title).font(.system(size: 13)).lineLimit(1)
                        Text(t.artist).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .hoverRow(radius: 8)
                }
            }
            .padding(.top, 2)
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(Theme.tertiary)
            Text("Nothing playing").font(.system(size: 15, weight: .medium))
            HStack(spacing: 10) {
                Button("Apple Music") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app")) }
                    .buttonStyle(CapsuleButtonStyle(kind: .secondary, height: 32))
                Button("YouTube Music") { NSWorkspace.shared.open(URL(string: "https://music.youtube.com")!) }
                    .buttonStyle(CapsuleButtonStyle(kind: .secondary, height: 32))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func control(_ symbol: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressStyle())
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
