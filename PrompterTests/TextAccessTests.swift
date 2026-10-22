import XCTest
@testable import Prompter

final class TextAccessTests: XCTestCase {
    func testSelectionWins() {
        XCTAssertEqual(TextAccess.decide(role: "AXTextArea", subrole: nil, selected: "fix this", value: "a lot of text fix this", isTerminal: false), .selection)
    }

    func testWholeFieldWhenNothingSelectedInEditableField() {
        XCTAssertEqual(TextAccess.decide(role: "AXTextArea", subrole: nil, selected: "", value: "make it faster", isTerminal: false), .wholeField)
    }

    func testEmptyEditableFieldIsRefused() {
        XCTAssertEqual(TextAccess.decide(role: "AXTextField", subrole: nil, selected: nil, value: "  ", isTerminal: false), .refuse(.empty))
    }

    func testPasswordFieldIsRefused() {
        XCTAssertEqual(TextAccess.decide(role: "AXTextField", subrole: "AXSecureTextField", selected: "hunter2", value: "hunter2", isTerminal: false),
                       .refuse(.secureField))
    }

    func testTerminalNeverUsesWholeBuffer() {
        XCTAssertEqual(TextAccess.decide(role: "AXTextArea", subrole: nil, selected: "", value: "entire scrollback", isTerminal: true), .copySelection)
    }

    func testUnknownElementFallsBackToCopyingTheSelectionNotSelectAll() {
        XCTAssertEqual(TextAccess.decide(role: "AXGroup", subrole: nil, selected: nil, value: nil, isTerminal: false), .copySelection)
        XCTAssertEqual(TextAccess.decide(role: nil, subrole: nil, selected: nil, value: nil, isTerminal: false), .copySelection)
    }

    func testClipboardRestoredOnlyIfStillOurs() {
        XCTAssertTrue(TextAccess.shouldRestoreClipboard(currentChangeCount: 7, writtenChangeCount: 7))
        XCTAssertFalse(TextAccess.shouldRestoreClipboard(currentChangeCount: 8, writtenChangeCount: 7)) // user copied meanwhile
    }
}
