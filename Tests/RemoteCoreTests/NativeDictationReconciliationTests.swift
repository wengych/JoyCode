import Foundation
import XCTest
@testable import RemoteCore

final class NativeDictationReconciliationTests: XCTestCase {
    private let target = ComposerTarget(
        sessionID: UUID(), applicationBundleID: "com.anthropic.claudefordesktop",
        windowID: "original-window", composerID: "original-composer"
    )

    private func snapshot(_ text: String, target: ComposerTarget? = nil,
                          focused: Bool = true, stable: Bool = true) -> ComposerSnapshot {
        ComposerSnapshot(target: target ?? self.target, text: text,
                         isFocused: focused, isStable: stable)
    }

    private func uncertainState() throws -> RemoteState {
        var state = RemoteState(selectedSessionID: target.sessionID)
        try state.acceptManualDraft(snapshot("previous ready draft"))
        try state.begin(with: snapshot("previous ready draft"))
        state.markUncertain()
        return state
    }

    func testConfirmedIdleUnlocksWithoutFocusOrSendReadiness() throws {
        for text in ["", "previous ready draft", "new native transcript"] {
            var state = try uncertainState()
            let observed = snapshot(text, focused: false)
            try state.reconcileConfirmedNativeIdle(with: observed)

            XCTAssertEqual(state.voicePhase, .idle)
            XCTAssertFalse(state.isTargetLocked)
            XCTAssertNil(state.lockedTarget)
            XCTAssertEqual(state.selectedSessionID, target.sessionID)
            XCTAssertNil(state.readyDraft)
            XCTAssertFalse(state.canSend)

            // Later focus/stability observations alone must not authorize sending.
            let focused = snapshot(text)
            state.observe(focused)
            XCTAssertFalse(state.canSend)
            XCTAssertThrowsError(try state.validatedReadyDraft(for: focused)) {
                XCTAssertEqual($0 as? RemoteCoreError, .draftNotReady)
            }
            if !text.isEmpty {
                try state.acceptManualDraft(focused)
                XCTAssertEqual(try state.validatedReadyDraft(for: focused).text, text)
            }
        }
    }

    func testIdleRejectionPreservesExistingReadyDraft() throws {
        var state = RemoteState(selectedSessionID: target.sessionID)
        let ready = snapshot("ready draft")
        try state.acceptManualDraft(ready)
        XCTAssertThrowsError(try state.reconcileConfirmedNativeIdle(with: snapshot("other text"))) {
            XCTAssertEqual($0 as? RemoteCoreError, .invalidVoiceTransition)
        }
        XCTAssertEqual(state.voicePhase, .idle)
        XCTAssertNil(state.lockedTarget)
        XCTAssertEqual(state.selectedSessionID, target.sessionID)
        XCTAssertTrue(state.canSend)
        XCTAssertEqual(try state.validatedReadyDraft(for: ready).text, ready.text)
    }

    func testRecordingAndTranscribingRejectionsPreserveTheirCompletionPaths() throws {
        for phase in [VoicePhase.recording, .transcribing] {
            var state = RemoteState(selectedSessionID: target.sessionID)
            let ready = snapshot("ready draft")
            try state.acceptManualDraft(ready)
            try state.begin(with: ready)
            if phase == .transcribing { try state.stop() }

            XCTAssertThrowsError(try state.reconcileConfirmedNativeIdle(with: snapshot("other text"))) {
                XCTAssertEqual($0 as? RemoteCoreError, .invalidVoiceTransition)
            }
            XCTAssertEqual(state.voicePhase, phase)
            XCTAssertEqual(state.lockedTarget, target)
            XCTAssertEqual(state.selectedSessionID, target.sessionID)
            XCTAssertNil(state.readyDraft)
            XCTAssertFalse(state.canSend)

            if phase == .recording {
                try state.cancelRecording(confirmed: true)
            } else {
                try state.completeConfirmedDictation(with: ready)
            }
            XCTAssertEqual(state.readyDraft, ReadyDraft(target: target, text: ready.text),
                           "Rejected reconciliation must preserve the prior ready draft and baseline")
        }
    }

    func testUnstableSampleLeavesUncertaintyAndAllowsLaterStableReconciliation() throws {
        var state = try uncertainState()
        XCTAssertThrowsError(try state.reconcileConfirmedNativeIdle(with: snapshot("new text", stable: false))) {
            XCTAssertEqual($0 as? RemoteCoreError, .focusNotConfirmed)
        }
        XCTAssertEqual(state.voicePhase, .uncertain)
        XCTAssertEqual(state.lockedTarget, target)
        XCTAssertEqual(state.selectedSessionID, target.sessionID)
        XCTAssertNil(state.readyDraft)
        XCTAssertFalse(state.canSend)

        try state.reconcileConfirmedNativeIdle(with: snapshot("new text", focused: false))
        XCTAssertEqual(state.voicePhase, .idle)
        XCTAssertNil(state.readyDraft)
    }

    func testEveryTargetIdentityFieldMustMatchBeforeUnlocking() throws {
        var noSession = target
        noSession.sessionID = nil
        var otherSession = target
        otherSession.sessionID = UUID()
        var otherApplication = target
        otherApplication.applicationBundleID = "com.openai.codex"
        var otherWindow = target
        otherWindow.windowID = "other-window"
        var otherComposer = target
        otherComposer.composerID = "other-composer"

        for wrongTarget in [noSession, otherSession, otherApplication, otherWindow, otherComposer] {
            var state = try uncertainState()
            XCTAssertThrowsError(try state.reconcileConfirmedNativeIdle(with: snapshot("text", target: wrongTarget))) {
                XCTAssertEqual($0 as? RemoteCoreError, .targetMismatch)
            }
            XCTAssertEqual(state.voicePhase, .uncertain)
            XCTAssertEqual(state.lockedTarget, target)
            XCTAssertEqual(state.selectedSessionID, target.sessionID)
            XCTAssertNil(state.readyDraft)
            XCTAssertFalse(state.canSend)

            try state.reconcileConfirmedNativeIdle(with: snapshot("text"))
            XCTAssertEqual(state.voicePhase, .idle)
            XCTAssertNil(state.readyDraft)
        }
    }

    func testUncertaintyWithoutCapturedTargetCannotAdoptAnObservedTarget() {
        var state = RemoteState(selectedSessionID: target.sessionID)
        state.markUncertain()
        XCTAssertThrowsError(try state.reconcileConfirmedNativeIdle(with: snapshot("text"))) {
            XCTAssertEqual($0 as? RemoteCoreError, .targetMismatch)
        }
        XCTAssertEqual(state.voicePhase, .uncertain)
        XCTAssertNil(state.lockedTarget)
        XCTAssertEqual(state.selectedSessionID, target.sessionID)
        XCTAssertFalse(state.canSend)
    }

    func testReconciledTextDoesNotBecomePriorReadinessForNextRecording() throws {
        var state = try uncertainState()
        let observed = snapshot("previous ready draft")
        try state.reconcileConfirmedNativeIdle(with: observed)
        try state.begin(with: observed)
        try state.stop()
        try state.completeConfirmedDictation(with: observed)

        XCTAssertEqual(state.voicePhase, .idle)
        XCTAssertEqual(state.selectedSessionID, target.sessionID)
        XCTAssertNil(state.readyDraft)
        XCTAssertFalse(state.canSend)
    }
}
