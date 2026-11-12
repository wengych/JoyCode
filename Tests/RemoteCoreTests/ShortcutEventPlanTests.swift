import XCTest
import RemoteCore

final class ShortcutEventPlanTests: XCTestCase {
    func testDefaultOptionGravePreservesVerifiedSequenceAndTiming() throws {
        XCTAssertEqual(try ShortcutEventPlan.steps(for: .defaultVoice), [
            ShortcutEventStep(keyCode: 58, isKeyDown: true, isModifier: true, flags: 0x80020, delayAfter: 0.025),
            ShortcutEventStep(keyCode: 50, isKeyDown: true, isModifier: false, flags: 0x80020, delayAfter: 0.08),
            ShortcutEventStep(keyCode: 50, isKeyDown: false, isModifier: false, flags: 0x80020, delayAfter: 0.025),
            ShortcutEventStep(keyCode: 58, isKeyDown: false, isModifier: true, flags: 0, delayAfter: 0)
        ])
    }

    func testEachPhysicalModifierHasItsOwnKeyCodeAndFlags() throws {
        let cases: [(ShortcutModifier, UInt16, UInt64)] = [
            (.leftControl, 59, 0x40001), (.rightControl, 62, 0x42000),
            (.leftShift, 56, 0x20002), (.rightShift, 60, 0x20004),
            (.leftOption, 58, 0x80020), (.rightOption, 61, 0x80040),
            (.leftCommand, 55, 0x100008), (.rightCommand, 54, 0x100010),
            (.function, 63, 0x800000)
        ]
        for (modifier, keyCode, expectedFlags) in cases {
            let steps = try ShortcutEventPlan.steps(for: VoiceShortcut(keyCode: nil, modifiers: [modifier]))
            XCTAssertEqual(steps, [
                ShortcutEventStep(keyCode: keyCode, isKeyDown: true, isModifier: true, flags: expectedFlags, delayAfter: 0.08),
                ShortcutEventStep(keyCode: keyCode, isKeyDown: false, isModifier: true, flags: 0, delayAfter: 0)
            ], modifier.rawValue)
        }
    }

    func testReleasingOneSideKeepsOtherSideAndGenericFlag() throws {
        let cases: [(ShortcutModifier, ShortcutModifier, UInt64, UInt64)] = [
            (.leftControl, .rightControl, 0x40001, 0x42001),
            (.leftShift, .rightShift, 0x20002, 0x20006),
            (.leftOption, .rightOption, 0x80020, 0x80060),
            (.leftCommand, .rightCommand, 0x100008, 0x100018)
        ]
        for (left, right, leftFlags, bothFlags) in cases {
            let steps = try ShortcutEventPlan.steps(for: VoiceShortcut(keyCode: nil, modifiers: [right, left]))
            XCTAssertEqual(steps.map(\.flags), [leftFlags, bothFlags, leftFlags, 0], left.rawValue)
            XCTAssertEqual(steps.map(\.isKeyDown), [true, true, false, false])
            XCTAssertEqual(steps.map(\.delayAfter), [0.025, 0.08, 0.025, 0])
        }
    }

    func testCanonicalPressOrderAndReverseReleaseAreCompleteAndSymmetric() throws {
        let shortcut = VoiceShortcut(keyCode: 50, modifiers: [
            .function, .rightCommand, .leftControl, .rightOption, .rightShift,
            .leftCommand, .rightControl, .leftOption, .leftShift, .leftControl
        ])
        let steps = try ShortcutEventPlan.steps(for: shortcut)
        let modifierKeys: [UInt16] = [59, 62, 56, 60, 58, 61, 55, 54, 63]
        XCTAssertEqual(steps.count, 20)
        XCTAssertEqual(Array(steps.prefix(9)).map(\.keyCode), modifierKeys)
        XCTAssertEqual(Array(steps.suffix(9)).map(\.keyCode), Array(modifierKeys.reversed()))
        XCTAssertTrue(steps.prefix(9).allSatisfy { $0.isModifier && $0.isKeyDown && $0.delayAfter == 0.025 })
        XCTAssertTrue(steps.suffix(9).allSatisfy { $0.isModifier && !$0.isKeyDown })
        XCTAssertEqual(steps[9].flags, 0x9E207F)
        XCTAssertEqual(steps[10].flags, steps[9].flags)
        XCTAssertEqual(steps[9].delayAfter, 0.08)
        XCTAssertEqual(steps[10].delayAfter, 0.025)
        XCTAssertEqual(steps.last?.flags, 0)
        XCTAssertEqual(steps.last?.delayAfter, 0)

        var held = Set<UInt16>()
        for step in steps {
            if step.isKeyDown {
                XCTAssertTrue(held.insert(step.keyCode).inserted)
            } else {
                XCTAssertNotNil(held.remove(step.keyCode))
            }
        }
        XCTAssertTrue(held.isEmpty)
    }

    func testFnOnlyUsesModifierTransitionsAndHoldDuration() throws {
        let steps = try ShortcutEventPlan.steps(for: VoiceShortcut(keyCode: nil, modifiers: [.function]))
        XCTAssertEqual(steps.map(\.keyCode), [63, 63])
        XCTAssertTrue(steps.allSatisfy(\.isModifier))
        XCTAssertEqual(steps.map(\.flags), [0x800000, 0])
        XCTAssertEqual(steps.map(\.delayAfter), [0.08, 0])
    }

    func testFunctionKeyWithoutModifiersUsesBalancedPlainKeyEvents() throws {
        let steps = try ShortcutEventPlan.steps(for: VoiceShortcut(keyCode: 100, modifiers: [], keyLabel: "F8"))
        XCTAssertEqual(steps, [
            ShortcutEventStep(keyCode: 100, isKeyDown: true, isModifier: false, flags: 0, delayAfter: 0.08),
            ShortcutEventStep(keyCode: 100, isKeyDown: false, isModifier: false, flags: 0, delayAfter: 0)
        ])
    }

    func testInvalidShortcutsAreRejectedBeforeReturningAnyPlan() {
        let cases = [
            VoiceShortcut(keyCode: nil, modifiers: []),
            VoiceShortcut(keyCode: 53, modifiers: [.leftOption]),
            VoiceShortcut(keyCode: 58, modifiers: [.leftControl]),
            VoiceShortcut(keyCode: UInt16.max, modifiers: [.leftCommand])
        ]
        for shortcut in cases {
            XCTAssertThrowsError(try ShortcutEventPlan.steps(for: shortcut))
        }
    }
}
