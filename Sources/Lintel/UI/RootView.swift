import SwiftUI

/// Notched display: the notch grows wings — agents on the left, music on the right — and the
/// light card drops out from under it. External display: two light capsules at the top edge.
struct RootView: View {
    @Environment(IslandModel.self) private var model
    @Environment(NowPlaying.self) private var music
    @Environment(AgentStore.self) private var store

    var body: some View {
        VStack(spacing: model.hasNotch ? 8 : 10) {
            if model.hasNotch { NotchBar() } else { CapsuleBar() }

            Group {
                if model.expanded == .agents {
                    AgentCard().measure { model.cardRect = $0 }
                } else if model.expanded == .music {
                    MusicCard().measure { model.cardRect = $0 }
                }
            }
            .transition(.asymmetric(insertion: .scale(scale: 0.9, anchor: .top).combined(with: .opacity),
                                    removal: .opacity.animation(.easeOut(duration: 0.1))))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(.named("panel"))
        .onChange(of: model.expanded) { _, new in music.setVisible(new == .music) }
    }
}

// MARK: - Notch

struct NotchBar: View {
    @Environment(IslandModel.self) private var model
    @Environment(AgentStore.self) private var store
    @Environment(NowPlaying.self) private var music

    private let ear: CGFloat = 7
    private var inset: CGFloat { ear + (wing > 0 ? 8 : 0) }

    /// Both wings share one width so the hardware notch stays centred.
    private var wing: CGFloat {
        let attention = store.hasPendingRequests || !store.needsYou.isEmpty
        if attention { return 118 }
        if store.sessions.isEmpty && music.state == nil { return model.expanded == nil ? 0 : 44 }
        return model.expanded == nil ? 64 : 76
    }

    var body: some View {
        let h = model.menuBarHeight
        HStack(spacing: 0) {
            AgentWing(height: h).frame(width: wing, alignment: .leading)
            Color.clear.frame(width: model.notchWidth)
            MusicWing(height: h).frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, inset)
        .frame(height: h)
        .background(NotchShape(ear: ear, bottomRadius: min(14, h * 0.4)).fill(Color.black))
        .contentShape(Rectangle())
        .measure { r in
            // Left half opens agents, right half opens music.
            model.agentPillRect = CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
            model.musicPillRect = CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
        }
        .onTapGesture { location in
            // Tap position is in the bar's own space.
            let total = wing * 2 + model.notchWidth + inset * 2
            IslandModel.shared.toggle(location.x < total / 2 ? .agents : .music)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: wing)
        .clipped()
    }
}

/// Agents, as they appear in the notch's left wing (white on black).
struct AgentWing: View {
    @Environment(AgentStore.self) private var store
    var height: CGFloat

    var body: some View {
        let ordered = store.sessions.sorted { ($0.status, $0.lastEventAt) < ($1.status, $1.lastEventAt) }
        let waiting = store.needsYou.first
        HStack(spacing: 8) {
            HStack(spacing: -5) {
                ForEach(ordered.prefix(3)) { s in
                    Avatar(session: s, size: height * 0.5, showsActivity: false)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
                }
            }
            if waiting != nil {
                Text("Needs you").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.amber)
                    .lineLimit(1).fixedSize()
            }
            Spacer(minLength: 0)
            if let s = store.working.first, waiting == nil {
                RingSpinner(color: NSColor(s.tint), lineWidth: 2, trackColor: NSColor.white.withAlphaComponent(0.15))
                    .frame(width: height * 0.38, height: height * 0.38)
            }
        }
        .frame(height: height)
    }
}

/// Now playing, as it appears in the notch's right wing.
struct MusicWing: View {
    @Environment(NowPlaying.self) private var music
    var height: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if let s = music.state {
                Equalizer(color: music.tint.blended(withFraction: 0.35, of: .white) ?? music.tint, playing: s.isPlaying)
                    .frame(width: 14, height: height * 0.32)
                Spacer(minLength: 0)
                Artwork(image: music.artwork, size: height * 0.52, radius: 5)
            }
        }
        .frame(height: height)
    }
}

// MARK: - External display

struct CapsuleBar: View {
    @Environment(IslandModel.self) private var model
    @Environment(NowPlaying.self) private var music

    private var height: CGFloat { min(30, max(24, model.menuBarHeight - 4)) }

    var body: some View {
        HStack(spacing: 8) {
            AgentCapsule(height: height)
                .measure { model.agentPillRect = $0 }
            if music.state != nil {
                MusicCapsule(height: height)
                    .measure { model.musicPillRect = $0 }
                    .onDisappear { model.musicPillRect = .zero }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(.top, max(1, (model.menuBarHeight - height) / 2))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: music.state == nil)
    }
}

struct AgentCapsule: View {
    @Environment(AgentStore.self) private var store
    var height: CGFloat

    var body: some View {
        let waiting = store.pending.first { $0.isBlocking }.flatMap { store.existing($0.sessionID) } ?? store.needsYou.first
        let busy = store.working.max { $0.lastEventAt < $1.lastEventAt }

        HStack(spacing: 8) {
            if let s = waiting {
                Avatar(session: s, size: height * 0.62)
                Text("Needs you").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.amber)
                Text(s.displayTitle).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).frame(maxWidth: 150, alignment: .leading)
            } else if let s = busy {
                Avatar(session: s, size: height * 0.62)
                Text(s.phase.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.primary)
                    .contentTransition(.opacity)
                Text(s.displayTitle).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                if store.working.count > 1 {
                    Text("+\(store.working.count - 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
                }
            } else if !store.sessions.isEmpty {
                HStack(spacing: -5) {
                    ForEach(store.sessions.prefix(5)) { s in
                        Avatar(session: s, size: height * 0.62, showsActivity: false)
                            .overlay(Circle().strokeBorder(Theme.capsuleFill, lineWidth: 1.5))
                    }
                }
            } else {
                Circle().fill(Theme.fillStrong).frame(width: height * 0.36, height: height * 0.36)
            }
        }
        .padding(.horizontal, store.sessions.isEmpty ? 8 : 10)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: height)
        .background(CapsuleBackground())
        .contentShape(Capsule())
        .onTapGesture { IslandModel.shared.toggle(.agents) }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: waiting?.id)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: busy?.id)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.sessions.count)
    }
}

struct MusicCapsule: View {
    @Environment(NowPlaying.self) private var music
    var height: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if let s = music.state {
                Artwork(image: music.artwork, size: height * 0.66, radius: 5)
                Text(s.track.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.primary)
                    .lineLimit(1).frame(maxWidth: 92, alignment: .leading)
                Equalizer(color: music.tint, playing: s.isPlaying)
                    .frame(width: 14, height: height * 0.4)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 10)
        // Size to the content: short titles give a short capsule; long ones truncate at the cap.
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: height)
        .background(CapsuleBackground())
        .contentShape(Capsule())
        .onTapGesture { IslandModel.shared.toggle(.music) }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: music.state?.track)
    }
}

extension View {
    /// Reports this view's frame in panel coordinates (for mouse hit-testing).
    func measure(_ update: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("panel")) }, action: update)
    }
}
