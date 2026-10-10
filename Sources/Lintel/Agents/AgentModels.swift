import Foundation
import Observation

enum AgentKind: String { case claude, codex, cursor
    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
}

enum AgentStatus: Int, Comparable {
    case waiting, working, finished, idle
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The four beats of a turn, shown as the segmented strip in the detail view.
enum Phase: Int, CaseIterable {
    case researching, reasoning, writing, reviewing

    var label: String {
        switch self {
        case .researching: "Researching"
        case .reasoning: "Reasoning"
        case .writing: "Writing"
        case .reviewing: "Reviewing"
        }
    }
    var symbol: String {
        switch self {
        case .researching: "magnifyingglass"
        case .reasoning: "sparkles"
        case .writing: "pencil.and.scribble"
        case .reviewing: "checkmark.circle.fill"
        }
    }

    static func forTool(_ name: String, detail: String) -> Phase {
        switch name {
        case "Read", "Grep", "Glob", "LS", "List", "WebSearch", "WebFetch", "Fetch", "ToolSearch", "Agent", "Task", "ReadLints":
            return .researching
        case "Edit", "MultiEdit", "Write", "Delete", "NotebookEdit", "apply_patch":
            return .writing
        case "Bash", "Shell", "shell", "exec_command", "local_shell":
            let d = detail.lowercased()
            let checks = ["test", "vitest", "jest", "pytest", "lint", "tsc", "build", "check", "git diff", "git status", "cargo", "swift build", "xcodebuild"]
            if checks.contains(where: d.contains) { return .reviewing }
            let looks = ["ls", "cat ", "grep", "rg ", "find ", "head", "tail", "sed -n", "git log", "git show"]
            if looks.contains(where: d.hasPrefix) { return .researching }
            return .writing
        case "TodoWrite", "TaskCreate", "TaskUpdate", "EnterPlanMode", "ExitPlanMode":
            return .reasoning
        default:
            return .researching
        }
    }
}

/// One line of a session's activity feed: what you said, what the agent said, thought or did.
struct FeedItem: Identifiable, Equatable {
    enum Kind: Equatable { case user, assistant, thinking, tool }
    enum Status: Equatable { case running, done, failed }

    let id: String
    var kind: Kind
    var text: String               // message / thought text, or the tool's target ("Reading ws.ts")
    var tool: String = ""          // tool name for .tool
    var status: Status = .done
    var date: Date
    var duration: TimeInterval?    // thinking time, when known
}

struct ToolStat: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var detail: String
    var count: Int
    var lastAt: Date
}

struct QuestionSpec: Identifiable, Equatable {
    struct Option: Equatable, Hashable { var label: String; var description: String }
    var id: String { question }
    var question: String
    var header: String
    var options: [Option]
    var multiSelect: Bool
}

/// Something an agent is blocked on (or is offering) that you can answer from the notch.
@MainActor
final class PendingRequest: Identifiable {
    enum Kind {
        case permission(tool: String, detail: String, description: String, canAlwaysAllow: Bool)
        case question([QuestionSpec])
        case reply(deadline: Date)            // Claude finished; you may send a follow-up
        case external(message: String)        // Needs you, but must be answered in the agent's own UI
    }

    let id = UUID()
    let sessionID: String
    let kind: Kind
    let createdAt = Date()
    /// Original tool input (echoed back with answers) and Claude's "always allow" suggestions.
    var toolInput: [String: Any] = [:]
    var suggestions: [Any] = []
    /// Which agent asked (answers are formatted per agent).
    var agent: AgentKind = .claude
    /// What to send when you don't decide here (time-out / "answer in the agent's own UI").
    var deferPayload = ""
    /// True while you're typing a reply, so the quick-reply window doesn't close under you.
    var hold = false
    /// Resolves the request with the hook's stdout payload ("" = defer to terminal).
    let resolve: (String) -> Void

    init(sessionID: String, kind: Kind, resolve: @escaping (String) -> Void) {
        self.sessionID = sessionID
        self.kind = kind
        self.resolve = resolve
    }

    var isBlocking: Bool {
        switch kind {
        case .permission, .question, .external: true
        case .reply: false
        }
    }
}

@MainActor @Observable
final class AgentSession: Identifiable {
    let id: String
    let kind: AgentKind
    var title: String = ""
    var cwd: String = ""
    var branch: String?
    var status: AgentStatus = .idle
    var phase: Phase = .reasoning
    var colorIndex: Int
    var turnStartedAt: Date?
    var turnEndedAt: Date?
    var lastEventAt = Date()
    var tools: [ToolStat] = []
    var turnToolCalls = 0
    var totalToolCalls = 0
    var tokens = 0
    /// Display name of the model ("Sonnet 5.5") and the reasoning effort when the tool reports it.
    var model = ""
    var effort: String?
    /// The session that spawned this one (Cursor subagents), shown folded under it in the list.
    var parentID: String?
    var lastMessage = ""
    /// Recent conversation and tool activity, oldest first (capped).
    var feed: [FeedItem] = []
    var lastPrompt = ""
    var notice: String?
    var transcriptPath: String?
    var agentPID: pid_t?
    var hookPPID: pid_t?
    var termProgram = ""
    /// Set for sessions started from the notch: the terminal they run in.
    var launchedIn: LaunchTerminal?

    init(id: String, kind: AgentKind, colorIndex: Int) {
        self.id = id
        self.kind = kind
        self.colorIndex = colorIndex
    }

    /// Takes a raw model id ("claude-sonnet-5-5-medium"); an effort folded into the id wins over `effort`.
    func setModel(_ raw: String, effort: String? = nil) {
        let (name, folded) = modelDisplayName(raw)
        if model != name { model = name }
        if let e = (folded ?? effort)?.lowercased(), !e.isEmpty, self.effort != e { self.effort = e }
    }

    var project: String { cwd.isEmpty ? kind.label : (cwd as NSString).lastPathComponent }

    /// The title the tool itself generated (Claude app, Cursor, Codex). Preferred over everything else.
    var generatedTitle: String?
    @ObservationIgnored var lastTitleLookup = Date.distantPast

    var displayTitle: String {
        if let g = generatedTitle, !g.isEmpty { return g }
        if !title.isEmpty { return title }
        if !lastPrompt.isEmpty { return lastPrompt }
        return project
    }

    var turnDuration: TimeInterval? {
        guard let s = turnStartedAt else { return nil }
        return (turnEndedAt ?? Date()).timeIntervalSince(s)
    }

    nonisolated static let feedLimit = 60

    /// Appends (or updates, by id) a feed item — used where activity arrives as events (Cursor, Codex).
    func upsertFeed(_ item: FeedItem) {
        if let i = feed.lastIndex(where: { $0.id == item.id }) { feed[i] = item } else { feed.append(item) }
        if feed.count > Self.feedLimit { feed.removeFirst(feed.count - Self.feedLimit) }
    }

    /// Marks the most recent running tool call as finished (when the event doesn't carry an id).
    func finishLatestTool(failed: Bool = false) {
        if let i = feed.lastIndex(where: { $0.kind == .tool && $0.status == .running }) {
            feed[i].status = failed ? .failed : .done
        }
    }

    func recordTool(_ name: String, detail: String) {
        turnToolCalls += 1
        totalToolCalls += 1
        if let i = tools.firstIndex(where: { $0.name == name }) {
            tools[i].count += 1
            tools[i].detail = detail
            tools[i].lastAt = Date()
            let t = tools.remove(at: i)
            tools.insert(t, at: 0)
        } else {
            tools.insert(ToolStat(name: name, detail: detail, count: 1, lastAt: Date()), at: 0)
        }
        phase = Phase.forTool(name, detail: detail)
    }

    func beginTurn(prompt: String?) {
        status = .working
        phase = .reasoning
        turnStartedAt = Date()
        turnEndedAt = nil
        tools = []
        turnToolCalls = 0
        notice = nil
        if let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            lastPrompt = String(p.split(separator: "\n").first ?? "").prefix(80).description
        }
    }

    func beginTurnIfIdle() {
        if status != .working { beginTurn(prompt: nil) }
    }

    func endTurn(message: String?) {
        status = .finished
        phase = .reviewing
        turnEndedAt = Date()
        if let m = message, !m.isEmpty { lastMessage = m }
    }

    /// Reads the git branch for `cwd` — off the main thread, because the folder can be on a slow or
    /// virtual file system (Google Drive, iCloud, network shares) where a read can block for a long time.
    func refreshBranch() {
        guard !cwd.isEmpty else { return }
        let path = cwd, id = self.id
        DispatchQueue.global(qos: .utility).async {
            let b = Self.gitBranch(at: path)
            DispatchQueue.main.async {
                guard let s = AgentStore.shared.existing(id), s.cwd == path, s.branch != b else { return }
                s.branch = b
            }
        }
    }

    nonisolated static func gitBranch(at path: String) -> String? {
        func head(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.hasPrefix("ref: refs/heads/") ? String(t.dropFirst(16)) : String(t.prefix(7))
        }
        var dir = URL(fileURLWithPath: path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for _ in 0..<8 {
            if let s = try? String(contentsOf: dir.appendingPathComponent(".git/HEAD"), encoding: .utf8) { return head(s) }
            // Worktrees: .git is a file pointing at the real gitdir.
            if let s = try? String(contentsOf: dir.appendingPathComponent(".git"), encoding: .utf8), s.hasPrefix("gitdir:") {
                let gitdir = s.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                return (try? String(contentsOfFile: gitdir + "/HEAD", encoding: .utf8)).map(head)
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir || parent.path == home || parent.path.count < home.count { break }
            dir = parent
        }
        return nil
    }
}

/// "claude-sonnet-5-5-medium" → ("Sonnet 5.5", "medium"); "claude-3-5-haiku-20241022" → ("Haiku 3.5", nil);
/// "gpt-5-codex" → ("GPT-5 Codex", nil).
func modelDisplayName(_ raw: String) -> (name: String, effort: String?) {
    var parts = raw.lowercased().split(separator: "-").map(String.init)
    var effort: String?
    let efforts = ["low", "medium", "high", "xhigh", "max"]
    while let last = parts.last, efforts.contains(last) || last == "thinking" || last == "fast" || (last.count == 8 && Int(last) != nil) {
        if efforts.contains(last) { effort = last }
        parts.removeLast()
    }
    if parts.first == "claude" { parts.removeFirst() }
    for family in ["opus", "sonnet", "haiku", "fable"] {
        guard let i = parts.firstIndex(of: family) else { continue }
        // The version sits after the family (opus-5-5) or, in older ids, before it (3-5-sonnet).
        let after = parts[(i + 1)...].prefix { Int($0) != nil }
        let before = parts[..<i].reversed().prefix { Int($0) != nil }.reversed()
        let version = (after.isEmpty ? Array(before) : Array(after)).joined(separator: ".")
        return (family.capitalized + (version.isEmpty ? "" : " \(version)"), effort)
    }
    let name = parts.joined(separator: "-")
    if name.hasPrefix("gpt-") {
        let rest = name.dropFirst(4).split(separator: "-", maxSplits: 1)
        return ("GPT-\(rest.first ?? "")" + (rest.count > 1 ? " " + rest[1].replacingOccurrences(of: "-", with: " ").capitalized : ""), effort)
    }
    return (String(name.prefix(20)), effort)
}

func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1000 { return "\(n / 1000)k" }
    return "\(n)"
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}
