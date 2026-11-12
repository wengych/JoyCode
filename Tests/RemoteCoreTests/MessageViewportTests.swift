import Foundation
import CoreGraphics
import XCTest
import RemoteCore

final class MessageViewportTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let pane = CGRect(x: 100, y: 50, width: 800, height: 750)
    private let composer = CGRect(x: 200, y: 650, width: 600, height: 100)

    func testShortNarrowNamedMessagesRemainScrollable() throws {
        let area = CGRect(x: 220, y: 500, width: 200, height: 100)
        XCTAssertEqual(try resolve(area).get(), CGRect(x: 230, y: 510, width: 180, height: 80))
    }

    func testAnonymousAreasStillRequireLargeViewport() {
        assertRejected(.tooShort, area: CGRect(x: 200, y: 500, width: 600, height: 100),
                       kind: .anonymousScrollArea)
        assertRejected(.tooNarrow, area: CGRect(x: 220, y: 100, width: 200, height: 400),
                       kind: .anonymousScrollArea)
    }

    func testFullContentBoundsAreClippedToPaneWindowAndComposer() throws {
        let area = CGRect(x: 0, y: -400, width: 1200, height: 2000)
        let result = try resolve(area).get()
        XCTAssertEqual(result, CGRect(x: 110, y: 60, width: 780, height: 572))
        XCTAssertTrue(pane.contains(result))
        XCTAssertTrue(window.contains(result))
        XCTAssertLessThan(result.maxY, composer.minY - 8)
    }

    func testPaneClippingExcludesAdjacentSideChat() {
        assertRejected(.outsidePaneOrWindow, area: CGRect(x: 910, y: 100, width: 80, height: 400))
    }

    func testNamedAreaStillRequiresHorizontalOverlapWithComposer() {
        assertRejected(.notAligned, area: CGRect(x: 110, y: 100, width: 80, height: 400))
    }

    func testAnonymousAreaRejectsMostlyOffscreenContentAndOuterPage() {
        assertRejected(.partlyOutsideViewport, area: CGRect(x: 200, y: -300, width: 600, height: 900),
                       kind: .anonymousScrollArea)
        assertRejected(.extendsIntoComposer, area: CGRect(x: 200, y: 50, width: 600, height: 700),
                       kind: .anonymousScrollArea)
    }

    func testAnonymousAreaRequiresStrongAlignment() {
        assertRejected(.notAligned, area: CGRect(x: 100, y: 100, width: 400, height: 400),
                       kind: .anonymousScrollArea)
    }

    func testAlignedAnonymousAreaUsesSameFinalViewport() throws {
        let area = CGRect(x: 200, y: 100, width: 600, height: 560)
        let named = try resolve(area).get()
        let anonymous = try resolve(area, kind: .anonymousScrollArea).get()
        XCTAssertEqual(named, anonymous)
        XCTAssertEqual(anonymous.maxY, composer.minY - 18)
        XCTAssertFalse(anonymous.intersects(composer))
    }

    func testInvalidBoundsAreRejectedBeforeIntersection() {
        let invalid: [CGRect] = [
            .null, .infinite, .zero,
            CGRect(x: 200, y: 100, width: -50, height: 400),
            CGRect(x: 200, y: 100, width: 600, height: 0),
            CGRect(x: CGFloat.nan, y: 100, width: 600, height: 400),
            CGRect(x: 200, y: 100, width: CGFloat.infinity, height: 400)
        ]
        for area in invalid { assertRejected(.invalidBounds, area: area) }
        assertFailure(.invalidBounds, MessageViewport.resolve(
            area: pane, pane: pane, window: .zero, composer: composer, kind: .namedMessages))
    }

    func testInvisibleComposerCannotAuthorizeAViewport() {
        assertFailure(.composerNotVisible, MessageViewport.resolve(
            area: pane, pane: pane, window: window,
            composer: CGRect(x: 200, y: 900, width: 600, height: 100), kind: .namedMessages))
    }

    func testEmptyIntersectionDoesNotBecomeUsableAfterCropping() {
        assertRejected(.outsidePaneOrWindow, area: CGRect(x: 200, y: 900, width: 600, height: 500))
        assertFailure(.outsidePaneOrWindow, MessageViewport.resolve(
            area: pane, pane: CGRect(x: 1200, y: 50, width: 800, height: 750),
            window: window, composer: composer, kind: .namedMessages))
    }

    func testRegionBelowComposerAndSmallHitRegionsAreRejected() {
        assertRejected(.noAreaAboveComposer, area: CGRect(x: 200, y: 660, width: 600, height: 80))
        assertRejected(.insufficientHitArea, area: CGRect(x: 200, y: 610, width: 600, height: 40))
        assertRejected(.insufficientHitArea, area: CGRect(x: 200, y: 100, width: 40, height: 400))
    }

    private func resolve(_ area: CGRect, kind: MessageViewport.Kind = .namedMessages)
        -> Result<CGRect, MessageViewport.Rejection> {
        MessageViewport.resolve(area: area, pane: pane, window: window, composer: composer, kind: kind)
    }

    private func assertRejected(_ expected: MessageViewport.Rejection, area: CGRect,
                                kind: MessageViewport.Kind = .namedMessages,
                                file: StaticString = #filePath, line: UInt = #line) {
        assertFailure(expected, resolve(area, kind: kind), file: file, line: line)
    }

    private func assertFailure(_ expected: MessageViewport.Rejection,
                               _ result: Result<CGRect, MessageViewport.Rejection>,
                               file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success(let rect): XCTFail("Expected \(expected), got \(rect)", file: file, line: line)
        case .failure(let reason): XCTAssertEqual(reason, expected, file: file, line: line)
        }
    }
}
