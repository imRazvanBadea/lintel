import AppKit

/// Runs the MediaRemote bridge (Bridge/LintelNowPlaying.m) inside /usr/bin/perl and streams its output.
/// See the bridge source for why it has to live in a platform binary.
@MainActor
final class NowPlayingBridge {
    struct Snapshot {
        var bundleID: String
        var playing: Bool
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var elapsed: Double
        var timestamp: Date
        var artworkKey: String
        var artwork: Data?
        var queue: [Track]
    }

    var onState: ((Snapshot?) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restarts = 0

    private static let perlScript = """
    use DynaLoader;
    my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $s = DynaLoader::dl_find_symbol($l, "lintel_np_run") or die "symbol";
    DynaLoader::dl_install_xsub("main::run", $s);
    run();
    """

    private var libraryPath: String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("libLintelNowPlaying.dylib").path,
            // `swift run` / development: the build script puts it in ./build
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("../../../build/libLintelNowPlaying.dylib").standardized.path,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func start() {
        guard process == nil, let lib = libraryPath else {
            if libraryPath == nil { NSLog("Lintel: now-playing bridge library not found") }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.perlScript, lib]
        let out = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardInput = inPipe
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { self?.received(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.terminated() }
        }
        do {
            try p.run()
            process = p
            input = inPipe.fileHandleForWriting
        } catch {
            NSLog("Lintel: could not start now-playing bridge: \(error)")
        }
    }

    func send(_ command: String) {
        try? input?.write(contentsOf: Data((command + "\n").utf8))
    }

    private func terminated() {
        process = nil
        input = nil
        buffer.removeAll()
        guard restarts < 5 else { return }
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            parse(Data(line))
        }
    }

    /// WebKit plays media from its GPU helper ("<App> Graphics and Media"), so for web views and
    /// Safari web apps the reported pid is the helper's. Map it back to the app it works for.
    private static func hostBundle(_ bundle: String, pid: pid_t) -> String {
        guard bundle.hasPrefix("com.apple.WebKit."), pid > 0 else { return bundle }
        let host = responsiblePID(pid)
        guard host > 0, host != pid, let id = NSRunningApplication(processIdentifier: host)?.bundleIdentifier else { return bundle }
        return id
    }

    private func parse(_ line: Data) {
        guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let err = d["error"] as? String { NSLog("Lintel: now-playing bridge: \(err)"); return }
        restarts = 0
        let title = d["title"] as? String ?? ""
        guard !title.isEmpty else { onState?(nil); return }
        let rate = (d["rate"] as? NSNumber)?.doubleValue ?? 0
        let ts = (d["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        let snap = Snapshot(
            bundleID: Self.hostBundle(d["bundle"] as? String ?? "", pid: (d["pid"] as? NSNumber)?.int32Value ?? 0),
            playing: (d["playing"] as? Bool ?? false) || rate > 0,
            title: title,
            artist: d["artist"] as? String ?? "",
            album: d["album"] as? String ?? "",
            duration: (d["duration"] as? NSNumber)?.doubleValue ?? 0,
            elapsed: (d["elapsed"] as? NSNumber)?.doubleValue ?? 0,
            timestamp: ts,
            artworkKey: d["artworkKey"] as? String ?? "",
            artwork: (d["artwork"] as? String).flatMap { Data(base64Encoded: $0) },
            queue: (d["queue"] as? [[String: Any]] ?? []).map { Track(title: $0["t"] as? String ?? "", artist: $0["a"] as? String ?? "") }
        )
        onState?(snap)
    }
}

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePID(_ pid: pid_t) -> pid_t
