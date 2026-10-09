import Foundation
import SQLite3

/// Finds the short title each tool generates for a conversation ("Shape edge refinement"),
/// instead of showing the first words of your prompt.
///  - Claude (desktop app): ~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json
///  - Cursor: the composer name in Cursor's state.vscdb
///  - Codex: thread names from ~/.codex/session_index.jsonl (handled by CodexWatcher)
/// Plain Claude Code in a terminal doesn't generate titles; those fall back to the prompt.
final class TitleResolver: @unchecked Sendable {
    static let shared = TitleResolver()
    private let queue = DispatchQueue(label: "lintel.titles", qos: .utility)

    private let claudeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    private let cursorDB = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")

    /// cliSessionId -> metadata file. Rebuilt when a session isn't found (at most every 10 s).
    private var claudeIndex: [String: URL] = [:]
    private var lastIndexed = Date.distantPast

    func title(for id: String, kind: AgentKind, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            let t: String?
            switch kind {
            case .claude: t = self.claudeTitle(id)
            case .cursor: t = self.cursorTitle(id)
            case .codex: t = nil
            }
            completion(t?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        }
    }

    // MARK: Claude desktop

    /// The Claude app's own id for a Claude Code session ("local_…"), used by its claude://code/continue link.
    func claudeDesktopSessionID(for cliID: String, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            if self.claudeIndex[cliID] == nil { self.indexClaude() }
            guard let url = self.claudeIndex[cliID],
                  let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { completion(nil); return }
            completion(obj["sessionId"] as? String)
        }
    }

    private func claudeTitle(_ id: String) -> String? {
        if claudeIndex[id] == nil, Date().timeIntervalSince(lastIndexed) > 10 { indexClaude() }
        guard let url = claudeIndex[id],
              let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj["title"] as? String
    }

    private func indexClaude() {
        lastIndexed = Date()
        guard let e = FileManager.default.enumerator(at: claudeDir, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in e where url.pathExtension == "json" {
            // cliSessionId sits near the top of the file; no need to parse the whole thing.
            guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
            let head = (try? fh.read(upToCount: 1024)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            try? fh.close()
            if let r = head.range(of: #""cliSessionId"\s*:\s*"([^"]+)""#, options: .regularExpression) {
                let m = head[r]
                if let q = m.range(of: #""[^"]+"$"#, options: .regularExpression) {
                    claudeIndex[String(m[q].dropFirst().dropLast())] = url
                }
            }
        }
    }

    // MARK: Cursor

    private func cursorTitle(_ id: String) -> String? {
        var db: OpaquePointer?
        let uri = "file:\(cursorDB.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var stmt: OpaquePointer?
        let sql = "SELECT json_extract(value, '$.name') FROM cursorDiskKV WHERE key = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let key = "composerData:\(id)"
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
