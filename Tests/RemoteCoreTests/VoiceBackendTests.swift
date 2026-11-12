import Foundation
import XCTest
@testable import RemoteCore

final class VoiceBackendTests: XCTestCase {
    func testFreshConfigurationsUseNativeDictation() throws {
        for configuration in [RemoteConfiguration(), .defaults] {
            XCTAssertEqual(configuration.defaultVoiceBackend, .nativeDictation)
            XCTAssertEqual(try configuration.resolveVoiceBackend(forBundleID: "com.openai.codex"), .nativeDictation)
            XCTAssertEqual(configuration.defaultVoiceShortcut, .defaultVoice)
            XCTAssertTrue(configuration.sessions.isEmpty)
        }
        XCTAssertEqual(VoiceBackend.supported, [.nativeDictation, .typeless])
    }

    func testLegacyConfigurationKeepsTypelessSessionsAndShortcutProfiles() throws {
        let codex = SavedSession(agent: .chatGPT, title: "Codex", deepLink: "codex://threads/codex-saved")
        let claude = SavedSession(agent: .claude, title: "Claude", deepLink: "claude://claude.ai/chat/claude-saved")
        let global = VoiceShortcut(keyCode: nil, modifiers: [.rightOption])
        let override = VoiceShortcut(keyCode: 49, modifiers: [.rightControl], keyLabel: "Space")
        struct LegacyProfile: Encodable {
            let voiceShortcut: VoiceShortcut?
        }
        struct LegacyConfiguration: Encodable {
            let sessions: [SavedSession]
            let lastSessionIDs: [String: UUID]
            let defaultVoiceShortcut: VoiceShortcut
            let applicationProfiles: [String: LegacyProfile]
        }
        let legacy = LegacyConfiguration(
            sessions: [claude, codex],
            lastSessionIDs: ["chatGPT": codex.id, "claude": claude.id, "futureAgent": UUID()],
            defaultVoiceShortcut: global,
            applicationProfiles: [
                "com.openai.codex": LegacyProfile(voiceShortcut: override),
                "net.example.future": LegacyProfile(voiceShortcut: nil)
            ]
        )
        let migrated = try JSONDecoder().decode(RemoteConfiguration.self, from: JSONEncoder().encode(legacy))
        let reloaded = try roundTrip(migrated)

        for configuration in [migrated, reloaded] {
            XCTAssertEqual(configuration.defaultVoiceBackend, .typeless)
            XCTAssertEqual(try configuration.resolveVoiceBackend(forBundleID: "com.openai.codex"), .typeless)
            XCTAssertEqual(configuration.sessions, legacy.sessions)
            XCTAssertEqual(configuration.lastSessionIDs, legacy.lastSessionIDs)
            XCTAssertEqual(configuration.defaultVoiceShortcut, global)
            XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.openai.codex"), override)
            XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.anthropic.claudefordesktop"), global)
            XCTAssertNotNil(configuration.applicationProfiles["net.example.future"])
            XCTAssertNil(configuration.applicationProfiles["com.openai.codex"]?.voiceBackend)
        }
    }

    func testMissingBackendInEmptyStoredConfigurationUsesLegacyBehavior() throws {
        let configuration = try JSONDecoder().decode(RemoteConfiguration.self, from: Data("{}".utf8))
        XCTAssertEqual(configuration.defaultVoiceBackend, .typeless)
        XCTAssertEqual(try configuration.resolveVoiceBackend(forBundleID: "com.anthropic.claudefordesktop"), .typeless)
    }

    func testOverridesMatchExactBundleIDsAndInheritanceTracksGlobalChanges() throws {
        var configuration = RemoteConfiguration(
            defaultVoiceBackend: .nativeDictation,
            applicationProfiles: [
                "com.openai.codex": ApplicationProfile(voiceBackend: .typeless),
                "com.anthropic.claudefordesktop": ApplicationProfile()
            ]
        )
        XCTAssertEqual(try configuration.resolveVoiceBackend(forBundleID: "com.openai.codex"), .typeless)
        for bundleID in ["com.openai.codex.helper", "com.openai", "COM.OPENAI.CODEX", "com.unknown.editor", ""] {
            XCTAssertEqual(try configuration.resolveVoiceBackend(forBundleID: bundleID), .nativeDictation, bundleID)
        }
        XCTAssertEqual(try configuration.resolveVoiceBackend(forBundleID: "com.anthropic.claudefordesktop"), .nativeDictation)
        configuration.defaultVoiceBackend = .typeless
        XCTAssertEqual(try configuration.resolveVoiceBackend(forBundleID: "com.anthropic.claudefordesktop"), .typeless)
        configuration.defaultVoiceBackend = .nativeDictation
        XCTAssertEqual(try configuration.resolveVoiceBackend(forBundleID: "com.openai.codex"), .typeless)
        configuration.applicationProfiles["com.openai.codex"]?.voiceBackend = nil
        XCTAssertEqual(try configuration.resolveVoiceBackend(forBundleID: "com.openai.codex"), .nativeDictation)
    }

    func testBackendAndShortcutOverridesAreIndependentAndRoundTrip() throws {
        let session = SavedSession(agent: .claude, title: "Keep", deepLink: "claude://claude.ai/chat/keep")
        let shortcut = VoiceShortcut(keyCode: nil, modifiers: [.function])
        let configuration = try roundTrip(RemoteConfiguration(
            sessions: [session], lastSessionIDs: ["claude": session.id],
            defaultVoiceBackend: .typeless,
            applicationProfiles: [
                "com.openai.codex": ApplicationProfile(voiceBackend: .nativeDictation),
                "com.anthropic.claudefordesktop": ApplicationProfile(voiceShortcut: shortcut),
                "net.example.future": ApplicationProfile(voiceShortcut: shortcut, voiceBackend: .nativeDictation)
            ]
        ))
        XCTAssertEqual(configuration.sessions, [session])
        XCTAssertEqual(configuration.lastSessionIDs["claude"], session.id)
        XCTAssertEqual(configuration.defaultVoiceBackend, .typeless)
        XCTAssertEqual(try configuration.resolveVoiceBackend(forBundleID: "com.openai.codex"), .nativeDictation)
        XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.openai.codex"), .defaultVoice)
        XCTAssertEqual(try configuration.resolveVoiceBackend(forBundleID: "com.anthropic.claudefordesktop"), .typeless)
        XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.anthropic.claudefordesktop"), shortcut)
        XCTAssertEqual(configuration.applicationProfiles["net.example.future"], ApplicationProfile(voiceShortcut: shortcut, voiceBackend: .nativeDictation))
    }

    func testUnknownBackendStringsSurviveDecodeAndRoundTripButFailResolution() throws {
        let session = SavedSession(agent: .chatGPT, title: "Preserved", deepLink: "codex://threads/preserved")
        let unknownGlobal = VoiceBackend.unknown("futureGlobal")
        let unknownOverride = VoiceBackend.unknown("futureOverride")
        let configuration = try roundTrip(RemoteConfiguration(
            sessions: [session], lastSessionIDs: ["chatGPT": session.id],
            defaultVoiceBackend: unknownGlobal,
            applicationProfiles: [
                "com.openai.codex": ApplicationProfile(voiceBackend: .nativeDictation),
                "com.anthropic.claudefordesktop": ApplicationProfile(voiceBackend: unknownOverride)
            ]
        ))
        XCTAssertEqual(configuration.sessions, [session])
        XCTAssertEqual(configuration.lastSessionIDs["chatGPT"], session.id)
        XCTAssertEqual(configuration.defaultVoiceBackend, unknownGlobal)
        XCTAssertEqual(configuration.applicationProfiles["com.anthropic.claudefordesktop"]?.voiceBackend, unknownOverride)
        XCTAssertEqual(try configuration.resolveVoiceBackend(forBundleID: "com.openai.codex"), .nativeDictation)
        XCTAssertThrowsError(try configuration.resolveVoiceBackend(forBundleID: "net.example.editor")) {
            XCTAssertEqual($0 as? VoiceBackendError, .unsupportedBackend("futureGlobal"))
        }
        XCTAssertThrowsError(try configuration.resolveVoiceBackend(forBundleID: "com.anthropic.claudefordesktop")) {
            XCTAssertEqual($0 as? VoiceBackendError, .unsupportedBackend("futureOverride"))
        }
        XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.openai.codex"), .defaultVoice)

        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        XCTAssertEqual(encoded["defaultVoiceBackend"] as? String, "futureGlobal")
    }

    func testRepairingUnknownBackendRestoresResolutionWithoutLosingSessions() throws {
        let session = SavedSession(agent: .claude, title: "Keep", deepLink: "claude://claude.ai/chat/keep")
        var configuration = try roundTrip(RemoteConfiguration(
            sessions: [session],
            defaultVoiceBackend: .unknown("unsupported"),
            applicationProfiles: ["com.anthropic.claudefordesktop": ApplicationProfile(voiceBackend: .unknown("invalid"))]
        ))
        configuration.defaultVoiceBackend = .nativeDictation
        configuration.applicationProfiles["com.anthropic.claudefordesktop"]?.voiceBackend = nil
        configuration = try roundTrip(configuration)
        XCTAssertEqual(try configuration.resolveVoiceBackend(forBundleID: "com.anthropic.claudefordesktop"), .nativeDictation)
        XCTAssertEqual(configuration.sessions, [session])
    }

    private func roundTrip(_ configuration: RemoteConfiguration) throws -> RemoteConfiguration {
        try JSONDecoder().decode(RemoteConfiguration.self, from: JSONEncoder().encode(configuration))
    }
}
