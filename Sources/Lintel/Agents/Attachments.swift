import AppKit
import UniformTypeIdentifiers

/// Images you add to a new chat or a reply. None of the agents takes a picture from outside their own window,
/// so each image is a file on disk and its path goes into the message; the agent opens it from there.
@MainActor
enum Attachments {
    /// Pasted images are saved here (picked or dropped files are used where they are).
    static let dir = AgentHooks.dir.appendingPathComponent("attachments")

    /// How long a pasted image is kept: long enough for the agent to open it, then it's gone.
    static let keepFor: TimeInterval = 6 * 3600

    /// Deletes pasted images older than `keepFor` — only files in Lintel's own attachments folder.
    /// Runs at launch and every hour.
    static func cleanUp() {
        let cutoff = Date().addingTimeInterval(-keepFor)
        let dir = dir
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for f in files {
                let created = (try? f.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
                if created < cutoff { try? fm.removeItem(at: f) }
            }
        }
    }

    private static var cleanupTimer: Timer?
    static func startCleanup() {
        cleanUp()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { cleanUp() }
        }
    }

    static func isImage(_ url: URL) -> Bool {
        (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) ?? false
    }

    /// The image on the clipboard, if any: copied image files first, else raw image data saved as a PNG.
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> [URL] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.filter(isImage)
            if !images.isEmpty { return images }
        }
        guard pb.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: pb), let url = save(image) else { return [] }
        return [url]
    }

    private static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appendingPathComponent("pasted-\(f.string(from: Date()))-\(UUID().uuidString.prefix(4)).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    /// The file picker, kept above the notch; the card stays open while it's up.
    static func pick(_ done: @escaping ([URL]) -> Void) {
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = false
        open.allowsMultipleSelection = true
        open.allowedContentTypes = [.image]
        open.prompt = "Attach"
        open.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        let model = IslandModel.shared
        model.holdOpen = true
        NSApp.activate(ignoringOtherApps: true)
        open.begin { response in
            model.holdOpen = false
            NSApp.windows.first { $0 is NotchPanel }?.makeKeyAndOrderFront(nil)
            done(response == .OK ? open.urls : [])
        }
    }

    /// The message with the images' paths after it.
    static func message(_ text: String, _ images: [URL]) -> String {
        guard !images.isEmpty else { return text }
        let list = images.map { "- \($0.path)" }.joined(separator: "\n")
        let head = images.count == 1 ? "Attached image (open it to see it):" : "Attached images (open them to see them):"
        return (text.isEmpty ? "" : text + "\n\n") + head + "\n" + list
    }
}

extension Notification.Name {
    /// ⌘V with an image on the clipboard while the notch has focus; the object is [URL].
    static let lintelPastedImages = Notification.Name("LintelPastedImages")
}
