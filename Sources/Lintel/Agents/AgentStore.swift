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
        // Keep the bridge script (and hook entries from older versions) current.
        for t in AgentHooks.Target.allCases {
            if let s = try? String(contentsOf: t.configURL, encoding: .utf8), s.contains(AgentHooks.marker) { try? AgentHooks.install(t) }
        }
        try? FileManager.default.removeItem(at: AgentHooks.dir.appendingPathComponent("claude-hook.sh")) // pre-1.1 script
        let token = AgentHooks.token()
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
        // Hand anything still open back to the agent's own UI (for Cursor, "ask" — never an implicit allow).
        for p in pending where p.sessionID == id { p.resolve(p.deferPayload) }
        pending.removeAll { $0.sessionID == id }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { sessions.removeAll { $0.id == id } }
    }

    /// How long a session stays in the list after its last activity (finished ones included).
    static let keepAlive: TimeInterval = 60 * 60

    /// Hides sessions that have had no news for an hour.
    private func sweep() {
        let now = Date()
        for s in sessions where now.timeIntervalSince(s.lastEventAt) > Self.keepAlive {
            if !pending.contains(where: { $0.sessionID == s.id && $0.isBlocking }) { remove(s.id) }
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
        p.resolve(payload.isEmpty ? p.deferPayload : payload)
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

    /// Takes you to the session itself: the exact Claude app chat, Codex thread or terminal tab when possible,
    /// otherwise the app that hosts it.
    func reveal(_ s: AgentSession) {
        switch s.kind {
        case .codex:
            if let url = URL(string: "codex://threads/\(s.id)") { NSWorkspace.shared.open(url) }
            return
        case .cursor:
            NowPlaying.activate(bundleID: Self.cursorBundleID)
            return
        case .claude:
            break
        }
        let pid = s.agentPID ?? s.hookPPID
        let host = pid.flatMap { Proc.hostingApp(of: $0) }
        // A session in the Claude app: open that very chat.
        if host?.bundleIdentifier == "com.anthropic.claudefordesktop" || host == nil {
            let id = s.id
            TitleResolver.shared.claudeDesktopSessionID(for: id) { local in
                DispatchQueue.main.async {
                    if let local, let url = URL(string: "claude://code/continue?session=\(local)&source=spotlight") {
                        NSWorkspace.shared.open(url)
                    } else {
                        AgentStore.shared.focusTerminal(s, host: host)
                    }
                }
            }
            return
        }
        focusTerminal(s, host: host)
    }

    /// Terminal / iTerm: select the tab running the session (matched by its tty). Others: bring the app forward.
    fileprivate func focusTerminal(_ s: AgentSession, host: NSRunningApplication?) {
        let bundle = host?.bundleIdentifier ?? Self.bundleForTerm(s.termProgram)
        if let pid = s.agentPID, let tty = Proc.tty(of: pid), let bundle {
            let script: String?
            switch bundle {
            case "com.apple.Terminal":
                script = """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected tab of w to t
                                set index of w to 1
                            end if
                        end repeat
                    end repeat
                    activate
                end tell
                """
            case "com.googlecode.iterm2":
                script = """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with ss in sessions of t
                                if tty of ss is "\(tty)" then
                                    select w
                                    tell t to select
                                    tell ss to select
                                end if
                            end repeat
                        end repeat
                    end repeat
                    activate
                end tell
                """
            default:
                script = nil
            }
            if let script {
                ScriptRunner.shared.run(script) { _ in }
                return
            }
        }
        if let bundle { NowPlaying.activate(bundleID: bundle) } else { host?.activate() }
    }

    private static func bundleForTerm(_ term: String) -> String? {
        switch term {
        case "Apple_Terminal": "com.apple.Terminal"
        case "iTerm.app": "com.googlecode.iterm2"
        case "vscode": "com.microsoft.VSCode"
        case "ghostty": "com.mitchellh.ghostty"
        case "WarpTerminal": "dev.warp.Warp-Stable"
        default: nil
        }
    }

    // MARK: Claude Code hook events

    private func handle(_ req: HookServer.Request, _ responder: HookServer.Responder) {
        let parts = req.path.split(separator: "/")
        if parts.count == 2, parts[0] == "debug" { debugHandler?(String(parts[1]), responder); return }
        if Date() < demoUntil { responder.respond(parts.first == "cursor" ? "{}" : ""); return }
        if parts.count == 2, parts[0] == "cursor" { handleCursor(String(parts[1]), req, responder); return }
        guard parts.count == 2, parts[0] == "claude" else { responder.respond(""); return }
        guard let json = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any],
              let sid = json["session_id"] as? String else { responder.respond(""); return }
        let event = String(parts[1])

        // Lintel's own usage check runs Claude Code in ~/.lintel — never show it as an agent.
        if let cwd = json["cwd"] as? String, cwd.hasPrefix(AgentHooks.dir.path) { responder.respond(""); return }

        // Status line refreshes carry plan usage; they say nothing about activity, so stop here.
        if event == "StatusLine" {
            UsageStore.shared.applyClaudeStatusLine(json)
            responder.respond("")
            return
        }

        if event == "SessionEnd" {
            remove(sid)
            responder.respond("")
            return
        }

        // Cursor's agent also runs hooks from ~/.claude/settings.json. Recognise it by the process tree.
        let ppid = req.headers["x-lintel-ppid"].flatMap { pid_t($0) }
        let kind = json["cursor_version"] != nil ? .cursor : originKind(sid: sid, ppid: ppid)
        if kind == .cursor && AgentHooks.isInstalled(.cursor) {
            responder.respond("") // Cursor's own hooks already report this conversation
            return
        }

        let s = session(id: sid, kind: kind)
        s.lastEventAt = Date()
        // Cursor reports the workspace in workspace_roots; its cwd can be an internal directory.
        let cwd = (json["workspace_roots"] as? [String])?.first ?? json["cwd"] as? String
        if let cwd, !cwd.isEmpty, cwd != s.cwd { s.cwd = cwd; s.refreshBranch() }
        if let t = json["transcript_path"] as? String { s.transcriptPath = t }
        if let term = req.headers["x-lintel-term"], !term.isEmpty { s.termProgram = term }
        if let pp = req.headers["x-lintel-ppid"].flatMap({ pid_t($0) }) {
            s.hookPPID = pp
            if s.agentPID == nil { s.agentPID = Proc.agentProcess(from: pp) }
        }
        if let m = json["model"] as? String, !m.isEmpty { s.model = shortModelName(m) }
        if s.generatedTitle == nil { refreshTitle(s) } // throttled; covers sessions that began before Lintel did
        if ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "PermissionRequest"].contains(event) {
            // The transcript is written just after the hook fires; read a beat later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refreshFeed(s) }
        }

        switch event {
        case "SessionStart":
            if s.status != .working { s.status = .idle }
            readTranscript(s)
            refreshTitle(s)
            responder.respond("")

        case "UserPromptSubmit":
            // A new prompt means any open quick-reply window is moot.
            for p in pendingFor(s) { if case .reply = p.kind { resolve(p, with: "") } }
            s.beginTurn(prompt: json["prompt"] as? String)
            if s.title.isEmpty { readTranscript(s) }
            refreshTitle(s)
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
            refreshTitle(s, force: true)
            UsageStore.shared.probeClaude(minInterval: 60)
            let secs = Settings.shared.quickReplySeconds
            let blockedByStopHook = (json["stop_hook_active"] as? Bool) == true
            if secs > 0 && !blockedByStopHook {
                let p = PendingRequest(sessionID: sid, kind: .reply(deadline: Date().addingTimeInterval(Double(secs)))) { payload in
                    responder.respond(payload)
                }
                p.agent = s.kind
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


    // MARK: Cursor hook events

    private func handleCursor(_ event: String, _ req: HookServer.Request, _ responder: HookServer.Responder) {
        guard let json = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any],
              let sid = (json["conversation_id"] as? String) ?? (json["session_id"] as? String) else { responder.respond("{}"); return }

        if event == "sessionEnd" {
            remove(sid)
            responder.respond("{}")
            return
        }

        let s = session(id: sid, kind: .cursor)
        s.lastEventAt = Date()
        let cwd = (json["cwd"] as? String) ?? (json["workspace_roots"] as? [String])?.first ?? (json["workspace_paths"] as? [String])?.first
        if let cwd, !cwd.isEmpty, cwd != s.cwd { s.cwd = cwd; s.refreshBranch() }
        if let pp = req.headers["x-lintel-ppid"].flatMap({ pid_t($0) }) { s.hookPPID = pp }
        if let m = (json["model"] as? String) ?? (json["model_id"] as? String), !m.isEmpty { s.model = shortModelName(m) }
        if s.generatedTitle == nil { refreshTitle(s) }

        switch event {
        case "sessionStart":
            if s.status != .working { s.status = .idle }
            responder.respond("{}")

        case "beforeSubmitPrompt":
            for p in pendingFor(s) { if case .reply = p.kind { resolve(p, with: "") } }
            s.beginTurn(prompt: json["prompt"] as? String)
            if let p = (json["prompt"] as? String).flatMap(FeedReader.cleanUserText) {
                s.upsertFeed(FeedItem(id: "u-\(json["generation_id"] as? String ?? UUID().uuidString)", kind: .user, text: p, date: Date()))
            }
            if s.title.isEmpty, let p = json["prompt"] as? String {
                s.title = String(p.split(separator: "\n").first ?? "").prefix(60).description
            }
            refreshTitle(s)
            responder.respond("{}")

        case "preToolUse":
            if s.turnStartedAt == nil || s.status != .working { s.beginTurnIfIdle() }
            let tool = json["tool_name"] as? String ?? "Tool"
            let input = json["tool_input"] as? [String: Any] ?? [:]
            s.recordTool(tool, detail: Self.detail(tool: tool, input: input))
            s.upsertFeed(FeedItem(id: "t-\(json["tool_use_id"] as? String ?? UUID().uuidString)", kind: .tool,
                                  text: FeedReader.describe(tool: tool, input: input), tool: FeedReader.displayName(tool),
                                  status: .running, date: Date()))
            responder.respond("{}")

        case "postToolUse", "postToolUseFailure":
            let failed = event == "postToolUseFailure"
            if let tid = json["tool_use_id"] as? String, let i = s.feed.lastIndex(where: { $0.id == "t-\(tid)" }) {
                s.feed[i].status = failed ? .failed : .done
            } else {
                s.finishLatestTool(failed: failed)
            }
            responder.respond("{}")

        case "afterAgentThought":
            s.status = .working
            s.phase = .reasoning
            let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ms = (json["duration_ms"] as? NSNumber)?.doubleValue
            s.upsertFeed(FeedItem(id: "th-\(UUID().uuidString)", kind: .thinking, text: text, date: Date(),
                                  duration: ms.map { $0 / 1000 }))
            responder.respond("{}")

        case "afterAgentResponse":
            if let t = json["text"] as? String, !t.isEmpty {
                s.lastMessage = t
                s.upsertFeed(FeedItem(id: "a-\(json["generation_id"] as? String ?? UUID().uuidString)", kind: .assistant,
                                      text: t.trimmingCharacters(in: .whitespacesAndNewlines), date: Date()))
            }
            refreshTitle(s)
            let keys = ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"]
            let n = keys.reduce(0) { $0 + ((json[$1] as? NSNumber)?.intValue ?? 0) }
            if n > 0 { s.tokens = n }
            responder.respond("{}")

        case "beforeShellExecution":
            guard Settings.shared.cursorShellApprovals else { responder.respond("{}"); return }
            let command = json["command"] as? String ?? ""
            let p = PendingRequest(sessionID: sid, kind: .permission(tool: "Shell", detail: command, description: "", canAlwaysAllow: false)) { payload in
                responder.respond(payload)
            }
            p.agent = .cursor
            p.deferPayload = #"{"permission":"ask"}"#
            responder.onClose = { [weak self] in MainActor.assumeIsolated { self?.discard(p) } }
            s.status = .waiting
            add(p)
            let timeout = Settings.shared.permissionTimeout
            if timeout > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout)) { [weak self] in self?.resolve(p, with: "") }
            }

        case "stop":
            let status = json["status"] as? String ?? "completed"
            s.endTurn(message: nil)
            refreshTitle(s, force: true)
            if status != "completed" { s.status = .idle }
            let secs = Settings.shared.quickReplySeconds
            if secs > 0 && status == "completed" {
                let p = PendingRequest(sessionID: sid, kind: .reply(deadline: Date().addingTimeInterval(Double(secs)))) { payload in
                    responder.respond(payload)
                }
                p.agent = .cursor
                p.deferPayload = "{}"
                responder.onClose = { [weak self] in MainActor.assumeIsolated { self?.discard(p) } }
                add(p)
                scheduleReplyTimeout(p, after: Double(secs))
            } else {
                responder.respond("{}")
            }
            if status == "completed" { announceFinished(s) }

        default:
            responder.respond("{}")
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
        model.showingList = false
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
        p.agent = s.kind
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
        if p.agent == .cursor { resolve(p, with: #"{"permission":"allow"}"#); return }
        var decision: [String: Any] = ["behavior": "allow"]
        if always, !p.suggestions.isEmpty { decision["updatedPermissions"] = p.suggestions }
        resolve(p, with: Self.permissionPayload(decision))
    }

    func deny(_ p: PendingRequest) {
        if p.agent == .cursor { resolve(p, with: Self.json(["permission": "deny", "user_message": "Denied from Lintel."])); return }
        resolve(p, with: Self.permissionPayload(["behavior": "deny", "message": "Denied from Lintel."]))
    }

    func answer(_ p: PendingRequest, answers: [String: String]) {
        var input = p.toolInput
        input["answers"] = answers
        resolve(p, with: Self.permissionPayload(["behavior": "allow", "updatedInput": input]))
    }

    /// Continue a finished turn with a follow-up message.
    func reply(_ p: PendingRequest, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let payload = p.agent == .cursor ? Self.json(["followup_message": t])
                                         : Self.json(["decision": "block", "reason": t])
        if let s = existing(p.sessionID) { s.beginTurn(prompt: t) }
        resolve(p, with: payload)
    }

    private static func json(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
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

    // MARK: Demo (developer tool for README screenshots)

    @ObservationIgnored private var demoUntil = Date.distantPast

    /// Replaces the list with made-up sessions and ignores real hook events for a while.
    func showDemo(seconds: Double = 30) {
        demoUntil = Date().addingTimeInterval(seconds)
        for p in pending { p.resolve(p.deferPayload) }
        pending.removeAll()
        sessions.removeAll()
        func make(_ id: String, _ kind: AgentKind, _ title: String, _ cwd: String, _ status: AgentStatus, _ phase: Phase,
                  tools: [(String, String, Int)] = [], tokens: Int = 0, model: String = "") -> AgentSession {
            let s = session(id: id, kind: kind)
            s.generatedTitle = title
            s.cwd = cwd
            s.branch = "main"
            s.status = status
            s.phase = phase
            s.turnStartedAt = Date().addingTimeInterval(-112)
            s.tokens = tokens
            s.model = model
            for (n, d, c) in tools { for _ in 0..<c { s.recordTool(n, detail: d) } }
            s.phase = phase
            return s
        }
        _ = make("demo-1", .claude, "Fix flaky websocket reconnect", "/Users/you/api", .working, .reviewing,
                 tools: [("Read", "reconnect.test.ts", 5), ("Edit", "ws.ts", 12), ("Bash", "pnpm vitest run ws", 3)],
                 tokens: 48_000, model: "opus")
        _ = make("demo-2", .cursor, "Landing page hero polish", "/Users/you/web", .working, .writing,
                 tools: [("Write", "Hero.tsx", 4)], tokens: 21_000, model: "sonnet")
        if let s = existing("demo-1") {
            let now = Date()
            func at(_ secs: Double) -> Date { now.addingTimeInterval(-secs) }
            s.feed = [
                FeedItem(id: "f1", kind: .user, text: "The websocket drops every few minutes on flaky Wi-Fi. Can you make reconnect reliable and add a test?", date: at(110)),
                FeedItem(id: "f2", kind: .thinking, text: "", date: at(104), duration: 6),
                FeedItem(id: "f3", kind: .assistant, text: "I'll look at how the client reconnects today, then add backoff and a test that simulates drops.", date: at(100)),
                FeedItem(id: "f4", kind: .tool, text: "Reading ws.ts", tool: "Read", status: .done, date: at(96)),
                FeedItem(id: "f5", kind: .tool, text: "Searching for “reconnect”", tool: "Grep", status: .done, date: at(90)),
                FeedItem(id: "f6", kind: .assistant, text: "Found it: reconnect retries immediately in a loop, so it hammers the server while the network is down.", date: at(70)),
                FeedItem(id: "f7", kind: .tool, text: "Editing ws.ts", tool: "Edit", status: .done, date: at(52)),
                FeedItem(id: "f8", kind: .tool, text: "Writing reconnect.test.ts", tool: "Write", status: .done, date: at(30)),
                FeedItem(id: "f9", kind: .thinking, text: "", date: at(20), duration: 4),
                FeedItem(id: "f10", kind: .tool, text: "Run the websocket tests", tool: "Bash", status: .running, date: at(8)),
            ]
        }
        let done = make("demo-3", .claude, "Write the changelog", "/Users/you/docs", .finished, .reviewing, tokens: 9_000, model: "sonnet")
        done.lastMessage = "Added a 1.2.0 entry covering the reconnect fix and the new settings screen."
        done.turnEndedAt = Date()
        _ = make("demo-4", .codex, "Refactor the payments store", "/Users/you/shop", .idle, .reasoning)
        UsageStore.shared.showDemo()
    }

    /// Adds a demo prompt for a screenshot: "permission" or "question".
    func showDemoPrompt(_ kind: String) {
        demoUntil = Date().addingTimeInterval(30)
        guard let s = existing("demo-1") else { return }
        let k: PendingRequest.Kind = kind == "question"
            ? .question([QuestionSpec(question: "Which reconnect strategy should I use?", header: "Strategy",
                                      options: [.init(label: "Exponential backoff", description: "Retry with growing delays, capped at 30s"),
                                                .init(label: "Fixed interval", description: "Retry every 2 seconds")],
                                      multiSelect: false)])
            : .permission(tool: "Bash", detail: "git push origin fix/ws-reconnect", description: "Push the branch", canAlwaysAllow: true)
        let p = PendingRequest(sessionID: s.id, kind: k) { _ in }
        p.deferPayload = ""
        s.status = .waiting
        withAnimation { pending.append(p) }
    }

    // MARK: Helpers

    @ObservationIgnored private var origins: [String: AgentKind] = [:]
    private static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    private func originKind(sid: String, ppid: pid_t?) -> AgentKind {
        if let k = origins[sid] { return k }
        var kind = AgentKind.claude
        if let pp = ppid, Proc.claudeProcess(from: pp) == nil,
           Proc.hostingApp(of: pp)?.bundleIdentifier == Self.cursorBundleID {
            kind = .cursor
        }
        origins[sid] = kind
        return kind
    }

    @ObservationIgnored private var feedReads: [String: Date] = [:]
    @ObservationIgnored private var feedPending: Set<String> = []

    /// Re-reads a Claude session's transcript into its feed (throttled; only worth it while the card is open).
    func refreshFeed(_ s: AgentSession, force: Bool = false) {
        guard s.kind == .claude, let path = s.transcriptPath else { return }
        guard force || IslandModel.shared.expanded == .agents else { return }
        let id = s.id
        if let last = feedReads[id], Date().timeIntervalSince(last) < 0.8 {
            // Coalesce bursts of events into one read shortly after.
            guard !feedPending.contains(id) else { return }
            feedPending.insert(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.feedPending.remove(id)
                if let s = self?.existing(id) { self?.refreshFeed(s, force: true) }
            }
            return
        }
        feedReads[id] = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let items = FeedReader.claude(path: path)
            DispatchQueue.main.async {
                guard let s = AgentStore.shared.existing(id), s.feed != items else { return }
                s.feed = items
            }
        }
    }

    /// Picks up the title the tool generated for this conversation (throttled).
    func refreshTitle(_ s: AgentSession, force: Bool = false) {
        guard force || s.generatedTitle == nil, Date().timeIntervalSince(s.lastTitleLookup) > (force ? 2 : 8) else { return }
        s.lastTitleLookup = Date()
        let id = s.id
        TitleResolver.shared.title(for: id, kind: s.kind) { title in
            guard let title else { return }
            DispatchQueue.main.async {
                AgentStore.shared.existing(id)?.generatedTitle = title
            }
        }
    }

    nonisolated static func detail(tool: String, input: [String: Any]) -> String {
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
