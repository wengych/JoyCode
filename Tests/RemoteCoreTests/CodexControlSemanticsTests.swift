import XCTest
@testable import RemoteCore

final class CodexControlSemanticsTests: XCTestCase {
    func testCurrentComposerSubmissionModesInEvidencedLanguages() {
        for label in ["Send", "发送", "傳送", "Queue", "排队", "加入佇列",
                      "Steer", "引导", "引導"] {
            XCTAssertTrue(CodexControlSemantics.isSend(role: "AXButton", names: [label]), label)
        }
        XCTAssertTrue(CodexControlSemantics.isSend(role: "AXButton", names: [" Send\n", "发送"]))
        XCTAssertTrue(CodexControlSemantics.isSend(role: "AXButton", names: ["STEER", "引導"]))
    }

    func testStopResumeAndVoiceControlsCannotSubmitReviewedDraft() {
        for label in ["Stop", "停止", "Resume", "继续", "繼續", "恢復",
                      "Transcribe and send", "转录并发送", "轉錄並傳送", "Start voice chat",
                      "Stop dictation", "Cancel dictation", "Retry dictation", "Dictate"] {
            XCTAssertFalse(CodexControlSemantics.isSend(role: "AXButton", names: [label]), label)
            XCTAssertFalse(CodexControlSemantics.isSend(role: "AXButton", names: ["Send", label],
                                                       identifier: "send-button"), label)
        }
    }

    func testUnknownAndSimilarLabelsAreNotSubmissionEvidence() {
        for label in ["", "Send message", "Resend", "Send settings", "Send to queue",
                      "Queue settings", "Steering", "发送设置", "排队中", "傳送中"] {
            XCTAssertFalse(CodexControlSemantics.isSend(role: "AXButton", names: [label]), label)
        }
        XCTAssertFalse(CodexControlSemantics.isSend(role: "AXButton", names: []))
    }

    func testIdentifierAloneDoesNotAuthorizeOrOverrideActionLabels() {
        for identifier: String? in [nil, "", "send-button", "composer-submit-button", "send"] {
            XCTAssertFalse(CodexControlSemantics.isSend(role: "AXButton", names: [], identifier: identifier))
            XCTAssertFalse(CodexControlSemantics.isSend(role: "AXButton", names: ["Stop"], identifier: identifier))
            XCTAssertFalse(CodexControlSemantics.isSend(role: "AXButton", names: ["Resume"], identifier: identifier))
            XCTAssertTrue(CodexControlSemantics.isSend(role: "AXButton", names: ["Send"], identifier: identifier))
        }
    }

    func testConflictingSubmissionModesDoNotChooseAnArbitraryAction() {
        for labels in [["Send", "Queue"], ["排队", "Steer"], ["引导", "傳送"]] {
            XCTAssertFalse(CodexControlSemantics.isSend(role: "AXButton", names: labels))
        }
    }

    func testSubmissionRequiresAVisibleButton() {
        XCTAssertFalse(CodexControlSemantics.isSend(role: "AXButton", names: ["Send"], hidden: true))
        XCTAssertTrue(CodexControlSemantics.isSend(role: "AXButton", names: ["Send"], hidden: false))
        for role in ["AXGroup", "AXScrollArea", "AXCheckBox", "AXTextField", "AXStaticText", "AXMenuItem", ""] {
            XCTAssertFalse(CodexControlSemantics.isSend(role: role, names: ["Send"]), role)
        }
    }

    func testConversationRegionMatchesOnlyObservedRolesAndWholeLabels() {
        for role in ["AXGroup", "AXScrollArea"] {
            for label in ["Conversation", "对话", "對話", " conversation\n"] {
                XCTAssertTrue(CodexControlSemantics.isConversationRegion(role: role, names: [label]))
            }
            for label in ["", "Conversations", "New conversation", "Conversation list", "对话列表", "新對話"] {
                XCTAssertFalse(CodexControlSemantics.isConversationRegion(role: role, names: [label]), label)
            }
        }
    }

    func testConversationRegionRejectsHiddenOrOtherControls() {
        XCTAssertFalse(CodexControlSemantics.isConversationRegion(role: "AXGroup", names: ["Conversation"], hidden: true))
        XCTAssertFalse(CodexControlSemantics.isConversationRegion(role: "AXScrollArea", names: []))
        for role in ["AXButton", "AXTextArea", "AXStaticText", "AXWebArea", ""] {
            XCTAssertFalse(CodexControlSemantics.isConversationRegion(role: role, names: ["Conversation"]), role)
        }
    }
}
