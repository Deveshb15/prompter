import XCTest
@testable import Prompter

final class ProviderTests: XCTestCase {
    // MARK: Claude stream-json (shapes recorded from claude 2.1.306)

    func testClaudeStreamDeltasAndResult() {
        let lines = [
            #"{"type":"system","subtype":"init","tools":[],"mcp_servers":[],"model":"claude-haiku-5-5"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"What's the "}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"best way?"}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"What's the best way?"}"#,
        ]
        XCTAssertEqual(lines.map(ClaudeEvent.parse), [.other, .textDelta("What's the "), .textDelta("best way?"),
                                                      .result(text: "What's the best way?", isError: false)])
    }

    func testClaudeErrorResultAndGarbage() {
        XCTAssertEqual(ClaudeEvent.parse(#"{"type":"result","subtype":"error_during_execution","result":"Not logged in"}"#),
                       .result(text: "Not logged in", isError: true))
        XCTAssertEqual(ClaudeEvent.parse("not json"), .other)
        XCTAssertEqual(ClaudeEvent.parse(#"{"type":"stream_event","event":{"delta":{"type":"thinking_delta","thinking":"x"}}}"#), .other)
    }

    func testErrorClassification() {
        XCTAssertEqual(ProviderError.classify("Invalid API key · Please run /login", kind: .claude), .notLoggedIn(.claude))
        XCTAssertEqual(ProviderError.classify("rate limited", kind: .codex), .failed("rate limited"))
    }

    // MARK: Codex app-server (shapes recorded from codex-cli 0.153.4)

    func testCodexResponses() {
        XCTAssertEqual(CodexMessage.parse(#"{"id":2,"result":{"thread":{"id":"t-1"}}}"#),
                       .response(id: 2, threadID: "t-1", modelIDs: [], error: nil))
        XCTAssertEqual(CodexMessage.parse(#"{"id":3,"result":{"data":[{"id":"gpt-6-astra"},{"id":"gpt-5.6-luna"}]}}"#),
                       .response(id: 3, threadID: nil, modelIDs: ["gpt-6-astra", "gpt-5.6-luna"], error: nil))
        XCTAssertEqual(CodexMessage.parse(#"{"id":4,"error":{"code":-32600,"message":"bad params"}}"#),
                       .response(id: 4, threadID: nil, modelIDs: [], error: "bad params"))
    }

    func testCodexStreamAndUnwrappedError() {
        XCTAssertEqual(CodexMessage.parse(#"{"method":"item/agentMessage/delta","params":{"delta":"Fix "}}"#), .delta("Fix "))
        XCTAssertEqual(CodexMessage.parse(#"{"method":"turn/completed","params":{}}"#), .turnCompleted)
        XCTAssertEqual(CodexMessage.parse(#"{"method":"mcpServer/startupStatus/updated","params":{}}"#), .other)
        let wrapped = #"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-6-luna' model is not supported when using Codex with a ChatGPT account.\"}}"#
        XCTAssertEqual(CodexMessage.parse(#"{"method":"error","params":{"error":{"message":"\#(wrapped)"},"willRetry":false}}"#),
                       .error("The 'gpt-6-luna' model is not supported when using Codex with a ChatGPT account.", willRetry: false))
    }

    // MARK: CLI locator

    func testLoginShellNoiseIsSkipped() {
        XCTAssertEqual(CLILocator.lastAbsolutePath(in: "Welcome back!\nlast login: today\n/Users/me/.local/bin/claude\n"), "/Users/me/.local/bin/claude")
        XCTAssertNil(CLILocator.lastAbsolutePath(in: "claude not found\n"))
    }

    func testVersionComparison() {
        XCTAssertTrue(CLILocator.isAtLeast("2.1.306", "2.1.293"))
        XCTAssertTrue(CLILocator.isAtLeast("2.1.293", "2.1.293"))
        XCTAssertFalse(CLILocator.isAtLeast("2.1.99", "2.1.293"))
        XCTAssertTrue(CLILocator.isAtLeast("3.0", "2.1.293"))
    }
}
