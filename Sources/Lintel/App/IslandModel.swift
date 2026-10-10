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
    /// Set by the back button: show the session list instead of the latest "Finished" card.
    var showingList = false
    /// Sessions whose subagents are shown in the list (folded by default).
    var unfolded: Set<String> = []
    /// The rows of the agent list, in order (⌘1…⌘9 follow this).
    var listedSessions: [AgentSession] { AgentStore.shared.listed(unfolded: unfolded).map(\.session) }
    /// The new-session composer is open in the agents card.
    var composing = false
    /// Keeps the card open while a system sheet (the folder picker) has the mouse.
    @ObservationIgnored var holdOpen = false
    /// What you were typing in the composer, kept if the card closes under you.
    var draftPrompt = ""
    var draftFolder: String?
    var draftImages: [URL] = []
    /// Replies you're writing, per session — kept when the card closes.
    var replyDrafts: [String: String] = [:]
    var replyImages: [String: [URL]] = [:]
    /// The reply box on screen (session id), if any.
    @ObservationIgnored var visibleReply: String?
    /// You're writing (a reply or a new chat): moving the mouse away won't close the card; a click outside still does.
    @ObservationIgnored var editing = false
    /// The usage dashboard is open in the agents card.
    var showingUsage = false
    var usageRange: UsageHistory.Range = .week
    var usageShowsCost = true
    /// The chart bucket under the pointer in the usage dashboard.
    var usageHover: Date?
    /// The pointer is over the notch bar (Minimal notch style shows the wings only then).
    var hoveringBar = false
    /// Wings pop out briefly for events (new song, finished turn) in Minimal style.
    var peeking = false
    @ObservationIgnored private var peekWork: DispatchWorkItem?

    func peek(for seconds: Double = 4) {
        peekWork?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { peeking = true }
        let w = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { self?.peeking = false }
        }
        peekWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    // Geometry of the screen the panel is on.
    var menuBarHeight: CGFloat = 24
    var notchWidth: CGFloat = 0           // 0 when the screen has no notch
    var hasNotch: Bool { notchWidth > 0 }
    /// The tallest a card can be on this screen (panel height minus the bar above it).
    var maxCardHeight: CGFloat = 560

    // Hit areas, in panel (SwiftUI, top-left origin) coordinates.
    @ObservationIgnored var agentPillRect: CGRect = .zero
    @ObservationIgnored var musicPillRect: CGRect = .zero
    @ObservationIgnored var cardRect: CGRect = .zero
    /// The whole notch bar (split into the two pills above).
    @ObservationIgnored var barRect: CGRect = .zero

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
            guard expanded != nil, !pinnedByEvent, !holdOpen, !editing, collapseWork == nil || collapseWork!.isCancelled else { return }
            let work = DispatchWorkItem { [weak self] in self?.collapse() }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    func expand(_ island: Island, pinned: Bool = false) {
        if island == .music && !Settings.shared.musicEnabled { return }
        collapseWork?.cancel()
        if island != expanded { selectedSessionID = nil; showingList = false; composing = false }
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
        selectedSessionID = nil
        showingList = false
        showingUsage = false
        composing = false
        editing = false
        NotificationCenter.default.post(name: .lintelCollapsed, object: nil)
    }
}

extension Notification.Name {
    static let lintelCollapsed = Notification.Name("LintelCollapsed")
    static let lintelAppearanceChanged = Notification.Name("LintelAppearanceChanged")
}

import SwiftUI
