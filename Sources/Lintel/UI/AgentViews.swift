import SwiftUI

// MARK: - Collapsed pill

struct AgentPill: View {
    @Environment(AgentStore.self) private var store
    var height: CGFloat

    var body: some View {
        let waiting = store.pending.first { $0.isBlocking }.flatMap { store.existing($0.sessionID) }
            ?? store.needsYou.first
        let busy = store.working.max { $0.lastEventAt < $1.lastEventAt }

        HStack(spacing: 8) {
            if let s = waiting {
                Mascot(color: s.tint, mood: .worried, size: height * 0.62)
                Text("Needs you").font(.system(size: 13, weight: .semibold))
                Text(s.displayTitle).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                RingSpinner(color: NSColor(Theme.red), lineWidth: 2.5, spinning: false, progress: 1)
                    .frame(width: height * 0.5, height: height * 0.5)
            } else if let s = busy {
                Mascot(color: s.tint, mood: .working, size: height * 0.62)
                Text(s.phase.label).font(.system(size: 13, weight: .semibold))
                    .contentTransition(.opacity)
                Text(s.displayTitle).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                if store.working.count > 1 {
                    Text("+\(store.working.count - 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
                }
                RingSpinner(color: NSColor(s.tint), lineWidth: 2.5)
                    .frame(width: height * 0.5, height: height * 0.5)
            } else if let first = store.sessions.first {
                Mascot(color: first.tint, mood: first.mood, size: height * 0.62)
                HStack(spacing: 4) {
                    ForEach(store.sessions.prefix(9)) { s in
                        Circle().fill(s.statusColor).frame(width: 6, height: 6)
                    }
                }
            } else {
                Mascot(color: .gray, mood: .sleeping, size: height * 0.62)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(PillBackground())
        .contentShape(Capsule())
        .onTapGesture { IslandModel.shared.toggle(.agents) }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: waiting?.id)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: busy?.id)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.sessions.count)
    }
}

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
        VStack(spacing: 2) {
            ForEach(Array(store.sessions.enumerated()), id: \.element.id) { i, s in
                SessionRow(session: s, index: i + 1)
            }
        }
        .padding(8)
    }
}

struct SessionRow: View {
    let session: AgentSession
    let index: Int

    private var subtitle: String {
        switch session.status {
        case .waiting: "Waiting on you · \(session.project)"
        case .working: "\(session.phase.label) · \(session.project)"
        case .finished: "Finished · \(session.project)"
        case .idle: session.project
        }
    }

    var body: some View {
        Button {
            IslandModel.shared.selectedSessionID = session.id
        } label: {
            HStack(spacing: 12) {
                Mascot(color: session.tint, mood: session.mood, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if session.kind == .codex {
                    Text("codex").font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                }
                if index <= 9 {
                    Text("⌘ \(index)").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Theme.tertiary)
                }
                Circle().fill(session.statusColor).frame(width: 9, height: 9)
                    .shadow(color: session.status == .working ? session.statusColor.opacity(0.8) : .clear, radius: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
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
    @State private var installed = ClaudeHooks.isInstalled

    var body: some View {
        VStack(spacing: 10) {
            Mascot(color: .gray, mood: .sleeping, size: 30)
            Text("No agents running").font(.system(size: 15, weight: .medium))
            if installed {
                Text("Start Claude Code or Codex and it will show up here.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            } else {
                Text("Connect Claude Code so sessions, prompts and questions appear in the notch.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                Button("Connect Claude Code") {
                    try? ClaudeHooks.install()
                    installed = ClaudeHooks.isInstalled
                }
                .buttonStyle(CapsuleButtonStyle(kind: .primary, height: 32))
                .frame(width: 200)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 30)
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
                Mascot(color: session.tint, mood: session.mood, size: 18)
                Text(session.displayTitle).font(.system(size: 15.5, weight: .semibold)).lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    Text(session.project)
                    if let b = session.branch {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                        Text(b).lineLimit(1)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 190, alignment: .trailing)
            }

            PhaseStrip(current: session.phase, active: session.status == .working || session.status == .finished,
                       done: session.status == .finished)

            if let notice = session.notice {
                Text(notice).font(.system(size: 12.5)).foregroundStyle(Theme.amber).lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.tools.isEmpty ? "No tool calls yet" : "Tool calls")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondary)
                    .padding(.bottom, 4)
                ForEach(session.tools.prefix(4)) { t in
                    HStack(spacing: 10) {
                        Image(systemName: Phase.forTool(t.name, detail: t.detail).symbol)
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 18)
                        Text(t.name).font(.system(size: 14))
                        Text(t.detail).font(Theme.mono).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text("×\(t.count)").font(.system(size: 12.5, design: .rounded)).foregroundStyle(Theme.tertiary)
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
                .buttonStyle(CapsuleButtonStyle(kind: .secondary, height: 32))
        }
        .padding(20)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 14.5, weight: .medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PhaseStrip: View {
    let current: Phase
    let active: Bool
    let done: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Phase.allCases, id: \.self) { p in
                let on = active && p == current
                VStack(spacing: 6) {
                    Image(systemName: p == .reviewing && done ? "checkmark.circle.fill" : p.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                    Text(p.label).font(.system(size: 12))
                    Capsule().fill(on ? Color.white.opacity(0.7) : .clear).frame(width: 22, height: 2.5)
                }
                .foregroundStyle(on ? Color.white : Theme.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(on ? Color.white.opacity(0.08) : .clear))
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.04)))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: current)
    }
}

// MARK: - Needs you

struct AttentionView: View {
    let request: PendingRequest
    let session: AgentSession
    let queued: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(Theme.red).frame(width: 9, height: 9)
                    .shadow(color: Theme.red.opacity(0.8), radius: 4)
                Text(headline).font(.system(size: 15.5, weight: .medium))
                Spacer()
                if queued > 0 {
                    Text("+\(queued) more").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(Int(Date().timeIntervalSince(request.createdAt)))s")
                        .font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.secondary).monospacedDigit()
                }
            }
            HStack(spacing: 8) {
                Mascot(color: session.tint, mood: .worried, size: 14)
                Text(session.displayTitle).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
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
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        )
        .padding(12)
    }

    private var headline: String {
        switch request.kind {
        case .permission: "Needs your go-ahead"
        case .question(let qs): qs.count > 1 ? "\(qs.count) questions for you" : "A question for you"
        case .external: session.kind == .codex ? "Codex needs you" : "Needs you in the terminal"
        case .reply: ""
        }
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
                Text(tool).font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
                Text(session.project).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                if !description.isEmpty {
                    Text("· \(description)").font(.system(size: 12.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
            }
            if !detail.isEmpty {
                ScrollView {
                    Text(detail).font(.system(size: 13.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.45))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline)))
            }
            HStack(spacing: 10) {
                Button("Allow") { AgentStore.shared.allow(request) }
                    .buttonStyle(CapsuleButtonStyle(kind: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Deny") { AgentStore.shared.deny(request) }
                    .buttonStyle(CapsuleButtonStyle(kind: .secondary))
            }
            HStack(spacing: 4) {
                if canAlways {
                    Button("Always allow") { AgentStore.shared.allow(request, always: true) }
                        .buttonStyle(CapsuleButtonStyle(kind: .quiet, height: 24))
                }
                Spacer()
                Button("Answer in terminal") { AgentStore.shared.deferToTerminal(request) }
                    .buttonStyle(CapsuleButtonStyle(kind: .quiet, height: 24))
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
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(questions) { q in
                        VStack(alignment: .leading, spacing: 6) {
                            if !q.header.isEmpty {
                                Text(q.header.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                            }
                            Text(q.question).font(.system(size: 14.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            ForEach(q.options, id: \.label) { o in
                                optionRow(q, o)
                            }
                            TextField("Something else…", text: Binding(
                                get: { other[q.question] ?? "" },
                                set: { other[q.question] = $0; if !$0.isEmpty && !q.multiSelect { picks[q.question] = [] } }))
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Submit") { submit() }
                    .buttonStyle(CapsuleButtonStyle(kind: .primary))
                    .disabled(!complete)
                    .opacity(complete ? 1 : 0.4)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Terminal") { AgentStore.shared.deferToTerminal(request) }
                    .buttonStyle(CapsuleButtonStyle(kind: .secondary))
                    .frame(width: 120)
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
                    .foregroundStyle(selected ? Color.white : Theme.tertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.label).font(.system(size: 13.5, weight: .medium))
                    if !o.description.isEmpty {
                        Text(o.description).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(selected ? 0.1 : 0.03)))
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
            if !message.isEmpty {
                Text(message).font(.system(size: 13.5, design: session.kind == .codex ? .monospaced : .default))
                    .lineLimit(5)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.45)))
            }
            HStack(spacing: 10) {
                Button(session.kind == .codex ? "Open Codex" : "Open terminal") {
                    AgentStore.shared.reveal(session)
                    AgentStore.shared.discard(request)
                    IslandModel.shared.collapse()
                }
                .buttonStyle(CapsuleButtonStyle(kind: .primary))
                Button("Dismiss") { AgentStore.shared.discard(request) }
                    .buttonStyle(CapsuleButtonStyle(kind: .secondary))
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
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17))
                    .symbolRenderingMode(.palette).foregroundStyle(Color.black, Theme.green)
                Text("Finished").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(relativeTime(session.turnEndedAt ?? Date())).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 8) {
                Mascot(color: session.tint, mood: .happy, size: 15)
                Text(session.displayTitle).font(.system(size: 14.5, weight: .medium)).lineLimit(1)
                if let b = session.branch {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                    Text(b).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            if !session.lastMessage.isEmpty {
                Text(session.lastMessage.prefix(600))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Theme.hairline)
            HStack(spacing: 14) {
                if session.tokens > 0 { Text("\(formatTokens(session.tokens)) tokens") }
                Text("\(session.turnToolCalls) tool calls")
                if let d = session.turnDuration { Text(formatDuration(d)) }
                Spacer()
                Button("Open") { AgentStore.shared.reveal(session); IslandModel.shared.collapse() }
                    .buttonStyle(CapsuleButtonStyle(kind: .quiet, height: 22))
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)

            if let reply {
                HStack(spacing: 10) {
                    HStack {
                        TextField("Reply to keep going…", text: $text)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .focused($focused)
                            .onSubmit(send)
                            .disabled(sent)
                        if sent { Text("Sent").font(.system(size: 12.5)).foregroundStyle(Theme.secondary) }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .background(Capsule().fill(Color.white.opacity(0.06)).overlay(Capsule().strokeBorder(Color.white.opacity(0.1))))

                    Button(action: send) {
                        ZStack {
                            if case .reply(let deadline) = reply.kind, !sent, text.isEmpty {
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    let total = max(1, deadline.timeIntervalSince(reply.createdAt))
                                    let left = max(0, deadline.timeIntervalSinceNow)
                                    Circle().trim(from: 0, to: left / total)
                                        .stroke(Color.black.opacity(0.25), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                        .padding(5)
                                        .animation(.linear(duration: 1), value: left)
                                }
                            }
                            Image(systemName: sent ? "checkmark" : "arrow.up").font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.white))
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
