import Foundation
import Network

/// A tiny HTTP/1.1 server on 127.0.0.1 that receives Claude Code hook events.
/// Requests can be answered later (permission prompts block until you decide).
final class HookServer: @unchecked Sendable {
    static let port: UInt16 = 47821

    struct Request {
        let path: String
        let headers: [String: String]
        let body: Data
    }

    /// Called on the main queue. Call `respond` exactly once (any thread); `onClose` fires if the
    /// client hangs up first (e.g. you answered in the terminal instead).
    typealias Handler = (Request, Responder) -> Void

    final class Responder: @unchecked Sendable {
        private let connection: NWConnection
        private let lock = NSLock()
        private var done = false
        var onClose: (() -> Void)?

        init(_ c: NWConnection) { connection = c }

        var isOpen: Bool { lock.withLock { !done } }

        func respond(_ body: String = "", status: String = "200 OK") {
            let shouldSend: Bool = lock.withLock {
                if done { return false }
                done = true
                return true
            }
            guard shouldSend else { return }
            let data = Data(body.utf8)
            let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }

        fileprivate func peerClosed() {
            let wasOpen: Bool = lock.withLock {
                let o = !done
                done = true
                return o
            }
            connection.cancel()
            if wasOpen { DispatchQueue.main.async { self.onClose?() } }
        }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "lintel.hooks")
    private let handler: Handler
    private let token: String

    init(token: String, handler: @escaping Handler) {
        self.token = token
        self.handler = handler
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { state in
                if case .failed(let e) = state { NSLog("Lintel: hook server failed: \(e)") }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            NSLog("Lintel: could not start hook server: \(error)")
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, buffer: Data())
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                self.dispatch(req, on: c)
            } else if isComplete || error != nil || buf.count > 8 << 20 {
                c.cancel()
            } else {
                self.read(c, buffer: buf)
            }
        }
    }

    private static func parse(_ buf: Data) -> Request? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buf[buf.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        // A missing, malformed or negative length means an empty body (never trust it for `prefix`).
        let length = max(0, Int(headers["content-length"] ?? "0") ?? 0)
        let body = buf[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return Request(path: String(requestLine[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func dispatch(_ req: Request, on c: NWConnection) {
        let responder = Responder(c)
        guard Self.equalInConstantTime(req.headers["x-lintel-token"] ?? "", token) else {
            responder.respond("", status: "403 Forbidden")
            return
        }
        // Watch for the client hanging up while we hold the response.
        watchClose(c, responder)
        DispatchQueue.main.async { self.handler(req, responder) }
    }

    /// Compares without returning early, so the time taken doesn't hint at how much of the token matched.
    private static func equalInConstantTime(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    private func watchClose(_ c: NWConnection, _ r: Responder) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                r.peerClosed()
            } else if r.isOpen {
                self?.watchClose(c, r)
            }
        }
    }
}
