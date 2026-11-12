import Foundation
import XCTest
@testable import RemoteCore

final class CancellationReadinessRegressionTests: XCTestCase {
    private let original = ComposerTarget(applicationBundleID: "com.anthropic.claudefordesktop",
                                          windowID: "window-a", composerID: "composer-a")

    private func snapshot(_ text: String, target: ComposerTarget) -> ComposerSnapshot {
        ComposerSnapshot(target: target, text: text, isFocused: true, isStable: true)
    }

    func testCancellingInAnotherTargetNeverRestoresTheOldChatsReadyDraft() throws {
        var otherApp = original
        otherApp.applicationBundleID = "com.openai.codex"
        var otherWindow = original
        otherWindow.windowID = "window-b"
        var otherComposer = original
        otherComposer.composerID = "composer-b"
        var otherSession = original
        otherSession.sessionID = UUID()

        for newTarget in [otherApp, otherWindow, otherComposer, otherSession] {
            var state = RemoteState()
            try state.acceptManualDraft(snapshot("same words", target: original))
            try state.begin(with: snapshot("same words", target: newTarget))
            try state.cancelRecording(confirmed: true)

            XCTAssertEqual(state.voicePhase, .idle)
            XCTAssertNil(state.lockedTarget)
            XCTAssertEqual(state.selectedSessionID, newTarget.sessionID)
            XCTAssertNil(state.readyDraft, "Cancelling the current target cannot revive another target's readiness")
            state.observe(snapshot("same words", target: newTarget))
            XCTAssertFalse(state.canSend)

            // The actual current draft remains usable after a fresh explicit send request.
            try state.acceptManualDraft(snapshot("same words", target: newTarget))
            XCTAssertEqual(try state.validatedReadyDraft(for: snapshot("same words", target: newTarget)).target,
                           newTarget)
        }
    }

    func testCancellingAfterAnUnobservedEditDoesNotRestoreStaleTextReadiness() throws {
        var state = RemoteState()
        try state.acceptManualDraft(snapshot("previous ready text", target: original))
        let edited = snapshot("edited before recording started", target: original)
        try state.begin(with: edited)
        try state.cancelRecording(confirmed: true)

        XCTAssertEqual(state.voicePhase, .idle)
        XCTAssertNil(state.readyDraft)
        state.observe(edited)
        XCTAssertFalse(state.canSend, "An unchanged cancelled recording cannot turn an unverified baseline into a ready transcript")
        try state.acceptManualDraft(edited)
        XCTAssertEqual(try state.validatedReadyDraft(for: edited).text, edited.text)
    }

    func testReturningAfterAnotherChatsCancellationCannotResurrectOldReadiness() throws {
        var other = original
        other.composerID = "composer-b"
        var state = RemoteState()
        let firstDraft = snapshot("draft a", target: original)
        try state.acceptManualDraft(firstDraft)

        try state.begin(with: snapshot("draft b", target: other))
        try state.cancelRecording(confirmed: true)
        try state.begin(with: firstDraft)
        try state.cancelRecording(confirmed: true)
        state.observe(firstDraft)

        XCTAssertEqual(state.voicePhase, .idle)
        XCTAssertFalse(state.isTargetLocked)
        XCTAssertNil(state.readyDraft)
        XCTAssertFalse(state.canSend)
        XCTAssertThrowsError(try state.consumeReadyDraft(for: firstDraft)) {
            XCTAssertEqual($0 as? RemoteCoreError, .draftNotReady)
        }
    }

    func testManualResetAfterInterruptDoesNotRestoreReadinessInAReenteredRecording() throws {
        for interruptedPhase in [VoicePhase.recording, .transcribing] {
            var state = RemoteState()
            let oldDraft = snapshot("previous ready text", target: original)
            try state.acceptManualDraft(oldDraft)
            try state.begin(with: oldDraft)
            if interruptedPhase == .transcribing { try state.stop() }
            state.markUncertain()

            XCTAssertEqual(state.lockedTarget, original)
            XCTAssertTrue(state.isTargetLocked)
            state.confirmVoiceStopped()
            XCTAssertEqual(state.voicePhase, .idle)
            XCTAssertNil(state.lockedTarget)
            XCTAssertNil(state.readyDraft)
            state.observe(oldDraft)
            XCTAssertFalse(state.canSend)

            var otherTarget = original
            otherTarget.applicationBundleID = "com.openai.codex"
            otherTarget.composerID = "current-codex-composer"
            try state.begin(with: snapshot("new current draft", target: otherTarget))
            try state.cancelRecording(confirmed: true)
            state.observe(oldDraft)
            XCTAssertNil(state.readyDraft, "Interrupt/reset cannot leave a previous-ready draft to restore later")
            XCTAssertFalse(state.canSend)
            XCTAssertFalse(state.isTargetLocked)

            // Only a new explicit manual-send validation may make that draft ready again.
            try state.acceptManualDraft(oldDraft)
            XCTAssertEqual(try state.validatedReadyDraft(for: oldDraft).text, oldDraft.text)
        }
    }
}
