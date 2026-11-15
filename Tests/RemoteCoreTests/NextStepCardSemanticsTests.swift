import XCTest
@testable import RemoteCore

final class NextStepCardSemanticsTests: XCTestCase {
    private func traits(_ names: String...) -> NextStepCardSemantics.ButtonTraits {
        NextStepCardSemantics.traits(names: names)
    }

    func testShortcutHintRequiresCommandAndReturnFromAnyNameSource() {
        XCTAssertTrue(traits("按好了，查日志 ⌘↩").hasShortcutHint)
        XCTAssertTrue(traits("按好了，查日志", "", "", "⌘", "↩").hasShortcutHint)
        XCTAssertTrue(traits("Yes, fix it", "⌘ Return").hasShortcutHint)
        XCTAssertFalse(traits("Press enter to continue").hasShortcutHint)
        XCTAssertFalse(traits("Use ⌘ key").hasShortcutHint)
        XCTAssertFalse(traits("Not now").hasShortcutHint)
    }

    func testDeclaredMetaEnterShortcutMarksThePrimaryOption() {
        // Observed in Claude 5.11492: glyphs are aria-hidden, aria-keyshortcuts carries the hint.
        let primary = NextStepCardSemantics.traits(names: ["测试选项一"], keyShortcuts: "Meta+Enter")
        let secondary = NextStepCardSemantics.traits(names: ["测试选项二"])
        XCTAssertTrue(primary.hasShortcutHint)
        XCTAssertFalse(primary.isSessionOffer)
        XCTAssertEqual(NextStepCardSemantics.classify([primary, secondary]), .nextStep(primaryIndex: 0, optionCount: 2))
        XCTAssertEqual(NextStepCardSemantics.classify([primary]), .nextStep(primaryIndex: 0, optionCount: 1))
        XCTAssertTrue(NextStepCardSemantics.traits(names: ["Yes"], keyShortcuts: "Control+Z Meta+Return").hasShortcutHint)
        for other in ["Meta+Shift+Enter", "Enter", "Meta+K", "Meta"] {
            XCTAssertFalse(NextStepCardSemantics.traits(names: ["Yes"], keyShortcuts: other).hasShortcutHint, other)
        }
        // The shortcut never rescues a blocked action.
        let merge = NextStepCardSemantics.traits(names: ["Merge"], keyShortcuts: "Meta+Enter")
        XCTAssertEqual(NextStepCardSemantics.classify([merge]), .blocked)
    }

    func testSessionOfferLabelsMatchExactlyAfterRemovingHint() {
        XCTAssertTrue(traits("New session").isSessionOffer)
        XCTAssertTrue(traits("Do it here ⌘↩").isSessionOffer)
        XCTAssertTrue(traits("在这里做").isSessionOffer)
        XCTAssertFalse(traits("New session please").isSessionOffer)
        XCTAssertFalse(traits("").isSessionOffer)
    }

    func testApprovalWordsAndAppActionsAreBlocked() {
        XCTAssertTrue(traits("Allow once").isBlocked)
        XCTAssertTrue(traits("Always allow").isBlocked)
        XCTAssertTrue(traits("拒绝").isBlocked)
        XCTAssertTrue(traits("Merge ⌘↩").isBlocked)
        XCTAssertTrue(traits("Create PR").isBlocked)
        XCTAssertTrue(traits("归档").isBlocked)
        // App actions are exact labels; a reply that merely mentions one stays a reply.
        XCTAssertFalse(traits("先 merge 再说").isBlocked)
        XCTAssertFalse(traits("按好了，查日志 ⌘↩").isBlocked)
    }

    func testClassifiesNextStepCardByItsSingleHintedPrimary() {
        let primary = traits("按好了，查日志 ⌘↩")
        let other = traits("先不做")
        XCTAssertEqual(NextStepCardSemantics.classify([primary]), .nextStep(primaryIndex: 0, optionCount: 1))
        XCTAssertEqual(NextStepCardSemantics.classify([primary, other]), .nextStep(primaryIndex: 0, optionCount: 2))
        XCTAssertEqual(NextStepCardSemantics.classify([other, primary]), .nextStep(primaryIndex: 1, optionCount: 2))
    }

    func testClassifiesSessionOfferWithoutHint() {
        XCTAssertEqual(NextStepCardSemantics.classify([traits("New session"), traits("Do it here")]),
                       .sessionOffer(optionCount: 2))
    }

    func testRejectsAmbiguousBlockedOrOversizedCards() {
        let hinted = traits("Yes ⌘↩")
        XCTAssertEqual(NextStepCardSemantics.classify([]), .unsupportedCount(0))
        XCTAssertEqual(NextStepCardSemantics.classify([hinted, traits("No"), traits("Maybe")]), .unsupportedCount(3))
        XCTAssertEqual(NextStepCardSemantics.classify([hinted, hinted]), .unrecognized)
        XCTAssertEqual(NextStepCardSemantics.classify([traits("Copy"), traits("Retry")]), .unrecognized)
        XCTAssertEqual(NextStepCardSemantics.classify([traits("Allow ⌘↩"), traits("Deny")]), .blocked)
        XCTAssertEqual(NextStepCardSemantics.classify([hinted, traits("Archive")]), .blocked)
    }

    func testDiagnosticNamesCarryNoLabelText() {
        let names = [
            NextStepCardSemantics.classify([traits("按好了，查日志 ⌘↩"), traits("先不做")]),
            NextStepCardSemantics.classify([traits("New session"), traits("Do it here")])
        ].map(\.diagnosticName)
        XCTAssertEqual(names, ["nextStep(primary=0,of=2)", "sessionOffer(of=2)"])
    }
}
