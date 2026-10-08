import SwiftUI

// MARK: - Expanded card

struct AgentCard: View {
    @Environment(AgentStore.self) private var store
    @Environment(IslandModel.self) private var model

    var body: some View {
        Group {
            if let p = store.pending.first(where: { $0.isBlocking }), let s = store.existing(p.sessionID) {
                AttentionView(request: p, session: s, queued: store.pending.filter(\.isBlocking).count - 1)
            } else if model.selectedSessionID == nil, let p = store.pending.last(where: { !$0.isBlocking }),
                      let s = store.existing(p.sessionID) {
                FinishedView(session: s, reply: p)
            } else if model.selectedSessionID == nil, let id = store.finishedFlash, let s = store.existing(id) {
                FinishedView(session: s, reply: nil)
            } else if let id = model.selectedSessionID ?? (store.sessions.count == 1 ? store.sessions.first?.id : nil),
                      let s = store.existing(id) {
                SessionDetailView(session: s, showBack: store.sessions.count > 1)
            } else if store.sessions.isEmpty {
                EmptyAgentsView()
            } else {
                SessionListView()
            }
        }
        .frame(width: 440)
        .card()
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.selectedSessionID)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: store.pending.map(\.id))
    }
}

// MARK: List

struct SessionListView: View {
    @Environment(AgentStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.sessions.enumerated()), id: \.element.id) { i, s in
                SessionRow(session: s, index: i + 1)
            }
        }
        .padding(6)
    }
}

struct SessionRow: View {
    let session: AgentSession
    let index: Int

    private var subtitle: String {
        let where_ = "\(session.project) · \(session.kind.label)"
        switch session.status {
        case .waiting: return "Waiting on you · \(where_)"
        case .working: return "\(session.phase.label) · \(where_)"
        case .finished: return "Finished · \(where_)"
        case .idle: return where_
        }
    }

    var body: some View {
        Button {
            IslandModel.shared.selectedSessionID = session.id
        } label: {
            HStack(spacing: 12) {
                Avatar(session: session, size: 30)
                    .padding(4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Theme.primary).lineLimit(1)
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if index <= 9 {
                    Text("⌘\(index)").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.tertiary)
                }
                Circle().fill(session.statusColor).frame(width: 8, height: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverRow()
        .contextMenu {
            Button("Jump to session") { AgentStore.shared.reveal(session) }
            Button("Hide from list") { AgentStore.shared.remove(session.id) }
        }
    }
}

struct EmptyAgentsView: View {
    @State private var claude = AgentHooks.isInstalled(.claude)
    @State private var cursor = AgentHooks.isInstalled(.cursor)

    var body: some View {
        VStack(spacing: 10) {
            Text("No agents running").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
            Text(claude || cursor ? "Start Claude Code, Cursor or Codex and it shows up here."
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
        .padding(.vertical, 24)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }
}

// MARK: Detail

struct SessionDetailView: View {
    let session: AgentSession
    var showBack: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if showBack {
                    Button { IslandModel.shared.selectedSessionID = nil } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(IconButtonStyle(size: 26))
                }
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
            }

            PhaseStrip(current: session.phase, active: session.status == .working || session.status == .finished,
                       done: session.status == .finished)

            if let notice = session.notice {
                Text(notice).font(.system(size: 12.5)).foregroundStyle(Theme.amber).lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.tools.isEmpty ? "No tool calls yet" : "Tool calls")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary)
                    .padding(.bottom, 4)
                ForEach(session.tools.prefix(4)) { t in
                    HStack(spacing: 10) {
                        Image(systemName: Phase.forTool(t.name, detail: t.detail).symbol)
                            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).frame(width: 16)
                        Text(t.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.primary)
                        Text(t.detail).font(Theme.mono).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text("×\(t.count)").font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.tertiary)
                    }
                    .padding(.vertical, 5)
                }
            }

            Divider().overlay(Theme.hairline)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack {
                    stat("Tokens", session.tokens > 0 ? formatTokens(session.tokens) : "—")
                    stat("Turn", session.turnDuration.map(formatDuration) ?? "—")
                    stat("Model", session.model.isEmpty ? session.kind.label.lowercased() : session.model)
                }
            }

            Button("Jump to session") { AgentStore.shared.reveal(session); IslandModel.shared.collapse() }
                .buttonStyle(PillButtonStyle(kind: .secondary, height: 34))
        }
        .padding(20)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            Text(value).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.primary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PhaseStrip: View {
    let current: Phase
    let active: Bool
    let done: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Phase.allCases, id: \.self) { p in
                let on = active && p == current
                VStack(spacing: 5) {
                    Image(systemName: p == .reviewing && done ? "checkmark.circle.fill" : p.symbol)
                        .font(.system(size: 13.5, weight: .medium))
                    Text(p.label).font(.system(size: 11.5, weight: on ? .medium : .regular))
                }
                .foregroundStyle(on ? Theme.primary : Theme.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(on ? Theme.raised : .clear)
                        .shadow(color: on ? .black.opacity(0.08) : .clear, radius: 3, y: 1)
                )
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.fill))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: current)
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
    @State private var text = ""
    @State private var sent = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
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
                HStack(spacing: 8) {
                    HStack {
                        TextField("Reply to keep going…", text: $text)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.primary)
                            .focused($focused)
                            .onSubmit(send)
                            .disabled(sent)
                        if sent { Text("Sent").font(.system(size: 12)).foregroundStyle(Theme.tertiary) }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Capsule().fill(Theme.fill))

                    Button(action: send) {
                        ZStack {
                            if case .reply(let deadline) = reply.kind, !sent, text.isEmpty {
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    let total = max(1, deadline.timeIntervalSince(reply.createdAt))
                                    let left = max(0, deadline.timeIntervalSinceNow)
                                    Circle().trim(from: 0, to: left / total)
                                        .stroke(Theme.onAction.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                        .padding(4)
                                        .animation(.linear(duration: 1), value: left)
                                }
                            }
                            Image(systemName: sent ? "checkmark" : "arrow.up").font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(Theme.onAction)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.action))
                    }
                    .buttonStyle(.plain)
                }
                .onChange(of: text) { _, t in reply.hold = !t.isEmpty || focused }
                .onChange(of: focused) { _, f in reply.hold = f || !text.isEmpty }
            }
        }
        .padding(20)
    }

    private func send() {
        guard let reply, !sent, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        sent = true
        AgentStore.shared.reply(reply, text: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { IslandModel.shared.collapse() }
    }
}
