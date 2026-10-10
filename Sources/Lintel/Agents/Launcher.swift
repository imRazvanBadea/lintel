import AppKit

/// The terminal new sessions open in.
enum LaunchTerminal: String, CaseIterable, Identifiable {
    case terminal, iterm, ghostty
    var id: String { rawValue }

    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .ghostty: "Ghostty"
        }
    }
    var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        }
    }
    /// What the shell reports as TERM_PROGRAM there (Lintel finds the session's app by it).
    var termProgram: String {
        switch self {
        case .terminal: "Apple_Terminal"
        case .iterm: "iTerm.app"
        case .ghostty: "ghostty"
        }
    }
    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var isInstalled: Bool { appURL != nil }
}

/// Starts a new agent session from the notch: the tool's own CLI, in your terminal, in the folder you
/// picked, with your prompt as the first message. Its hooks then report it like any other session,
/// so the feed, questions and "Jump to session" all work as usual.
@MainActor
enum Launcher {
    enum Failure: Error { case notInstalled(AgentKind), terminalFailed(String) }

    /// The CLI each tool ships (Cursor's is `cursor-agent`).
    private static func command(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "cursor-agent"
        }
    }

    private static var found: [AgentKind: String] = [:]

    /// Common install locations first; anything else is looked up once through a login shell.
    static func locateCLIs() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local",
                    "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin"]
        var missing: [AgentKind] = []
        for kind in [AgentKind.claude, .codex, .cursor] {
            if let p = dirs.map({ "\($0)/\(command(kind))" }).first(where: FileManager.default.isExecutableFile) {
                found[kind] = p
            } else {
                missing.append(kind)
            }
        }
        guard !missing.isEmpty else { return }
        let names = missing.map(command)
        DispatchQueue.global(qos: .utility).async {
            var paths: [String: String] = [:]
            for name in names {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", "command -v \(name)"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { continue }
                p.waitUntilExit()
                let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if p.terminationStatus == 0, s.hasPrefix("/") { paths[name] = s }
            }
            DispatchQueue.main.async {
                for kind in missing { if let p = paths[command(kind)] { found[kind] = p } }
            }
        }
    }

    static func hasCLI(_ kind: AgentKind) -> Bool { found[kind] != nil }

    /// The desktop app that can start a session from a link (Codex's app ships as "ChatGPT").
    static func appBundleID(_ kind: AgentKind) -> String? {
        switch kind {
        case .claude: "com.anthropic.claudefordesktop"
        case .cursor: AgentStore.cursorBundleID
        case .codex: "com.openai.codex"
        }
    }

    static func hasApp(_ kind: AgentKind) -> Bool {
        appBundleID(kind).flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } != nil
    }

    static func isAvailable(_ kind: AgentKind) -> Bool { hasCLI(kind) || hasApp(kind) }

    /// Where `kind` will open: its app when you prefer apps (or it has no CLI), otherwise the terminal.
    static func opensInApp(_ kind: AgentKind) -> Bool {
        hasApp(kind) && (Settings.shared.launchInApp || !hasCLI(kind))
    }

    // MARK: Recent folders

    private static let recentsKey = "recentProjects"

    /// Folders you started sessions in, newest first, plus the ones agents are running in now.
    static func recentFolders() -> [String] {
        let saved = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        let live = AgentStore.shared.sessions.sorted { $0.lastEventAt > $1.lastEventAt }.map(\.cwd)
        var seen = Set<String>()
        return (saved + live).filter {
            !$0.isEmpty && !$0.hasPrefix(AgentHooks.dir.path) && seen.insert($0).inserted
                && FileManager.default.fileExists(atPath: $0)
        }.prefix(8).map { $0 }
    }

    private static func remember(_ folder: String) {
        var saved = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        saved.removeAll { $0 == folder }
        saved.insert(folder, at: 0)
        UserDefaults.standard.set(Array(saved.prefix(12)), forKey: recentsKey)
    }

    // MARK: Launch

    /// A launched Codex / Cursor session whose id we learn only once it reports in.
    private struct Expected { let kind: AgentKind; let folder: String; let known: Set<String>; let at: Date; let terminal: LaunchTerminal? }
    private static var expected: [Expected] = []

    /// Returns the session id when it is known up front (Claude Code takes one on the command line).
    static func launch(_ kind: AgentKind, folder: String, prompt: String, images: [URL] = []) -> Result<String?, Failure> {
        // The apps only take text from outside, so images travel as paths in the message.
        // A prompt starting with "-" would be read by the CLI as an option; a leading space keeps it a message.
        let prompt = prompt.hasPrefix("-") ? " " + prompt : prompt
        let message = Attachments.message(prompt, images)
        remember(folder)
        let terminal = Settings.shared.launchTerminal

        let store = AgentStore.shared
        if opensInApp(kind) {
            switch kind {
            case .claude: openInClaudeApp(folder: folder, prompt: message)
            case .cursor: openInCursorApp(folder: folder, prompt: message)
            case .codex: openInCodexApp(folder: folder, prompt: message)
            }
            expected.append(Expected(kind: kind, folder: folder, known: Set(store.sessions.map(\.id)), at: Date(), terminal: nil))
            return .success(nil)
        }
        guard let exe = found[kind] else { return .failure(.notInstalled(kind)) }

        var args: [String] = []
        var sessionID: String?
        if kind == .claude {
            let id = UUID().uuidString.lowercased()
            args += ["--session-id", id]
            sessionID = id
        }
        if kind == .codex {
            // The Codex CLI attaches images itself.
            for i in images { args.append("--image=\(i.path)") } // "=" so the prompt isn't read as another image
            if !prompt.isEmpty { args.append(prompt) }
        } else if !message.isEmpty {
            args.append(message)
        }

        do {
            try openInTerminal(terminal, folder: folder, exe: exe, args: args)
        } catch let f as Failure {
            return .failure(f)
        } catch {
            return .failure(.terminalFailed(error.localizedDescription))
        }

        if let sessionID {
            // Show it right away; its hooks fill in the rest as they arrive.
            let s = store.session(id: sessionID, kind: kind)
            s.cwd = folder
            s.refreshBranch()
            s.launchedIn = terminal
            s.termProgram = terminal.termProgram
            s.lastEventAt = Date()
            s.beginTurn(prompt: prompt.isEmpty ? nil : prompt)
            if message.isEmpty { s.status = .idle }
        } else {
            expected.append(Expected(kind: kind, folder: folder, known: Set(store.sessions.map(\.id)), at: Date(), terminal: terminal))
        }
        return .success(sessionID)
    }

    /// Called when the session list changes: picks up the Codex / Cursor session a launch started.
    /// Returns its id so the card can open it.
    static func claimLaunched() -> String? {
        expected.removeAll { Date().timeIntervalSince($0.at) > 120 }
        for (i, e) in expected.enumerated() {
            let folder = URL(fileURLWithPath: e.folder).standardizedFileURL.path
            guard let s = AgentStore.shared.sessions.first(where: {
                !e.known.contains($0.id) && $0.parentID == nil && ($0.kind == e.kind || e.kind == .cursor)
                    && inside($0.cwd, folder)
            }) else { continue }
            s.launchedIn = e.terminal
            expected.remove(at: i)
            return s.id
        }
        return nil
    }

    /// The folder itself or somewhere in it (the Claude app may run a session in a worktree inside the project).
    private static func inside(_ cwd: String, _ folder: String) -> Bool {
        let c = URL(fileURLWithPath: cwd).standardizedFileURL.path
        return c == folder || c.hasPrefix(folder + "/")
    }

    /// Writes a one-off script (cd, run the agent, then leave you in your shell) and opens it in the terminal.
    private static func openInTerminal(_ terminal: LaunchTerminal, folder: String, exe: String, args: [String]) throws {
        guard let app = (terminal.isInstalled ? terminal : .terminal).appURL else { throw Failure.terminalFailed("No terminal app found") }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

        let dir = AgentHooks.dir.appendingPathComponent("launch")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("\(UUID().uuidString).command")
        let body = """
        #!/bin/zsh -l
        rm -f -- "$0"
        # Don't hand the agent markers from wherever Lintel itself was started (e.g. inside a Claude Code session).
        unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SSE_PORT AI_AGENT
        clear
        cd -- \(q(folder)) || exit 1
        \(([exe] + args).map(q).joined(separator: " "))
        exec "${SHELL:-/bin/zsh}" -l

        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false // stay in the notch; "Jump to session" brings the terminal forward
        if terminal == .ghostty && terminal.isInstalled {
            config.createsNewApplicationInstance = true
            config.arguments = ["-e", script.path]
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
                if let error { NSLog("Lintel: launch failed: \(error)") }
            }
        } else {
            NSWorkspace.shared.open([script], withApplicationAt: app, configuration: config) { _, error in
                if let error { NSLog("Lintel: launch failed: \(error)") }
            }
        }
    }

    /// A new Claude Code session in the Claude app, in that folder, with the prompt in its composer.
    private static func openInClaudeApp(folder: String, prompt: String) {
        var c = URLComponents(string: "claude://code/new")!
        c.queryItems = (prompt.isEmpty ? [] : [URLQueryItem(name: "q", value: prompt)])
            + [URLQueryItem(name: "folder", value: folder), URLQueryItem(name: "source", value: "lintel")]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    /// A new Codex thread in that folder, with the prompt in its composer.
    private static func openInCodexApp(folder: String, prompt: String) {
        var c = URLComponents(string: "codex://threads/new")!
        c.queryItems = [URLQueryItem(name: "path", value: folder)] + (prompt.isEmpty ? [] : [URLQueryItem(name: "prompt", value: prompt)])
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    /// Opens the folder in Cursor's Agents window (`cursor --glass`), then hands it the prompt through its
    /// deeplink, which fills in whichever Cursor window is in front.
    private static func openInCursorApp(folder: String, prompt: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentStore.cursorBundleID) else { return }
        let sendPrompt: @MainActor @Sendable () -> Void = {
            guard !prompt.isEmpty else { return }
            var c = URLComponents(string: "cursor://anysphere.cursor-deeplink/prompt")!
            c.queryItems = [URLQueryItem(name: "text", value: prompt)]
            if let url = c.url {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSWorkspace.shared.open(url) }
            }
        }
        let cli = app.appendingPathComponent("Contents/Resources/app/bin/cursor")
        let p = Process()
        p.executableURL = cli
        p.arguments = ["--glass", folder]
        p.environment = ProcessInfo.processInfo.environment.filter { k, _ in !k.hasPrefix("VSCODE_") && !k.hasPrefix("ELECTRON_") }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in DispatchQueue.main.async(execute: sendPrompt) }
        do {
            try p.run()
        } catch {
            // No launcher script: the editor window will have to do.
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            sendPrompt()
        }
    }
}
