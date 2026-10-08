import Foundation

/// Installs / removes Lintel's hooks in Claude Code (~/.claude/settings.json) and Cursor (~/.cursor/hooks.json).
/// The bridge script fails open: if Lintel isn't running, the agent behaves exactly as before.
enum AgentHooks {
    enum Target: String, CaseIterable {
        case claude, cursor

        var name: String { self == .claude ? "Claude Code" : "Cursor" }
        var configURL: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return self == .claude ? home.appendingPathComponent(".claude/settings.json")
                                   : home.appendingPathComponent(".cursor/hooks.json")
        }
        /// Whether the agent seems to be installed at all.
        var isAvailable: Bool {
            let fm = FileManager.default
            return fm.fileExists(atPath: configURL.deletingLastPathComponent().path)
        }
        /// Events and the timeout (seconds) the agent should allow the hook.
        var events: [(String, Int)] {
            switch self {
            case .claude:
                [("SessionStart", 5), ("UserPromptSubmit", 5), ("PreToolUse", 5), ("PostToolUse", 5),
                 ("Notification", 5), ("PermissionRequest", 86_400), ("Stop", 600), ("SessionEnd", 5)]
            case .cursor:
                [("sessionStart", 5), ("beforeSubmitPrompt", 5), ("preToolUse", 5), ("afterAgentThought", 5),
                 ("afterAgentResponse", 5), ("beforeShellExecution", 3_600), ("stop", 600), ("sessionEnd", 5)]
            }
        }
    }

    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lintel")
    static let scriptURL = dir.appendingPathComponent("hook.sh")
    static let tokenURL = dir.appendingPathComponent("token")
    static let marker = ".lintel/"

    static let script = """
    #!/bin/sh
    # Lintel bridge for agent hooks: hook.sh <claude|cursor> <event>
    # Fails open: if Lintel is not running, nothing changes.
    AGENT="$1"; EVENT="$2"
    TOKEN=$(cat "$HOME/.lintel/token" 2>/dev/null) || exit 0
    case "$EVENT" in
      PermissionRequest|Stop|stop|beforeShellExecution) MAX=86400 ;;
      *) MAX=2 ;;
    esac
    /usr/bin/curl -s --max-time "$MAX" -X POST \\
      -H "X-Lintel-Token: $TOKEN" -H "X-Lintel-PPID: $PPID" -H "X-Lintel-Term: ${TERM_PROGRAM:-}" \\
      -H "Content-Type: application/json" --data-binary @- \\
      "http://127.0.0.1:\(HookServer.port)/$AGENT/$EVENT" 2>/dev/null
    exit 0
    """

    /// Shared secret so other local processes can't drive the notch.
    static func token() -> String {
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        let t = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? t.write(to: tokenURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return t
    }

    static func isInstalled(_ t: Target) -> Bool {
        guard let s = try? String(contentsOf: t.configURL, encoding: .utf8) else { return false }
        return s.contains(scriptURL.path) && FileManager.default.fileExists(atPath: scriptURL.path)
    }

    static func writeScript() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        _ = token()
    }

    static func install(_ t: Target) throws {
        try writeScript()
        var root = try load(t)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in t.events {
            var entries = stripped(hooks[event], target: t)
            let command = "\(scriptURL.path) \(t.rawValue) \(event)"
            switch t {
            case .claude:
                entries.append(["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": timeout]]])
            case .cursor:
                entries.append(["command": command, "timeout": timeout])
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks
        if t == .cursor, root["version"] == nil { root["version"] = 1 }
        try save(root, to: t)
    }

    static func uninstall(_ t: Target) throws {
        var root = try load(t)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            let entries = stripped(hooks[key], target: t)
            if entries.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = entries }
        }
        if hooks.isEmpty && t == .claude { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try save(root, to: t)
    }

    /// Existing hook entries for an event, minus any Lintel ones.
    private static func stripped(_ value: Any?, target: Target) -> [[String: Any]] {
        guard let entries = value as? [[String: Any]] else { return [] }
        let isOurs: ([String: Any]) -> Bool = { (($0["command"] as? String) ?? "").contains(marker) }
        switch target {
        case .cursor:
            return entries.filter { !isOurs($0) }
        case .claude:
            return entries.compactMap { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return entry }
                let kept = inner.filter { !isOurs($0) }
                if kept.isEmpty { return nil }
                var e = entry
                e["hooks"] = kept
                return e
            }
        }
    }

    private static func load(_ t: Target) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: t.configURL.path) else { return [:] }
        let data = try Data(contentsOf: t.configURL)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Lintel", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(t.configURL.path) is not a JSON object — not touching it."])
        }
        return obj
    }

    private static func save(_ root: [String: Any], to t: Target) throws {
        let fm = FileManager.default
        let url = t.configURL
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("lintel-backup")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
