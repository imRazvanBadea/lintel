import Foundation

/// Starts a helper CLI the way terminals do: as its own "responsible process" for macOS privacy checks.
/// Spawned normally, a child's file access is attributed to Lintel, and a privacy check charged to a
/// menu-bar app can block the child's `open()` forever (Claude Code hung at startup this way).
enum Spawn {
    struct Child: Sendable {
        let pid: pid_t
        let stdin: FileHandle
        let stdout: FileHandle

        func kill(after grace: TimeInterval = 2) {
            Darwin.kill(pid, SIGTERM)
            let pid = pid
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { if Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) } }
        }
    }

    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let disclaim: Disclaim? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        .map { unsafeBitCast($0, to: Disclaim.self) }

    /// stdin/stdout are pipes, stderr goes to /dev/null. `onExit` runs (off the main thread) once the child is reaped.
    static func run(_ exe: String, _ args: [String], environment: [String: String], directory: String,
                    onExit: @escaping @Sendable () -> Void) -> Child? {
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0 else { return nil }
        guard pipe(&outPipe) == 0 else { close(inPipe[0]); close(inPipe[1]); return nil }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Only 0/1/2 reach the child; everything else Lintel has open stays closed.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        _ = disclaim?(&attr, 1)

        let argv = ([exe] + args).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &actions, &attr, argv, envp)
        close(inPipe[0]); close(outPipe[1])
        guard rc == 0 else { close(inPipe[1]); close(outPipe[0]); return nil }
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1) // writing to a child that already quit must not kill Lintel

        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            onExit()
        }
        return Child(pid: pid,
                     stdin: FileHandle(fileDescriptor: inPipe[1], closeOnDealloc: true),
                     stdout: FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true))
    }
}
