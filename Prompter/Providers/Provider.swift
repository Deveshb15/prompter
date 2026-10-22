import Foundation

enum ProviderKind: String, CaseIterable, Sendable {
    case claude, codex

    var binaryName: String { rawValue }
    var displayName: String { self == .claude ? "Claude Code" : "Codex" }
    var pathDefaultsKey: String { "\(rawValue)Path" }
    var loginCommand: String { self == .claude ? "claude auth login" : "codex login" }
    var statusArguments: [String] { self == .claude ? ["auth", "status"] : ["login", "status"] }
    /// Haiku 5.5 needs Claude Code 2.1.293+ (see docs/spike-results.md).
    var minimumVersion: String? { self == .claude ? "2.1.293" : nil }
}

enum ProviderError: LocalizedError, Equatable {
    case notInstalled(ProviderKind)
    case notLoggedIn(ProviderKind)
    case outdated(ProviderKind, found: String, required: String)
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notInstalled(let k):
            return "Couldn't find the `\(k.binaryName)` command. Install \(k.displayName), or set its path in Settings."
        case .notLoggedIn(let k):
            return "\(k.displayName) isn't logged in. Run `\(k.loginCommand)` in Terminal."
        case .outdated(let k, let found, let required):
            return "\(k.displayName) \(found) is too old; Prompter needs \(required) or newer."
        case .failed(let message):
            return message.isEmpty ? "The rewrite failed." : message
        case .cancelled:
            return "Cancelled."
        }
    }

    /// Turns CLI error text into a typed error so the overlay can show the right fix.
    static func classify(_ text: String, kind: ProviderKind) -> ProviderError {
        let lower = text.lowercased()
        if ["not logged in", "log in", "login", "logged out", "authenticate", "unauthorized", "401"].contains(where: lower.contains) {
            return .notLoggedIn(kind)
        }
        return .failed(String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)))
    }
}

/// One rewrite at a time; `onDelta` receives the accumulated text so far.
protocol Provider: AnyObject, Sendable {
    func prewarm() async
    func rewrite(_ message: String, mode: Mode, onDelta: @escaping @Sendable (String) -> Void) async throws -> String
    func cancel() async
}

/// Spawns a CLI with pipes. Arguments are an array (never a shell string), so captured text can't inject commands.
func makeProcess(_ binary: URL, _ arguments: [String], cwd: URL, path: String?) -> (Process, stdin: Pipe, stdout: Pipe, stderr: Pipe) {
    let p = Process()
    p.executableURL = binary
    p.arguments = arguments
    p.currentDirectoryURL = cwd
    var env = ProcessInfo.processInfo.environment
    if let path { env["PATH"] = path } // GUI apps don't inherit the user's shell PATH
    p.environment = env
    let i = Pipe(), o = Pipe(), e = Pipe()
    p.standardInput = i; p.standardOutput = o; p.standardError = e
    return (p, i, o, e)
}

/// An empty working directory per CLI, so no project CLAUDE.md / AGENTS.md / .mcp.json gets loaded.
func emptyWorkingDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("prompter-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
