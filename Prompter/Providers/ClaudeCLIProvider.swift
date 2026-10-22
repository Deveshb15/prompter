import Foundation

/// One line of `claude -p --output-format stream-json --include-partial-messages`.
enum ClaudeEvent: Equatable {
    case textDelta(String)
    case result(text: String, isError: Bool)
    case other

    static func parse(_ line: String) -> ClaudeEvent {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return .other }
        switch obj["type"] as? String {
        case "stream_event":
            let delta = (obj["event"] as? [String: Any])?["delta"] as? [String: Any]
            if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String { return .textDelta(text) }
        case "result":
            let isError = obj["is_error"] as? Bool ?? (obj["subtype"] as? String != "success")
            return .result(text: obj["result"] as? String ?? "", isError: isError)
        default:
            break
        }
        return .other
    }
}

final class ClaudeCLIProvider: Provider {
    private let workers: [Mode: ClaudeWorker]

    init(binary: URL, path: String?) {
        workers = Dictionary(uniqueKeysWithValues: Mode.allCases.map { ($0, ClaudeWorker(binary: binary, promptFile: $0.promptURL, path: path)) })
    }

    func prewarm() async { for w in workers.values { await w.prewarm() } }

    func rewrite(_ message: String, mode: Mode, onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        try await workers[mode]!.run(message, onDelta: onDelta)
    }

    func cancel() async { for w in workers.values { await w.cancel() } }
}

/// Keeps one `claude -p` process started and waiting on stdin, uses it for exactly one rewrite, then replaces it.
/// Pre-warming hides ~1 s of CLI startup; one process per rewrite means no context carries between rewrites.
actor ClaudeWorker {
    private let binary: URL
    private let arguments: [String]
    private let path: String?
    private let cwd = emptyWorkingDirectory()
    private var warm: (Process, stdin: Pipe, stdout: Pipe, stderr: Pipe)?
    private var running: Process?
    private var cancelled = false

    init(binary: URL, promptFile: URL, path: String?) {
        self.binary = binary
        self.path = path
        // Flags verified in docs/spike-results.md: no tools, no MCP, no user settings/hooks/CLAUDE.md.
        arguments = ["-p", "--model", "haiku", "--effort", "low",
                     "--system-prompt-file", promptFile.path,
                     "--tools", "", "--disallowedTools", "mcp__*",
                     "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                     "--setting-sources", "",
                     "--no-session-persistence", "--permission-prompts", "none",
                     "--input-format", "stream-json", "--output-format", "stream-json",
                     "--verbose", "--include-partial-messages"]
    }

    func prewarm() {
        guard warm?.0.isRunning != true else { return }
        let w = makeProcess(binary, arguments, cwd: cwd, path: path)
        if (try? w.0.run()) != nil { warm = w }
    }

    func run(_ message: String, onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        prewarm()
        guard let w = warm, w.0.isRunning else { throw ProviderError.failed("Couldn't start Claude Code.") }
        let (process, stdin, stdout, stderr) = w
        warm = nil
        running = process
        cancelled = false
        defer {
            if process.isRunning { process.terminate() }
            running = nil
            prewarm() // ready for the next hotkey press
        }

        let payload: [String: Any] = ["type": "user", "message": ["role": "user", "content": message]]
        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: line)

        var text = ""
        for try await raw in stdout.fileHandleForReading.bytes.lines {
            switch ClaudeEvent.parse(raw) {
            case .textDelta(let t):
                text += t
                onDelta(text)
            case .result(let result, let isError):
                if isError { throw ProviderError.classify(result, kind: .claude) }
                return result
            case .other:
                continue
            }
        }
        if cancelled { throw ProviderError.cancelled }
        let err = String(decoding: stderr.fileHandleForReading.availableData, as: UTF8.self)
        throw ProviderError.classify(err.isEmpty ? "Claude Code stopped unexpectedly." : err, kind: .claude)
    }

    func cancel() {
        cancelled = true
        running?.terminate()
    }
}
