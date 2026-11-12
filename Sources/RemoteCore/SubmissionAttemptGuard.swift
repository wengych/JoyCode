/// In-memory receipts for unresolved submissions, independently keyed by target.
/// A native action error may mean the request was delivered, so a receipt survives
/// that error and submissions to other targets.
/// Target strings are opaque live identities supplied by the platform adapter.
public struct SubmissionAttemptGuard {
    private var pending: [String: String] = [:]

    public init() {}

    /// Read-only preflight: focus changes and rejected attempts cannot clear the
    /// previous dispatch or authorize resending an unchanged composer.
    public func permits(target: String, text: String) -> Bool {
        pending[target] != text
    }

    public func hasPending(target: String) -> Bool {
        pending[target] != nil
    }

    /// A verified change in the same live composer, including clearing after send,
    /// ends the duplicate hold. Observations from another target have no effect.
    public mutating func observe(target: String, text: String) {
        guard let dispatchedText = pending[target], dispatchedText != text else { return }
        pending.removeValue(forKey: target)
    }

    /// Call exactly at the native mutation boundary, before issuing AXPress.
    /// Do not call for preflight failure or only after AXPress succeeds.
    public mutating func recordDispatch(target: String, text: String) {
        pending[target] = text
    }
}
