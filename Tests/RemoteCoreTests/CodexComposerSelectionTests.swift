import XCTest
@testable import RemoteCore

final class CodexComposerSelectionTests: XCTestCase {
    private typealias Selection = CodexComposerSelection
    private typealias Candidate = Selection.Candidate

    func testExactInstalledLabelsMatchTheirFixedCategory() {
        let cases: [(Selection.LabelCategory, [String])] = [
            (.askChatGPT, ["Ask ChatGPT", "询问 ChatGPT", "問問 ChatGPT", "問 ChatGPT"]),
            (.workWithCodex, ["Work with Codex", "和 Codex 一起工作", "與 Codex 協作"]),
            (.workWithChatGPT, ["Work with ChatGPT", "使用 ChatGPT Work", "與 ChatGPT 一起工作", "與 ChatGPT 協作"]),
            (.doAnything, ["Do anything", "随心输入", "想做什麼都可以", "輸入任何任務"]),
            (.working, ["Working…", "处理中…", "處理中…"]),
            (.goal, ["Describe your goal, define measurable outcomes for best results",
                "描述你的目标，并设定可衡量的预期成果，以取得最佳效果", "描述你的目標，並設定可衡量的成果，以獲得最佳成效",
                "描述你的目標，並設定可衡量的成果，以取得最佳成效"]),
            (.plan, ["Describe your task to generate a plan...", "描述你的任务以生成套餐…",
                "描述你的任務以產生方案…", "描述你的任務以生成計劃..."]),
            (.project, ["New chat in this project", "此项目中的新聊天", "此專案中的新對話", "在此項目中開始新對話"])
        ]
        for (category, labels) in cases {
            for label in labels {
                let evidence = ComposerEvidence(role: "AXTextArea", description: label)
                XCTAssertEqual(Selection.recognizedLabel(evidence), category, label)
                XCTAssertTrue(Selection.isEligible(evidence, isEditable: true), label)
            }
        }
    }

    func testEachNameAttributeCanProvideRecognitionWithoutCombiningFields() {
        let cases = [ComposerEvidence(title: " Ask ChatGPT\n"),
            ComposerEvidence(description: "ASK CHATGPT"), ComposerEvidence(label: "Ask ChatGPT"),
            ComposerEvidence(placeholder: "Ask ChatGPT")]
        for evidence in cases { XCTAssertEqual(Selection.recognizedLabel(evidence), .askChatGPT) }
        XCTAssertNil(Selection.recognizedLabel(ComposerEvidence(title: "Ask", description: "ChatGPT")))
        XCTAssertEqual(Selection.recognizedLabel(ComposerEvidence(
            title: "Ask ChatGPT", label: "Working…")), .multipleKnown)
    }

    func testAccessibleNameTakesPriorityOverPlaceholder() {
        let evidence = ComposerEvidence(role: "AXTextArea", title: "Editor",
            description: "Ask ChatGPT", placeholder: "Working…")
        XCTAssertEqual(Selection.recognizedLabel(evidence), .askChatGPT)
        XCTAssertEqual(Selection.matchingSource(evidence), .accessibleName)
    }

    func testUnknownAccessibleNameCannotBorrowKnownPlaceholder() {
        for evidence in [
            ComposerEvidence(role: "AXTextArea", title: "Builder Message", placeholder: "Ask ChatGPT"),
            ComposerEvidence(role: "AXTextArea", description: "Builder Message", placeholder: "Ask ChatGPT"),
            ComposerEvidence(role: "AXTextArea", label: "Builder Message", placeholder: "Ask ChatGPT"),
            ComposerEvidence(role: "AXTextArea", title: "Editor", description: "Message", placeholder: "Ask ChatGPT")
        ] {
            XCTAssertNil(Selection.recognizedLabel(evidence))
            XCTAssertNil(Selection.matchingSource(evidence))
            XCTAssertFalse(Selection.isEligible(evidence, isEditable: true))
        }
    }

    func testUnnamedEditorPlaceholderIsDiagnosticOnly() {
        let evidence = ComposerEvidence(role: "AXTextArea", title: " \n", description: "\t", placeholder: "Ask ChatGPT")
        XCTAssertEqual(Selection.recognizedLabel(evidence), .askChatGPT)
        XCTAssertEqual(Selection.matchingSource(evidence), .placeholder)
        XCTAssertFalse(Selection.isEligible(evidence, isEditable: true))
        XCTAssertEqual(Selection.rejectionReason(for: evidence, isEditable: true), .missingAccessibleName)
        XCTAssertNil(Selection.recognizedLabel(ComposerEvidence(role: "AXTextArea", placeholder: "Ask my agent")))
    }

    func testGenericPartialDynamicAndSpecialEditorLabelsDoNotAuthorizeComposer() {
        for label in ["Prompt", "Message composer", "Reply", "消息", "回复", "Ask ChatGPT now",
                      "Example: Work with Codex", "Working...", "Working for 5 seconds…",
                      "Ask custom agent", "New chat in My project", "Type", "输入", "輸入",
                      "Add instructions…", "添加说明…", "新增指示…", "加入指示…"] {
            let evidence = ComposerEvidence(role: "AXTextArea", description: label)
            XCTAssertNil(Selection.recognizedLabel(evidence), label)
            XCTAssertFalse(Selection.isEligible(evidence, isEditable: true), label)
            XCTAssertEqual(Selection.rejectionReason(for: evidence, isEditable: true), .unrecognizedLabel)
        }
    }

    func testKnownIdentifierAloneCannotAuthorizeCodexComposer() {
        for identifier in ["prompt-textarea", "chat-input", "data-codex-composer"] {
            let evidence = ComposerEvidence(role: "AXTextArea", identifier: identifier)
            XCTAssertNil(Selection.recognizedLabel(evidence))
            XCTAssertFalse(Selection.isEligible(evidence, isEditable: true))
        }
    }

    func testReadOnlyTextIsRejectedEvenWhenEnabledAndExactlyNamed() {
        for enabled in [nil, false, true] as [Bool?] {
            let evidence = ComposerEvidence(role: "AXTextArea", description: "Ask ChatGPT", isEnabled: enabled)
            XCTAssertEqual(Selection.recognizedLabel(evidence), .askChatGPT)
            XCTAssertFalse(Selection.isEligible(evidence, isEditable: false))
        }
        XCTAssertEqual(Selection.rejectionReason(for: ComposerEvidence(role: "AXTextArea",
            description: "Ask ChatGPT", isEnabled: true), isEditable: false), .notEditable)
    }

    func testWrongRoleHiddenAndDisabledAreRejectedDespiteEditableFlag() {
        let cases: [(ComposerEvidence, Selection.RejectionReason)] = [
            (.init(role: "AXStaticText", description: "Ask ChatGPT"), .unsupportedRole),
            (.init(role: "AXGroup", description: "Ask ChatGPT"), .unsupportedRole),
            (.init(role: "AXTextArea", description: "Ask ChatGPT", isHidden: true), .hidden),
            (.init(role: "AXTextArea", description: "Ask ChatGPT", isEnabled: false), .disabled)
        ]
        for (evidence, reason) in cases {
            XCTAssertFalse(Selection.isEligible(evidence, isEditable: true))
            XCTAssertEqual(Selection.rejectionReason(for: evidence, isEditable: true), reason)
        }
        XCTAssertTrue(Selection.isEligible(ComposerEvidence(role: "AXTextField",
            description: "Ask ChatGPT", isEnabled: true, isHidden: false), isEditable: true))
    }

    func testReadOnlyOrUnrecognizedFocusedCandidateCannotOverrideRealComposer() throws {
        let real = candidate(1, main: true)
        let readOnly = candidate(2, editable: false, focused: true)
        let unknown = candidate(3, recognized: false, focused: true)
        XCTAssertEqual(try Selection.select([readOnly, unknown, real]), real)
        XCTAssertNil(try Selection.select([readOnly, unknown]))
    }

    func testUniqueFocusedEligibleComposerFollowsActivePane() throws {
        let main = candidate(1, main: true)
        let activeSecondary = candidate(2, focused: true, secondary: true)
        XCTAssertEqual(try Selection.select([main, activeSecondary]), activeSecondary)
        XCTAssertEqual(try Selection.select([activeSecondary, main]), activeSecondary)
    }

    func testMultipleFocusedEligibleComposersRemainAmbiguous() {
        assertAmbiguous([candidate(1, focused: true, main: true), candidate(2, focused: true, secondary: true)])
    }

    func testUniqueMainPaneWinsWithoutFocus() throws {
        let main = candidate(1, main: true)
        XCTAssertEqual(try Selection.select([candidate(2), main, candidate(3, secondary: true)]), main)
        XCTAssertEqual(try Selection.select([main, candidate(2)]), main)
    }

    func testSecondaryMainMarkerDoesNotClaimPrimaryPane() throws {
        let main = candidate(1)
        XCTAssertEqual(try Selection.select([candidate(2, main: true, secondary: true), main]), main)
    }

    func testMultipleMainPaneComposersRemainAmbiguous() {
        assertAmbiguous([candidate(1, main: true), candidate(2, main: true)])
    }

    func testUniqueNonsecondaryComposerSelectedWithoutMainMarker() throws {
        let main = candidate(1)
        XCTAssertEqual(try Selection.select([candidate(2, secondary: true), main]), main)
        XCTAssertNil(try Selection.select([candidate(2, secondary: true)]))
        XCTAssertNil(try Selection.select([]))
    }

    func testMultipleRealUnfocusedComposersRejectEitherTraversalOrder() {
        let candidates = [candidate(10), candidate(1)]
        assertAmbiguous(candidates)
        assertAmbiguous(Array(candidates.reversed()))
    }

    private func candidate(_ id: Int, recognized: Bool = true, editable: Bool = true,
                           focused: Bool = false, main: Bool = false, secondary: Bool = false) -> Candidate {
        Candidate(id: id, recognized: recognized, isEditable: editable, isFocused: focused,
                  isInMainPane: main, isSecondary: secondary)
    }

    private func assertAmbiguous(_ candidates: [Candidate], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Selection.select(candidates), file: file, line: line) { error in
            XCTAssertEqual(error as? Selection.SelectionError, .ambiguous, file: file, line: line)
        }
    }
}
