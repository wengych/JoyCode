import Foundation

/// Converts a normalized velocity into whole-pixel scroll packets without losing fractions.
/// Supply validated velocity observations; elapsed time accounts for skipped sampling ticks.
/// Reset when motion becomes ineligible, including neutral input, disconnect, or suspension.
public struct ScrollMotionIntegrator {
    private static let maximumPixelsPerSecond = 1_440.0
    private static let minimumDeliveryInterval: TimeInterval = 1.0 / 30.0
    private static let maximumSampleGap: TimeInterval = 0.1
    // Accommodate subtraction error in monotonic-clock timestamps at exact rate boundaries.
    private static let timeTolerance: TimeInterval = 1e-9
    private static let maximumPendingPixels = maximumPixelsPerSecond
        * (minimumDeliveryInterval + maximumSampleGap) + 1

    private var previousSampleTime: TimeInterval?
    private var lastDeliveryTime: TimeInterval?
    private var direction: FloatingPointSign?
    private var pendingPixels = 0.0

    public init() {}

    public mutating func reset() {
        previousSampleTime = nil
        lastDeliveryTime = nil
        direction = nil
        pendingPixels = 0
    }

    /// Returns 0 when no event should be posted. The first sample starts a gesture;
    /// later samples apply the current velocity over the elapsed sampling interval.
    public mutating func sample(normalized: Double, at time: TimeInterval) -> Int32 {
        guard normalized.isFinite, normalized != 0, time.isFinite else {
            reset()
            return 0
        }

        let velocity = max(-1, min(1, normalized))
        guard let previousSampleTime, let lastDeliveryTime else {
            beginGesture(direction: velocity.sign, at: time)
            return 0
        }

        let elapsed = time - previousSampleTime
        let sinceDelivery = time - lastDeliveryTime
        guard elapsed.isFinite, elapsed > 0,
              elapsed <= Self.maximumSampleGap + Self.timeTolerance,
              sinceDelivery.isFinite, direction == velocity.sign else {
            // Never carry stale movement across a clock discontinuity or a reversal.
            beginGesture(direction: velocity.sign, at: time)
            return 0
        }

        self.previousSampleTime = time
        pendingPixels += velocity * Self.maximumPixelsPerSecond * elapsed
        // Normal operation is already bounded by the delivery interval and gap limit.
        // Keep the conversion explicitly safe even at floating-point extremes.
        pendingPixels = max(-Self.maximumPendingPixels, min(Self.maximumPendingPixels, pendingPixels))
        guard sinceDelivery + Self.timeTolerance >= Self.minimumDeliveryInterval else { return 0 }

        let pixels = Int32(pendingPixels.rounded(.towardZero))
        guard pixels != 0 else { return 0 }
        pendingPixels -= Double(pixels)
        self.lastDeliveryTime = time
        return pixels
    }

    private mutating func beginGesture(direction: FloatingPointSign, at time: TimeInterval) {
        previousSampleTime = time
        lastDeliveryTime = time
        self.direction = direction
        pendingPixels = 0
    }
}
