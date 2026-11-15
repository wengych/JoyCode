import XCTest
@testable import RemoteCore

final class ChoiceCardStateTests: XCTestCase {
    func testOneAnswerPerCardUntilObservedAbsent() {
        var state = ChoiceCardState()
        XCTAssertTrue(state.permits("a"))
        state.recordDispatch("a")
        XCTAssertFalse(state.permits("a"))
        // Other cards, including the next question of the same panel, stay answerable.
        XCTAssertTrue(state.permits("b"))
        // Absence of another card never releases this one.
        state.observeAbsent("b")
        XCTAssertFalse(state.permits("a"))
        state.observeAbsent("a")
        XCTAssertTrue(state.permits("a"))
    }

    func testRepeatedDispatchStaysBlockedUntilOneObservedAbsence() {
        var state = ChoiceCardState()
        state.recordDispatch("a")
        state.recordDispatch("a")
        state.observeAbsent("a")
        XCTAssertTrue(state.permits("a"))
    }
}
