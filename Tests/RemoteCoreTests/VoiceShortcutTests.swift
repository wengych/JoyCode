import Foundation
import XCTest
@testable import RemoteCore

final class VoiceShortcutTests: XCTestCase {
    func testLegacyConfigurationMigratesWithoutLosingEitherAgentsSessions() throws {
        let codex = SavedSession(agent: .chatGPT, title: "Current Codex", deepLink: "codex://threads/codex-session")
        let claude = SavedSession(agent: .claude, title: "Saved Claude", deepLink: "claude://claude.ai/chat/claude-session")
        let unknownSelection = UUID()
        struct LegacyConfiguration: Encodable {
            let sessions: [SavedSession]
            let lastSessionIDs: [String: UUID]
        }
        let legacy = LegacyConfiguration(
            sessions: [claude, codex],
            lastSessionIDs: ["chatGPT": codex.id, "claude": claude.id, "futureAgent": unknownSelection]
        )

        let migrated = try JSONDecoder().decode(RemoteConfiguration.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(migrated.sessions, legacy.sessions)
        XCTAssertEqual(migrated.lastSessionIDs, legacy.lastSessionIDs)
        XCTAssertEqual(migrated.defaultVoiceShortcut, .defaultVoice)
        XCTAssertTrue(migrated.applicationProfiles.isEmpty)
        XCTAssertEqual(try migrated.resolveVoiceShortcut(forBundleID: "com.openai.codex"), .defaultVoice)

        let reloaded = try roundTrip(migrated)
        XCTAssertEqual(reloaded.sessions, legacy.sessions)
        XCTAssertEqual(reloaded.lastSessionIDs, legacy.lastSessionIDs)
        XCTAssertEqual(reloaded.defaultVoiceShortcut, .defaultVoice)
    }

    func testMissingLegacyCollectionsUseEmptyDefaults() throws {
        let configuration = try JSONDecoder().decode(RemoteConfiguration.self, from: Data("{}".utf8))
        XCTAssertTrue(configuration.sessions.isEmpty)
        XCTAssertTrue(configuration.lastSessionIDs.isEmpty)
        XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.openai.codex"), .defaultVoice)
    }

    func testInheritanceTracksGlobalEditsAndBundleIDsMatchExactly() throws {
        let global = VoiceShortcut(keyCode: nil, modifiers: [.rightOption])
        let codex = VoiceShortcut(keyCode: 49, modifiers: [.rightControl], keyLabel: "Space")
        var configuration = RemoteConfiguration(
            defaultVoiceShortcut: global,
            applicationProfiles: [
                "com.openai.codex": ApplicationProfile(voiceShortcut: codex),
                "com.anthropic.claudefordesktop": ApplicationProfile()
            ]
        )

        XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.openai.codex"), codex)
        for bundleID in ["com.openai.codex.helper", "com.openai", "COM.OPENAI.CODEX", "com.unknown.editor", ""] {
            XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: bundleID), global, bundleID)
        }
        XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.anthropic.claudefordesktop"), global)
        configuration.defaultVoiceShortcut = VoiceShortcut(keyCode: nil, modifiers: [.function])
        XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.anthropic.claudefordesktop"), configuration.defaultVoiceShortcut)
        XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.openai.codex"), codex)
    }

    func testClearingOverrideRestoresInheritanceWithoutChangingSessions() throws {
        let session = SavedSession(agent: .claude, title: "Keep me", deepLink: "claude://claude.ai/chat/keep")
        let override = VoiceShortcut(keyCode: nil, modifiers: [.rightCommand])
        var configuration = RemoteConfiguration(
            sessions: [session], lastSessionIDs: ["claude": session.id],
            applicationProfiles: ["com.openai.codex": ApplicationProfile(voiceShortcut: override)]
        )
        XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.openai.codex"), override)
        configuration.applicationProfiles["com.openai.codex"]?.voiceShortcut = nil
        XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.openai.codex"), .defaultVoice)
        configuration = try roundTrip(configuration)
        XCTAssertNotNil(configuration.applicationProfiles["com.openai.codex"])
        XCTAssertNil(configuration.applicationProfiles["com.openai.codex"]?.voiceShortcut)
        XCTAssertEqual(configuration.sessions, [session])
        XCTAssertEqual(configuration.lastSessionIDs["claude"], session.id)
        configuration.applicationProfiles.removeValue(forKey: "com.openai.codex")
        XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.openai.codex"), .defaultVoice)
    }

    func testInvalidExplicitOverrideNeverFallsBackAndDoesNotEraseStoredSessions() throws {
        let session = SavedSession(agent: .chatGPT, title: "Preserved", deepLink: "codex://threads/preserved")
        let invalid = VoiceShortcut(keyCode: 65_535, modifiers: [.leftOption])
        let configuration = RemoteConfiguration(
            sessions: [session], lastSessionIDs: ["chatGPT": session.id],
            applicationProfiles: ["com.openai.codex": ApplicationProfile(voiceShortcut: invalid)]
        )
        let decoded = try roundTrip(configuration)
        XCTAssertEqual(decoded.sessions, [session])
        XCTAssertEqual(decoded.lastSessionIDs["chatGPT"], session.id)
        XCTAssertEqual(decoded.applicationProfiles["com.openai.codex"]?.voiceShortcut, invalid)
        XCTAssertThrowsError(try decoded.resolveVoiceShortcut(forBundleID: "com.openai.codex")) {
            XCTAssertEqual($0 as? VoiceShortcutError, .invalidKeyCode(65_535))
        }
        XCTAssertEqual(try decoded.resolveVoiceShortcut(forBundleID: "com.anthropic.claudefordesktop"), .defaultVoice)
    }

    func testInvalidGlobalFailsInheritedResolutionButValidOverrideStillWorks() throws {
        let override = VoiceShortcut(keyCode: nil, modifiers: [.rightControl, .rightOption])
        let configuration = try roundTrip(RemoteConfiguration(
            defaultVoiceShortcut: VoiceShortcut(keyCode: nil, modifiers: []),
            applicationProfiles: [
                "com.openai.codex": ApplicationProfile(voiceShortcut: override),
                "com.anthropic.claudefordesktop": ApplicationProfile()
            ]
        ))
        XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: "com.openai.codex"), override)
        for bundleID in ["com.unknown.editor", "com.anthropic.claudefordesktop"] {
            XCTAssertThrowsError(try configuration.resolveVoiceShortcut(forBundleID: bundleID)) {
                XCTAssertEqual($0 as? VoiceShortcutError, .emptyCombination)
            }
        }
    }

    func testUnknownApplicationProfilesArePreservedWithoutChangingAgentSelection() throws {
        let futureShortcut = VoiceShortcut(keyCode: 96, modifiers: [], keyLabel: "F5")
        let unknownBundleID = "net.example.future-editor"
        let configuration = try roundTrip(RemoteConfiguration(applicationProfiles: [
            unknownBundleID: ApplicationProfile(voiceShortcut: futureShortcut)
        ]))
        XCTAssertEqual(configuration.applicationProfiles[unknownBundleID]?.voiceShortcut, futureShortcut)
        XCTAssertEqual(try configuration.resolveVoiceShortcut(forBundleID: unknownBundleID), futureShortcut)
        XCTAssertTrue(configuration.sessions.isEmpty)
        XCTAssertTrue(configuration.lastSessionIDs.isEmpty)
    }

    func testValidationNormalizesModifiersWithoutLosingLeftRightIdentityOrLabel() throws {
        let shortcut = VoiceShortcut(
            keyCode: 50,
            modifiers: [.function, .rightCommand, .rightOption, .leftControl, .rightControl,
                        .leftShift, .rightShift, .leftCommand, .leftOption, .leftControl],
            keyLabel: "`"
        )
        let validated = try shortcut.validated()
        XCTAssertEqual(validated.modifiers, ShortcutModifier.allCases)
        XCTAssertEqual(validated.keyCode, 50)
        XCTAssertEqual(validated.keyLabel, "`")
        XCTAssertEqual(try validated.validated(), validated)
        let decoded = try JSONDecoder().decode(VoiceShortcut.self, from: JSONEncoder().encode(validated))
        XCTAssertEqual(decoded, validated)
        XCTAssertEqual(decoded.modifiers.count, 9)
    }

    func testPureModifiersBareFunctionKeysAndExplicitUserCombinationsAreSupported() throws {
        for modifier in ShortcutModifier.allCases {
            let shortcut = VoiceShortcut(keyCode: nil, modifiers: [modifier])
            XCTAssertEqual(try shortcut.validated(), shortcut)
        }
        for keyCode: UInt16 in [0, 36, 49, 64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122] {
            let shortcut = VoiceShortcut(keyCode: keyCode, modifiers: [])
            XCTAssertEqual(try shortcut.validated(), shortcut)
        }
        for keyCode: UInt16 in [12, 13, 36, 76] {
            let shortcut = VoiceShortcut(keyCode: keyCode, modifiers: [.rightCommand])
            XCTAssertEqual(try shortcut.validated(), shortcut)
        }
    }

    func testRejectsEmptyEscapeModifierLockUnknownAndPowerPrimaryKeys() {
        XCTAssertThrowsError(try VoiceShortcut(keyCode: nil, modifiers: []).validated()) {
            XCTAssertEqual($0 as? VoiceShortcutError, .emptyCombination)
        }
        XCTAssertThrowsError(try VoiceShortcut(keyCode: 53, modifiers: [.rightControl]).validated()) {
            XCTAssertEqual($0 as? VoiceShortcutError, .escapeReservedForCancellation)
        }
        for keyCode: UInt16 in 54...63 {
            XCTAssertThrowsError(try VoiceShortcut(keyCode: keyCode, modifiers: [.leftOption]).validated()) {
                XCTAssertEqual($0 as? VoiceShortcutError, .modifierUsedAsPrimary)
            }
        }
        for keyCode: UInt16 in [52, 66, 68, 70, 77, 108, 112, 127, 128, 255, 65_535] {
            XCTAssertThrowsError(try VoiceShortcut(keyCode: keyCode, modifiers: [.leftOption]).validated()) {
                XCTAssertEqual($0 as? VoiceShortcutError, .invalidKeyCode(keyCode))
            }
        }
    }

    private func roundTrip(_ configuration: RemoteConfiguration) throws -> RemoteConfiguration {
        try JSONDecoder().decode(RemoteConfiguration.self, from: JSONEncoder().encode(configuration))
    }
}
