import Foundation
import CoreServices

/// Follows Codex (desktop app + CLI) by tailing the rollout logs in ~/.codex/sessions.
/// Read-only: Codex approvals are surfaced with a jump-to-Codex button.
@MainActor
final class CodexWatcher {
    private weak var store: AgentStore?
    /// Honours CODEX_HOME like Codex itself does.
    private let root = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    private var sessionsDir: URL { root.appendingPathComponent("sessions") }
    private var indexURL: URL { root.appendingPathComponent("session_index.jsonl") }

    private var stream: FSEventStreamRef?
    /// file path -> bytes consumed. Only touched on `io`.
    nonisolated(unsafe) private var offsets: [String: UInt64] = [:]
    private var fileSession: [String: String] = [:] // file path -> session id
    private var titles: [String: String] = [:]
    private let io = DispatchQueue(label: "lintel.codex", qos: .utility)
    private var timer: Timer?

    /// Only sessions touched this recently are shown.
    private var liveWindow: TimeInterval { AgentStore.keepAlive }

    init(store: AgentStore) { self.store = store }

    func start() {
        loadTitles()
        initialScan()
        startStream()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
        timer?.invalidate()
    }

    private func expire() {
        guard let store else { return }
        for s in store.sessions where s.kind == .codex {
            if Date().timeIntervalSince(s.lastEventAt) > liveWindow { store.remove(s.id) }
        }
    }

    // MARK: Files

    private func initialScan() {
        let dir = sessionsDir
        let cutoff = Date().addingTimeInterval(-liveWindow)
        io.async { [weak self] in
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            var recent: [URL] = []
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if m > cutoff { recent.append(url) }
            }
            for url in recent { self?.consume(url, initial: true) }
        }
    }

    private func startStream() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<CodexWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated { me.changed(Array(arr.prefix(count))) }
        }
        // Watch ~/.codex so session_index.jsonl changes are seen too.
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func changed(_ paths: [String]) {
        let sessionsPrefix = sessionsDir.path
        for p in Set(paths) {
            if p.hasSuffix("session_index.jsonl") { loadTitles(); continue }
            guard p.hasPrefix(sessionsPrefix), p.hasSuffix(".jsonl") else { continue }
            let url = URL(fileURLWithPath: p)
            io.async { [weak self] in self?.consume(url, initial: false) }
        }
    }

    private func loadTitles() {
        let url = indexURL
        io.async { [weak self] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            var t: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let id = d["id"] as? String, let name = d["thread_name"] as? String else { continue }
                t[id] = name
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.titles = t
                for s in self.store?.sessions ?? [] where s.kind == .codex { if let n = t[s.id] { s.generatedTitle = n } }
            }
        }
    }

    /// Reads new lines from a rollout file (runs on `io`).
    nonisolated private func consume(_ url: URL, initial: Bool) {
        let path = url.path
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let known = offsets[path]
        var start = known ?? 0
        if start > size { start = 0 }
        // First sight of a big file: we still need the session_meta at the top, then only the tail.
        var head: Data?
        if known == nil && size > 2_000_000 {
            try? fh.seek(toOffset: 0)
            head = try? fh.read(upToCount: 64 * 1024)
            start = size - 1_000_000
        }
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return }
        // Only consume complete lines.
        var chunk = data
        if let lastNL = chunk.lastIndex(of: UInt8(ascii: "\n")) {
            chunk = chunk[chunk.startIndex...lastNL]
        } else if !initial {
            return
        }
        let consumed = start + UInt64(chunk.count)
        var lines: [[String: Any]] = []
        for blob in [head, chunk].compactMap({ $0 }) {
            for line in blob.split(separator: UInt8(ascii: "\n")) {
                if let d = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] { lines.append(d) }
            }
        }
        offsets[path] = consumed
        let parsed = lines
        DispatchQueue.main.async { [weak self] in
            self?.apply(parsed, file: path, initial: initial)
        }
    }

    // MARK: Events

    private func apply(_ lines: [[String: Any]], file: String, initial: Bool) {
        guard let store else { return }
        var session: AgentSession? = fileSession[file].flatMap { store.existing($0) }

        for d in lines {
            let type = d["type"] as? String
            let p = d["payload"] as? [String: Any] ?? [:]
            if type == "session_meta" {
                guard let id = p["id"] as? String else { continue }
                fileSession[file] = id
                let s = store.session(id: id, kind: .codex)
                if let cwd = p["cwd"] as? String, cwd != s.cwd { s.cwd = cwd; s.refreshBranch() }
                if let n = titles[id] { s.generatedTitle = n }
                session = s
                continue
            }
            if session == nil, let id = fileSession[file] { session = store.session(id: id, kind: .codex) }
            guard let s = session else { continue }
            s.lastEventAt = Date()

            switch type {
            case "turn_context":
                if let m = p["model"] as? String { s.model = shortModelName(m) }
            case "event_msg":
                switch p["type"] as? String ?? "" {
                case "task_started":
                    s.beginTurn(prompt: nil)
                case "user_message":
                    if let m = p["message"] as? String {
                        s.lastPrompt = String(m.split(separator: "\n").first ?? "").prefix(80).description
                        if let t = FeedReader.cleanUserText(m) {
                            s.upsertFeed(FeedItem(id: "u-\(d["timestamp"] as? String ?? UUID().uuidString)", kind: .user,
                                                  text: t, date: Self.date(d) ?? Date()))
                        }
                    }
                case "agent_message":
                    if let m = p["message"] as? String {
                        s.lastMessage = m
                        s.upsertFeed(FeedItem(id: "a-\(d["timestamp"] as? String ?? UUID().uuidString)", kind: .assistant,
                                              text: m.trimmingCharacters(in: .whitespacesAndNewlines), date: Self.date(d) ?? Date()))
                    }
                case "agent_reasoning":
                    let t = (p["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    s.upsertFeed(FeedItem(id: "th-\(d["timestamp"] as? String ?? UUID().uuidString)", kind: .thinking,
                                          text: t, date: Self.date(d) ?? Date()))
                case "task_complete":
                    s.endTurn(message: p["last_agent_message"] as? String)
                    clearExternal(s)
                    if !initial { store.announceFinished(s) }
                case "turn_aborted":
                    s.status = .idle
                    s.turnEndedAt = Date()
                    clearExternal(s)
                case "token_count":
                    if let rl = p["rate_limits"] as? [String: Any] { UsageStore.shared.applyCodex(rl) }
                    if let info = p["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] {
                        s.tokens = (last["input_tokens"] as? Int ?? 0) + (last["output_tokens"] as? Int ?? 0)
                    }
                case let t where t.contains("approval"):
                    // With Lintel's Codex hooks connected, the PermissionRequest hook brings the real prompt.
                    if !initial && !AgentHooks.isInstalled(.codex) {
                        s.status = .waiting
                        let msg = (p["command"] as? [String]).map { $0.joined(separator: " ") } ?? (p["reason"] as? String ?? "Codex needs your approval")
                        store.add(PendingRequest(sessionID: s.id, kind: .external(message: msg)) { _ in })
                    }
                default: break
                }
            case "response_item":
                let pt = p["type"] as? String ?? ""
                if pt == "function_call" || pt == "custom_tool_call" || pt == "local_shell_call" {
                    if s.status != .working && !initial { s.status = .working }
                    clearExternal(s)
                    let name = p["name"] as? String ?? "shell"
                    s.recordTool(name, detail: Self.detail(p))
                    let callID = p["call_id"] as? String ?? UUID().uuidString
                    s.upsertFeed(FeedItem(id: "t-\(callID)", kind: .tool, text: Self.describe(name, p),
                                          tool: FeedReader.displayName(name), status: .running, date: Self.date(d) ?? Date()))
                } else if pt == "function_call_output" || pt == "custom_tool_call_output" {
                    if let callID = p["call_id"] as? String, let i = s.feed.lastIndex(where: { $0.id == "t-\(callID)" }) {
                        s.feed[i].status = .done
                    }
                }
            default: break
            }
        }

        // Replaying history shouldn't leave stale "working" state for long-dead turns.
        if initial, let s = session, s.status == .working, Date().timeIntervalSince(fileModified(file)) > 120 {
            s.status = .idle
        }
    }

    private func clearExternal(_ s: AgentSession) {
        guard let store else { return }
        for p in store.pendingFor(s) { if case .external = p.kind { store.discard(p) } }
        if s.status == .waiting { s.status = .working }
    }

    private func fileModified(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    private static func date(_ d: [String: Any]) -> Date? {
        guard let ts = d["timestamp"] as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: ts)
    }

    /// Feed text for a Codex tool call, e.g. "Running rg hero".
    private static func describe(_ name: String, _ p: [String: Any]) -> String {
        let raw = p["arguments"] as? String ?? p["input"] as? String ?? ""
        if let args = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
            if let c = args["cmd"] as? String ?? args["command"] as? String { return c }
            if let c = args["command"] as? [String] { return c.joined(separator: " ") }
            return FeedReader.describe(tool: name, input: args)
        }
        if name == "apply_patch" {
            // The patch names the files it touches: "*** Update File: path".
            let files = raw.split(separator: "\n").compactMap { l -> String? in
                for k in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where l.hasPrefix(k) {
                    return (String(l.dropFirst(k.count)) as NSString).lastPathComponent
                }
                return nil
            }
            return files.isEmpty ? "Editing files" : "Editing " + files.prefix(3).joined(separator: ", ")
        }
        return detail(p)
    }

    private static func detail(_ p: [String: Any]) -> String {
        let raw = p["arguments"] as? String ?? p["input"] as? String ?? ""
        if let d = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
            if let c = d["cmd"] as? String ?? d["command"] as? String { return c }
            if let c = d["command"] as? [String] { return c.joined(separator: " ") }
            if let path = d["path"] as? String { return (path as NSString).lastPathComponent }
        }
        let firstLine = raw.split(separator: "\n").first.map(String.init) ?? raw
        return String(firstLine.prefix(120))
    }
}
