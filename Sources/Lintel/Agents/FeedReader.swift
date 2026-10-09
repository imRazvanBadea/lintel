import Foundation

/// Builds a session's activity feed (your messages, the agent's replies and thinking, tool calls) from
/// Claude Code's transcript. Cursor and Codex feeds are assembled from their events instead.
enum FeedReader {
    /// Reads the tail of a Claude Code transcript (.jsonl) and returns the most recent feed items.
    static func claude(path: String, maxBytes: Int = 600 * 1024, limit: Int = AgentSession.feedLimit) -> [FeedItem] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return [] }

        var items: [FeedItem] = []
        var toolIndex: [String: Int] = [:]      // tool_use id -> index in items
        var lastAssistantDate: Date?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() } // first line is likely cut off
        for raw in lines {
            guard let d = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any] else { continue }
            let type = d["type"] as? String
            guard type == "user" || type == "assistant" else { continue }
            if d["isMeta"] as? Bool == true || d["isSidechain"] as? Bool == true { continue } // system notes, subagents
            guard let msg = d["message"] as? [String: Any] else { continue }
            let date = (d["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            let uuid = d["uuid"] as? String ?? UUID().uuidString

            if type == "user" {
                if let text = msg["content"] as? String {
                    if let t = cleanUserText(text) { items.append(FeedItem(id: uuid, kind: .user, text: t, date: date)) }
                    continue
                }
                guard let blocks = msg["content"] as? [[String: Any]] else { continue }
                var texts: [String] = []
                var images = 0
                for b in blocks {
                    switch b["type"] as? String {
                    case "tool_result":
                        if let id = b["tool_use_id"] as? String, let i = toolIndex[id] {
                            items[i].status = (b["is_error"] as? Bool == true) ? .failed : .done
                        }
                    case "text":
                        if let t = b["text"] as? String, let c = cleanUserText(t) { texts.append(c) }
                    case "image":
                        images += 1
                    default: break
                    }
                }
                if !texts.isEmpty || images > 0 {
                    var text = texts.joined(separator: "\n")
                    if images > 0 { text += (text.isEmpty ? "" : "\n") + (images == 1 ? "📎 Image" : "📎 \(images) images") }
                    items.append(FeedItem(id: uuid, kind: .user, text: text, date: date))
                }
            } else {
                guard let blocks = msg["content"] as? [[String: Any]] else { continue }
                for (n, b) in blocks.enumerated() {
                    let id = "\(uuid)#\(n)"
                    switch b["type"] as? String {
                    case "text":
                        let t = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { items.append(FeedItem(id: id, kind: .assistant, text: t, date: date)) }
                    case "thinking":
                        // Recent models redact the text; keep the beat ("Thought for 4s") either way.
                        let t = (b["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let dur = lastAssistantDate.map { date.timeIntervalSince($0) }
                        if items.last?.kind == .thinking, t.isEmpty { continue } // collapse runs of empty thoughts
                        items.append(FeedItem(id: id, kind: .thinking, text: t, date: date,
                                              duration: dur.flatMap { $0 > 0 && $0 < 600 ? $0 : nil }))
                    case "tool_use":
                        let name = b["name"] as? String ?? "Tool"
                        let input = b["input"] as? [String: Any] ?? [:]
                        if name == "TodoWrite" || name == "TaskCreate" || name == "TaskUpdate" { continue }
                        let item = FeedItem(id: id, kind: .tool, text: describe(tool: name, input: input),
                                            tool: displayName(name), status: .running, date: date)
                        if let tid = b["id"] as? String { toolIndex[tid] = items.count }
                        items.append(item)
                    default: break
                    }
                }
                lastAssistantDate = date
            }
        }
        return Array(items.suffix(limit))
    }

    /// Strips system-injected markup from a user message; nil when nothing human is left.
    static func cleanUserText(_ raw: String) -> String? {
        var t = raw
        // Remove tagged system blocks (<system-reminder>…</system-reminder>, <command-name>…, etc.)
        while let open = t.range(of: #"<([a-z][a-z0-9_-]*)[^>]*>"#, options: .regularExpression) {
            let tag = String(t[open]).dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if let close = t.range(of: "</\(tag)>", range: open.upperBound..<t.endIndex) {
                t.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                t.removeSubrange(open)
            }
        }
        // Drop "[Image: …]" placeholders and attachment notes.
        t = t.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("[Image") && !$0.hasPrefix("[Request interrupted") }
            .joined(separator: "\n")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// "Reading reconnect.test.ts", "Running pnpm test", …
    static func describe(tool: String, input: [String: Any]) -> String {
        func file(_ k: String) -> String? { (input[k] as? String).map { ($0 as NSString).lastPathComponent } }
        func str(_ k: String) -> String? { (input[k] as? String)?.replacingOccurrences(of: "\n", with: " ") }
        switch tool {
        case "Read", "NotebookRead": return "Reading " + (file("file_path") ?? file("path") ?? "a file")
        case "Edit", "MultiEdit", "NotebookEdit", "apply_patch": return "Editing " + (file("file_path") ?? file("notebook_path") ?? file("path") ?? "a file")
        case "Write": return "Writing " + (file("file_path") ?? file("path") ?? "a file")
        case "Delete": return "Deleting " + (file("path") ?? file("file_path") ?? "a file")
        case "Bash", "Shell", "shell", "exec_command", "local_shell":
            return str("description").map { $0 } ?? str("command") ?? "Running a command"
        case "Grep": return "Searching for " + (str("pattern").map { "“\($0)”" } ?? "text")
        case "Glob", "LS", "List": return "Finding " + (str("pattern") ?? str("path") ?? "files")
        case "WebFetch", "Fetch": return "Fetching " + (str("url").flatMap { URL(string: $0)?.host } ?? "a page")
        case "WebSearch": return "Searching the web for " + (str("query").map { "“\($0)”" } ?? "…")
        case "Task", "Agent": return str("description") ?? "Delegating to a subagent"
        case "AskUserQuestion": return "Asking you a question"
        default:
            if tool.hasPrefix("mcp__") { return str("description") ?? AgentStore.detail(tool: tool, input: input) }
            return AgentStore.detail(tool: tool, input: input)
        }
    }

    /// "mcp__terminal__read_terminal" -> "read terminal · terminal" (opaque server ids are dropped)
    static func displayName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let comps = tool.components(separatedBy: "__")
        guard comps.count >= 3 else { return tool }
        let server = comps[1].count > 20 ? "" : comps[1]
        let name = comps[2...].joined(separator: "__").replacingOccurrences(of: "_", with: " ")
        return server.isEmpty ? name : "\(name) · \(server)"
    }
}
