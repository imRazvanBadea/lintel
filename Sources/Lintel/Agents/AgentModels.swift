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
    var model = ""
    var lastMessage = ""
    var lastPrompt = ""
    var notice: String?
    var transcriptPath: String?
    var agentPID: pid_t?
    var hookPPID: pid_t?
    var termProgram = ""

    init(id: String, kind: AgentKind, colorIndex: Int) {
        self.id = id
        self.kind = kind
        self.colorIndex = colorIndex
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

    func refreshBranch() {
        guard !cwd.isEmpty else { return }
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<8 {
            let head = dir.appendingPathComponent(".git/HEAD")
            if let s = try? String(contentsOf: head, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                branch = t.hasPrefix("ref: refs/heads/") ? String(t.dropFirst(16)) : String(t.prefix(7))
                return
            }
            // Worktrees: .git is a file pointing at the real gitdir.
            let gitFile = dir.appendingPathComponent(".git")
            if let s = try? String(contentsOf: gitFile, encoding: .utf8), s.hasPrefix("gitdir:") {
                let path = s.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                if let h = try? String(contentsOfFile: path + "/HEAD", encoding: .utf8) {
                    let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
                    branch = t.hasPrefix("ref: refs/heads/") ? String(t.dropFirst(16)) : String(t.prefix(7))
                }
                return
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        branch = nil
    }
}

func shortModelName(_ m: String) -> String {
    let l = m.lowercased()
    for n in ["opus", "sonnet", "haiku", "fable"] where l.contains(n) { return n }
    if l.hasPrefix("gpt") || l.contains("codex") { return String(m.prefix(14)) }
    return String(m.prefix(14))
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
