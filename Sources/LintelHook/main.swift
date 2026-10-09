// lintel-hook <claude|cursor|codex> <event>
//
// Run by Claude Code, Cursor and Codex for each hook event. Reads the event JSON from stdin, forwards it
// to Lintel on 127.0.0.1 with the private token, and prints Lintel's answer (a decision, a reply…) to
// stdout for the agent. It always exits 0 and prints nothing when Lintel isn't running, so the agent
// carries on exactly as if Lintel weren't installed.
//
// Plain BSD sockets on purpose: hooks run on every tool call, and this starts in a few milliseconds.
import Darwin

let args = CommandLine.arguments
guard args.count >= 3 else { exit(0) }
let agent = args[1], event = args[2]
let port: UInt16 = 47821

func readAll(_ fd: Int32) -> [UInt8] {
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}

// Token (mode 0600, written by Lintel).
guard let home = getenv("HOME").map({ String(cString: $0) }) else { exit(0) }
let tokenFD = open(home + "/.lintel/token", O_RDONLY)
guard tokenFD >= 0 else { exit(0) }
let token = String(decoding: readAll(tokenFD), as: UTF8.self).filter { !$0.isWhitespace }
close(tokenFD)
guard !token.isEmpty else { exit(0) }

let body = readAll(STDIN_FILENO)

// Events that wait for you (approvals, replies) may hold a long time; everything else is quick.
let blocking: Set<String> = ["PermissionRequest", "Stop", "stop", "beforeShellExecution"]
let timeoutSeconds = blocking.contains(event) ? 86_400 : 2

let fd = socket(AF_INET, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var on: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
var sendTV = timeval(tv_sec: 2, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTV, socklen_t(MemoryLayout<timeval>.size))

var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = inet_addr("127.0.0.1")
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
guard connected == 0 else { exit(0) } // Lintel isn't running

let term = getenv("TERM_PROGRAM").map { String(cString: $0) } ?? ""
let head = "POST /\(agent)/\(event) HTTP/1.1\r\n" +
    "Host: 127.0.0.1\r\n" +
    "Content-Type: application/json\r\n" +
    "Content-Length: \(body.count)\r\n" +
    "X-Lintel-Token: \(token)\r\n" +
    "X-Lintel-PPID: \(getppid())\r\n" +
    "X-Lintel-Term: \(term.filter { $0 != "\r" && $0 != "\n" })\r\n" +
    "Connection: close\r\n\r\n"
let request = Array(head.utf8) + body
var sent = 0
while sent < request.count {
    let n = request[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    if n <= 0 { exit(0) }
    sent += n
}

let response = readAll(fd)
close(fd)

// "HTTP/1.1 200 OK\r\n…\r\n\r\n<body>" — print the body only for a 200.
guard response.count > 12, String(decoding: response[9..<12], as: UTF8.self) == "200" else { exit(0) }
let sep: [UInt8] = [13, 10, 13, 10]
if let i = (0...(response.count - 4)).first(where: { Array(response[$0..<$0 + 4]) == sep }) {
    let out = response[(i + 4)...]
    if !out.isEmpty { _ = out.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) } }
}
exit(0)
