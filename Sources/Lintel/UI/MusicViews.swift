import SwiftUI

struct Artwork: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.fillStrong)
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
                VStack(spacing: 6) {
                    Image(systemName: "music.note").font(.system(size: 20)).foregroundStyle(Theme.tertiary)
                    Text("Nothing playing").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.primary)
                    Text("Play something in any app or browser and it shows up here.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            if let hint = music.hint {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.tertiary)
                    Text(hint).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5))
            }
        }
        .padding(20)
        .frame(width: 380)
        .card()
    }

    private func nowPlaying(_ s: PlayerState) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Button { music.openSource() } label: {
                    Artwork(image: music.artwork, size: 64, radius: 12)
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.track.title).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    Text(s.track.artist).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                    Text(music.sourceLabel).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        .padding(.top, 1)
                }
                Spacer(minLength: 0)
                Equalizer(color: music.tint, playing: s.isPlaying, bars: 4)
                    .frame(width: 18, height: 16)
            }

            if s.duration > 0 {
                TimelineView(.periodic(from: .now, by: s.isPlaying ? 0.5 : 60)) { _ in
                    let pos = music.currentPosition
                    VStack(spacing: 5) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.fillStrong)
                                Capsule().fill(Theme.action)
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

            HStack(spacing: 32) {
                control("backward.fill", 16) { music.previous() }
                Button { music.playPause() } label: {
                    Image(systemName: s.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.onAction)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Theme.action))
                }
                .buttonStyle(PressStyle())
                control("forward.fill", 16) { music.next() }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func upNext(_ s: PlayerState) -> some View {
        if !s.upNext.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider().overlay(Theme.hairline).padding(.bottom, 12)
                Text("Up next").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary).padding(.bottom, 4)
                ForEach(Array(s.upNext.prefix(5).enumerated()), id: \.offset) { i, t in
                    UpNextRow(index: i, track: t) { music.play(upNextIndex: i) }
                }
            }
        }
    }

    private func control(_ symbol: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One upcoming track; click to play it now.
struct UpNextRow: View {
    let index: Int
    let track: Track
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Text("\(index + 1)").opacity(hover ? 0 : 1)
                    Image(systemName: "play.fill").font(.system(size: 9)).opacity(hover ? 1 : 0)
                }
                .font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.tertiary).frame(width: 14)
                Text(track.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary).lineLimit(1)
                Text(track.artist).font(.system(size: 12.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.fill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Play now")
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
