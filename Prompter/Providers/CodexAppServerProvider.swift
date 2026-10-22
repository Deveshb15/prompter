import Foundation

/// One JSONL message from `codex app-server` (protocol confirmed in docs/spike-results.md).
enum CodexMessage: Equatable {
    case response(id: Int, threadID: String?, modelIDs: [String], error: String?)
    case delta(String)
    case turnCompleted
    case error(String, willRetry: Bool)
    case other

    static func parse(_ line: String) -> CodexMessage {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return .other }
        if let id = obj["id"] as? Int, obj["method"] == nil {
            let result = obj["result"] as? [String: Any]
            let thread = (result?["thread"] as? [String: Any])?["id"] as? String
            let models = (result?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            let error = (obj["error"] as? [String: Any]).map { ($0["message"] as? String) ?? "\($0)" }
            return .response(id: id, threadID: thread, modelIDs: models, error: error)
        }
        let params = obj["params"] as? [String: Any]
        switch obj["method"] as? String {
        case "item/agentMessage/delta":
            return .delta(params?["delta"] as? String ?? "")
        case "turn/completed":
            return .turnCompleted
        case "error":
            let message = (params?["error"] as? [String: Any])?["message"] as? String ?? "Codex error"
            return .error(innerMessage(message), willRetry: params?["willRetry"] as? Bool ?? false)
        default:
            return .other
        }
    }

    /// Codex wraps API errors as a JSON string: {"error":{"message":"..."}}. Surface the readable part.
    static func innerMessage(_ s: String) -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { return s }
        return ((obj["error"] as? [String: Any])?["message"] as? String) ?? s
    }
}

/// Keeps one `codex app-server` alive and starts a fresh thread per rewrite.
actor CodexAppServerProvider: Provider {
    private let binary: URL
    private let path: String?
    private let cwd = emptyWorkingDirectory()
    private let instructions: [Mode: String]
    private var process: Process?
    private var stdin: FileHandle?
    private var inbox: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var closed = false
    private var nextID = 0
    private var model = "gpt-5.6-luna"
    private var cancelled = false
    private var starting: Task<Void, Error>?
    private var generation = 0 // lines from a killed server's reader are dropped

    // The user's MCP servers, hooks, skills and plugins otherwise load into every rewrite (docs/spike-results.md).
    private static let isolate = ["-c", "mcp_servers={}", "-c", "features.hooks=false", "-c", "features.skills=false",
                                  "-c", "features.plugins=false", "-c", "features.apps=false",
                                  "-c", "project_doc_max_bytes=0", "-c", #"web_search="disabled""#]

    init(binary: URL, path: String?) {
        self.binary = binary
        self.path = path
        instructions = Dictionary(uniqueKeysWithValues: Mode.allCases.map { ($0, (try? String(contentsOf: $0.promptURL)) ?? "") })
    }

    func prewarm() async { try? await start() }

    func rewrite(_ message: String, mode: Mode, onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        cancelled = false
        try await start()
        let thread = try await request("thread/start", ["model": model, "cwd": cwd.path, "approvalPolicy": "never",
                                                         "sandbox": "read-only", "baseInstructions": instructions[mode]!,
                                                         "ephemeral": true])
        guard let threadID = thread.threadID else { throw ProviderError.failed("Codex didn't start a thread.") }
        nextID += 1
        try send(["id": nextID, "method": "turn/start",
                  "params": ["threadId": threadID, "effort": "low", "input": [["type": "text", "text": message]]]])

        var text = ""
        while let line = await nextLine() {
            switch CodexMessage.parse(line) {
            case .delta(let d):
                text += d
                onDelta(text)
            case .turnCompleted:
                return text
            case .error(let m, let willRetry) where !willRetry:
                throw ProviderError.classify(m, kind: .codex)
            case .response(_, _, _, let error?):
                throw ProviderError.classify(error, kind: .codex)
            default:
                continue
            }
        }
        throw cancelled ? ProviderError.cancelled : ProviderError.failed("Codex stopped unexpectedly.")
    }

    // ponytail: cancelling kills the server, so the next rewrite pays ~1 s of startup; use turn/interrupt if that matters.
    func cancel() {
        cancelled = true
        process?.terminate()
        process = nil
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    // MARK: - JSON-RPC over stdio

    /// Pre-warm and the first rewrite can both call this; they share one launch so only one reader waits on the server.
    private func start() async throws {
        if let starting { return try await starting.value }
        if process?.isRunning == true { return }
        let launch = Task { try await self.launch() }
        starting = launch
        defer { starting = nil }
        try await launch.value
    }

    private func launch() async throws {
        generation += 1
        let gen = generation
        let (p, i, o, _) = makeProcess(binary, ["app-server"] + Self.isolate, cwd: cwd, path: path)
        inbox = []; closed = false
        do { try p.run() } catch { throw ProviderError.failed("Couldn't start Codex: \(error.localizedDescription)") }
        process = p
        stdin = i.fileHandleForWriting
        let reader = o.fileHandleForReading
        Task.detached { [weak self] in
            do { for try await line in reader.bytes.lines { await self?.deliver(line, gen) } } catch {}
            await self?.deliver(nil, gen)
        }
        _ = try await request("initialize", ["clientInfo": ["name": "Prompter", "version": "0.1"]])
        try send(["method": "initialized"])
        // ponytail: picks the fastest model by name ("luna"); revisit if OpenAI renames tiers.
        let models = try await request("model/list", [:]).modelIDs
        if let fast = models.first(where: { $0.contains("luna") }) ?? models.first { model = fast }
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> (threadID: String?, modelIDs: [String]) {
        nextID += 1
        let id = nextID
        try send(["id": id, "method": method, "params": params])
        while let line = await nextLine() {
            if case let .response(rid, thread, models, error) = CodexMessage.parse(line), rid == id {
                if let error { throw ProviderError.classify(error, kind: .codex) }
                return (thread, models)
            }
        }
        throw cancelled ? ProviderError.cancelled : ProviderError.failed("Codex stopped unexpectedly.")
    }

    private func send(_ object: [String: Any]) throws {
        guard let stdin else { throw ProviderError.failed("Codex isn't running.") }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func deliver(_ line: String?, _ gen: Int) {
        guard gen == generation else { return }
        if let w = waiter {
            waiter = nil
            w.resume(returning: line)
        } else if let line {
            inbox.append(line)
        } else {
            closed = true
        }
    }

    private func nextLine() async -> String? {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }
}
