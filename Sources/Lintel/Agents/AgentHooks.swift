import AppKit

/// Installs / removes Lintel's hooks in Claude Code (~/.claude/settings.json) and Cursor (~/.cursor/hooks.json).
/// The bridge script fails open: if Lintel isn't running, the agent behaves exactly as before.
enum AgentHooks {
    enum Target: String, CaseIterable {
        case claude, cursor, codex

        var name: String {
            switch self {
            case .claude: "Claude Code"
            case .cursor: "Cursor"
            case .codex: "Codex"
            }
        }
        var configURL: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claude: return home.appendingPathComponent(".claude/settings.json")
            case .cursor: return home.appendingPathComponent(".cursor/hooks.json")
            case .codex: return AgentHooks.codexHome.appendingPathComponent("hooks.json")
            }
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
                [("sessionStart", 5), ("beforeSubmitPrompt", 5), ("preToolUse", 5), ("postToolUse", 5),
                 ("postToolUseFailure", 5), ("afterAgentThought", 5),
                 ("afterAgentResponse", 5), ("beforeShellExecution", 3_600), ("stop", 600), ("sessionEnd", 5)]
            case .codex:
                // Activity comes from Codex's session logs; hooks add what logs can't: approvals and replies.
                [("SessionStart", 5), ("UserPromptSubmit", 5), ("PermissionRequest", 86_400), ("Stop", 600)]
            }
        }
    }

    /// Honours CODEX_HOME like Codex itself does.
    static var codexHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lintel")
    /// The compiled hook helper (Sources/LintelHook), copied here so hooks keep working if the app moves.
    static let helperURL = dir.appendingPathComponent("bin/lintel-hook")
    static let tokenURL = dir.appendingPathComponent("token")
    static let marker = ".lintel/"

    /// The helper shipped inside the app bundle (or next to the binary in development builds).
    private static var bundledHelper: URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [exe.deletingLastPathComponent().appendingPathComponent("lintel-hook")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

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
        return s.contains(helperURL.path) && FileManager.default.isExecutableFile(atPath: helperURL.path)
    }

    /// Copies the hook helper out of the app bundle (when it changed) and drops files from older versions.
    static func installHelper() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let src = bundledHelper, !fm.contentsEqual(atPath: src.path, andPath: helperURL.path) {
            try? fm.removeItem(at: helperURL)
            try fm.copyItem(at: src, to: helperURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        }
        for old in ["hook.sh", "token-header", "claude-hook.sh"] { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
        _ = token()
    }

    static func install(_ t: Target) throws {
        try installHelper()
        var root = try load(t)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in t.events {
            var entries = stripped(hooks[event], target: t)
            let command = "\(helperURL.path) \(t.rawValue) \(event)"
            switch t {
            case .claude, .codex:
                entries.append(["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": timeout]]])
            case .cursor:
                entries.append(["command": command, "timeout": timeout])
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks
        if t == .cursor, root["version"] == nil { root["version"] = 1 }
        if t == .codex { try enableCodexHooksFeature() }
        // Claude Code hands its status line command the plan usage (5-hour / weekly, with reset times).
        // Only claim the status line if you don't already have one; Lintel prints nothing, so it stays empty.
        if t == .claude, let sl = root["statusLine"] as? [String: Any], ((sl["command"] as? String) ?? "").contains(marker) {
            root.removeValue(forKey: "statusLine") // ours, from an older version — re-added below
        }
        if t == .claude, root["statusLine"] == nil {
            root["statusLine"] = ["type": "command", "command": "\(helperURL.path) claude StatusLine", "padding": 0]
        }
        try save(root, to: t)
    }

    static func uninstall(_ t: Target) throws {
        var root = try load(t)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            let entries = stripped(hooks[key], target: t)
            if entries.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = entries }
        }
        if hooks.isEmpty && t != .cursor { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        if let sl = root["statusLine"] as? [String: Any], ((sl["command"] as? String) ?? "").contains(marker) {
            root.removeValue(forKey: "statusLine")
        }
        try save(root, to: t)
    }

    /// Existing hook entries for an event, minus any Lintel ones.
    private static func stripped(_ value: Any?, target: Target) -> [[String: Any]] {
        guard let entries = value as? [[String: Any]] else { return [] }
        let isOurs: ([String: Any]) -> Bool = { (($0["command"] as? String) ?? "").contains(marker) }
        switch target {
        case .cursor:
            return entries.filter { !isOurs($0) }
        case .claude, .codex:
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

    // MARK: Codex

    /// Codex only runs hooks with `hooks = true` under `[features]` in config.toml.
    static func enableCodexHooksFeature() throws {
        let url = codexHome.appendingPathComponent("config.toml")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = text.components(separatedBy: "\n")
        if let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[features]") }) {
            // Look within the [features] table (up to the next table header).
            let end = lines[(header + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            var section = Array(lines[(header + 1)..<end])
            if let i = section.firstIndex(where: { $0.range(of: #"^\s*(codex_)?hooks\s*="#, options: .regularExpression) != nil }) {
                if section[i].contains("true") && !section[i].contains("codex_hooks") { return }
                section[i] = "hooks = true"
            } else {
                section.insert("hooks = true", at: 0)
            }
            text = (Array(lines[...header]) + section + Array(lines[end...])).joined(separator: "\n")
        } else {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += "\n[features]\nhooks = true\n"
        }
        let backup = url.appendingPathExtension("lintel-backup")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    enum CodexReadiness: Equatable { case approved, needsApproval, notRegistered, unknown }

    /// Opens Terminal with Codex running so you can approve Lintel's hooks (`/hooks`). Uses a .command file,
    /// so it needs no extra permissions.
    @MainActor static func openCodexForApproval() {
        guard let exe = codexExecutable else { return }
        let url = dir.appendingPathComponent("approve-codex-hooks.command")
        let script = """
        #!/bin/sh
        clear
        echo "Lintel: type /hooks, approve Lintel's hooks, then quit Codex (Ctrl-C) and start a new chat."
        echo
        exec '\(exe.replacingOccurrences(of: "'", with: "'\\''"))'
        """
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    /// The Codex command-line binary (bundled with the Codex / ChatGPT desktop app, or on PATH).
    static var codexExecutable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
                "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Codex runs new hooks only after you approve them (`/hooks` in the Codex CLI). Asks Codex's own
    /// app server for the hook list — no thread is started and no hooks run.
    static func codexReadiness(completion: @escaping @Sendable (CodexReadiness) -> Void) {
        guard let exe = codexExecutable else { completion(.unknown); return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["app-server", "--stdio"]
            p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            var env = ProcessInfo.processInfo.environment
            env["CODEX_HOME"] = codexHome.path
            p.environment = env
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = FileHandle.nullDevice
            let lines = LineBuffer()
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result = CodexReadiness.unknown
            output.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { return }
                for line in lines.append(chunk) {
                    guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    if d["id"] as? Int == 1 {
                        let msgs: [[String: Any]] = [["method": "initialized", "params": [String: Any]()],
                                                     ["id": 2, "method": "hooks/list", "params": ["cwds": [FileManager.default.homeDirectoryForCurrentUser.path]]]]
                        for m in msgs {
                            if let data = try? JSONSerialization.data(withJSONObject: m) { try? input.fileHandleForWriting.write(contentsOf: data + Data([10])) }
                        }
                    } else if d["id"] as? Int == 2 {
                        let entries = ((d["result"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
                        let ours = entries.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
                            .filter { (($0["command"] as? String) ?? "").contains(helperURL.path) }
                        if ours.isEmpty { result = .notRegistered }
                        else if ours.contains(where: { ["untrusted", "modified"].contains($0["trustStatus"] as? String ?? "") }) { result = .needsApproval }
                        else if ours.allSatisfy({ ["trusted", "managed"].contains($0["trustStatus"] as? String ?? "") }) { result = .approved }
                        done.signal()
                    }
                }
            }
            do {
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                try p.run()
                let hello: [String: Any] = ["id": 1, "method": "initialize",
                                            "params": ["clientInfo": ["name": "lintel", "version": "1.0"],
                                                       "capabilities": ["experimentalApi": true]]]
                try input.fileHandleForWriting.write(contentsOf: try JSONSerialization.data(withJSONObject: hello) + Data([10]))
                _ = done.wait(timeout: .now() + 8)
            } catch {}
            output.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
            completion(result)
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
