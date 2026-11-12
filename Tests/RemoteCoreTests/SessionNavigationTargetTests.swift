import XCTest
@testable import RemoteCore

final class SessionNavigationTargetTests: XCTestCase {
    func testRoutesBothSupportedForegroundApplications() throws {
        XCTAssertEqual(try SessionNavigationTarget.resolve(
            foregroundBundleID: "com.anthropic.claudefordesktop", voicePhase: .idle), .claude)
        XCTAssertEqual(try SessionNavigationTarget.resolve(
            foregroundBundleID: "com.openai.codex", voicePhase: .idle), .codex)
        XCTAssertEqual(SessionNavigationTarget.claude.bundleID, "com.anthropic.claudefordesktop")
        XCTAssertEqual(SessionNavigationTarget.codex.bundleID, "com.openai.codex")
    }

    func testEachResolutionUsesFreshForegroundWithoutRememberedFallback() throws {
        let foregrounds: [String?] = [
            "com.anthropic.claudefordesktop", "com.openai.codex", "com.apple.finder",
            nil, "com.anthropic.claudefordesktop"
        ]
        let actual = try foregrounds.map {
            try SessionNavigationTarget.resolve(foregroundBundleID: $0, voicePhase: .idle)
        }
        XCTAssertEqual(actual, [.claude, .codex, nil, nil, .claude])
    }

    func testUnknownAndNearMatchBundleIdentifiersDoNotSelectAnAgent() throws {
        for bundleID: String? in [
            nil, "", "com.apple.finder", "local.weng.XboxAgentRemote", "Claude", "ChatGPT",
            "com.openai.chat", "com.openai.codex.helper", "com.openai.Codex",
            " com.openai.codex", "com.openai.codex ",
            "com.anthropic.claudefordesktop.helper", "com.anthropic.claude"
        ] {
            XCTAssertNil(try SessionNavigationTarget.resolve(
                foregroundBundleID: bundleID, voicePhase: .idle), "Unexpected route for \(bundleID ?? "nil")")
        }
    }

    func testEveryNonIdleVoicePhaseLocksNavigationRegardlessOfForeground() {
        for phase in [VoicePhase.recording, .transcribing, .uncertain] {
            for bundleID: String? in ["com.anthropic.claudefordesktop", "com.openai.codex", "com.apple.finder", nil] {
                XCTAssertThrowsError(try SessionNavigationTarget.resolve(
                    foregroundBundleID: bundleID, voicePhase: phase)) {
                    XCTAssertEqual($0 as? RemoteCoreError, .targetLocked)
                }
            }
        }
    }
}
