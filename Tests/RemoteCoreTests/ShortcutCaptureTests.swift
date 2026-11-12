import XCTest
import RemoteCore

final class ShortcutCaptureTests: XCTestCase {
    func testNormalShortcutCompletesOnlyAfterAllKeysAreReleased() throws {
        var capture = ShortcutCapture()
        XCTAssertEqual(capture.modifiersChanged([.rightOption]), .waiting)
        XCTAssertEqual(capture.keyDown(50, label: "`", modifiers: [.rightOption], isRepeat: false), .waiting)
        XCTAssertEqual(capture.keyUp(50), .waiting)
        XCTAssertEqual(capture.modifiersChanged([]),
                       .completed(try VoiceShortcut(keyCode: 50, modifiers: [.rightOption], keyLabel: "`").validated()))
        XCTAssertTrue(capture.pressedModifiers.isEmpty)
        XCTAssertNil(capture.primaryKeyCode)
    }

    func testPureModifierChordKeepsBothSidesAndFunction() throws {
        var capture = ShortcutCapture()
        XCTAssertEqual(capture.modifiersChanged([.leftControl]), .waiting)
        XCTAssertEqual(capture.modifiersChanged([.leftControl, .rightControl, .function]), .waiting)
        XCTAssertEqual(capture.modifiersChanged([.rightControl, .function]), .waiting)
        XCTAssertEqual(capture.modifiersChanged([.function]), .waiting)
        XCTAssertEqual(capture.modifiersChanged([]), .completed(try VoiceShortcut(
            keyCode: nil, modifiers: [.leftControl, .rightControl, .function]).validated()))
    }

    func testModifierReleasedBeforeMainKeyWaitsForKeyUp() throws {
        var capture = ShortcutCapture()
        _ = capture.modifiersChanged([.leftShift])
        _ = capture.keyDown(0, label: "A", modifiers: [.leftShift], isRepeat: false)
        XCTAssertEqual(capture.modifiersChanged([]), .waiting)
        XCTAssertEqual(capture.keyUp(0), .completed(try VoiceShortcut(
            keyCode: 0, modifiers: [.leftShift], keyLabel: "A").validated()))
    }

    func testPlainKeyAndAutoRepeat() {
        var capture = ShortcutCapture()
        XCTAssertEqual(capture.keyDown(0, label: "A", modifiers: [], isRepeat: false), .waiting)
        XCTAssertEqual(capture.keyDown(0, label: "A", modifiers: [], isRepeat: true), .waiting)
        XCTAssertEqual(capture.keyUp(0), .completed(VoiceShortcut(keyCode: 0, modifiers: [], keyLabel: "A")))
    }

    func testResetAfterFocusLossDiscardsAllPressedState() {
        var capture = ShortcutCapture()
        _ = capture.modifiersChanged([.leftCommand])
        _ = capture.keyDown(0, label: "A", modifiers: [.leftCommand], isRepeat: false)
        capture.reset()
        XCTAssertEqual(capture.keyUp(0), .waiting)
        XCTAssertEqual(capture.modifiersChanged([]), .waiting)
        XCTAssertTrue(capture.pressedModifiers.isEmpty)
        XCTAssertNil(capture.primaryKeyCode)
    }

    func testSecondMainKeyIsRejected() {
        var capture = ShortcutCapture()
        _ = capture.keyDown(0, label: "A", modifiers: [], isRepeat: false)
        guard case .invalid = capture.keyDown(1, label: "S", modifiers: [], isRepeat: false) else {
            return XCTFail("Two main keys must not silently record the first key")
        }
        XCTAssertNil(capture.primaryKeyCode)
    }

    func testRollingModifierChordIsRejected() {
        var capture = ShortcutCapture()
        _ = capture.modifiersChanged([.leftOption, .rightControl])
        _ = capture.modifiersChanged([.rightControl])
        guard case .invalid = capture.modifiersChanged([.rightControl, .rightCommand]) else {
            return XCTFail("Nonoverlapping modifiers must not become a fabricated chord")
        }
    }

    func testModifierAddedAfterMainKeyIsRejected() {
        var capture = ShortcutCapture()
        _ = capture.keyDown(0, label: "A", modifiers: [], isRepeat: false)
        guard case .invalid = capture.modifiersChanged([.leftShift]) else {
            return XCTFail("A changing chord requires another explicit recording attempt")
        }
    }

    func testMissingPhysicalModifierEventIsRejected() {
        var capture = ShortcutCapture()
        guard case .invalid = capture.keyDown(0, label: "A", modifiers: [.rightOption], isRepeat: false) else {
            return XCTFail("Incomplete state must not guess which modifier is pressed")
        }
    }
}
