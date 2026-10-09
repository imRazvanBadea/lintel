import Foundation
import Observation

/// Token and cost history per tool and model, read from what the tools already keep on disk:
///  - Claude Code: `usage` on assistant messages in ~/.claude*/projects/**/*.jsonl (deduplicated by message id)
///  - Codex: `token_count` events in ~/.codex*/sessions/**/*.jsonl
///  - Cursor: recorded by Lintel from Cursor's afterAgentResponse hook (Cursor keeps no usage on disk)
/// Files are read once and then only from where the last scan stopped; results live in ~/Library/Caches/Lintel.
@MainActor @Observable
final class UsageHistory {
    static let shared = UsageHistory()

    enum Range: String, CaseIterable, Identifiable {
        case day = "24h", week = "7d", month = "30d", quarter = "90d"
        var id: String { rawValue }
        var seconds: TimeInterval { [.day: 86_400, .week: 7 * 86_400, .month: 30 * 86_400, .quarter: 90 * 86_400][self]! }
        /// Hourly points for a day, daily points otherwise.
        var step: TimeInterval { self == .day ? 3600 : 86_400 }
    }

    struct Point: Identifiable { let id = UUID(); let date: Date; let tool: AgentKind; let tokens: Int; let cost: Double }
    struct ToolTotal: Identifiable { var id: AgentKind { tool }; let tool: AgentKind; var tokens = 0; var cost = 0.0; var sessions = 0; var unpricedTokens = 0 }
    struct ModelTotal: Identifiable { var id: String { "\(tool.rawValue)|\(model)" }; let tool: AgentKind; let model: String; var tokens = 0; var cost: Double?; }
    struct Summary {
        var points: [Point] = []
        var tools: [ToolTotal] = []
        var models: [ModelTotal] = []
        var totals = TokenCounts()
        var cost = 0.0
        var savings = 0.0
        var sessions = 0
    }

    private(set) var isScanning = false
    private(set) var lastScan: Date?
    /// Bumped after every scan so views recompute.
    private(set) var revision = 0

    @ObservationIgnored private let queue = DispatchQueue(label: "lintel.usage-history", qos: .utility)
    /// Only touched on `queue` while scanning.
    @ObservationIgnored nonisolated(unsafe) private var index = Index()
    /// What queries read on the main thread: a copy taken after each scan.
    @ObservationIgnored private var snapshot = Index()
    @ObservationIgnored private var loaded = false

    // MARK: Persistence

    struct Bucket: Codable { var tool: String; var model: String; var hour: Int; var t: TokenCounts }
    struct FileState: Codable { var offset: UInt64; var codexTotal: TokenCounts? ; var codexModel: String? }
    struct SessionSpan: Codable { var tool: String; var first: Int; var last: Int }

    struct Index: Codable {
        var version = 1
        var files: [String: FileState] = [:]
        var seen: Set<String> = []                 // Claude message ids already counted
        var buckets: [String: Bucket] = [:]        // "tool|model|hour"
        var sessions: [String: SessionSpan] = [:]
    }

    nonisolated private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Lintel")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-history.json")
    }
    nonisolated static var cursorLogURL: URL { AgentHooks.dir.appendingPathComponent("cursor-usage.jsonl") }

    // MARK: Scanning

    /// Reads anything new since the last scan (in the background).
    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let firstLoad = !loaded
        loaded = true
        queue.async { [self] in
            if firstLoad, let data = try? Data(contentsOf: Self.cacheURL),
               let saved = try? JSONDecoder().decode(Index.self, from: data), saved.version == Index().version {
                index = saved
            }
            scanAll()
            if let data = try? JSONEncoder().encode(index) { try? data.write(to: Self.cacheURL, options: .atomic) }
            let snap = index
            DispatchQueue.main.async {
                self.snapshot = snap
                self.isScanning = false
                self.lastScan = Date()
                self.revision += 1
            }
        }
    }

    nonisolated private func scanAll() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let cutoff = Date().addingTimeInterval(-92 * 86_400)
        let dirs = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        // Default homes first, then extra accounts (~/.claude-work, ~/.codex-work, …).
        let claudeHomes = dirs.filter { $0 == ".claude" || $0.hasPrefix(".claude-") }.map { home.appendingPathComponent("\($0)/projects") }
        let codexHomes = [AgentHooks.codexHome.appendingPathComponent("sessions")]
            + dirs.filter { $0.hasPrefix(".codex-") }.map { home.appendingPathComponent("\($0)/sessions") }

        for root in claudeHomes { forEachJSONL(in: root, modifiedAfter: cutoff) { scanClaude($0) } }
        for root in codexHomes { forEachJSONL(in: root, modifiedAfter: cutoff) { scanCodex($0) } }
        scanCursorLog()
        pruneOld()
    }

    nonisolated private func forEachJSONL(in root: URL, modifiedAfter cutoff: Date, _ body: (URL) -> Void) {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if m > cutoff { autoreleasepool { body(url) } }
        }
    }

    /// New complete lines of a file since the last scan.
    nonisolated private func newLines(_ url: URL, state: inout FileState) -> [Data.SubSequence]? {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if state.offset > size { state = FileState(offset: 0) } // rewritten
        guard size > state.offset else { return nil }
        try? fh.seek(toOffset: state.offset)
        guard let data = try? fh.readToEnd(), let lastNL = data.lastIndex(of: 10) else { return nil }
        state.offset += UInt64(lastNL - data.startIndex + 1)
        return data[data.startIndex...lastNL].split(separator: 10)
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = { // only used on the scan queue
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated private func add(_ tool: AgentKind, model: String, at date: Date, _ t: TokenCounts, session: String?) {
        guard t.total > 0 else { return }
        let hour = Int(date.timeIntervalSince1970 / 3600)
        let key = "\(tool.rawValue)|\(model)|\(hour)"
        index.buckets[key, default: Bucket(tool: tool.rawValue, model: model, hour: hour, t: TokenCounts())].t += t
        if let session {
            let ts = Int(date.timeIntervalSince1970)
            var span = index.sessions[session] ?? SessionSpan(tool: tool.rawValue, first: ts, last: ts)
            span.first = min(span.first, ts)
            span.last = max(span.last, ts)
            index.sessions[session] = span
        }
    }

    nonisolated private func scanClaude(_ url: URL) {
        var state = index.files[url.path] ?? FileState(offset: 0)
        defer { index.files[url.path] = state }
        guard let lines = newLines(url, state: &state) else { return }
        let session = url.deletingPathExtension().lastPathComponent
        for line in lines {
            // Assistant lines can be huge (tool output); pull out only the fields we need instead of parsing it all.
            guard line.count > 40, Self.find(Self.kAssistant, in: line) != nil,
                  let usageAt = Self.find(Self.kUsage, in: line, last: true),
                  let usageJSON = Self.object(in: line, from: usageAt + Self.kUsage.count - 1),
                  let u = (try? JSONSerialization.jsonObject(with: Data(usageJSON))) as? [String: Any] else { continue }
            let msgID = Self.string(after: Self.kMsgID, in: line).map { "msg_" + $0 } ?? ""
            let id = msgID + (Self.string(after: Self.kRequestID, in: line) ?? "")
            // The same message is written once per content block (and copied into forked sessions).
            guard !id.isEmpty, index.seen.insert(id).inserted else { continue }
            let model = Self.string(after: Self.kModel, in: line) ?? "unknown"
            guard !model.hasPrefix("<") else { continue } // "<synthetic>" placeholder messages
            let date = Self.string(after: Self.kTimestamp, in: line).flatMap { Self.iso.date(from: $0) } ?? Date()
            func n(_ k: String, _ o: [String: Any] = u) -> Int { (o[k] as? NSNumber)?.intValue ?? 0 }
            var t = TokenCounts(input: n("input_tokens"), output: n("output_tokens"), cacheRead: n("cache_read_input_tokens"))
            if let cc = u["cache_creation"] as? [String: Any] {
                t.cacheWrite5m = n("ephemeral_5m_input_tokens", cc)
                t.cacheWrite1h = n("ephemeral_1h_input_tokens", cc)
            } else {
                t.cacheWrite5m = n("cache_creation_input_tokens")
            }
            let sid = Self.string(after: Self.kSessionID, in: line) ?? session
            add(.claude, model: model, at: date, t, session: "claude:" + sid)
        }
    }

    // Byte patterns for the fast path. JSON keys in transcripts are written without spaces.
    nonisolated private static let kAssistant = Array(#""type":"assistant""#.utf8)
    nonisolated private static let kUsage = Array(#""usage":{"#.utf8)
    nonisolated private static let kMsgID = Array(#""id":"msg_"#.utf8)
    nonisolated private static let kRequestID = Array(#""requestId":""#.utf8)
    nonisolated private static let kModel = Array(#""model":""#.utf8)
    nonisolated private static let kTimestamp = Array(#""timestamp":""#.utf8)
    nonisolated private static let kSessionID = Array(#""sessionId":""#.utf8)

    /// The string value right after `key` (first occurrence), up to the closing quote.
    /// Index of `needle` in `line` (first, or last), using memmem — far faster than generic collection search.
    nonisolated private static func find(_ needle: [UInt8], in line: Data.SubSequence, last: Bool = false) -> Data.Index? {
        line.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Data.Index? in
            guard let base = buf.baseAddress else { return nil }
            var found: Int?
            var offset = 0
            while offset <= buf.count - needle.count,
                  let hit = memmem(base + offset, buf.count - offset, needle, needle.count) {
                found = base.distance(to: hit)
                if !last { break }
                offset = found! + 1
            }
            return found.map { line.startIndex + $0 }
        }
    }

    nonisolated private static func string(after key: [UInt8], in line: Data.SubSequence) -> String? {
        guard let at = find(key, in: line) else { return nil }
        var i = at + key.count
        let start = i
        while i < line.endIndex, line[i] != 34 { if line[i] == 92 { i += 1 }; i += 1 } // 34 = ", 92 = \
        guard i <= line.endIndex else { return nil }
        return String(decoding: line[start..<min(i, line.endIndex)], as: UTF8.self)
    }

    /// The balanced {...} object starting at `start` (which points at the "{").
    nonisolated private static func object(in line: Data.SubSequence, from start: Data.Index) -> Data.SubSequence? {
        guard start < line.endIndex, line[start] == 123 else { return nil } // {
        var depth = 0, i = start, inString = false
        while i < line.endIndex {
            let c = line[i]
            if inString {
                if c == 92 { i += 1 } else if c == 34 { inString = false }
            } else if c == 34 { inString = true }
            else if c == 123 { depth += 1 }
            else if c == 125 { depth -= 1; if depth == 0 { return line[start...i] } }
            i += 1
        }
        return nil
    }

    nonisolated private func scanCodex(_ url: URL) {
        var state = index.files[url.path] ?? FileState(offset: 0)
        defer { index.files[url.path] = state }
        guard let lines = newLines(url, state: &state) else { return }
        var session = url.deletingPathExtension().lastPathComponent
        for line in lines {
            guard let d = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let p = d["payload"] as? [String: Any] ?? [:]
            switch d["type"] as? String {
            case "session_meta":
                if let id = p["id"] as? String { session = id }
            case "turn_context":
                if let m = p["model"] as? String { state.codexModel = m }
            case "event_msg" where p["type"] as? String == "token_count":
                guard let info = p["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] else { continue }
                func n(_ k: String) -> Int { (total[k] as? NSNumber)?.intValue ?? 0 }
                // OpenAI semantics: input includes cached input; output includes reasoning.
                let cached = n("cached_input_tokens")
                let now = TokenCounts(input: max(0, n("input_tokens") - cached), output: n("output_tokens"), cacheRead: cached)
                let prev = state.codexTotal ?? TokenCounts()
                let delta = TokenCounts(input: max(0, now.input - prev.input), output: max(0, now.output - prev.output),
                                        cacheRead: max(0, now.cacheRead - prev.cacheRead))
                state.codexTotal = now
                let date = (d["timestamp"] as? String).flatMap { Self.iso.date(from: $0) } ?? Date()
                add(.codex, model: state.codexModel ?? "codex", at: date, delta, session: "codex:" + session)
            default: break
            }
        }
    }

    nonisolated private func scanCursorLog() {
        let url = Self.cursorLogURL
        var state = index.files[url.path] ?? FileState(offset: 0)
        defer { index.files[url.path] = state }
        guard let lines = newLines(url, state: &state) else { return }
        for line in lines {
            guard let d = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            func n(_ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
            let t = TokenCounts(input: n("input"), output: n("output"), cacheRead: n("cacheRead"), cacheWrite5m: n("cacheWrite"))
            let date = Date(timeIntervalSince1970: (d["ts"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)
            add(.cursor, model: d["model"] as? String ?? "cursor", at: date, t, session: "cursor:" + (d["session"] as? String ?? ""))
        }
    }

    nonisolated private func pruneOld() {
        let minHour = Int(Date().addingTimeInterval(-92 * 86_400).timeIntervalSince1970 / 3600)
        index.buckets = index.buckets.filter { $0.value.hour >= minHour }
        index.sessions = index.sessions.filter { $0.value.last >= minHour * 3600 }
    }

    /// Cursor keeps no usage on disk, so Lintel writes down what its hook reports.
    nonisolated static func recordCursor(session: String, model: String, json: [String: Any]) {
        func n(_ k: String) -> Int { (json[k] as? NSNumber)?.intValue ?? 0 }
        let entry: [String: Any] = ["ts": Date().timeIntervalSince1970, "session": session, "model": model,
                                    "input": n("input_tokens"), "output": n("output_tokens"),
                                    "cacheRead": n("cache_read_tokens"), "cacheWrite": n("cache_write_tokens")]
        guard n("input_tokens") + n("output_tokens") > 0,
              var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        line.append(10)
        let url = cursorLogURL
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(line)
            try? fh.close()
        } else {
            try? line.write(to: url)
        }
    }

    // MARK: Queries

    func summary(_ range: Range) -> Summary {
        _ = revision
        let now = Date()
        let start = now.addingTimeInterval(-range.seconds)
        let startHour = Int(start.timeIntervalSince1970 / 3600)
        var s = Summary()
        var perTool: [AgentKind: ToolTotal] = [:]
        var perModel: [String: ModelTotal] = [:]
        var series: [String: (Date, AgentKind, Int, Double)] = [:]
        let cal = Calendar.current

        for b in snapshot.buckets.values where b.hour >= startHour {
            guard let tool = AgentKind(rawValue: b.tool) else { continue }
            let cost = Pricing.cost(b.t, model: b.model)
            let tokens = b.t.total
            s.totals += b.t
            s.cost += cost ?? 0
            s.savings += Pricing.cacheSavings(b.t, model: b.model)

            var tt = perTool[tool] ?? ToolTotal(tool: tool)
            tt.tokens += tokens
            tt.cost += cost ?? 0
            if cost == nil { tt.unpricedTokens += tokens }
            perTool[tool] = tt

            let mk = "\(tool.rawValue)|\(Pricing.normalize(b.model))"
            var mt = perModel[mk] ?? ModelTotal(tool: tool, model: Pricing.normalize(b.model), cost: nil)
            mt.tokens += tokens
            if let cost { mt.cost = (mt.cost ?? 0) + cost }
            perModel[mk] = mt

            let date = Date(timeIntervalSince1970: TimeInterval(b.hour) * 3600)
            let slot = range == .day ? cal.dateInterval(of: .hour, for: date)!.start : cal.startOfDay(for: date)
            let key = "\(slot.timeIntervalSince1970)|\(tool.rawValue)"
            let cur = series[key] ?? (slot, tool, 0, 0)
            series[key] = (slot, tool, cur.2 + tokens, cur.3 + (cost ?? 0))
        }

        let startEpoch = Int(start.timeIntervalSince1970)
        for span in snapshot.sessions.values where span.last >= startEpoch {
            guard let tool = AgentKind(rawValue: span.tool) else { continue }
            perTool[tool, default: ToolTotal(tool: tool)].sessions += 1
            s.sessions += 1
        }

        // Fill gaps with zeros so the chart's lines drop to the axis on quiet days.
        let tools = Set(perTool.keys)
        var slot = range == .day ? cal.dateInterval(of: .hour, for: start)!.start : cal.startOfDay(for: start)
        while slot <= now {
            for tool in tools {
                let key = "\(slot.timeIntervalSince1970)|\(tool.rawValue)"
                if series[key] == nil { series[key] = (slot, tool, 0, 0) }
            }
            slot = slot.addingTimeInterval(range.step)
        }
        s.points = series.values.map { Point(date: $0.0, tool: $0.1, tokens: $0.2, cost: $0.3) }.sorted { $0.date < $1.date }
        s.tools = perTool.values.sorted { $0.tokens > $1.tokens }
        s.models = perModel.values.sorted { ($0.cost ?? -1, $0.tokens) > ($1.cost ?? -1, $1.tokens) }
        return s
    }
}
