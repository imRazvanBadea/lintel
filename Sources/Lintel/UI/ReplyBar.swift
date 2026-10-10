import SwiftUI

/// "Reply to keep going…" under a finished turn the agent is still holding open: the reply continues that same
/// session in place (in the Claude, Codex or Cursor app, or the terminal). The ring on the send button is the time left.
/// What you type is kept per session, so closing the card doesn't lose it.
struct ReplyBar: View {
    @Environment(IslandModel.self) private var model
    let session: AgentSession
    let request: PendingRequest
    /// Called after the reply went in.
    var onSent: () -> Void = {}

    @State private var sent = false
    @FocusState private var focused: Bool

    private var text: Binding<String> {
        Binding(get: { model.replyDrafts[session.id] ?? "" }, set: { model.replyDrafts[session.id] = $0 })
    }
    private var images: Binding<[URL]> {
        Binding(get: { model.replyImages[session.id] ?? [] }, set: { model.replyImages[session.id] = $0 })
    }
    private var hasDraft: Bool {
        !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.wrappedValue.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AttachmentStrip(images: images).padding(.leading, 4)
            HStack(spacing: 8) {
                HStack(alignment: .bottom) {
                    TextField("Reply to keep going…", text: text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1...5)
                        .focused($focused)
                        .onSubmit(send)
                        .disabled(sent)
                        .padding(.vertical, 3)
                        .frame(minHeight: 24)
                    if sent {
                        Text("Sent").font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(.vertical, 4)
                    } else {
                        AttachButton(images: images, size: 24)
                    }
                }
                // The text keeps its inset on the left; the 📎 sits the same 8pt from the right, top and bottom.
                .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
                .frame(minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.fill))
                .acceptsImages(images)

                Button(action: send) {
                    ZStack {
                        if case .reply(let deadline) = request.kind, !sent, !hasDraft {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                let total = max(1, deadline.timeIntervalSince(request.createdAt))
                                let left = max(0, deadline.timeIntervalSinceNow)
                                Circle().trim(from: 0, to: left / total)
                                    .stroke(Theme.onAction.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .padding(4)
                                    .animation(.linear(duration: 1), value: left)
                            }
                        }
                        Image(systemName: sent ? "checkmark" : "arrow.up").font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(Theme.onAction)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.action))
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            model.visibleReply = session.id
            update()
        }
        .onChange(of: text.wrappedValue) { update() }
        .onChange(of: images.wrappedValue) { update() }
        .onChange(of: focused) { update() }
        .onDisappear {
            if model.visibleReply == session.id { model.visibleReply = nil }
            model.editing = false
            // Closed mid-reply: keep the turn open a minute so you can come back and send it.
            guard hasDraft else { request.hold = false; return }
            let id = session.id, request = request
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                if IslandModel.shared.visibleReply != id { request.hold = false }
            }
        }
    }

    /// While you're writing, the turn stays open past its countdown and hovering away doesn't close the card.
    private func update() {
        let writing = focused || hasDraft
        request.hold = writing
        model.editing = writing
    }

    private func send() {
        guard !sent, hasDraft else { return }
        let message = Attachments.message(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines), images.wrappedValue)
        sent = true
        model.replyDrafts[session.id] = nil
        model.replyImages[session.id] = nil
        model.editing = false
        AgentStore.shared.reply(request, text: message)
        onSent()
    }
}
