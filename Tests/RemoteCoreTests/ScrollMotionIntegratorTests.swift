import XCTest
import RemoteCore

final class ScrollMotionIntegratorTests: XCTestCase {
    func testFirstSampleDoesNotProduceRetroactiveMovement() {
        var integrator = ScrollMotionIntegrator()
        XCTAssertEqual(integrator.sample(normalized: 1, at: 40_000), 0)
        XCTAssertEqual(Double(integrator.sample(normalized: 1, at: 40_000 + 1.0 / 30)), 48, accuracy: 1)
    }

    func testLightMotionEventuallyProducesWholePixels() {
        for sign in [-1.0, 1.0] {
            let packets = sampleConstantMotion(normalized: sign * 0.001, frequency: 120, seconds: 3)
            XCTAssertEqual(packets.reduce(0, +), Int32(sign * 4))
            XCTAssertTrue(packets.contains { $0 != 0 })
            XCTAssertTrue(packets.allSatisfy { $0 == 0 || $0 == Int32(sign) })
        }
    }

    func testEqualDurationsPreserveDistanceAcrossSamplingFrequencies() {
        for velocity in [-1.0, -0.217, -0.001, 0.001, 0.217, 1.0] {
            for start in [0.0, 100_000.0] {
                let totals = [30, 60, 120].map { frequency in
                    sampleConstantMotion(normalized: velocity, frequency: frequency, seconds: 3, start: start)
                        .reduce(0, +)
                }
                XCTAssertLessThanOrEqual(totals.max()! - totals.min()!, 1, "velocity \(velocity), start \(start)")
                for total in totals {
                    XCTAssertEqual(Double(total), velocity * 1_440 * 3, accuracy: 1.001)
                }
            }
        }
    }

    func testDeliveryRateLimitsPacketsWithoutDroppingIntegratedMovement() {
        var integrator = ScrollMotionIntegrator()
        var lastPacketTime: TimeInterval?
        var total: Int32 = 0
        var packetCount = 0
        for index in 0...120 {
            let time = Double(index) / 120
            let pixels = integrator.sample(normalized: 1, at: time)
            if pixels != 0 {
                if let previous = lastPacketTime {
                    XCTAssertGreaterThanOrEqual(time - previous, 1.0 / 30 - 1e-9)
                }
                lastPacketTime = time
                packetCount += 1
                total += pixels
            }
        }
        XCTAssertEqual(packetCount, 30)
        XCTAssertEqual(Double(total), 1_440, accuracy: 1)
    }

    func testOuterThirtyHertzValidationGatePreservesConstantVelocityAcrossSkippedTicks() {
        let timerFrequency = 60.0
        let duration = 3.0
        let validationInterval = 1.0 / 30
        let maximumValidationCadence = 3.0 / timerFrequency

        for velocity in [-1.0, -0.001, 0.001, 1.0] {
            for start in [0.0, 100_000.0] {
                var integrator = ScrollMotionIntegrator()
                var lastValidatedAt = 0.0 // Matches the bridge's initial outer-gate timestamp.
                var validatedTimes: [TimeInterval] = []
                var packetTimes: [TimeInterval] = []
                var total: Int32 = 0

                for index in 0...Int(timerFrequency * duration) {
                    let time = start + Double(index) / timerFrequency
                    // Retain the production gate's strict comparison: floating-point
                    // boundaries can delay validation until the following 60 Hz tick.
                    guard time - lastValidatedAt >= validationInterval else { continue }
                    lastValidatedAt = time
                    validatedTimes.append(time)
                    let packet = integrator.sample(normalized: velocity, at: time)
                    if packet != 0 {
                        packetTimes.append(time)
                        total += packet
                    }
                }

                let firstValidatedAt = validatedTimes.first!
                let finalValidatedAt = validatedTimes.last!
                let gaps = zip(validatedTimes.dropFirst(), validatedTimes).map { $0 - $1 }
                XCTAssertTrue(gaps.contains { $0 > validationInterval + 1e-9 })
                XCTAssertTrue(gaps.allSatisfy { $0 <= maximumValidationCadence + 1e-9 })
                XCTAssertFalse(packetTimes.isEmpty, "Light motion must eventually deliver pixels")
                XCTAssertEqual(
                    Double(total), velocity * 1_440 * (finalValidatedAt - firstValidatedAt),
                    accuracy: 1.001, "velocity \(velocity), start \(start)"
                )

                // A timer run can finish before the next validation; only that final
                // cadence and a subpixel remainder may be absent from delivered totals.
                XCTAssertLessThanOrEqual(start + duration - finalValidatedAt, maximumValidationCadence + 1e-9)
                XCTAssertEqual(
                    Double(total), velocity * 1_440 * (start + duration - firstValidatedAt),
                    accuracy: abs(velocity) * 1_440 * maximumValidationCadence + 1.001
                )
                for (time, previousTime) in zip(packetTimes.dropFirst(), packetTimes) {
                    XCTAssertGreaterThanOrEqual(time - previousTime, validationInterval - 1e-9)
                }
            }
        }
    }

    func testNeutralAndExplicitResetDiscardPendingFractions() {
        for resetUsingNeutral in [false, true] {
            var integrator = ScrollMotionIntegrator()
            XCTAssertEqual(integrator.sample(normalized: 0.01, at: 0), 0)
            XCTAssertEqual(integrator.sample(normalized: 0.01, at: 1.0 / 30), 0) // 0.48 px.
            if resetUsingNeutral {
                XCTAssertEqual(integrator.sample(normalized: 0, at: 0.04), 0)
            } else {
                integrator.reset() // Caller uses this at a disconnect or suspension boundary.
            }
            XCTAssertEqual(integrator.sample(normalized: 0.01, at: 0.05), 0)
            XCTAssertEqual(integrator.sample(normalized: 0.01, at: 0.05 + 1.0 / 30), 0)
            XCTAssertEqual(integrator.sample(normalized: 0.01, at: 0.05 + 2.0 / 30), 0)
            XCTAssertEqual(integrator.sample(normalized: 0.01, at: 0.05 + 3.0 / 30), 1)
        }
    }

    func testReversalDiscardsOldDirectionIncludingUndeliveredWholePixels() {
        for sign in [-1.0, 1.0] {
            var integrator = ScrollMotionIntegrator()
            XCTAssertEqual(integrator.sample(normalized: sign, at: 0), 0)
            XCTAssertEqual(integrator.sample(normalized: sign, at: 1.0 / 120), 0) // 12 px pending.
            XCTAssertEqual(integrator.sample(normalized: -sign * 0.01, at: 2.0 / 120), 0)
            XCTAssertEqual(integrator.sample(normalized: -sign * 0.01, at: 2.0 / 120 + 1.0 / 30), 0)
            XCTAssertEqual(integrator.sample(normalized: -sign * 0.01, at: 2.0 / 120 + 2.0 / 30), 0)
            XCTAssertEqual(integrator.sample(normalized: -sign * 0.01, at: 2.0 / 120 + 3.0 / 30), Int32(-sign))
        }
    }

    func testNonfiniteInputOrTimeResetsGesture() {
        let invalidSamples: [(Double, TimeInterval)] = [
            (.nan, 0.02), (.infinity, 0.02), (-.infinity, 0.02),
            (1, .nan), (1, .infinity), (1, -.infinity)
        ]
        for (value, time) in invalidSamples {
            var integrator = ScrollMotionIntegrator()
            XCTAssertEqual(integrator.sample(normalized: 1, at: 0), 0)
            XCTAssertEqual(integrator.sample(normalized: 1, at: 1.0 / 120), 0)
            XCTAssertEqual(integrator.sample(normalized: value, at: time), 0)
            XCTAssertEqual(integrator.sample(normalized: 1, at: 0.025), 0)
            XCTAssertEqual(Double(integrator.sample(normalized: 1, at: 0.025 + 1.0 / 30)), 48, accuracy: 1)
        }
    }

    func testDuplicateReversedAndLongGapTimestampsDoNotCatchUp() {
        for time in [0.01, -0.01, 0.110_01, 100_000.0, Double.greatestFiniteMagnitude] {
            var integrator = ScrollMotionIntegrator()
            XCTAssertEqual(integrator.sample(normalized: 1, at: 0), 0)
            XCTAssertEqual(integrator.sample(normalized: 1, at: 0.01), 0)
            XCTAssertEqual(integrator.sample(normalized: 1, at: time), 0)
            if time < 1_000_000 {
                XCTAssertEqual(Double(integrator.sample(normalized: 1, at: time + 1.0 / 30)), 48, accuracy: 1)
            }
        }
    }

    func testInputClampingAndMaximumPermittedGapKeepPacketsBounded() {
        for value in [-Double.greatestFiniteMagnitude, -2, 2, Double.greatestFiniteMagnitude] {
            var integrator = ScrollMotionIntegrator()
            XCTAssertEqual(integrator.sample(normalized: value, at: 0), 0)
            XCTAssertEqual(integrator.sample(normalized: value, at: 0.03), 0)
            let packet = integrator.sample(normalized: value, at: 0.13)
            XCTAssertEqual(Double(packet), (value < 0 ? -1 : 1) * 1_440 * 0.13, accuracy: 1)
            XCTAssertLessThanOrEqual(abs(packet), 193)
        }
        var integrator = ScrollMotionIntegrator()
        XCTAssertEqual(integrator.sample(normalized: 1, at: -Double.greatestFiniteMagnitude), 0)
        XCTAssertEqual(integrator.sample(normalized: 1, at: Double.greatestFiniteMagnitude), 0)
    }

    private func sampleConstantMotion(
        normalized: Double, frequency: Int, seconds: Int, start: TimeInterval = 0
    ) -> [Int32] {
        var integrator = ScrollMotionIntegrator()
        return (0...(frequency * seconds)).map { index in
            integrator.sample(normalized: normalized, at: start + Double(index) / Double(frequency))
        }
    }
}
