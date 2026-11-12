import XCTest
import RemoteCore

final class ComposerSemanticsTests: XCTestCase {
    func testGenericTitleDoesNotMaskComposerDescription() {
        XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(
            role: "AXTextArea", title: "Editor", description: "Prompt"
        )), 75)
        XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(
            role: "AXTextArea", title: "Editor", description: "Message composer"
        )), 95)
    }

    func testKnownIdentifierTakesPriorityOverGenericSearchWords() {
        for identifier in ["prompt-textarea", "chat-input"] {
            XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(
                role: "AXTextArea", identifier: identifier, placeholder: "Search or ask a question"
            )), 120, identifier)
        }
    }

    func testSearchInputsAreNotComposers() {
        XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(
            role: "AXTextField", identifier: "message-search", title: "Search messages"
        )), 0)
        XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(
            role: "AXTextField", title: "搜索消息", description: "Message input"
        )), 0)
    }

    func testGroupIsRejectedEvenWithKnownIdentifier() {
        XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(
            role: "AXGroup", identifier: "prompt-textarea", description: "Message composer"
        )), 0)
    }

    func testDisabledAndHiddenInputsAreRejectedBeforeIdentifierMatch() {
        XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(
            role: "AXTextArea", identifier: "prompt-textarea", isEnabled: false
        )), 0)
        XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(
            role: "AXTextArea", identifier: "prompt-textarea", isHidden: true
        )), 0)
    }

    func testUnidentifiedTextAreaIsRejected() {
        XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(role: "AXTextArea")), 0)
        XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(role: "AXTextArea", title: "Editor")), 0)
    }

    func testLabelAndPlaceholderRemainAvailableWithGenericTitle() {
        XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(
            role: "AXTextArea", title: "Editor", description: "Multiline input", label: "ASK CODEX"
        )), 95)
        XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(
            role: "AXTextField", title: "Editor", placeholder: "输入消息", isEnabled: true, isHidden: false
        )), 95)
    }

    func testSeparateFieldsDoNotManufactureStrongMatchingPhrase() {
        XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(
            role: "AXTextArea", title: "Message", description: "Composer"
        )), 75)
    }

    func testInstalledCodexChatAndWorkComposerLabels() {
        for label in ["Work with Codex", "和 Codex 一起工作", "Do anything", "随心输入", "Ask ChatGPT", "询问 ChatGPT", "Work with ChatGPT", "使用 ChatGPT Work", "與 Codex 協作", "問問 ChatGPT", "問 ChatGPT", "想做什麼都可以", "輸入任何任務"] {
            XCTAssertEqual(ComposerSemantics.score(ComposerEvidence(
                role: "AXTextArea", title: "Editor", description: label
            )), 95, label)
        }
    }
}
