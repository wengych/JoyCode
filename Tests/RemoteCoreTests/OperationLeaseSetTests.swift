import XCTest
@testable import RemoteCore

final class OperationLeaseSetTests: XCTestCase {
    func testNestedOperationKeepsOuterBusyUntilBothFinish() {
        var leases = OperationLeaseSet()
        let outer = leases.begin()
        let inner = leases.begin()
        leases.end(inner)
        XCTAssertTrue(leases.isBusy)
        leases.end(outer)
        XCTAssertFalse(leases.isBusy)
    }

    func testInvalidatedOldCompletionCannotReleaseNewWork() {
        var leases = OperationLeaseSet()
        let old = leases.begin()
        leases.invalidate()
        XCTAssertFalse(leases.isBusy)
        let current = leases.begin()
        leases.end(old)
        XCTAssertTrue(leases.isBusy)
        leases.end(current)
        XCTAssertFalse(leases.isBusy)
    }

    func testNestedStaleDefersDoNotOverrideNewNestedWork() {
        var leases = OperationLeaseSet()
        let oldOuter = leases.begin()
        let oldInner = leases.begin()
        leases.invalidate()
        let newOuter = leases.begin()
        let newInner = leases.begin()
        leases.end(oldInner)
        leases.end(newInner)
        leases.end(oldOuter)
        XCTAssertTrue(leases.isBusy)
        leases.end(newOuter)
        XCTAssertFalse(leases.isBusy)
    }

    func testDuplicateReleaseDoesNotReleaseAnotherOperation() {
        var leases = OperationLeaseSet()
        let first = leases.begin()
        let second = leases.begin()
        leases.end(first)
        leases.end(first)
        XCTAssertTrue(leases.isBusy)
        leases.end(second)
        XCTAssertFalse(leases.isBusy)
    }
}
