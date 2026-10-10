import SwiftUI

/// "+" in the agents list: pick a tool and a project, type the task, and it starts in your terminal.
struct NewSessionView: View {
    @Environment(IslandModel.self) private var model
    @Environment(Settings.self) private var settings
    @State private var choosingFolder = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private let kinds: [AgentKind] = [.claude, .codex, .cursor]
    private var folder: String? { model.draftFolder ?? Launcher.recentFolders().first }
    private var canStart: Bool { folder != nil && Launcher.isAvailable(settings.launchAgent) }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { model.composing = false } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .help("All agents")
                Text("New session").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                ForEach(kinds, id: \.self) { kind in agentChip(kind) }
            }

            folderPicker

            TextField("What should it work on?", text: $model.draftPrompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.primary)
                .lineLimit(3...8)
                .focused($focused)
                .onSubmit(start)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.fill))
                .acceptsImages($model.draftImages)

            AttachmentStrip(images: $model.draftImages)

            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                destinationSwitch
                Spacer(minLength: 4)
                AttachButton(images: $model.draftImages, size: 32)
                Button(action: start) {
                    HStack(spacing: 6) {
                        Text("Start")
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 32))
                .fixedSize()
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canStart)
                .opacity(canStart ? 1 : 0.4)
            }
        }
        .padding(20)
        // While you're writing, moving the mouse away doesn't close the card (a click outside still does).
        .onChange(of: focused) { updateEditing() }
        .onChange(of: model.draftPrompt) { updateEditing() }
        .onChange(of: model.draftImages) { updateEditing() }
        .onDisappear { model.editing = false }
        .onAppear {
            if !Launcher.isAvailable(settings.launchAgent), let k = kinds.first(where: Launcher.isAvailable) { settings.launchAgent = k }
            DispatchQueue.main.async { focused = true }
        }
    }

    /// App / Terminal: where this session opens. Only one side shows when the tool has just one.
    @ViewBuilder
    private var destinationSwitch: some View {
        let kind = settings.launchAgent
        let inApp = Launcher.opensInApp(kind)
        let both = Launcher.hasApp(kind) && Launcher.hasCLI(kind)
        HStack(spacing: 2) {
            if Launcher.hasApp(kind) { destinationChip(kind == .claude ? "Claude app" : "\(kind.label) app", selected: inApp) { settings.launchInApp = true } }
            if Launcher.hasCLI(kind) { destinationChip(settings.launchTerminal.label, selected: !inApp) { settings.launchInApp = false } }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(both ? Theme.fill : .clear))
        .help("Where the session opens")
    }

    private func destinationChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? Theme.primary : Theme.tertiary)
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule(style: .continuous).fill(selected ? Theme.fillStrong : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func updateEditing() {
        model.editing = focused || !model.draftPrompt.isEmpty || !model.draftImages.isEmpty
    }

    private func agentChip(_ kind: AgentKind) -> some View {
        let selected = settings.launchAgent == kind
        let available = Launcher.isAvailable(kind)
        return Button { settings.launchAgent = kind; error = nil } label: {
            HStack(spacing: 6) {
                AgentLogo(kind: kind, size: 15)
                Text(kind == .claude ? "Claude Code" : kind.label).font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(selected ? Theme.primary : Theme.secondary)
            .padding(.horizontal, 12).frame(height: 32).frame(maxWidth: .infinity)
            .background(Capsule(style: .continuous).fill(selected ? Theme.fillStrong : Theme.fill))
            .overlay(Capsule(style: .continuous).strokeBorder(selected ? Theme.primary.opacity(0.25) : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
        .help(available ? "" : "\(kind.label) isn't installed")
    }

    /// The folder, and (tapped) your recent projects plus "Other folder…".
    @ViewBuilder
    private var folderPicker: some View {
        VStack(spacing: 2) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { choosingFolder.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Theme.secondary).frame(width: 18)
                    if let folder {
                        Text((folder as NSString).lastPathComponent).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.primary)
                        Text(abbreviate((folder as NSString).deletingLastPathComponent)).font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.head)
                    } else {
                        Text("Choose a project folder").font(.system(size: 13.5)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
                        .rotationEffect(.degrees(choosingFolder ? 180 : 0))
                }
                .padding(.horizontal, 12).frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if choosingFolder {
                ForEach(Launcher.recentFolders().filter { $0 != folder }.prefix(5), id: \.self) { f in
                    folderRow(icon: "clock", title: (f as NSString).lastPathComponent, detail: abbreviate((f as NSString).deletingLastPathComponent)) {
                        model.draftFolder = f
                        choosingFolder = false
                    }
                }
                folderRow(icon: "folder.badge.plus", title: "Other folder…", detail: "") { chooseFolder() }
            }
        }
        .padding(.bottom, choosingFolder ? 4 : 0)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.fill))
    }

    private func folderRow(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.tertiary).frame(width: 18)
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.primary)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverRow(radius: 10)
        .padding(.horizontal, 4)
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.canCreateDirectories = true
        open.prompt = "Choose"
        open.message = "Pick the project the agent should work in"
        if let folder { open.directoryURL = URL(fileURLWithPath: folder).deletingLastPathComponent() }
        // Above the notch, and keep the card open while the mouse is over the picker.
        open.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        model.holdOpen = true
        NSApp.activate(ignoringOtherApps: true)
        open.begin { response in
            model.holdOpen = false
            if response == .OK, let url = open.url {
                model.draftFolder = url.path
                choosingFolder = false
            }
            NSApp.windows.first { $0 is NotchPanel }?.makeKeyAndOrderFront(nil)
            focused = true
        }
    }

    private func start() {
        guard canStart, let folder else { return }
        let prompt = model.draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = settings.launchAgent
        switch Launcher.launch(kind, folder: folder, prompt: prompt, images: model.draftImages) {
        case .success(let id):
            model.draftPrompt = ""
            model.draftImages = []
            model.draftFolder = folder
            model.composing = false
            if let id {
                model.selectedSessionID = id
            } else {
                model.showingList = true
            }
        case .failure(.notInstalled(let k)):
            error = "Couldn't find the \(k.label) command line tool."
        case .failure(.terminalFailed(let why)):
            error = "Couldn't open \(settings.launchTerminal.label): \(why)"
        }
    }
}
