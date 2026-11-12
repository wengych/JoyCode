import Foundation
import XCTest
@testable import RemoteCore

final class NativeDictationCompletionTests: XCTestCase {
    private let target = ComposerTarget(applicationBundleID: "com.anthropic.claudefordesktop", windowID: "window-1", composerID: "composer-1")

    private func snapshot(_ text: String, target: ComposerTarget? = nil, focused: Bool = true, stable: Bool = true) -> ComposerSnapshot {
        ComposerSnapshot(target: target ?? self.target, text: text, isFocused: focused, isStable: stable)
    }

    func testConfirmedChangedTranscriptBecomesReadyWithoutSending() throws {
        var state = RemoteState()
        try state.begin(with: snapshot("seed"))
        try state.stop()
        let completed = snapshot("seed and transcript")
        try state.completeConfirmedDictation(with: completed)

        XCTAssertEqual(state.voicePhase, .idle)
        XCTAssertFalse(state.isTargetLocked)
        XCTAssertNil(state.lockedTarget)
        XCTAssertEqual(state.readyDraft, ReadyDraft(target: target, text: completed.text))
        XCTAssertTrue(state.canSend)
        XCTAssertEqual(try state.validatedReadyDraft(for: completed).text, completed.text)
        XCTAssertNotNil(state.readyDraft, "Completion does not consume or submit the draft")
    }

    func testConfirmedEmptyOrUnchangedRecordingUnlocksWithoutReadyingUnverifiedText() throws {
        for (baseline, result) in [("", ""), ("seed", "seed"), ("seed", " \n"), ("seed", "seed\n  ")] {
            var state = RemoteState()
            try state.begin(with: snapshot(baseline))
            try state.stop()
            try state.completeConfirmedDictation(with: snapshot(result))

            XCTAssertEqual(state.voicePhase, .idle)
            XCTAssertNil(state.lockedTarget)
            XCTAssertNil(state.readyDraft)
            XCTAssertFalse(state.canSend)
            try state.begin(with: snapshot(result))
            XCTAssertEqual(state.voicePhase, .recording, "An empty recording must not block the next recording")
        }
    }

    func testUnchangedRecordingPreservesOnlyExactPreviousReadyDraft() throws {
        var state = RemoteState()
        try state.acceptManualDraft(snapshot("ready draft"))
        try state.begin(with: snapshot("ready draft"))
        try state.stop()
        try state.completeConfirmedDictation(with: snapshot("ready draft"))
        XCTAssertEqual(state.readyDraft, ReadyDraft(target: target, text: "ready draft"))
        XCTAssertTrue(state.canSend)

        try state.begin(with: snapshot("edited without a stable observation"))
        try state.stop()
        try state.completeConfirmedDictation(with: snapshot("edited without a stable observation"))
        XCTAssertNil(state.readyDraft, "An older ready draft must not authorize an unchanged new baseline")
        XCTAssertFalse(state.canSend)
    }

    func testUnchangedRecordingDoesNotRestoreReadinessFromAnotherComposer() throws {
        var state = RemoteState()
        try state.acceptManualDraft(snapshot("same text"))
        var otherTarget = target
        otherTarget.composerID = "other-composer"
        try state.begin(with: snapshot("same text", target: otherTarget))
        try state.stop()
        try state.completeConfirmedDictation(with: snapshot("same text", target: otherTarget))
        XCTAssertEqual(state.voicePhase, .idle)
        XCTAssertNil(state.readyDraft)
        XCTAssertFalse(state.canSend)
    }

    func testEmptyCompletionClearsPreviousReadiness() throws {
        var state = RemoteState()
        try state.acceptManualDraft(snapshot("ready draft"))
        try state.begin(with: snapshot("ready draft"))
        try state.stop()
        try state.completeConfirmedDictation(with: snapshot(""))
        XCTAssertEqual(state.voicePhase, .idle)
        XCTAssertNil(state.readyDraft)
        XCTAssertFalse(state.canSend)
    }

    func testOnlyTranscribingStateCanComplete() throws {
        var state = RemoteState()
        XCTAssertThrowsError(try state.completeConfirmedDictation(with: snapshot("text"))) {
            XCTAssertEqual($0 as? RemoteCoreError, .invalidVoiceTransition)
        }
        try state.begin(with: snapshot(""))
        XCTAssertThrowsError(try state.completeConfirmedDictation(with: snapshot("text"))) {
            XCTAssertEqual($0 as? RemoteCoreError, .invalidVoiceTransition)
        }
        XCTAssertEqual(state.voicePhase, .recording)
        XCTAssertEqual(state.lockedTarget, target)
        state.markUncertain()
        XCTAssertThrowsError(try state.completeConfirmedDictation(with: snapshot("text"))) {
            XCTAssertEqual($0 as? RemoteCoreError, .invalidVoiceTransition)
        }
        XCTAssertEqual(state.voicePhase, .uncertain)
        XCTAssertTrue(state.isTargetLocked)
    }

    func testUnstableOrUnfocusedCompletionLeavesTargetLocked() throws {
        for invalid in [snapshot("text", focused: false), snapshot("text", stable: false)] {
            var state = RemoteState()
            try state.begin(with: snapshot(""))
            try state.stop()
            XCTAssertThrowsError(try state.completeConfirmedDictation(with: invalid)) {
                XCTAssertEqual($0 as? RemoteCoreError, .focusNotConfirmed)
            }
            XCTAssertEqual(state.voicePhase, .transcribing)
            XCTAssertEqual(state.lockedTarget, target)
            XCTAssertNil(state.readyDraft)
            try state.completeConfirmedDictation(with: snapshot("text"))
            XCTAssertTrue(state.canSend)
        }
    }

    func testEveryTargetIdentityFieldMustMatchBeforeCompletion() throws {
        var otherSession = target
        otherSession.sessionID = UUID()
        var otherApplication = target
        otherApplication.applicationBundleID = "com.openai.codex"
        var otherWindow = target
        otherWindow.windowID = "other-window"
        var otherComposer = target
        otherComposer.composerID = "other-composer"
        for otherTarget in [otherSession, otherApplication, otherWindow, otherComposer] {
            var state = RemoteState()
            try state.begin(with: snapshot(""))
            try state.stop()
            XCTAssertThrowsError(try state.completeConfirmedDictation(with: snapshot("text", target: otherTarget))) {
                XCTAssertEqual($0 as? RemoteCoreError, .targetMismatch)
            }
            XCTAssertEqual(state.voicePhase, .transcribing)
            XCTAssertEqual(state.lockedTarget, target)
            XCTAssertNil(state.readyDraft)
            try state.completeConfirmedDictation(with: snapshot("text"))
            XCTAssertTrue(state.canSend)
        }
    }
}
