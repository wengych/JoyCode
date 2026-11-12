import Foundation
import XCTest
@testable import RemoteCore

@MainActor
final class ReadinessActionGateTests: XCTestCase {
    private enum Failure: Error, Equatable {
        case targetChanged, baselineChanged, mutationResultUnknown, probeFailed
    }

    private final class Clock {
        var time: TimeInterval = 0
        func advance(_ amount: TimeInterval) { time += amount }
    }

    func testReadinessFalseFalseTruePerformsExactlyOnceAndReturnsValue() async throws {
        let clock = Clock()
        var probes = 0
        var mutations = 0
        var events: [String] = []
        let result = try await ReadinessActionGate.run(deadline: 1, now: { clock.time }, wait: {
            events.append("wait")
            clock.advance(0.1)
        }, validate: {
            events.append("validate")
        }, isReady: {
            events.append("probe")
            probes += 1
            return probes == 3
        }, perform: {
            events.append("perform")
            mutations += 1
            return 42
        })
        XCTAssertEqual(result, 42)
        XCTAssertEqual(mutations, 1)
        XCTAssertEqual(events, ["validate", "probe", "wait", "validate", "probe", "wait", "validate", "probe", "perform"])
    }

    func testTimeoutDoesNotMutate() async {
        let clock = Clock()
        var probes = 0
        var mutations = 0
        do {
            try await ReadinessActionGate.run(deadline: 1, now: { clock.time }, wait: {
                clock.advance(0.4)
            }, validate: {}, isReady: {
                probes += 1
                return false
            }, perform: { mutations += 1 })
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? ReadinessActionGate.GateError, .timedOut)
        }
        XCTAssertEqual(probes, 3)
        XCTAssertEqual(mutations, 0)
    }

    func testTargetChangeAfterWaitIsTerminalAndNeverRetried() async {
        let clock = Clock()
        var targetValid = true
        var validations = 0
        var waits = 0
        var probes = 0
        var mutations = 0
        do {
            try await ReadinessActionGate.run(deadline: 1, now: { clock.time }, wait: {
                waits += 1
                clock.advance(0.1)
                // A second retry could see the original target again; it is not permitted.
                targetValid = waits > 1
            }, validate: {
                validations += 1
                if !targetValid { throw Failure.targetChanged }
            }, isReady: {
                probes += 1
                return probes > 1
            }, perform: { mutations += 1 })
            XCTFail("Expected changed target")
        } catch {
            XCTAssertEqual(error as? Failure, .targetChanged)
        }
        XCTAssertEqual(validations, 2)
        XCTAssertEqual(waits, 1)
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(mutations, 0)
    }

    func testTypingDuringWaitRejectsStaleBaselineBeforeMutation() async {
        let clock = Clock()
        let baseline = "original"
        var draft = baseline
        var probes = 0
        var mutations = 0
        do {
            try await ReadinessActionGate.run(deadline: 1, now: { clock.time }, wait: {
                clock.advance(0.1)
                draft = "edited during readiness"
            }, validate: {
                guard draft == baseline else { throw Failure.baselineChanged }
            }, isReady: {
                probes += 1
                return probes > 1
            }, perform: { mutations += 1 })
            XCTFail("Expected changed baseline")
        } catch {
            XCTAssertEqual(error as? Failure, .baselineChanged)
        }
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(mutations, 0)
    }

    func testMutationErrorIsPropagatedWithoutRetry() async {
        let clock = Clock()
        var waits = 0
        var probes = 0
        var mutations = 0
        do {
            try await ReadinessActionGate.run(deadline: 1, now: { clock.time }, wait: {
                waits += 1
            }, validate: {}, isReady: {
                probes += 1
                return true
            }, perform: {
                mutations += 1
                throw Failure.mutationResultUnknown
            })
            XCTFail("Expected mutation error")
        } catch {
            XCTAssertEqual(error as? Failure, .mutationResultUnknown)
        }
        XCTAssertEqual(waits, 0)
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(mutations, 1)
    }

    func testValidationExhaustingDeadlineDoesNotProbeOrMutate() async {
        let clock = Clock()
        var probes = 0
        var mutations = 0
        do {
            try await ReadinessActionGate.run(deadline: 1, now: { clock.time }, wait: {
                XCTFail("Validation timeout must not wait")
            }, validate: {
                clock.advance(1)
            }, isReady: {
                probes += 1
                return true
            }, perform: { mutations += 1 })
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? ReadinessActionGate.GateError, .timedOut)
        }
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(mutations, 0)
    }

    func testProbeExhaustingDeadlineDoesNotMutateEvenWhenReady() async {
        for ready in [false, true] {
            let clock = Clock()
            var mutations = 0
            do {
                try await ReadinessActionGate.run(deadline: 1, now: { clock.time }, wait: {
                    XCTFail("Probe timeout must not wait")
                }, validate: {}, isReady: {
                    clock.advance(1)
                    return ready
                }, perform: { mutations += 1 })
                XCTFail("Expected timeout")
            } catch {
                XCTAssertEqual(error as? ReadinessActionGate.GateError, .timedOut)
            }
            XCTAssertEqual(mutations, 0)
        }
    }

    func testCancellationFromWaitStopsBeforeAnotherProbeOrMutation() async {
        let clock = Clock()
        var validations = 0
        var probes = 0
        var mutations = 0
        do {
            try await ReadinessActionGate.run(deadline: 1, now: { clock.time }, wait: {
                clock.advance(0.1)
                throw CancellationError()
            }, validate: {
                validations += 1
            }, isReady: {
                probes += 1
                return probes > 1
            }, perform: { mutations += 1 })
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(validations, 1)
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(mutations, 0)
    }

    func testExpiredDeadlineDoesNotCallAnyOperation() async {
        do {
            try await ReadinessActionGate.run(deadline: 1, now: { 1 }, wait: {
                XCTFail("Expired gate must not wait")
            }, validate: {
                XCTFail("Expired gate must not validate")
            }, isReady: {
                XCTFail("Expired gate must not probe")
                return true
            }, perform: {
                XCTFail("Expired gate must not mutate")
            })
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? ReadinessActionGate.GateError, .timedOut)
        }
    }

    func testProbeFailureDoesNotWaitRetryOrMutate() async {
        let clock = Clock()
        var probes = 0
        var mutations = 0
        do {
            try await ReadinessActionGate.run(deadline: 1, now: { clock.time }, wait: {
                XCTFail("Failed probe must not retry")
            }, validate: {}, isReady: {
                probes += 1
                throw Failure.probeFailed
            }, perform: { mutations += 1 })
            XCTFail("Expected probe error")
        } catch {
            XCTAssertEqual(error as? Failure, .probeFailed)
        }
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(mutations, 0)
    }
}
