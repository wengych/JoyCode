import XCTest
@testable import RemoteCore

final class CodexDictationSemanticsTests: XCTestCase {
    private typealias Semantics = CodexDictationSemantics
    private typealias Evidence = Semantics.ControlEvidence

    func testKnownEnglishLabelsMatchExactlyOnButtonRoles() {
        let cases: [(String, Semantics.Control)] = [
            ("Dictate", .dictate), ("Stop dictation", .stop),
            ("Cancel dictation", .cancel), ("Transcribe and send", .transcribeAndSend),
            ("Transcribing", .processing), ("Retry dictation", .retry)
        ]
        for (label, control) in cases {
            for role in ["AXButton", "AXCheckBox"] {
                XCTAssertEqual(Semantics.match(role: role, names: ["", label], hidden: false), control)
                XCTAssertEqual(Semantics.match(role: role, names: [label.uppercased(), " \(label)\n"], hidden: nil), control)
            }
        }
    }

    func testEvidencedSimplifiedAndTraditionalLabelsMatch() {
        let cases: [(Semantics.Control, [String])] = [
            (.dictate, ["听写", "聽寫"]),
            (.stop, ["停止听写", "停止聽寫", "停止口述"]),
            (.cancel, ["取消听写", "取消聽寫", "Cancel transcription", "取消转录", "取消轉錄"]),
            (.transcribeAndSend, ["转录并发送", "轉錄並傳送"]),
            (.processing, ["正在转写", "轉錄中", "正在轉錄", "Starting dictation; click to cancel",
                "正在启动听写；点击可取消", "正在開始聽寫；按一下即可取消", "正在啟動聽寫，按一下即可取消",
                "Finishing dictation", "正在完成听写", "正在完成聽寫",
                "Preparing dictation", "正在准备听写", "正在準備聽寫"]),
            (.retry, ["重试听写", "重新嘗試聽寫轉錄", "重試聽寫"])
        ]
        for (control, labels) in cases {
            for label in labels {
                XCTAssertEqual(Semantics.match(role: "AXButton", names: [label], hidden: false), control)
            }
        }
    }

    func testUnknownPartialAndUnevidencedLocalizedNamesDoNotMatch() {
        for name in ["", "Stop", "Cancel", "Send", "Start dictation", "Stop dictation and send",
                     "Transcribe and send now", "Retry", "Dictating", "停止", "发送", "語音輸入"] {
            XCTAssertNil(Semantics.match(role: "AXButton", names: [name], hidden: false))
        }
    }

    func testHiddenOrWrongRoleControlsDoNotMatch() {
        XCTAssertNil(Semantics.match(role: "AXButton", names: ["Dictate"], hidden: true))
        for role in ["AXTextArea", "AXStaticText", "AXGroup", "AXProgressIndicator", ""] {
            XCTAssertNil(Semantics.match(role: role, names: ["Dictate"], hidden: false))
        }
    }

    func testConflictingRecognizedNamesNeverChooseAnAction() {
        for names in [["Dictate", "Stop dictation"], ["Stop dictation", "Transcribe and send"],
                      ["Cancel dictation", "Retry dictation"], ["停止听写", "转录并发送"]] {
            XCTAssertNil(Semantics.match(role: "AXButton", names: names, hidden: false))
        }
        XCTAssertEqual(Semantics.match(role: "AXButton", names: ["Stop dictation", "Stop dictation"], hidden: false), .stop)
    }

    func testIdleRequiresUniqueEnabledDictateAndEditableComposer() {
        for owned in [false, true] {
            for ending in [false, true] {
                XCTAssertEqual(Semantics.classify(controls: [Evidence(kind: .dictate, enabled: true)],
                    composerEditable: true, owned: owned, endingRequested: ending), .idle)
            }
        }
        XCTAssertEqual(Semantics.classify(controls: [Evidence(kind: .dictate, enabled: false)],
            composerEditable: true, owned: false, endingRequested: false), .unavailable)
        XCTAssertEqual(Semantics.classify(controls: [Evidence(kind: .dictate, enabled: true)],
            composerEditable: false, owned: false, endingRequested: false), .unavailable)
    }

    func testOwnedDisabledOrReadOnlyStartIsProcessingNotIdle() {
        for enabled in [false, true] {
            for editable in [false, true] where !enabled || !editable {
                XCTAssertEqual(Semantics.classify(controls: [Evidence(kind: .dictate, enabled: enabled)],
                    composerEditable: editable, owned: true, endingRequested: true), .processing)
            }
        }
    }

    func testEnabledStopAndCancelConfirmRecordingWithEitherEditorState() {
        let controls = [Evidence(kind: .stop, enabled: true), Evidence(kind: .cancel, enabled: true)]
        for editable in [false, true] {
            for owned in [false, true] {
                for ending in [false, true] {
                    XCTAssertEqual(Semantics.classify(controls: controls, composerEditable: editable,
                        owned: owned, endingRequested: ending), .recording)
                }
            }
        }
    }

    func testTranscribeAndSendNeverSubstitutesForStopOrConfirmsIdle() {
        let send = Evidence(kind: .transcribeAndSend, enabled: true)
        let cancel = Evidence(kind: .cancel, enabled: true)
        XCTAssertEqual(Semantics.classify(controls: [send], composerEditable: true,
            owned: false, endingRequested: false), .unavailable)
        XCTAssertEqual(Semantics.classify(controls: [send, cancel], composerEditable: true,
            owned: true, endingRequested: false), .unavailable)
        XCTAssertEqual(Semantics.classify(controls: [send, .init(kind: .dictate, enabled: true)],
            composerEditable: true, owned: true, endingRequested: true), .unavailable)
        XCTAssertEqual(Semantics.classify(controls: [send, cancel, .init(kind: .stop, enabled: true)],
            composerEditable: true, owned: true, endingRequested: false), .recording)
    }

    func testDuplicateOrContradictoryControlsAreUnavailable() {
        for controls: [Evidence] in [
            [.init(kind: .stop, enabled: true), .init(kind: .stop, enabled: true), .init(kind: .cancel, enabled: true)],
            [.init(kind: .dictate, enabled: true), .init(kind: .dictate, enabled: false)],
            [.init(kind: .cancel, enabled: true), .init(kind: .cancel, enabled: false)],
            [.init(kind: .dictate, enabled: true), .init(kind: .stop, enabled: true), .init(kind: .cancel, enabled: true)],
            [.init(kind: .dictate, enabled: true), .init(kind: .processing, enabled: false)],
            [.init(kind: .processing, enabled: false), .init(kind: .stop, enabled: true), .init(kind: .cancel, enabled: true)]
        ] {
            XCTAssertEqual(Semantics.classify(controls: controls, composerEditable: true,
                owned: true, endingRequested: true), .unavailable)
        }
    }

    func testPartialRecordingPairDoesNotConfirmRecording() {
        for kind in [Semantics.Control.stop, .cancel] {
            XCTAssertEqual(Semantics.classify(controls: [Evidence(kind: kind, enabled: true)],
                composerEditable: true, owned: true, endingRequested: false), .unavailable)
        }
    }

    func testDisabledRecordingControlsRequireOwnershipToInferProcessing() {
        for stopEnabled in [false, true] {
            for cancelEnabled in [false, true] where !stopEnabled || !cancelEnabled {
                let controls = [Evidence(kind: .stop, enabled: stopEnabled), Evidence(kind: .cancel, enabled: cancelEnabled)]
                XCTAssertEqual(Semantics.classify(controls: controls, composerEditable: false,
                    owned: true, endingRequested: true), .processing)
                XCTAssertEqual(Semantics.classify(controls: controls, composerEditable: false,
                    owned: false, endingRequested: false), .unavailable)
            }
        }
    }

    func testExplicitTranscribingIsProcessingAndNeverReadyToSend() {
        for enabled in [false, true] {
            for owned in [false, true] {
                XCTAssertEqual(Semantics.classify(controls: [Evidence(kind: .processing, enabled: enabled)],
                    composerEditable: true, owned: owned, endingRequested: owned), owned ? .processing : .unavailable)
            }
        }
        XCTAssertEqual(Semantics.classify(controls: [
            .init(kind: .processing, enabled: false), .init(kind: .stop, enabled: false), .init(kind: .cancel, enabled: true)
        ], composerEditable: false, owned: true, endingRequested: true), .processing)
    }

    func testMissingControlsOnlyInferProcessingDuringAnOwnedEnding() {
        for owned in [false, true] {
            for ending in [false, true] {
                XCTAssertEqual(Semantics.classify(controls: [], composerEditable: true,
                    owned: owned, endingRequested: ending), owned && ending ? .processing : .unavailable)
            }
        }
        XCTAssertEqual(Semantics.classify(controls: [.init(kind: .transcribeAndSend, enabled: true)],
            composerEditable: true, owned: true, endingRequested: true), .processing)
    }

    func testRetrySurfaceNeverMeansIdleOrStartsAutomatically() {
        for controls: [Evidence] in [[.init(kind: .retry, enabled: true)],
            [.init(kind: .retry, enabled: false), .init(kind: .dictate, enabled: true)],
            [.init(kind: .retry, enabled: true), .init(kind: .processing, enabled: false)]] {
            XCTAssertEqual(Semantics.classify(controls: controls, composerEditable: true,
                owned: true, endingRequested: true), .unavailable)
        }
    }
}
