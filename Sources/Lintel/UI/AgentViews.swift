import SwiftUI

// MARK: - Expanded card

struct AgentCard: View {
    @Environment(AgentStore.self) private var store
    @Environment(IslandModel.self) private var model

    var body: some View {
        Group {
            if model.showingUsage {
                UsageDashboard()
            } else if model.composing {
                NewSessionView()
            } else if let id = model.selectedSessionID, let s = store.existing(id),
               let p = store.pending.first(where: { $0.sessionID == id && $0.isBlocking }) {
                AttentionView(request: p, session: s, queued: 0)
            } else if let id = model.selectedSessionID, let s = store.existing(id),
                      let p = store.pending.first(where: { $0.sessionID == id && !$0.isBlocking }) {
                FinishedView(session: s, reply: p)
            } else if !model.showingList, model.selectedSessionID == nil,
               let p = store.pending.first(where: { $0.isBlocking }), let s = store.existing(p.sessionID) {
                AttentionView(request: p, session: s, queued: store.pending.filter(\.isBlocking).count - 1)
            } else if !model.showingList, model.selectedSessionID == nil, let p = store.pending.last(where: { !$0.isBlocking }),
                      let s = store.existing(p.sessionID) {
                FinishedView(session: s, reply: p)
            } else if !model.showingList, model.selectedSessionID == nil, let id = store.finishedFlash, let s = store.existing(id) {
                FinishedView(session: s, reply: nil)
            } else if let id = model.selectedSessionID, let s = store.existing(id) {
                VStack(spacing: 0) {
                    SessionDetailView(session: s, showBack: true)
                    UsageFooter()
                }
            } else {
                VStack(spacing: 0) {
                    SessionListView()
                    UsageFooter()
                }
            }
        }
        .frame(width: model.showingUsage ? 500 : 440)
        .card()
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.selectedSessionID)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.showingList)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.showingUsage)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.composing)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: store.pending.map(\.id))
    }
}

/// "‹" — back to the list of all agents.
struct BackButton: View {
    var body: some View {
        Button {
            IslandModel.shared.selectedSessionID = nil
            IslandModel.shared.showingList = true
        } label: { Image(systemName: "chevron.left") }
        .buttonStyle(IconButtonStyle(size: 26))
        .help("All agents")
    }
}

// MARK: Usage

/// Plan usage for every connected tool: what's left of the 5-hour window at a glance; hover for the week and resets.
struct UsageFooter: View {
    @Environment(UsageStore.self) private var usage
    @State private var hovering = false

    /// One row of the footer: a tool's default account, or an extra one ("work").
    struct Entry: Identifiable { let id: String; let kind: AgentKind; let slug: String?; let usage: UsageStore.Usage }

    /// Every account we have numbers for, in a fixed order, whether or not it has a session open right now.
    private var entries: [Entry] {
        var out: [Entry] = []
        for k in [AgentKind.claude, .cursor, .codex] {
            if let u = usage.usage[k] { out.append(Entry(id: k.rawValue, kind: k, slug: nil, usage: u)) }
            for (a, u) in usage.extraUsage.sorted(by: { $0.key.id < $1.key.id }) where a.kind == k {
                out.append(Entry(id: a.id, kind: k, slug: a.slug, usage: u))
            }
        }
        return out
    }

    var body: some View {
        let entries = self.entries
        if !entries.isEmpty {
            VStack(spacing: 8) {
                Divider().overlay(Theme.hairline)
                if entries.count == 1 || hovering {
                    // One tool, or hovering: the 5-hour window, the week and the reset for each.
                    VStack(spacing: 8) {
                        ForEach(entries) { e in fullRow(e.kind, e.usage, slug: e.slug) }
                    }
                    .transition(.opacity)
                } else {
                    // Several at once: just the 5-hour window each, side by side.
                    HStack(spacing: 14) {
                        ForEach(entries) { e in compact(e.kind, e.usage, slug: e.slug) }
                        Spacer(minLength: 0)
                    }
                    .transition(.opacity)
                }
            }
            .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { hovering = h } }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .contentShape(Rectangle())
            .onTapGesture { IslandModel.shared.showingUsage = true }
            .help("Usage history")
        }
    }

    private func logo(_ kind: AgentKind, slug: String?, size: CGFloat) -> some View {
        HStack(spacing: 3) {
            AgentLogo(kind: kind, size: size)
            if let slug { Text(slug).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.tertiary).lineLimit(1) }
        }
    }

    /// One tool: 5-hour + week + reset.
    @ViewBuilder
    private func fullRow(_ kind: AgentKind, _ u: UsageStore.Usage, slug: String?) -> some View {
        HStack(spacing: 12) {
            logo(kind, slug: slug, size: 16)
            if let short = u.short {
                meter("5h", short, width: 46)
                if let week = u.weekly { meter(windowLabel(week), week, width: 46) }
                Spacer(minLength: 4)
                Text(resetText(short))
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(short.usedPercent >= 100 ? Theme.amber : Theme.tertiary)
                    .lineLimit(1).fixedSize()
            } else if let long = u.weekly {
                // Only a long window (Codex's free plan: 30 days).
                meter(windowLabel(long), long, width: 46)
                Spacer(minLength: 4)
                Text(resetText(long))
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(long.usedPercent >= 100 ? Theme.amber : Theme.tertiary)
                    .lineLimit(1).fixedSize()
            } else {
                planInfo(kind, u)
            }
        }
        .help(help(u))
    }

    /// Several tools: logo, a short bar and what's left (or when it comes back).
    @ViewBuilder
    private func compact(_ kind: AgentKind, _ u: UsageStore.Usage, slug: String?) -> some View {
        HStack(spacing: 6) {
            logo(kind, slug: slug, size: 15)
            if let short = u.short ?? u.weekly {
                bar(short, width: 30)
                Text(short.usedPercent >= 100 ? resetText(short).replacingOccurrences(of: "Back in ", with: "↺ ")
                                              : "\(Int(100 - min(100, short.usedPercent)))%")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(short.usedPercent >= 100 ? Theme.amber : Theme.secondary)
                    .lineLimit(1).fixedSize()
            } else if kind == .cursor {
                Button { Self.openCursorUsage() } label: {
                    Text(u.plan ?? "Usage").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .help(help(u, kind: kind))
    }

    /// No numbers to show: the plan, and for Cursor a link to its dashboard.
    @ViewBuilder
    private func planInfo(_ kind: AgentKind, _ u: UsageStore.Usage) -> some View {
        HStack(spacing: 6) {
            Text(u.plan.map { "\($0) plan" } ?? kind.label)
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            if let note = u.note { InfoTip(text: note) }
        }
        Spacer(minLength: 4)
        if kind == .cursor {
            Button { Self.openCursorUsage() } label: {
                HStack(spacing: 3) {
                    Text("Usage").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private static func openCursorUsage() {
        NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard?tab=usage")!)
    }

    private func help(_ u: UsageStore.Usage, kind: AgentKind? = nil) -> String {
        var parts: [String] = []
        if let k = kind { parts.append(k.label) }
        if let s = u.short { parts.append("5-hour: \(Int(s.usedPercent))% used") }
        if let w = u.weekly { parts.append("\(windowLabel(w).lowercased()): \(Int(w.usedPercent))% used") }
        if let s = u.short, s.resetsAt != nil { parts.append(resetText(s).lowercased()) }
        if u.short?.estimated == true { parts.append("estimated from the Claude app's log") }
        return parts.joined(separator: " · ")
    }

    private func bar(_ w: UsageStore.Window, width: CGFloat) -> some View {
        let used = min(100, max(0, w.usedPercent))
        let color: Color = used >= 100 ? Theme.red : (used >= 80 ? Theme.amber : Theme.primary.opacity(0.75))
        return ZStack(alignment: .leading) {
            Capsule().fill(Theme.fillStrong)
            Capsule().fill(color).frame(width: width * used / 100)
        }
        .frame(width: width, height: 4)
    }

    private func meter(_ label: String, _ w: UsageStore.Window, width: CGFloat) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).fixedSize()
            bar(w, width: width)
            Text("\(Int(100 - min(100, max(0, w.usedPercent))))% left").font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
        }
    }

    private func windowLabel(_ w: UsageStore.Window) -> String {
        guard let m = w.minutes, m > 8 * 24 * 60 else { return "Week" }
        return m >= 28 * 24 * 60 ? "Month" : "\(m / (24 * 60))d"
    }

    private func resetText(_ w: UsageStore.Window) -> String {
        guard let r = w.resetsAt else { return w.usedPercent >= 100 ? "Limit reached" : "" }
        let mins = Int(r.timeIntervalSinceNow / 60)
        let approx = w.estimated ? "~" : ""
        let when: String
        if mins < 60 { when = "\(max(1, mins))m" }
        else if mins < 24 * 60 { when = "\(mins / 60)h \(mins % 60)m" }
        else if mins < 7 * 24 * 60 { when = r.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        else { when = r.formatted(.dateTime.month(.abbreviated).day()) }
        return w.usedPercent >= 100 ? "Back in \(approx)\(when)" : "Resets in \(approx)\(when)"
    }
}

/// The tool's own app icon (Claude, Cursor, Codex), so rows stay short.
struct AgentLogo: View {
    let kind: AgentKind
    var size: CGFloat = 16

    private static var cache: [AgentKind: NSImage] = [:]
    private static let bundleIDs: [AgentKind: [String]] = [
        .claude: ["com.anthropic.claudefordesktop"],
        .cursor: ["com.todesktop.230313mzl4w4u92"],
        .codex: ["com.openai.codex", "com.openai.chat"],
    ]

    private var image: NSImage? {
        if let i = Self.cache[kind] { return i }
        for id in Self.bundleIDs[kind] ?? [] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let i = NSWorkspace.shared.icon(forFile: url.path)
                Self.cache[kind] = i
                return i
            }
        }
        return nil
    }

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Text(kind.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
        }
    }
}

// MARK: List

struct SessionListView: View {
    @Environment(AgentStore.self) private var store
    @Environment(IslandModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Agents").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
                if !store.working.isEmpty {
                    Text("\(store.working.count) working").font(.system(size: 12.5)).foregroundStyle(Theme.tertiary)
                }
                if AwakeController.shared.mode != .off {
                    Image(systemName: "eye").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                        .help("You can close the lid: your agents keep running and the Mac sleeps when they're done.")
                }
                Spacer(minLength: 0)
                Button { model.composing = true } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("New session (⌘N)")
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 4)

            if store.sessions.isEmpty {
                EmptyAgentsView()
            }
            ForEach(Array(store.listed(unfolded: model.unfolded).enumerated()), id: \.element.session.id) { i, row in
                SessionRow(session: row.session, index: i + 1, nested: row.nested)
            }
        }
        .padding(6)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.unfolded)
    }
}

struct SessionRow: View {
    @Environment(AgentStore.self) private var store
    @Environment(IslandModel.self) private var model
    let session: AgentSession
    let index: Int
    var nested = false

    private var status: String {
        switch session.status {
        case .waiting: return "Waiting on you · "
        case .working: return "\(session.phase.label) · "
        case .finished: return "Finished · "
        case .idle: return ""
        }
    }

    var body: some View {
        let subagents = nested ? [] : store.subagents(of: session)
        HStack(spacing: 8) {
            Button {
                IslandModel.shared.selectedSessionID = session.id
            } label: {
                HStack(spacing: 12) {
                    Avatar(session: session, size: nested ? 24 : 30)
                        .padding(4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayTitle).font(.system(size: nested ? 13.5 : 14.5, weight: .medium))
                            .foregroundStyle(Theme.primary).lineLimit(1)
                        HStack(spacing: 4) {
                            Text("\(status)\(session.project) ·").lineLimit(1)
                            AgentLogo(kind: session.kind, size: 13)
                            Text(session.kind.label).lineLimit(1).fixedSize()
                        }
                        .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 8)
                    if index <= 9 {
                        Text("⌘\(index)").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !subagents.isEmpty { fold(subagents) }
        }
        .padding(.leading, nested ? 30 : 10)
        .padding(.trailing, 10)
        .padding(.vertical, nested ? 5 : 8)
        .hoverRow()
        .contextMenu {
            Button("Jump to session") { AgentStore.shared.reveal(session) }
            Button("Hide from list") { AgentStore.shared.remove(session.id) }
        }
    }

    /// The subagents this session spawned, folded into a small stack; click to show or hide them.
    private func fold(_ subagents: [AgentSession]) -> some View {
        let open = model.unfolded.contains(session.id)
        return Button {
            if open { model.unfolded.remove(session.id) } else { model.unfolded.insert(session.id) }
        } label: {
            HStack(spacing: 5) {
                HStack(spacing: 2) {
                    ForEach(subagents.prefix(3)) { s in Avatar(session: s, size: 12, showsActivity: false) }
                }
                if subagents.count > 3 {
                    Text("+\(subagents.count - 3)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 7).frame(height: 24)
            .background(Capsule().fill(open ? Theme.fillStrong : Theme.fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide subagents" : "Show \(subagents.count) subagent\(subagents.count == 1 ? "" : "s")")
    }
}

struct EmptyAgentsView: View {
    @State private var claude = AgentHooks.isInstalled(.claude)
    @State private var cursor = AgentHooks.isInstalled(.cursor)

    var body: some View {
        VStack(spacing: 10) {
            Text("No agents running").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
            Text(claude || cursor ? "Press + to start Claude Code, Codex or Cursor in a project, or start one anywhere and it shows up here."
                                  : "Connect your agents so sessions, prompts and questions show up here.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                if !claude {
                    Button("Connect Claude Code") { try? AgentHooks.install(.claude); claude = AgentHooks.isInstalled(.claude) }
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 32))
                }
                if !cursor && AgentHooks.Target.cursor.isAvailable {
                    Button("Connect Cursor") { try? AgentHooks.install(.cursor); cursor = AgentHooks.isInstalled(.cursor) }
                        .buttonStyle(PillButtonStyle(kind: claude ? .primary : .secondary, height: 32))
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 12)
        .padding(.bottom, 20)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }
}

// MARK: Detail

struct SessionDetailView: View {
    @Environment(AgentStore.self) private var store
    let session: AgentSession
    var showBack: Bool

    /// The finished turn the agent is still holding open for a reply, if any.
    private var openTurn: PendingRequest? { store.pendingFor(session).first { !$0.isBlocking } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if showBack { BackButton() }
                Avatar(session: session, size: 24)
                    .padding(.horizontal, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(session.project)
                        if let b = session.branch {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5))
                            Text(b).lineLimit(1)
                        }
                        Text("· \(session.kind.label)")
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                StatusChip(session: session)
            }

            if let notice = session.notice {
                Text(notice).font(.system(size: 12.5)).foregroundStyle(Theme.amber).lineLimit(2)
            }

            ActivityFeed(session: session)

            if let openTurn {
                ReplyBar(session: session, request: openTurn)
                    .id(openTurn.id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 8) {
                AgentLogo(kind: session.kind, size: 15)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let parts = [session.tokens > 0 ? "\(formatTokens(session.tokens)) tokens" : nil,
                                 session.model.isEmpty ? nil : session.model,
                                 session.effort.map { $0 == "xhigh" ? "XHigh" : $0.capitalized },
                                 session.turnDuration.map { formatDuration($0) }].compactMap { $0 }
                    Text(parts.joined(separator: " · "))
                        .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Theme.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .help([session.kind.label, session.model, session.effort.map { "\($0) effort" }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                Spacer(minLength: 4)
                Button("Jump to session") { AgentStore.shared.reveal(session); IslandModel.shared.collapse() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 30))
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize()
            }
        }
        .padding(20)
        .onAppear { AgentStore.shared.refreshFeed(session, force: true) }
    }
}

/// Working / Waiting on you / Finished, with how long.
struct StatusChip: View {
    let session: AgentSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 5) {
                Circle().fill(session.statusColor).frame(width: 6, height: 6)
                Text(label).lineLimit(1)
            }
            .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Theme.fill))
        }
    }

    private var label: String {
        switch session.status {
        case .working: return "Working" + (session.turnDuration.map { " · \(formatDuration($0))" } ?? "")
        case .waiting: return "Needs you"
        case .finished: return "Finished · " + relativeTime(session.turnEndedAt ?? session.lastEventAt)
        case .idle: return "Idle"
        }
    }
}

/// The conversation, newest at the bottom: your messages, the agent's replies and thinking, and its tool calls.
/// No box around it — it fades out at the top and bottom edges while there's more to scroll.
struct ActivityFeed: View {
    let session: AgentSession
    @State private var moreAbove = false
    @State private var moreBelow = false

    private static let fade: CGFloat = 22

    /// Your latest message and everything the agent did since (capped).
    private var items: [FeedItem] {
        let feed = session.feed
        guard let u = feed.lastIndex(where: { $0.kind == .user }) else { return Array(feed.suffix(30)) }
        return [feed[u]] + feed[(u + 1)...].suffix(40)
    }

    var body: some View {
        let items = self.items
        if items.isEmpty, !session.lastMessage.isEmpty {
            FeedRow(item: FeedItem(id: "last", kind: .assistant, text: session.lastMessage, date: session.turnEndedAt ?? Date()),
                    tint: session.tint)
        } else if items.isEmpty {
            Text(session.status == .working ? "Working…" : "No activity yet")
                .font(.system(size: 12.5)).foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { item in FeedRow(item: item, tint: session.tint).id(item.id) }
                        if session.status == .working, items.last?.status != .running {
                            WorkingRow(tint: session.tint).id("working")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 320)
                .onScrollGeometryChange(for: [Bool].self) { g in
                    [g.contentOffset.y > 2, g.contentOffset.y + g.containerSize.height < g.contentSize.height - 2]
                } action: { _, v in
                    withAnimation(.easeOut(duration: 0.15)) { moreAbove = v[0]; moreBelow = v[1] }
                }
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(colors: [moreAbove ? .clear : .black, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.fade)
                        Color.black
                        LinearGradient(colors: [.black, moreBelow ? .clear : .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.fade)
                    }
                )
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: items.last?.id) { _, id in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id ?? "working", anchor: .bottom) }
                }
            }
        }
    }
}

struct FeedRow: View {
    let item: FeedItem
    let tint: Color

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: [tint.lighter, tint], startPoint: .top, endPoint: .bottom))
                    )
                    .textSelection(.enabled)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(tint).frame(width: 6, height: 6).padding(.top, 6)
                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .thinking:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    .frame(width: 6).padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.duration.map { "Thought for \(formatDuration($0))" } ?? "Thought")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary)
                    if !item.text.isEmpty {
                        Text(item.text).font(.system(size: 12)).italic().foregroundStyle(Theme.tertiary).lineLimit(3)
                    }
                }
            }
        case .tool:
            HStack(alignment: .top, spacing: 8) {
                statusMark.frame(width: 6).padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.tool).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                        Text(statusText).font(.system(size: 11.5)).foregroundStyle(item.status == .failed ? Theme.red : Theme.tertiary)
                    }
                    if !item.text.isEmpty {
                        Text(item.text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }

    @ViewBuilder private var statusMark: some View {
        switch item.status {
        case .running:
            RingSpinner(color: NSColor(tint), lineWidth: 1.5).frame(width: 9, height: 9).offset(x: -1.5, y: -1)
        case .done: Circle().fill(Theme.green).frame(width: 6, height: 6)
        case .failed: Circle().fill(Theme.red).frame(width: 6, height: 6)
        }
    }

    private var statusText: String {
        switch item.status {
        case .running: "Running"
        case .done: "Completed"
        case .failed: "Failed"
        }
    }
}

/// The trailing "still working" line while the agent thinks between steps.
struct WorkingRow: View {
    let tint: Color
    var body: some View {
        HStack(spacing: 8) {
            RingSpinner(color: NSColor(tint), lineWidth: 1.5).frame(width: 9, height: 9).offset(x: -1.5)
            Text("Working…").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: - Needs you

struct AttentionView: View {
    let request: PendingRequest
    let session: AgentSession
    let queued: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BackButton()
                Avatar(session: session, size: 22, showsActivity: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
                    Text("\(session.displayTitle) · \(session.project)")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                if queued > 0 {
                    Text("+\(queued) more").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(Int(Date().timeIntervalSince(request.createdAt)))s")
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.tertiary).monospacedDigit()
                }
            }

            switch request.kind {
            case .permission(let tool, let detail, let description, let canAlways):
                PermissionBody(request: request, session: session, tool: tool, detail: detail,
                               description: description, canAlways: canAlways)
            case .question(let qs):
                QuestionBody(request: request, questions: qs)
            case .external(let message):
                ExternalBody(request: request, session: session, message: message)
            case .reply:
                EmptyView()
            }
        }
        .padding(20)
    }

    private var headline: String {
        switch request.kind {
        case .permission: "Needs your go-ahead"
        case .question(let qs): qs.count > 1 ? "\(qs.count) questions for you" : "A question for you"
        case .external: "Needs you in \(session.kind == .claude ? "the terminal" : session.kind.label)"
        case .reply: ""
        }
    }
}

struct CodeBlock: View {
    let text: String
    var body: some View {
        ScrollView {
            Text(text).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 140)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill))
    }
}

struct PermissionBody: View {
    let request: PendingRequest
    let session: AgentSession
    let tool: String
    let detail: String
    let description: String
    let canAlways: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(tool).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.primary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().strokeBorder(Theme.hairline))
                if !description.isEmpty {
                    Text(description).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            if !detail.isEmpty { CodeBlock(text: detail) }
            HStack(spacing: 8) {
                Button("Deny") { AgentStore.shared.deny(request) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Button("Allow") { AgentStore.shared.allow(request) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
            }
            HStack(spacing: 4) {
                if canAlways {
                    Button("Always allow") { AgentStore.shared.allow(request, always: true) }
                        .buttonStyle(PillButtonStyle(kind: .quiet, height: 24))
                }
                Spacer()
                Button(session.kind == .cursor ? "Decide in Cursor" : "Answer in terminal") { AgentStore.shared.deferToTerminal(request) }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 24))
            }
            .font(.system(size: 12))
        }
    }
}

struct QuestionBody: View {
    let request: PendingRequest
    let questions: [QuestionSpec]
    @State private var picks: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    private var complete: Bool {
        questions.allSatisfy { q in !(picks[q.question] ?? []).isEmpty || !(other[q.question] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(questions) { q in
                        VStack(alignment: .leading, spacing: 6) {
                            if !q.header.isEmpty {
                                Text(q.header.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                            }
                            Text(q.question).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 2)
                            ForEach(q.options, id: \.label) { o in optionRow(q, o) }
                            TextField("Something else…", text: Binding(
                                get: { other[q.question] ?? "" },
                                set: { other[q.question] = $0; if !$0.isEmpty && !q.multiSelect { picks[q.question] = [] } }))
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.primary)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Terminal") { AgentStore.shared.deferToTerminal(request) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .frame(width: 120)
                Button("Submit") { submit() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(!complete)
                    .opacity(complete ? 1 : 0.35)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func optionRow(_ q: QuestionSpec, _ o: QuestionSpec.Option) -> some View {
        let selected = picks[q.question]?.contains(o.label) ?? false
        return Button {
            var set = picks[q.question] ?? []
            if q.multiSelect {
                if selected { set.remove(o.label) } else { set.insert(o.label) }
            } else {
                set = [o.label]
                other[q.question] = ""
            }
            picks[q.question] = set
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: q.multiSelect ? (selected ? "checkmark.square.fill" : "square")
                                                : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.primary : Theme.tertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.label).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.primary)
                    if !o.description.isEmpty {
                        Text(o.description).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Theme.fill : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Theme.primary.opacity(0.85) : Theme.hairline, lineWidth: selected ? 1.5 : 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        var answers: [String: String] = [:]
        for q in questions {
            var parts = q.options.map(\.label).filter { picks[q.question]?.contains($0) ?? false }
            let o = (other[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !o.isEmpty { parts.append(o) }
            answers[q.question] = parts.joined(separator: ", ")
        }
        AgentStore.shared.answer(request, answers: answers)
    }
}

struct ExternalBody: View {
    let request: PendingRequest
    let session: AgentSession
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !message.isEmpty { CodeBlock(text: message) }
            HStack(spacing: 8) {
                Button("Dismiss") { AgentStore.shared.discard(request) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Button(session.kind == .claude ? "Open terminal" : "Open \(session.kind.label)") {
                    AgentStore.shared.reveal(session)
                    AgentStore.shared.discard(request)
                    IslandModel.shared.collapse()
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
    }
}

// MARK: - Finished

struct FinishedView: View {
    let session: AgentSession
    let reply: PendingRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BackButton()
                Avatar(session: session, size: 22, showsActivity: false)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Finished").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.green)
                    }
                    HStack(spacing: 5) {
                        Text(session.displayTitle).lineLimit(1)
                        if let b = session.branch {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5))
                            Text(b).lineLimit(1)
                        }
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Text(relativeTime(session.turnEndedAt ?? Date())).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            if !session.lastMessage.isEmpty {
                Text(session.lastMessage.prefix(600))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.primary.opacity(0.85))
                    .lineLimit(5)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if session.tokens > 0 { Text("\(formatTokens(session.tokens)) tokens") }
                Text("\(session.turnToolCalls) tool calls")
                if let d = session.turnDuration { Text(formatDuration(d)) }
                Spacer()
                Button("Open") { AgentStore.shared.reveal(session); IslandModel.shared.collapse() }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 22))
            }
            .font(.system(size: 12)).foregroundStyle(Theme.tertiary)

            if let reply {
                ReplyBar(session: session, request: reply) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { IslandModel.shared.collapse() }
                }
            }
        }
        .padding(20)
    }
}
