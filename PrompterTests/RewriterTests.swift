import XCTest
@testable import Prompter

final class RewriterTests: XCTestCase {
    func testFaithfulRewriteKeepingURLIsReplaced() {
        let draft = "can you summarize https://example.com/post and list the main claims"
        let out = "Summarize https://example.com/post and list its main claims."
        XCTAssertEqual(Rewriter.check(draft: draft, output: out, mode: .polish), .replace(out))
    }

    func testShortDraftMayGrowAFewWords() {
        let out = "Fix the bug in the login form. Tell me what caused it and how you checked the fix works."
        XCTAssertEqual(Rewriter.check(draft: "fix the bug", output: out, mode: .polish), .replace(out))
    }

    func testUnchangedOutputIsReplaced() {
        let draft = "What's the best way to learn Rust?"
        XCTAssertEqual(Rewriter.check(draft: draft, output: draft, mode: .polish), .replace(draft))
    }

    func testPolishMuchLongerThanDraftGoesToPreview() {
        let draft = String(repeating: "word ", count: 20)
        let out = String(repeating: "longer ", count: 120)
        guard case .preview = Rewriter.check(draft: draft, output: out, mode: .polish) else { return XCTFail() }
    }

    func testExpandMayBeMuchLonger() {
        let out = "What's the best way to learn Rust? My background: [languages you know]. " + String(repeating: "detail ", count: 60).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(Rewriter.check(draft: "whats the best way to learn rust", output: out, mode: .expand), .replace(out))
    }

    func testReplyInsteadOfRewriteGoesToPreview() {
        let verdict = Rewriter.check(draft: "write a poem about cats", output: "Sure! Here's an improved prompt: Write a poem about cats.", mode: .polish)
        guard case .preview(_, let reason) = verdict else { return XCTFail() }
        XCTAssertTrue(reason.contains("reply"))
    }

    func testDraftThatItselfStartsWithHereIsNotFlagged() {
        let draft = "here's my code, why does it crash"
        let out = "Here's my code. Why does it crash?"
        XCTAssertEqual(Rewriter.check(draft: draft, output: out, mode: .polish), .replace(out))
    }

    func testDroppedCodeSpanGoesToPreview() {
        let verdict = Rewriter.check(draft: "why does `npm run build` fail", output: "Why does the build fail?", mode: .polish)
        guard case .preview(_, let reason) = verdict else { return XCTFail() }
        XCTAssertTrue(reason.contains("`npm run build`"))
    }

    func testEditedQuoteGoesToPreview() {
        // Seen in the eval: the rewriter "improved" the sentence the user wanted edited.
        let draft = #"make this sound less stiff: "Per our discussion, I am hereby confirming the meeting.""#
        let out = #"Make this sound less stiff: "Per our discussion, I'm confirming the meeting.""#
        guard case .preview = Rewriter.check(draft: draft, output: out, mode: .polish) else { return XCTFail() }
    }

    func testSlashCommandAndMentionMustSurvive() {
        let draft = "/review check @src/auth.ts for security issues"
        XCTAssertEqual(Rewriter.check(draft: draft, output: draft, mode: .polish), .replace(draft))
        guard case .preview = Rewriter.check(draft: draft, output: "Review src/auth.ts for security issues.", mode: .polish) else { return XCTFail() }
    }

    func testPathSegmentsAreNotMistakenForSlashCommands() {
        XCTAssertFalse(Rewriter.protectedTokens(in: "look in src/theme.tsx").contains("/theme"))
    }

    func testEmptyOutputAborts() {
        guard case .abort = Rewriter.check(draft: "hi", output: "  \n ", mode: .polish) else { return XCTFail() }
    }

    func testCleanStripsWrappingQuotesAndFence() {
        XCTAssertEqual(Rewriter.clean("\"Fix the login loop.\""), "Fix the login loop.")
        XCTAssertEqual(Rewriter.clean("```text\nFix the login loop.\n```"), "Fix the login loop.")
        XCTAssertEqual(Rewriter.clean(#""a" and "b""#), #""a" and "b""#) // not one wrapping quote pair
    }
}
