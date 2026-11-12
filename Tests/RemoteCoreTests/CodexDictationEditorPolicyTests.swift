import XCTest
@testable import RemoteCore

final class CodexDictationEditorPolicyTests: XCTestCase {
    private typealias Policy = CodexDictationEditorPolicy

    func testOriginalUniqueKnownEditorDoesNotNeedAnEndRequest() {
        for owned in [false, true] {
            for ending in [false, true] {
                for idle in [false, true] {
                    XCTAssertEqual(Policy.resolve(owned: owned, endingRequested: ending, idle: idle,
                        editorCount: 1, originalEditor: true, recognizedEditor: true,
                        settledEditorMatches: nil), .original)
                }
            }
        }
    }

    func testHiddenEditorDuringOwnedRecordingWaitsWithoutCompletionEvidence() {
        for ending in [false, true] {
            for idle in [false, true] {
                XCTAssertEqual(Policy.resolve(owned: true, endingRequested: ending, idle: idle,
                    editorCount: 0, originalEditor: false, recognizedEditor: false,
                    settledEditorMatches: nil), .waiting)
            }
        }
    }

    func testNoEditorWithoutOwnershipCannotInferProcessing() {
        for ending in [false, true] {
            for idle in [false, true] {
                XCTAssertEqual(Policy.resolve(owned: false, endingRequested: ending, idle: idle,
                    editorCount: 0, originalEditor: false, recognizedEditor: false,
                    settledEditorMatches: nil), .reject)
            }
        }
    }

    func testReplacementDuringRecordingRejectsEvenIfItLooksIdle() {
        for idle in [false, true] {
            XCTAssertEqual(Policy.resolve(owned: true, endingRequested: false, idle: idle,
                editorCount: 1, originalEditor: false, recognizedEditor: true,
                settledEditorMatches: nil), .reject)
        }
    }

    func testReplacementWithoutOwnershipRejectsEvenAfterEndRequest() {
        for ending in [false, true] {
            for idle in [false, true] {
                XCTAssertEqual(Policy.resolve(owned: false, endingRequested: ending, idle: idle,
                    editorCount: 1, originalEditor: false, recognizedEditor: true,
                    settledEditorMatches: nil), .reject)
            }
        }
    }

    func testKnownReplacementAfterStopOrCancelWaitsUntilIdle() {
        XCTAssertEqual(Policy.resolve(owned: true, endingRequested: true, idle: false,
            editorCount: 1, originalEditor: false, recognizedEditor: true,
            settledEditorMatches: nil), .waiting)
        XCTAssertEqual(Policy.resolve(owned: true, endingRequested: true, idle: true,
            editorCount: 1, originalEditor: false, recognizedEditor: true,
            settledEditorMatches: nil), .completedReplacement)
    }

    func testUnknownWritableEditorNeverBecomesCompletionEditor() {
        for original in [false, true] {
            for idle in [false, true] {
                XCTAssertEqual(Policy.resolve(owned: true, endingRequested: true, idle: idle,
                    editorCount: 1, originalEditor: original, recognizedEditor: false,
                    settledEditorMatches: nil), .reject)
            }
        }
    }

    func testDuplicateEditorsRejectEvenWhenOneIsOriginalAndKnown() {
        for count in [-1, 2, 3] {
            for original in [false, true] {
                XCTAssertEqual(Policy.resolve(owned: true, endingRequested: true, idle: true,
                    editorCount: count, originalEditor: original, recognizedEditor: true,
                    settledEditorMatches: nil), .reject)
            }
        }
    }

    func testPinnedCompletionEditorCanBeReadAgainOnlyWhenIdle() {
        XCTAssertEqual(Policy.resolve(owned: true, endingRequested: true, idle: true,
            editorCount: 1, originalEditor: false, recognizedEditor: true,
            settledEditorMatches: true), .completedReplacement)
        XCTAssertEqual(Policy.resolve(owned: true, endingRequested: true, idle: false,
            editorCount: 1, originalEditor: false, recognizedEditor: true,
            settledEditorMatches: true), .waiting)
    }

    func testPinnedCompletionEditorCannotChangeEvenBackToOriginal() {
        for original in [false, true] {
            for idle in [false, true] {
                XCTAssertEqual(Policy.resolve(owned: true, endingRequested: true, idle: idle,
                    editorCount: 1, originalEditor: original, recognizedEditor: true,
                    settledEditorMatches: false), .reject)
            }
        }
    }

    func testCancellationRebuildSequenceOnlyAdoptsAtConfirmedIdle() {
        let sequence: [Policy.Decision] = [
            Policy.resolve(owned: true, endingRequested: false, idle: false, editorCount: 0,
                originalEditor: false, recognizedEditor: false, settledEditorMatches: nil),
            Policy.resolve(owned: true, endingRequested: true, idle: false, editorCount: 0,
                originalEditor: false, recognizedEditor: false, settledEditorMatches: nil),
            Policy.resolve(owned: true, endingRequested: true, idle: false, editorCount: 1,
                originalEditor: false, recognizedEditor: true, settledEditorMatches: nil),
            Policy.resolve(owned: true, endingRequested: true, idle: true, editorCount: 1,
                originalEditor: false, recognizedEditor: true, settledEditorMatches: nil),
            Policy.resolve(owned: true, endingRequested: true, idle: true, editorCount: 1,
                originalEditor: false, recognizedEditor: true, settledEditorMatches: true),
            Policy.resolve(owned: true, endingRequested: true, idle: true, editorCount: 1,
                originalEditor: false, recognizedEditor: true, settledEditorMatches: false)
        ]
        XCTAssertEqual(sequence, [.waiting, .waiting, .waiting,
                                  .completedReplacement, .completedReplacement, .reject])
    }

    func testManualEndingReplacementNeedsExplicitReadOnlyIdleRecovery() {
        XCTAssertEqual(Policy.resolve(owned: true, endingRequested: false, idle: true,
            editorCount: 1, originalEditor: false, recognizedEditor: true,
            settledEditorMatches: nil), .reject)
        XCTAssertEqual(Policy.resolve(owned: true, endingRequested: false, idle: true,
            editorCount: 1, originalEditor: false, recognizedEditor: true,
            settledEditorMatches: nil, readOnlyRecovery: true), .completedReplacement)
    }

    func testReadOnlyRecoveryCannotRetargetAnActiveRecording() {
        XCTAssertEqual(Policy.resolve(owned: true, endingRequested: false, idle: false,
            editorCount: 1, originalEditor: false, recognizedEditor: true,
            settledEditorMatches: nil, readOnlyRecovery: true), .reject)
    }

    func testReadOnlyRecoveryCannotAdoptForeignUnknownOrDuplicateEditors() {
        XCTAssertEqual(Policy.resolve(owned: false, endingRequested: false, idle: true,
            editorCount: 1, originalEditor: false, recognizedEditor: true,
            settledEditorMatches: nil, readOnlyRecovery: true), .reject)
        XCTAssertEqual(Policy.resolve(owned: true, endingRequested: false, idle: true,
            editorCount: 1, originalEditor: false, recognizedEditor: false,
            settledEditorMatches: nil, readOnlyRecovery: true), .reject)
        XCTAssertEqual(Policy.resolve(owned: true, endingRequested: false, idle: true,
            editorCount: 2, originalEditor: false, recognizedEditor: true,
            settledEditorMatches: nil, readOnlyRecovery: true), .reject)
    }

    func testReadOnlyRecoveryStillRequiresThePinnedCompletionEditor() {
        XCTAssertEqual(Policy.resolve(owned: true, endingRequested: false, idle: true,
            editorCount: 1, originalEditor: false, recognizedEditor: true,
            settledEditorMatches: true, readOnlyRecovery: true), .completedReplacement)
        for original in [false, true] {
            XCTAssertEqual(Policy.resolve(owned: true, endingRequested: false, idle: true,
                editorCount: 1, originalEditor: original, recognizedEditor: true,
                settledEditorMatches: false, readOnlyRecovery: true), .reject)
        }
    }
}
