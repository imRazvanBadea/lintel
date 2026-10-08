import Foundation
import AppKit

/// Runs AppleScript off the main thread on one serial queue (NSAppleScript is not thread-safe).
final class ScriptRunner: @unchecked Sendable {
    static let shared = ScriptRunner()
    private let queue = DispatchQueue(label: "lintel.applescript", qos: .userInitiated)
    private var cache: [String: NSAppleScript] = [:]

    struct Failure: Error { let message: String; let code: Int }

    func run(_ source: String, completion: @escaping @Sendable (Result<NSAppleEventDescriptor, Failure>) -> Void) {
        queue.async {
            let result = self.runSync(source)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func fire(_ source: String) { queue.async { _ = self.runSync(source) } }

    private func runSync(_ source: String) -> Result<NSAppleEventDescriptor, Failure> {
        let script: NSAppleScript
        if let s = cache[source] { script = s } else {
            guard let s = NSAppleScript(source: source) else { return .failure(.init(message: "compile", code: -1)) }
            var err: NSDictionary?
            s.compileAndReturnError(&err)
            cache[source] = s
            script = s
        }
        var err: NSDictionary?
        let out = script.executeAndReturnError(&err)
        if let err {
            return .failure(.init(message: err[NSAppleScript.errorMessage] as? String ?? "error",
                                  code: err[NSAppleScript.errorNumber] as? Int ?? 0))
        }
        return .success(out)
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

extension NSAppleEventDescriptor {
    var items: [NSAppleEventDescriptor] {
        guard numberOfItems > 0 else { return [] }
        return (1...numberOfItems).compactMap { atIndex($0) }
    }
}
