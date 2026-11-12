import XCTest
@testable import RemoteCore

final class SubmissionAttemptGuardTests: XCTestCase {
    func testUnchangedComposerCannotRepeatTheLastNativeRequest() {
        var guardState = SubmissionAttemptGuard()
        XCTAssertFalse(guardState.hasPending(target: "chat-a"))
        XCTAssertTrue(guardState.permits(target: "chat-a", text: "test message"))
        guardState.recordDispatch(target: "chat-a", text: "test message")
        XCTAssertTrue(guardState.hasPending(target: "chat-a"))
        for _ in 0..<3 {
            XCTAssertFalse(guardState.permits(target: "chat-a", text: "test message"))
        }
    }

    func testAXPressErrorDoesNotPermitAnIdenticalRetry() {
        enum AXFailure: Error { case resultUnknown }
        var guardState = SubmissionAttemptGuard()
        var nativeRequests = 0

        func sendIfPermitted() throws {
            guard guardState.permits(target: "chat-a", text: "do the task") else { return }
            guardState.recordDispatch(target: "chat-a", text: "do the task")
            nativeRequests += 1
            // A timeout is compatible with delivery; no successful result arrives.
            throw AXFailure.resultUnknown
        }

        XCTAssertThrowsError(try sendIfPermitted())
        guardState.observe(target: "chat-a", text: "do the task")
        XCTAssertNoThrow(try sendIfPermitted())
        XCTAssertEqual(nativeRequests, 1)
    }

    func testEditedTextOrDifferentTargetAllowsANewExplicitSend() {
        var guardState = SubmissionAttemptGuard()
        guardState.recordDispatch(target: "chat-a", text: "same words")
        XCTAssertTrue(guardState.permits(target: "chat-a", text: "edited words"))
        XCTAssertTrue(guardState.permits(target: "chat-a", text: "same words\n"))
        XCTAssertTrue(guardState.permits(target: "chat-b", text: "same words"))
        XCTAssertFalse(guardState.permits(target: "chat-a", text: "same words"))
    }

    func testSwitchingFocusAwayAndBackDoesNotDiscardReceipt() {
        var guardState = SubmissionAttemptGuard()
        guardState.recordDispatch(target: "original-window", text: "pending request")
        XCTAssertTrue(guardState.permits(target: "other-window", text: "other draft"))
        XCTAssertTrue(guardState.permits(target: "other-app", text: "pending request"))
        XCTAssertFalse(guardState.permits(target: "original-window", text: "pending request"))
    }

    func testFailedPreflightNeitherRecordsANewAttemptNorClearsTheOldOne() {
        var guardState = SubmissionAttemptGuard()
        guardState.recordDispatch(target: "chat-a", text: "last dispatch")

        // A first B send is permitted, but its later AX/window preflight fails.
        XCTAssertTrue(guardState.permits(target: "chat-b", text: "unsent draft"))
        // No recordDispatch call occurred: B is still retryable, while A is not.
        XCTAssertTrue(guardState.permits(target: "chat-b", text: "unsent draft"))
        XCTAssertFalse(guardState.permits(target: "chat-a", text: "last dispatch"))
    }

    func testDispatchingAnotherTargetKeepsBothReceiptsPending() {
        var guardState = SubmissionAttemptGuard()
        guardState.recordDispatch(target: "chat-a", text: "first")
        XCTAssertFalse(guardState.permits(target: "chat-a", text: "first"))

        guardState.recordDispatch(target: "chat-b", text: "second")
        XCTAssertFalse(guardState.permits(target: "chat-b", text: "second"))
        XCTAssertFalse(guardState.permits(target: "chat-a", text: "first"))
        XCTAssertTrue(guardState.hasPending(target: "chat-a"))
        XCTAssertTrue(guardState.hasPending(target: "chat-b"))
    }

    func testVerifiedClearingAllowsIntentionalSamePromptAgain() {
        var guardState = SubmissionAttemptGuard()
        guardState.recordDispatch(target: "chat-a", text: "repeatable task")
        XCTAssertFalse(guardState.permits(target: "chat-a", text: "repeatable task"))

        guardState.observe(target: "chat-a", text: "")
        XCTAssertFalse(guardState.hasPending(target: "chat-a"))
        XCTAssertTrue(guardState.permits(target: "chat-a", text: "repeatable task"))
        guardState.recordDispatch(target: "chat-a", text: "repeatable task")
        XCTAssertFalse(guardState.permits(target: "chat-a", text: "repeatable task"))
    }

    func testOtherTargetClearingCannotReleaseTheOriginalUnknownRequest() {
        var guardState = SubmissionAttemptGuard()
        guardState.recordDispatch(target: "chat-a", text: "pending request")
        guardState.observe(target: "chat-b", text: "")
        guardState.observe(target: "chat-b", text: "different draft")
        guardState.observe(target: "chat-a", text: "pending request")
        XCTAssertFalse(guardState.permits(target: "chat-a", text: "pending request"))
    }

    func testVerifiedEditAllowsANewRequestWithoutCreatingANewReceipt() {
        var guardState = SubmissionAttemptGuard()
        guardState.recordDispatch(target: "chat-a", text: "old content")
        guardState.observe(target: "chat-a", text: "reviewed content")
        XCTAssertTrue(guardState.permits(target: "chat-a", text: "reviewed content"))
        // A user can deliberately restore the old prompt after the verified edit.
        guardState.observe(target: "chat-a", text: "old content")
        XCTAssertTrue(guardState.permits(target: "chat-a", text: "old content"))
    }

    func testUnknownRequestRemainsBlockedAfterSendingAndClearingAnotherChat() {
        var guardState = SubmissionAttemptGuard()
        // A's AXPress result is unknown and its composer still shows the old text.
        guardState.recordDispatch(target: "chat-a", text: "possibly delivered")
        guardState.observe(target: "chat-a", text: "possibly delivered")

        // The user switches to B, sends successfully, and B visibly clears.
        XCTAssertTrue(guardState.permits(target: "chat-b", text: "another request"))
        guardState.recordDispatch(target: "chat-b", text: "another request")
        guardState.observe(target: "chat-b", text: "")
        XCTAssertFalse(guardState.hasPending(target: "chat-b"))

        // Returning to A cannot bypass its unresolved receipt through that B send.
        guardState.observe(target: "chat-a", text: "possibly delivered")
        XCTAssertTrue(guardState.hasPending(target: "chat-a"))
        XCTAssertFalse(guardState.permits(target: "chat-a", text: "possibly delivered"))
    }

    func testNewDispatchOnOneTargetDoesNotReplaceAnotherTargetsPendingText() {
        var guardState = SubmissionAttemptGuard()
        guardState.recordDispatch(target: "chat-a", text: "first version")
        guardState.recordDispatch(target: "chat-b", text: "other pending request")
        guardState.observe(target: "chat-a", text: "reviewed version")
        guardState.recordDispatch(target: "chat-a", text: "reviewed version")

        XCTAssertFalse(guardState.permits(target: "chat-a", text: "reviewed version"))
        XCTAssertTrue(guardState.permits(target: "chat-a", text: "first version"))
        XCTAssertFalse(guardState.permits(target: "chat-b", text: "other pending request"))
        guardState.observe(target: "chat-a", text: "")
        XCTAssertFalse(guardState.hasPending(target: "chat-a"))
        XCTAssertTrue(guardState.hasPending(target: "chat-b"))
    }
}
