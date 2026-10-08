import Foundation

/// Installs / removes Lintel's entries in ~/.claude/settings.json.
/// The bridge script fails open: if Lintel isn't running, Claude Code behaves exactly as before.
enum ClaudeHooks {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lintel")
    static let scriptURL = dir.appendingPathComponent("claude-hook.sh")
    static let tokenURL = dir.appendingPathComponent("token")
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    static let marker = ".lintel/claude-hook.sh"

    /// Events we listen to, with the hook timeout Claude Code should allow (seconds).
    static let events: [(String, Int)] = [
        ("SessionStart", 5), ("UserPromptSubmit", 5), ("PreToolUse", 5), ("PostToolUse", 5),
        ("Notification", 5), ("PermissionRequest", 86_400), ("Stop", 600), ("SessionEnd", 5),
    ]

    static let script = """
    #!/bin/sh
    # Lintel bridge for Claude Code hooks. Fails open: if Lintel is not running, nothing changes.
    EVENT="$1"
    TOKEN=$(cat "$HOME/.lintel/token" 2>/dev/null) || exit 0
    case "$EVENT" in
      PermissionRequest|Stop) MAX=86400 ;;
      *) MAX=2 ;;
    esac
    /usr/bin/curl -s --max-time "$MAX" -X POST \\
      -H "X-Lintel-Token: $TOKEN" -H "X-Lintel-PPID: $PPID" -H "X-Lintel-Term: ${TERM_PROGRAM:-}" \\
      -H "Content-Type: application/json" --data-binary @- \\
      "http://127.0.0.1:\(HookServer.port)/claude/$EVENT" 2>/dev/null
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

    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsURL), let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains(marker) && FileManager.default.fileExists(atPath: scriptURL.path)
    }

    static func writeScript() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        _ = token()
    }

    static func install() throws {
        try writeScript()
        var root = try loadSettings()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = scriptURL.path
        for (event, timeout) in events {
            var entries = stripped(hooks[event])
            entries.append([
                "matcher": "*",
                "hooks": [["type": "command", "command": "\(command) \(event)", "timeout": timeout]],
            ])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        try save(root)
    }

    static func uninstall() throws {
        var root = try loadSettings()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            let entries = stripped(hooks[key])
            if entries.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = entries }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try save(root)
    }

    /// Existing hook entries for an event, minus any Lintel ones.
    private static func stripped(_ value: Any?) -> [[String: Any]] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return entry }
            let kept = inner.filter { !(($0["command"] as? String) ?? "").contains(marker) }
            if kept.isEmpty { return nil }
            var e = entry
            e["hooks"] = kept
            return e
        }
    }

    private static func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Lintel", code: 1, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json is not a JSON object — not touching it."])
        }
        return obj
    }

    private static func save(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = settingsURL.appendingPathExtension("lintel-backup")
        if fm.fileExists(atPath: settingsURL.path) {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
