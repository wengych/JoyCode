import XCTest
import RemoteCore

final class ClaudeComposerSelectionTests: XCTestCase {
    private typealias Candidate = ClaudeComposerSelection.Candidate

    func testSameNamedMainAndSidePromptsSelectMain() throws {
        let main = candidate(1, score: 75, primary: true)
        let side = candidate(2, score: 75, side: true)
        XCTAssertEqual(try ClaudeComposerSelection.select([side, main]), main)
    }

    func testFocusedSidePromptTakesPriority() throws {
        let main = candidate(1, score: 120, primary: true)
        let side = candidate(2, score: 75, focused: true, side: true)
        XCTAssertEqual(try ClaudeComposerSelection.select([main, side]), side)
    }

    func testNearbyMainScoresAreAmbiguousIncludingBoundary() {
        for secondScore in [100, 95, 85] {
            XCTAssertThrowsError(try ClaudeComposerSelection.select([
                candidate(1, score: 100, primary: true),
                candidate(2, score: secondScore, primary: true)
            ])) { error in
                XCTAssertEqual(error as? ClaudeComposerSelection.SelectionError, .ambiguous)
            }
        }
    }

    func testSufficientScoreDifferenceSelectsBest() throws {
        let best = candidate(1, score: 100, primary: true)
        XCTAssertEqual(try ClaudeComposerSelection.select([
            candidate(2, score: 84, primary: true), best
        ]), best)
    }

    func testNonpositiveScoresAreIgnoredEvenWhenFocused() throws {
        let main = candidate(3, score: 75, primary: true)
        XCTAssertEqual(try ClaudeComposerSelection.select([
            candidate(1, score: -1, focused: true, side: true),
            candidate(2, score: 0, primary: true), main
        ]), main)
        XCTAssertNil(try ClaudeComposerSelection.select([candidate(4, score: -10)]))
    }

    func testOnlyUnfocusedSidePromptReturnsNil() throws {
        XCTAssertNil(try ClaudeComposerSelection.select([
            candidate(1, score: 120, side: true, primary: true)
        ]))
    }

    func testPrimaryPaneTakesPriorityOverHigherScoreOutsidePane() throws {
        let primary = candidate(1, score: 75, primary: true)
        XCTAssertEqual(try ClaudeComposerSelection.select([
            candidate(2, score: 120), primary
        ]), primary)
    }

    func testMainPromptOutsidePrimaryPaneRemainsFallback() throws {
        let main = candidate(1, score: 75)
        XCTAssertEqual(try ClaudeComposerSelection.select([main]), main)
        XCTAssertNil(try ClaudeComposerSelection.select([]))
    }

    func testSaturatedSearchResultsAreRejected() {
        for count in [32, 33] {
            XCTAssertThrowsError(try ClaudeComposerSelection.validateResultCount(count: count, limit: 32)) { error in
                XCTAssertEqual(error as? ClaudeComposerSelection.SelectionError,
                               .resultLimitReached(count: count, limit: 32))
            }
        }
    }

    func testUnsaturatedSearchResultsAreAccepted() {
        XCTAssertNoThrow(try ClaudeComposerSelection.validateResultCount(count: 0, limit: 32))
        XCTAssertNoThrow(try ClaudeComposerSelection.validateResultCount(count: 31, limit: 32))
    }

    private func candidate(_ id: Int, score: Int, focused: Bool = false,
                           side: Bool = false, primary: Bool = false) -> Candidate {
        Candidate(id: id, score: score, isFocused: focused,
                  isSideChat: side, isInPrimaryPane: primary)
    }
}
