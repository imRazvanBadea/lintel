import AppKit
import Observation

@MainActor @Observable
final class AgentStore {
    static let shared = AgentStore()
    static let paletteCount = 9

    private(set) var sessions: [AgentSession] = []
    private(set) var pending: [PendingRequest] = []

    @ObservationIgnored var onAttention: (() -> Void)?
    /// Development hooks (snapshot / expand), token-protected like everything else.
    @ObservationIgnored var debugHandler: ((String, HookServer.Responder) -> Void)?
    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private var codex: CodexWatcher?
    @ObservationIgnored private var sweepTimer: Timer?

    var hasPendingRequests: Bool { pending.contains { $0.isBlocking } }
    var needsYou: [AgentSession] { sessions.filter { $0.status == .waiting } }
    var working: [AgentSession] { sessions.filter { $0.status == .working } }

    func start() {
        if ClaudeHooks.isInstalled { try? ClaudeHooks.writeScript() } // keep the bridge script current
        let token = ClaudeHooks.token()
        server = HookServer(token: token) { [weak self] req, responder in
            MainActor.assumeIsolated { self?.handle(req, responder) }
        }
        server?.start()
        updateCodex()
        Settings.shared.onCodexChange = { [weak self] in self?.updateCodex() }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    private func updateCodex() {
        if Settings.shared.codexEnabled {
            if codex == nil { codex = CodexWatcher(store: self); codex?.start() }
        } else {
            codex?.stop()
            codex = nil
            sessions.removeAll { $0.kind == .codex }
        }
    }

    // MARK: Sessions

    func session(id: String, kind: AgentKind) -> AgentSession {
        if let s = sessions.first(where: { $0.id == id }) { return s }
        let used = Set(sessions.map(\.colorIndex))
        let color = (0..<Self.paletteCount).first { !used.contains($0) } ?? sessions.count % Self.paletteCount
        let s = AgentSession(id: id, kind: kind, colorIndex: color)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { sessions.append(s) }
        return s
    }

    func existing(_ id: String) -> AgentSession? { sessions.first { $0.id == id } }

    func remove(_ id: String) {
        for p in pending where p.sessionID == id { p.resolve("") }
        pending.removeAll { $0.sessionID == id }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { sessions.removeAll { $0.id == id } }
    }

    /// Drops sessions whose process went away, and quiets stale ones.
    private func sweep() {
        let now = Date()
        for s in sessions {
            if s.kind == .claude, let pid = s.agentPID, !Proc.isAlive(pid) { remove(s.id); continue }
            let quiet = now.timeIntervalSince(s.lastEventAt)
            if s.status == .finished && quiet > 15 * 60 && !pending.contains(where: { $0.sessionID == s.id }) { s.status = .idle }
            if s.kind == .claude && s.agentPID == nil && quiet > 3 * 3600 { remove(s.id) }
        }
        // Resolve quick-reply windows that ran out.
        for p in pending {
            if case .reply(let deadline) = p.kind, deadline < now, !p.hold { resolve(p, with: "") }
        }
    }

    // MARK: Pending requests

    func add(_ p: PendingRequest) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { pending.append(p) }
        if p.isBlocking {
            if Settings.shared.playSounds { NSSound(named: "Tink")?.play() }
            onAttention?()
        }
    }

    func resolve(_ p: PendingRequest, with payload: String) {
        guard pending.contains(where: { $0.id == p.id }) else { return }
        p.resolve(payload)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { pending.removeAll { $0.id == p.id } }
        if let s = existing(p.sessionID), s.status == .waiting, !pending.contains(where: { $0.sessionID == s.id && $0.isBlocking }) {
            s.status = .working
        }
        if pending.isEmpty, IslandModel.shared.pinnedByEvent { IslandModel.shared.collapse() }
    }

    /// Drop a request without answering it (the agent moved on by itself).
    func discard(_ p: PendingRequest) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { pending.removeAll { $0.id == p.id } }
        if let s = existing(p.sessionID), s.status == .waiting, !pending.contains(where: { $0.sessionID == s.id && $0.isBlocking }) {
            s.status = .working
        }
    }

    func pendingFor(_ s: AgentSession) -> [PendingRequest] { pending.filter { $0.sessionID == s.id } }

    // MARK: Focus

    /// Brings the terminal / editor / desktop app that hosts the session to the front.
    func reveal(_ s: AgentSession) {
        if s.kind == .codex {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first {
                app.activate()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
            return
        }
        if let pid = s.agentPID ?? s.hookPPID, let app = Proc.hostingApp(of: pid) {
            app.activate()
            return
        }
        let bundle: String? = switch s.termProgram {
        case "Apple_Terminal": "com.apple.Terminal"
        case "iTerm.app": "com.googlecode.iterm2"
        case "vscode": "com.microsoft.VSCode"
        case "ghostty": "com.mitchellh.ghostty"
        case "WarpTerminal": "dev.warp.Warp-Stable"
        default: nil
        }
        if let bundle, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { app.activate() }
    }

    // MARK: Claude Code hook events

    private func handle(_ req: HookServer.Request, _ responder: HookServer.Responder) {
        let parts = req.path.split(separator: "/")
        if parts.count == 2, parts[0] == "debug" { debugHandler?(String(parts[1]), responder); return }
        guard parts.count == 2, parts[0] == "claude" else { responder.respond(""); return }
        guard let json = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any],
              let sid = json["session_id"] as? String else { responder.respond(""); return }
        let event = String(parts[1])

        if event == "SessionEnd" {
            remove(sid)
            responder.respond("")
            return
        }

        let s = session(id: sid, kind: .claude)
        s.lastEventAt = Date()
        if let cwd = json["cwd"] as? String, cwd != s.cwd { s.cwd = cwd; s.refreshBranch() }
        if let t = json["transcript_path"] as? String { s.transcriptPath = t }
        if let term = req.headers["x-lintel-term"], !term.isEmpty { s.termProgram = term }
        if let pp = req.headers["x-lintel-ppid"].flatMap({ pid_t($0) }) {
            s.hookPPID = pp
            if s.agentPID == nil { s.agentPID = Proc.agentProcess(from: pp) }
        }
        if let m = json["model"] as? String, !m.isEmpty { s.model = shortModelName(m) }

        switch event {
        case "SessionStart":
            if s.status != .working { s.status = .idle }
            readTranscript(s)
            responder.respond("")

        case "UserPromptSubmit":
            // A new prompt means any open quick-reply window is moot.
            for p in pendingFor(s) { if case .reply = p.kind { resolve(p, with: "") } }
            s.beginTurn(prompt: json["prompt"] as? String)
            if s.title.isEmpty { readTranscript(s) }
            responder.respond("")

        case "PreToolUse":
            s.status = pending.contains(where: { $0.sessionID == sid && $0.isBlocking }) ? .waiting : .working
            if s.turnStartedAt == nil { s.beginTurn(prompt: nil) }
            let tool = json["tool_name"] as? String ?? "Tool"
            let input = json["tool_input"] as? [String: Any] ?? [:]
            if tool != "AskUserQuestion" { s.recordTool(tool, detail: Self.detail(tool: tool, input: input)) }
            responder.respond("")

        case "PostToolUse":
            // If the tool ran, any prompt for it was settled elsewhere (e.g. in the terminal).
            for p in pendingFor(s) where p.isBlocking {
                if case .external = p.kind { discard(p) }
            }
            if !pending.contains(where: { $0.sessionID == sid && $0.isBlocking }) { s.status = .working }
            responder.respond("")

        case "Notification":
            let message = json["message"] as? String ?? ""
            let type = json["notification_type"] as? String ?? ""
            if type == "permission_prompt" || message.localizedCaseInsensitiveContains("permission") {
                // Only surface if we don't already hold this prompt ourselves.
                if !pending.contains(where: { $0.sessionID == sid && $0.isBlocking }) {
                    s.status = .waiting
                    add(PendingRequest(sessionID: sid, kind: .external(message: message)) { _ in })
                }
            } else if type == "idle_prompt" {
                if s.status == .working { s.status = .finished }
            } else if !message.isEmpty {
                s.notice = message
            }
            responder.respond("")

        case "PermissionRequest":
            handlePermission(s, json: json, responder: responder)

        case "Stop":
            for p in pendingFor(s) where p.isBlocking { if case .external = p.kind { discard(p) } }
            s.endTurn(message: json["last_assistant_message"] as? String)
            readTranscript(s)
            let secs = Settings.shared.quickReplySeconds
            let blockedByStopHook = (json["stop_hook_active"] as? Bool) == true
            if secs > 0 && !blockedByStopHook {
                let p = PendingRequest(sessionID: sid, kind: .reply(deadline: Date().addingTimeInterval(Double(secs)))) { payload in
                    responder.respond(payload)
                }
                responder.onClose = { [weak self] in MainActor.assumeIsolated { self?.discard(p) } }
                add(p)
                scheduleReplyTimeout(p, after: Double(secs))
            } else {
                responder.respond("")
            }
            announceFinished(s)

        default:
            responder.respond("")
        }
    }

    private func scheduleReplyTimeout(_ p: PendingRequest, after secs: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            guard let self, self.pending.contains(where: { $0.id == p.id }) else { return }
            if p.hold { self.scheduleReplyTimeout(p, after: 3) } else { self.resolve(p, with: "") }
        }
    }

    /// Brief "Finished" toast: open the agents island on this session for a few seconds.
    var finishedFlash: String?
    func announceFinished(_ s: AgentSession) {
        if Settings.shared.playSounds { NSSound(named: "Glass")?.play() }
        let model = IslandModel.shared
        guard model.expanded == nil || model.expanded == .agents, !hasPendingRequests else { return }
        finishedFlash = s.id
        model.expand(.agents, pinned: true)
        model.selectedSessionID = nil
        let id = s.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.finishedFlash == id else { return }
            self.finishedFlash = nil
            // Only close it if you didn't start interacting with it.
            if model.pinnedByEvent && !self.hasPendingRequests && !self.pending.contains(where: { $0.sessionID == id }) {
                model.collapse()
            }
        }
    }

    private func handlePermission(_ s: AgentSession, json: [String: Any], responder: HookServer.Responder) {
        let tool = json["tool_name"] as? String ?? "Tool"
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let suggestions = json["permission_suggestions"] as? [Any] ?? []

        let kind: PendingRequest.Kind
        if tool == "AskUserQuestion", let qs = input["questions"] as? [[String: Any]] {
            kind = .question(qs.map { q in
                QuestionSpec(question: q["question"] as? String ?? "",
                             header: q["header"] as? String ?? "",
                             options: (q["options"] as? [[String: Any]] ?? []).map {
                                 .init(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "")
                             },
                             multiSelect: q["multiSelect"] as? Bool ?? false)
            })
        } else {
            kind = .permission(tool: tool, detail: Self.detail(tool: tool, input: input),
                               description: input["description"] as? String ?? "",
                               canAlwaysAllow: !suggestions.isEmpty)
        }

        let p = PendingRequest(sessionID: s.id, kind: kind) { payload in
            responder.respond(payload)
        }
        p.toolInput = input
        p.suggestions = suggestions
        responder.onClose = { [weak self] in MainActor.assumeIsolated { self?.discard(p) } }
        s.status = .waiting
        add(p)

        let timeout = Settings.shared.permissionTimeout
        if timeout > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout)) { [weak self] in
                self?.resolve(p, with: "") // hand it back to the terminal
            }
        }
    }

    // MARK: Answers

    func allow(_ p: PendingRequest, always: Bool = false) {
        var decision: [String: Any] = ["behavior": "allow"]
        if always, !p.suggestions.isEmpty { decision["updatedPermissions"] = p.suggestions }
        resolve(p, with: Self.permissionPayload(decision))
    }

    func deny(_ p: PendingRequest) {
        resolve(p, with: Self.permissionPayload(["behavior": "deny", "message": "Denied from Lintel."]))
    }

    func answer(_ p: PendingRequest, answers: [String: String]) {
        var input = p.toolInput
        input["answers"] = answers
        resolve(p, with: Self.permissionPayload(["behavior": "allow", "updatedInput": input]))
    }

    func reply(_ p: PendingRequest, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let payload = (try? JSONSerialization.data(withJSONObject: ["decision": "block", "reason": t]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if let s = existing(p.sessionID) { s.beginTurn(prompt: t) }
        resolve(p, with: payload)
    }

    /// Answer in the terminal instead.
    func deferToTerminal(_ p: PendingRequest) {
        resolve(p, with: "")
        if let s = existing(p.sessionID) { reveal(s) }
    }

    private static func permissionPayload(_ decision: [String: Any]) -> String {
        let obj: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // MARK: Helpers

    static func detail(tool: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "notebook_path", "url", "pattern", "query", "path", "prompt", "description"] {
            if let v = input[key] as? String, !v.isEmpty {
                if key.hasSuffix("path") || key == "path" { return (v as NSString).lastPathComponent }
                return v.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return ""
    }

    /// Pulls title, model, context size and last reply from the tail of the transcript.
    private func readTranscript(_ s: AgentSession) {
        guard let path = s.transcriptPath else { return }
        let id = s.id
        DispatchQueue.global(qos: .utility).async {
            let r = TranscriptTail.read(path: path)
            DispatchQueue.main.async {
                guard let s = AgentStore.shared.existing(id) else { return }
                if let t = r.title { s.title = t }
                if let m = r.model { s.model = shortModelName(m) }
                if let n = r.tokens { s.tokens = n }
                if s.lastMessage.isEmpty || s.status == .finished, let msg = r.lastText { s.lastMessage = msg }
            }
        }
    }
}

enum TranscriptTail {
    struct Result { var title: String?; var model: String?; var tokens: Int?; var lastText: String? }

    static func read(path: String, maxBytes: Int = 512 * 1024) -> Result {
        var r = Result()
        guard let fh = FileHandle(forReadingAtPath: path) else { return r }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return r }
        for line in text.split(separator: "\n").reversed() {
            guard let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch d["type"] as? String {
            case "custom-title" where r.title == nil: r.title = d["customTitle"] as? String
            case "agent-name" where r.title == nil: r.title = d["agentName"] as? String
            case "summary" where r.title == nil: r.title = d["summary"] as? String
            case "assistant":
                guard let msg = d["message"] as? [String: Any] else { break }
                if r.model == nil, let m = msg["model"] as? String, !m.hasPrefix("<") { r.model = m }
                if r.tokens == nil, let u = msg["usage"] as? [String: Any] {
                    let keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"]
                    r.tokens = keys.reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
                }
                if r.lastText == nil, let content = msg["content"] as? [[String: Any]] {
                    let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    if let t = texts.last, !t.isEmpty { r.lastText = t }
                }
            default: break
            }
            if r.title != nil && r.model != nil && r.tokens != nil && r.lastText != nil { break }
        }
        return r
    }
}

import SwiftUI
