import XCTest
@testable import RemoteCore

final class ForegroundActionPolicyTests: XCTestCase {
    private let claude = "com.anthropic.claudefordesktop"
    private let codex = "com.openai.codex"

    func testIdleClaudeSupportsEveryOrdinaryAction() throws {
        for action in ForegroundAction.allCases {
            XCTAssertEqual(try ForegroundActionPolicy.resolve(
                action: action, foregroundBundleID: claude, voicePhase: .idle,
                ownedBundleID: nil), .claude)
        }
    }

    func testIdleCodexSupportsEveryOrdinaryActionRegardlessOfStaleVoiceOwner() throws {
        for action in ForegroundAction.allCases {
            XCTAssertEqual(try ForegroundActionPolicy.resolve(
                action: action, foregroundBundleID: codex, voicePhase: .idle,
                ownedBundleID: claude), .chatGPT)
        }
    }

    func testUnknownForegroundNeverFallsBackToTheOwnedAgent() {
        for foreground: String? in [nil, "", "com.apple.finder", "local.weng.XboxAgentRemote",
                                   "com.openai.codex.helper", "com.anthropic.claudefordesktop.helper",
                                   "com.openai.Codex", " com.anthropic.claudefordesktop"] {
            for action in ForegroundAction.allCases {
                XCTAssertThrowsError(try ForegroundActionPolicy.resolve(
                    action: action, foregroundBundleID: foreground, voicePhase: .idle,
                    ownedBundleID: claude)) {
                    XCTAssertEqual($0 as? ForegroundActionPolicyError, .unsupportedForeground)
                }
            }
        }
    }

    func testSendAndSessionStayLockedInEveryNonIdlePhase() {
        for phase in [VoicePhase.recording, .transcribing, .uncertain] {
            for foreground: String? in [claude, codex, "com.apple.finder", nil] {
                for owner: String? in [claude, codex, nil] {
                    for action in [ForegroundAction.send, .session] {
                        XCTAssertThrowsError(try ForegroundActionPolicy.resolve(
                            action: action, foregroundBundleID: foreground, voicePhase: phase,
                            ownedBundleID: owner)) {
                            XCTAssertEqual($0 as? RemoteCoreError, .targetLocked)
                        }
                    }
                }
            }
        }
    }

    func testLockedVoiceCancelAndScrollRequireTheCurrentOwnedAgent() throws {
        for phase in [VoicePhase.recording, .transcribing, .uncertain] {
            for action in [ForegroundAction.voice, .cancel, .scroll] {
                XCTAssertEqual(try ForegroundActionPolicy.resolve(
                    action: action, foregroundBundleID: claude, voicePhase: phase,
                    ownedBundleID: claude), .claude)
                for pair: (String?, String?) in [(codex, claude), (nil, claude),
                                                ("com.apple.finder", claude), (claude, nil),
                                                (claude, codex), (codex, nil),
                                                ("com.apple.finder", "com.apple.finder"),
                                                ("com.openai.codex.helper", "com.openai.codex.helper")] {
                    XCTAssertThrowsError(try ForegroundActionPolicy.resolve(
                        action: action, foregroundBundleID: pair.0, voicePhase: phase,
                        ownedBundleID: pair.1)) {
                        XCTAssertEqual($0 as? ForegroundActionPolicyError, .voiceTargetMismatch)
                    }
                }
                XCTAssertEqual(try ForegroundActionPolicy.resolve(
                    action: action, foregroundBundleID: codex, voicePhase: phase,
                    ownedBundleID: codex), .chatGPT)
            }
        }
    }

    func testCodexOwnedVoiceCannotOperateClaudeOrAnotherForeground() {
        var writes: [ForegroundAction] = []
        for phase in [VoicePhase.recording, .transcribing, .uncertain] {
            for action in [ForegroundAction.voice, .cancel, .scroll] {
                for foreground: String? in [claude, "com.apple.finder", nil] {
                    XCTAssertThrowsError(try {
                        _ = try ForegroundActionPolicy.resolve(
                            action: action, foregroundBundleID: foreground,
                            voicePhase: phase, ownedBundleID: codex)
                        writes.append(action)
                    }()) {
                        XCTAssertEqual($0 as? ForegroundActionPolicyError, .voiceTargetMismatch)
                    }
                }
            }
        }
        XCTAssertTrue(writes.isEmpty)
    }

    func testTargetIdentityRejectsAppProcessAndWindowChanges() {
        let expected = ForegroundTargetIdentity(bundleID: claude, pid: 41, windowID: "window-1")
        for current in [
            ForegroundTargetIdentity(bundleID: codex, pid: 41, windowID: "window-1"),
            ForegroundTargetIdentity(bundleID: claude, pid: 42, windowID: "window-1"),
            ForegroundTargetIdentity(bundleID: claude, pid: 41, windowID: "window-2")
        ] {
            XCTAssertThrowsError(try ForegroundActionPolicy.validate(expected: expected, current: current)) {
                XCTAssertEqual($0 as? ForegroundActionPolicyError, .targetChanged)
            }
        }
    }

    func testMissingOrInvalidWindowIdentityNeverPermitsOperation() {
        let expected = ForegroundTargetIdentity(bundleID: claude, pid: 41, windowID: "window-1")
        let invalid: [ForegroundTargetIdentity?] = [
            nil, .init(bundleID: claude, pid: 41, windowID: ""),
            .init(bundleID: claude, pid: 41, windowID: " \n"),
            .init(bundleID: claude, pid: 0, windowID: "window-1"),
            .init(bundleID: claude, pid: -1, windowID: "window-1"),
            .init(bundleID: "", pid: 41, windowID: "window-1")
        ]
        var mutations = 0
        for current in invalid {
            XCTAssertThrowsError(try ForegroundActionPolicy.withVerifiedTarget(
                expected: expected, current: { current }, operation: { mutations += 1 })) {
                XCTAssertEqual($0 as? ForegroundActionPolicyError, .targetUnavailable)
            }
        }
        XCTAssertEqual(mutations, 0)
        XCTAssertThrowsError(try ForegroundActionPolicy.validate(
            expected: .init(bundleID: claude, pid: 41, windowID: ""), current: expected))
    }

    func testEveryActionRechecksForegroundAtTheMutationBoundary() throws {
        for bundleID in [claude, codex] {
            let original = ForegroundTargetIdentity(bundleID: bundleID, pid: 41, windowID: "window-1")
            for action in ForegroundAction.allCases {
                _ = try ForegroundActionPolicy.resolve(action: action, foregroundBundleID: bundleID,
                                                      voicePhase: .idle, ownedBundleID: nil)
                for changed: ForegroundTargetIdentity? in [
                    .init(bundleID: bundleID == claude ? codex : claude, pid: 51, windowID: "other-window"),
                    .init(bundleID: bundleID, pid: 41, windowID: "window-2"),
                    .init(bundleID: bundleID, pid: 42, windowID: "window-1"), nil
                ] {
                    var writes: [ForegroundAction] = []
                    XCTAssertThrowsError(try ForegroundActionPolicy.withVerifiedTarget(
                        expected: original, current: { changed }, operation: { writes.append(action) }))
                    XCTAssertTrue(writes.isEmpty, "\(action) mutated a stale \(bundleID) target")
                }
            }
        }
    }

    func testRejectedRoutesNeverReachTheMutationClosure() {
        var writes: [ForegroundAction] = []
        for action in ForegroundAction.allCases {
            XCTAssertThrowsError(try {
                _ = try ForegroundActionPolicy.resolve(action: action, foregroundBundleID: "com.apple.finder",
                                                      voicePhase: .idle, ownedBundleID: claude)
                let target = ForegroundTargetIdentity(bundleID: "com.apple.finder", pid: 51, windowID: "other-window")
                try ForegroundActionPolicy.withVerifiedTarget(expected: target, current: { target }) {
                    writes.append(action)
                }
            }())
        }
        XCTAssertTrue(writes.isEmpty)
    }

    func testCurrentTargetIsReadForEveryMutationAndSuccessfulOperationRunsOnce() throws {
        let original = ForegroundTargetIdentity(bundleID: claude, pid: 41, windowID: "window-1")
        var current = original
        var reads = 0
        var writes = 0
        let readCurrent = { reads += 1; return current }
        let result = try ForegroundActionPolicy.withVerifiedTarget(expected: original, current: readCurrent) {
            writes += 1
            return "once"
        }
        XCTAssertEqual(result, "once")
        current = .init(bundleID: claude, pid: 41, windowID: "window-2")
        XCTAssertThrowsError(try ForegroundActionPolicy.withVerifiedTarget(expected: original, current: readCurrent) {
            writes += 1
        })
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(writes, 1)
    }

    func testReadFailureStopsAndOperationFailureIsNotRetried() {
        enum ProbeError: Error { case read, operation }
        let target = ForegroundTargetIdentity(bundleID: claude, pid: 41, windowID: "window-1")
        var writes = 0
        XCTAssertThrowsError(try ForegroundActionPolicy.withVerifiedTarget(expected: target, current: {
            throw ProbeError.read
        }, operation: { writes += 1 }))
        XCTAssertEqual(writes, 0)
        XCTAssertThrowsError(try ForegroundActionPolicy.withVerifiedTarget(expected: target, current: { target }) {
            writes += 1
            throw ProbeError.operation
        })
        XCTAssertEqual(writes, 1)
    }
}
