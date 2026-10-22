import XCTest
@testable import Prompter

@MainActor
final class CoordinatorTests: XCTestCase {
    private var replaced: [String] = []
    private var rewriteCalls = 0
    private var cancelCalls = 0

    private func make(rewrite: @escaping (String) async throws -> String,
                      replace: ((CapturedText, String) async throws -> ReplaceOutcome)? = nil) -> Coordinator {
        Coordinator(
            capture: { CapturedText(pid: 1, appName: "ChatGPT", isTerminal: false, element: nil, mode: .copied, text: "fix bug") },
            replace: { [unowned self] t, s in
                if let replace { return try await replace(t, s) }
                replaced.append(s)
                return .replaced
            },
            rewrite: { [unowned self] message, _, _ in
                await MainActor.run { rewriteCalls += 1 }
                XCTAssertTrue(message.contains("<draft>\nfix bug\n</draft>"))
                return try await rewrite(message)
            },
            cancelRewrite: { [unowned self] in await MainActor.run { cancelCalls += 1 } })
    }

    func testHappyPathReplacesOnce() async {
        let c = make { _ in "Fix the bug." }
        c.trigger(.polish)
        await c.settle()
        XCTAssertEqual(replaced, ["Fix the bug."])
        XCTAssertEqual(c.phase, .done(.replaced))
    }

    func testSecondPressWhileBusyIsIgnored() async {
        let c = make { _ in try await Task.sleep(nanoseconds: 100_000_000); return "Fix the bug." }
        c.trigger(.polish)
        c.trigger(.polish)
        c.trigger(.expand)
        await c.settle()
        XCTAssertEqual(rewriteCalls, 1)
        XCTAssertEqual(replaced.count, 1)
    }

    func testNotLoggedInShowsFixAndNeverReplaces() async {
        let c = make { _ in throw ProviderError.notLoggedIn(.claude) }
        c.trigger(.polish)
        await c.settle()
        XCTAssertTrue(replaced.isEmpty)
        guard case .failed(let message) = c.phase else { return XCTFail() }
        XCTAssertTrue(message.contains("claude auth login"))
    }

    func testTextChangedDuringRewriteIsNotReplaced() async {
        let c = make(rewrite: { _ in "Fix the bug." }, replace: { _, _ in throw TextAccessError.textChanged })
        c.trigger(.polish)
        await c.settle()
        XCTAssertEqual(c.phase, .failed(TextAccessError.textChanged.errorDescription!))
    }

    func testEscCancelsWithoutReplacing() async {
        let c = make { _ in try await Task.sleep(nanoseconds: 5_000_000_000); return "late" }
        c.trigger(.polish)
        try? await Task.sleep(nanoseconds: 50_000_000)
        c.cancel()
        await c.settle()
        try? await Task.sleep(nanoseconds: 50_000_000) // cancelRewrite runs in its own task
        XCTAssertTrue(replaced.isEmpty)
        XCTAssertEqual(cancelCalls, 1)
        XCTAssertEqual(c.phase, .idle)
    }

    func testSuspiciousOutputWaitsForUserBeforeReplacing() async {
        let c = make { _ in "Sure! Here's a better prompt: Fix the bug." }
        c.trigger(.polish)
        await c.settle()
        guard case .preview = c.phase else { return XCTFail("expected preview, got \(c.phase)") }
        XCTAssertTrue(replaced.isEmpty)
        c.acceptPreview()
        await c.settle()
        XCTAssertEqual(replaced, ["Sure! Here's a better prompt: Fix the bug."])
    }

    func testDiscardedPreviewNeverReplaces() async {
        let c = make { _ in "Sure! Here's a better prompt: Fix the bug." }
        c.trigger(.polish)
        await c.settle()
        c.dismiss()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertTrue(replaced.isEmpty)
    }
}
