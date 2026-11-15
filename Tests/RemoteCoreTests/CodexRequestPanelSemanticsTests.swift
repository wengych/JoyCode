import XCTest
@testable import RemoteCore

final class CodexRequestPanelSemanticsTests: XCTestCase {
    func testRecognizesPanelButtonsInShippedLanguages() {
        XCTAssertEqual(CodexRequestPanelSemantics.buttonKind(label: "Submit"), .submit)
        XCTAssertEqual(CodexRequestPanelSemantics.buttonKind(label: "提交"), .submit)
        XCTAssertEqual(CodexRequestPanelSemantics.buttonKind(label: " Continue "), .proceed)
        XCTAssertEqual(CodexRequestPanelSemantics.buttonKind(label: "继续"), .proceed)
        XCTAssertEqual(CodexRequestPanelSemantics.buttonKind(label: "下一步"), .next)
        XCTAssertEqual(CodexRequestPanelSemantics.buttonKind(label: "Next question"), .nextQuestion)
        XCTAssertEqual(CodexRequestPanelSemantics.buttonKind(label: "上一个问题"), .previousQuestion)
        XCTAssertEqual(CodexRequestPanelSemantics.buttonKind(label: "跳过"), .skip)
        XCTAssertEqual(CodexRequestPanelSemantics.buttonKind(label: "Dismiss"), .dismiss)
        XCTAssertEqual(CodexRequestPanelSemantics.buttonKind(label: "Dismiss, 5 seconds remaining"), .dismiss)
        // ChatGPT.app 26.1111 renders the primary action as a label plus a ⏎ key cap.
        XCTAssertEqual(CodexRequestPanelSemantics.buttonKind(label: "Submit ⏎"), .submit)
        XCTAssertEqual(CodexRequestPanelSemantics.buttonKind(label: "Continue⏎"), .proceed)
        XCTAssertEqual(CodexRequestPanelSemantics.buttonKind(label: "提交 ⏎"), .submit)
        XCTAssertNil(CodexRequestPanelSemantics.buttonKind(label: "⏎"))
        XCTAssertNil(CodexRequestPanelSemantics.buttonKind(label: "Submit feedback"))
        XCTAssertNil(CodexRequestPanelSemantics.buttonKind(label: "Dismissive"))
        XCTAssertNil(CodexRequestPanelSemantics.buttonKind(label: ""))
    }

    func testRecommendedBadgeMustBeItsOwnText() {
        XCTAssertTrue(CodexRequestPanelSemantics.hasRecommendedBadge(childTexts: ["Use SQLite", "Recommended"]))
        XCTAssertTrue(CodexRequestPanelSemantics.hasRecommendedBadge(childTexts: ["用 SQLite", "推荐"]))
        XCTAssertFalse(CodexRequestPanelSemantics.hasRecommendedBadge(childTexts: ["Use the recommended defaults"]))
    }

    func testDefaultOptionPrefersSingleCheckedThenSingleRecommended() {
        XCTAssertEqual(CodexRequestPanelSemantics.defaultOption(checked: [false, true, false], recommended: [true, false, false]), 1)
        XCTAssertEqual(CodexRequestPanelSemantics.defaultOption(checked: [false, false], recommended: [false, true]), 1)
        XCTAssertNil(CodexRequestPanelSemantics.defaultOption(checked: [true, true], recommended: [false, false]))
        XCTAssertNil(CodexRequestPanelSemantics.defaultOption(checked: [false, false], recommended: [false, false]))
        XCTAssertNil(CodexRequestPanelSemantics.defaultOption(checked: [false, false], recommended: [true, true]))
        XCTAssertNil(CodexRequestPanelSemantics.defaultOption(checked: [], recommended: []))
        XCTAssertNil(CodexRequestPanelSemantics.defaultOption(checked: [true], recommended: []))
    }

    func testAdvanceNeedsExactlyOneForwardButton() {
        XCTAssertEqual(CodexRequestPanelSemantics.advanceButton([.dismiss, .skip, .submit]), 2)
        XCTAssertEqual(CodexRequestPanelSemantics.advanceButton([.previousQuestion, .nextQuestion, .proceed, nil]), 2)
        XCTAssertNil(CodexRequestPanelSemantics.advanceButton([.skip, .dismiss, .nextQuestion]))
        XCTAssertNil(CodexRequestPanelSemantics.advanceButton([.submit, .next]))
    }
}
