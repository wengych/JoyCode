import Foundation
import XCTest
@testable import RemoteCore

final class RemoteCoreTests: XCTestCase {
    private func target(sessionID: UUID? = nil, window: String = "window-1", composer: String = "chat-1") -> ComposerTarget {
        ComposerTarget(sessionID: sessionID, applicationBundleID: "com.openai.codex", windowID: window, composerID: composer)
    }

    private func snapshot(_ text: String, target: ComposerTarget? = nil, focused: Bool = true, stable: Bool = true) -> ComposerSnapshot {
        ComposerSnapshot(target: target ?? self.target(), text: text, isFocused: focused, isStable: stable)
    }

    func testExactExistingSessionLinksAndAgentBinding() throws {
        let codex = "codex://threads/019b0c11-7495-7000-8000-c40c883bde75"
        let claude = "claude://claude.ai/chat/a16d7b11-3501-414d-8143-c82fed3cb2c9"
        XCTAssertEqual(try SessionDeepLink.validatedURL(codex, agent: .chatGPT).absoluteString, codex)
        XCTAssertEqual(try SessionDeepLink.validatedURL(claude, agent: .claude).absoluteString, claude)
        XCTAssertThrowsError(try SessionDeepLink.validatedURL(codex, agent: .claude))
        XCTAssertThrowsError(try SessionDeepLink.validatedURL(claude, agent: .chatGPT))
    }

    func testRejectsURLPayloadsRatherThanOpeningUncheckedDestinations() {
        let invalidCodex = [
            "https://threads/abc", "codex://elsewhere/abc", "codex://threads/new",
            "codex://threads/NEW", "codex://threads/", "codex://threads/abc/",
            "codex://threads/abc/extra", "codex://threads//abc", "codex://threads/..",
            "codex://threads/%61bc", "codex://threads/abc%2Fextra", "codex://threads/abc%3Fq%3Dtext",
            "codex://threads/abc?q=prompt", "codex://threads/abc?", "codex://threads/abc#fragment",
            "codex://user@threads/abc", "codex://threads:123/abc", " codex://threads/abc",
            "codex://threads/ab\nc", "codex://threads/abc\n", "codex://threads/中文"
        ]
        for link in invalidCodex {
            XCTAssertThrowsError(try SessionDeepLink.validatedURL(link, agent: .chatGPT), link)
        }
        let invalidClaude = [
            "claude://claude.ai/new?q=prompt", "claude://claude.ai/chat/new",
            "claude://claude.ai/chat/abc?q=prompt", "claude://claude.ai/chat/abc#send",
            "claude://claude.ai.evil/chat/abc", "claude://evil@claude.ai/chat/abc",
            "claude://claude.ai/chat/abc/extra", "claude://claude.ai/chat/%2e%2e",
            "claude://claude.ai/chat/abc%2Fnew", "claude://claude.ai/CHAT/abc"
        ]
        for link in invalidClaude {
            XCTAssertThrowsError(try SessionDeepLink.validatedURL(link, agent: .claude), link)
        }
    }

    func testNavigationUsesStoredAgentOrderWithoutWrappingOrCrossingAgents() throws {
        let a = SavedSession(agent: .chatGPT, title: "A", deepLink: "codex://threads/a")
        let b = SavedSession(agent: .claude, title: "B", deepLink: "claude://claude.ai/chat/b")
        let c = SavedSession(agent: .chatGPT, title: "C", deepLink: "codex://threads/c")
        var configuration = RemoteConfiguration(sessions: [a, b, c])
        XCTAssertNil(configuration.session(before: a.id, for: .chatGPT))
        XCTAssertEqual(configuration.session(after: a.id, for: .chatGPT), c)
        XCTAssertEqual(configuration.session(before: c.id, for: .chatGPT), a)
        XCTAssertNil(configuration.session(after: c.id, for: .chatGPT))
        XCTAssertNil(configuration.session(after: b.id, for: .chatGPT))
        XCTAssertNil(configuration.session(after: UUID(), for: .chatGPT))
        var state = RemoteState()
        try state.selectSession(c.id, configuration: &configuration)
        try state.selectSession(b.id, configuration: &configuration)
        XCTAssertEqual(configuration.lastSession(for: .chatGPT), c)
        XCTAssertEqual(configuration.lastSession(for: .claude), b)
        try state.selectCurrentSession(for: .claude, configuration: &configuration)
        XCTAssertNil(configuration.lastSession(for: .claude))
        XCTAssertEqual(configuration.lastSession(for: .chatGPT), c)
        XCTAssertTrue(RemoteConfiguration.defaults.sessions.isEmpty)
        XCTAssertTrue(RemoteConfiguration.defaults.lastSessionIDs.isEmpty)
        let decoded = try JSONDecoder().decode(RemoteConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded.sessions, configuration.sessions)
        XCTAssertEqual(decoded.lastSessionIDs, configuration.lastSessionIDs)
    }

    func testCurrentChatCanBeginWithoutStableTextAndStaysLockedUntilVerifiedDraft() throws {
        let saved = SavedSession(agent: .claude, title: "Other", deepLink: "claude://claude.ai/chat/other")
        var configuration = RemoteConfiguration(sessions: [saved])
        var state = RemoteState(selectedSessionID: saved.id)
        try state.begin(with: snapshot("existing", stable: false))
        XCTAssertNil(state.selectedSessionID, "Unregistered foreground chat takes priority over an old saved selection")
        XCTAssertEqual(state.voicePhase, .recording)
        XCTAssertTrue(state.isTargetLocked)
        XCTAssertThrowsError(try state.selectSession(saved.id, configuration: &configuration))
        XCTAssertThrowsError(try state.selectCurrentSession(for: .claude, configuration: &configuration))
        try state.stop()
        XCTAssertTrue(state.isTargetLocked)
        XCTAssertThrowsError(try state.consumeReadyDraft(for: snapshot("existing plus new text")))
        state.observe(snapshot("existing plus new text", stable: false))
        XCTAssertEqual(state.voicePhase, .transcribing)
        state.observe(snapshot("existing plus new text"))
        XCTAssertEqual(state.voicePhase, .idle)
        XCTAssertFalse(state.isTargetLocked)
        XCTAssertTrue(state.canSend)
        XCTAssertNotNil(state.readyDraft, "An earlier rejected A was not queued and did not consume the eventual draft")
    }

    func testEmptyUnchangedAndWhitespaceOnlyChangesNeverBecomeReady() throws {
        var state = RemoteState()
        try state.begin(with: snapshot("already typed"))
        try state.stop()
        for text in ["", " \n", "already typed", "already typed\n  "] {
            state.observe(snapshot(text))
            XCTAssertEqual(state.voicePhase, .transcribing)
            XCTAssertNil(state.readyDraft)
            XCTAssertFalse(state.canSend)
        }
    }

    func testFocusOrChatChangeDuringTranscriptionRequiresManualResolution() throws {
        for changed in [snapshot("transcript", focused: false), snapshot("transcript", target: target(composer: "other-chat")), snapshot("transcript", target: target(window: "other-window"))] {
            var state = RemoteState()
            try state.begin(with: snapshot(""))
            try state.stop()
            state.observe(changed)
            XCTAssertEqual(state.voicePhase, .uncertain)
            XCTAssertEqual(state.lockedTarget, target())
            XCTAssertTrue(state.isTargetLocked)
            state.observe(snapshot("transcript"))
            XCTAssertEqual(state.voicePhase, .uncertain, "A matching composer cannot prove the external voice state")
            XCTAssertFalse(state.canSend)
            state.confirmVoiceStopped()
            XCTAssertEqual(state.voicePhase, .idle)
            XCTAssertFalse(state.isTargetLocked)
            XCTAssertFalse(state.canSend)
            XCTAssertNil(state.readyDraft)
        }
    }

    func testSendRequiresFreshStableFocusedSameComposerAndConsumesOnlyOnce() throws {
        var state = RemoteState()
        try state.begin(with: snapshot(""))
        try state.stop()
        state.observe(snapshot("draft"))
        XCTAssertTrue(state.canSend)
        let invalid = [snapshot("draft", stable: false), snapshot("draft", focused: false), snapshot("draft", target: target(composer: "other-chat")), snapshot("changed without observation")]
        for current in invalid {
            XCTAssertThrowsError(try state.consumeReadyDraft(for: current))
            XCTAssertNotNil(state.readyDraft)
        }
        state.observe(snapshot("draft", focused: false))
        XCTAssertFalse(state.canSend)
        state.observe(snapshot("edited draft"))
        XCTAssertTrue(state.canSend)
        let consumed = try state.consumeReadyDraft(for: snapshot("edited draft"))
        XCTAssertEqual(consumed.text, "edited draft")
        XCTAssertFalse(state.canSend)
        XCTAssertThrowsError(try state.consumeReadyDraft(for: snapshot("edited draft")))
    }

    func testCancellationKeepsPreviousDraftButUnconfirmedCancelKeepsTargetLocked() throws {
        var state = RemoteState()
        try state.begin(with: snapshot(""))
        try state.stop()
        state.observe(snapshot("original draft"))
        try state.begin(with: snapshot("original draft"))
        try state.cancelRecording(confirmed: true)
        XCTAssertEqual(state.readyDraft?.text, "original draft")
        XCTAssertFalse(state.canSend, "Cancellation requires a fresh composer observation before send")
        state.observe(snapshot("original draft"))
        XCTAssertTrue(state.canSend)
        try state.begin(with: snapshot("original draft"))
        try state.cancelRecording(confirmed: false)
        XCTAssertEqual(state.voicePhase, .uncertain)
        XCTAssertTrue(state.isTargetLocked)
        XCTAssertFalse(state.canSend)
        XCTAssertThrowsError(try state.cancelRecording(confirmed: true))
    }

    func testManualSendRequiresStableVisibleDraftAndCannotUnlockVoice() throws {
        var state = RemoteState()
        for invalid in [snapshot("", stable: true), snapshot("typed", focused: false), snapshot("typed", stable: false), snapshot("typed", target: target(sessionID: UUID()))] {
            XCTAssertThrowsError(try state.acceptManualDraft(invalid))
            XCTAssertNil(state.readyDraft)
        }
        try state.acceptManualDraft(snapshot("typed"))
        XCTAssertEqual(try state.validatedReadyDraft(for: snapshot("typed")).text, "typed")
        _ = try state.consumeReadyDraft(for: snapshot("typed"))
        XCTAssertFalse(state.canSend)
        try state.begin(with: snapshot("typed"))
        XCTAssertThrowsError(try state.acceptManualDraft(snapshot("typed")))
        try state.stop()
        XCTAssertThrowsError(try state.acceptManualDraft(snapshot("typed")))
        state.markUncertain()
        XCTAssertThrowsError(try state.acceptManualDraft(snapshot("typed")))
        XCTAssertTrue(state.isTargetLocked)
    }
}
