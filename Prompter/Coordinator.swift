import Foundation

@MainActor
final class Coordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(Mode, String)
        case done(ReplaceOutcome)
        case preview(String, reason: String)
        case failed(String)
    }

    typealias Capture = @MainActor () async throws -> CapturedText
    typealias Replace = @MainActor (CapturedText, String) async throws -> ReplaceOutcome
    typealias Rewrite = (String, Mode, @escaping @Sendable (String) -> Void) async throws -> String

    @Published private(set) var phase: Phase = .idle
    private(set) var original: String?

    private let capture: Capture
    private let replace: Replace
    private let rewrite: Rewrite
    private let cancelRewrite: () async -> Void
    private var task: Task<Void, Never>?
    private var target: CapturedText?
    private var pending: String?

    init(capture: @escaping Capture, replace: @escaping Replace, rewrite: @escaping Rewrite, cancelRewrite: @escaping () async -> Void) {
        self.capture = capture
        self.replace = replace
        self.rewrite = rewrite
        self.cancelRewrite = cancelRewrite
    }

    func trigger(_ mode: Mode) {
        guard task == nil else { return } // one rewrite at a time; extra presses are ignored
        if case .preview = phase { return }
        task = Task {
            defer { task = nil }
            do {
                let t = try await capture()
                target = t
                original = t.text
                phase = .working(mode, "")
                let output = try await rewrite(Rewriter.userMessage(app: t.appName, draft: t.text), mode) { partial in
                    Task { @MainActor [weak self] in
                        if case .working(let m, _) = self?.phase { self?.phase = .working(m, partial) }
                    }
                }
                try Task.checkCancellation()
                switch Rewriter.check(draft: t.text, output: output, mode: mode) {
                case .replace(let text):
                    phase = .done(try await replace(t, text))
                case .preview(let text, let reason):
                    pending = text
                    phase = .preview(text, reason: reason)
                case .abort(let message):
                    phase = .failed(message)
                }
            } catch is CancellationError {
                phase = .idle
            } catch ProviderError.cancelled {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard let task else { return }
        task.cancel()
        Task { await cancelRewrite() }
        phase = .idle
    }

    func acceptPreview() {
        guard case .preview = phase, let t = target, let text = pending else { return }
        pending = nil
        phase = .working(.polish, text)
        task = Task {
            defer { task = nil }
            do { phase = .done(try await replace(t, text)) } catch { phase = .failed(error.localizedDescription) }
        }
    }

    func dismiss() {
        pending = nil
        if task == nil { phase = .idle }
    }

    /// For tests: wait for the in-flight rewrite to finish.
    func settle() async { await task?.value }
}
