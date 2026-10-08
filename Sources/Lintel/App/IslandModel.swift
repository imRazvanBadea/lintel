import AppKit
import Observation

enum Island: Equatable { case agents, music }

/// Shared UI state for the notch: which island is open, and where things are on screen
/// (used to decide when the panel should catch the mouse and when it should let clicks through).
@MainActor @Observable
final class IslandModel {
    static let shared = IslandModel()

    var expanded: Island?
    /// Session shown in the agent detail view (nil = list).
    var selectedSessionID: String?

    // Geometry of the screen the panel is on.
    var menuBarHeight: CGFloat = 24
    var notchWidth: CGFloat = 0           // 0 when the screen has no notch
    var hasNotch: Bool { notchWidth > 0 }

    // Hit areas, in panel (SwiftUI, top-left origin) coordinates.
    @ObservationIgnored var agentPillRect: CGRect = .zero
    @ObservationIgnored var musicPillRect: CGRect = .zero
    @ObservationIgnored var cardRect: CGRect = .zero

    @ObservationIgnored private var collapseWork: DispatchWorkItem?
    @ObservationIgnored private var expandWork: DispatchWorkItem?
    /// Set when an expansion was triggered by an event (not hover) so moving the mouse
    /// elsewhere does not immediately close it.
    @ObservationIgnored var pinnedByEvent = false

    func hoverChanged(over island: Island?, overCard: Bool) {
        if let island {
            collapseWork?.cancel()
            guard expanded != island else { return }
            expandWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.expand(island)
            }
            expandWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (expanded == nil ? 0.12 : 0.05), execute: work)
        } else if overCard {
            collapseWork?.cancel()
            expandWork?.cancel()
            pinnedByEvent = false
        } else {
            expandWork?.cancel()
            guard expanded != nil, !pinnedByEvent, collapseWork == nil || collapseWork!.isCancelled else { return }
            let work = DispatchWorkItem { [weak self] in self?.collapse() }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    func expand(_ island: Island, pinned: Bool = false) {
        collapseWork?.cancel()
        if island != expanded { selectedSessionID = nil }
        pinnedByEvent = pinned
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { expanded = island }
    }

    func toggle(_ island: Island) {
        if expanded == island { collapse() } else { expand(island, pinned: true) }
    }

    func collapse() {
        collapseWork?.cancel()
        collapseWork = nil
        pinnedByEvent = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            expanded = nil
        }
        cardRect = .zero
        NotificationCenter.default.post(name: .lintelCollapsed, object: nil)
    }
}

extension Notification.Name {
    static let lintelCollapsed = Notification.Name("LintelCollapsed")
}

import SwiftUI
