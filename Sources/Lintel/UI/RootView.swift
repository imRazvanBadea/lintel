import SwiftUI

/// Two islands with a gap between them — agents on the left, music on the right.
/// On a notched display the notch itself is the gap.
struct RootView: View {
    @Environment(IslandModel.self) private var model
    @Environment(NowPlaying.self) private var music
    @Environment(Settings.self) private var settings

    private var pillHeight: CGFloat { min(30, max(22, model.menuBarHeight - 6)) }
    private var gap: CGFloat { model.hasNotch ? model.notchWidth + 12 : 10 }
    private var showMusicPill: Bool { !(settings.hideMusicWhenIdle && music.state == nil) }

    var body: some View {
        GeometryReader { geo in
            let half = max(0, (geo.size.width - gap) / 2)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .trailing, spacing: 10) {
                    AgentPill(height: pillHeight)
                        .measure { model.agentPillRect = $0 }
                    if model.expanded == .agents {
                        AgentCard()
                            .measure { model.cardRect = $0 }
                            .transition(.asymmetric(insertion: .scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity),
                                                    removal: .scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity)))
                    }
                }
                .frame(width: half, alignment: .trailing)

                Color.clear.frame(width: gap, height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    if showMusicPill {
                        MusicPill(height: pillHeight)
                            .measure { model.musicPillRect = $0 }
                            .onDisappear { model.musicPillRect = .zero }
                    }
                    if model.expanded == .music {
                        MusicCard()
                            .measure { model.cardRect = $0 }
                            .transition(.asymmetric(insertion: .scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity),
                                                    removal: .scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity)))
                    }
                }
                .frame(width: half, alignment: .leading)
            }
            .padding(.top, max(2, (model.menuBarHeight - pillHeight) / 2))
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .coordinateSpace(.named("panel"))
        .preferredColorScheme(.dark)
        .onChange(of: model.expanded) { _, new in
            music.setVisible(new == .music)
        }
    }
}

extension View {
    /// Reports this view's frame in panel coordinates (for mouse hit-testing).
    func measure(_ update: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("panel")) }, action: update)
    }
}
