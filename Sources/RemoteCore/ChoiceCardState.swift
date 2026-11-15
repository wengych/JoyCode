import Foundation

/// One-answer-per-card receipts for Claude choice cards and Codex request-panel questions.
/// Keys are opaque live identities from the platform adapter (window, container and an
/// in-memory label digest), never label text. There is deliberately no controller-side
/// option selection: Claude shows no selection state, so the controller only answers the
/// first option and anything else is left to the user.
public struct ChoiceCardState {
    private var answered: Set<String> = []

    public init() {}

    /// Read-only preflight: once any option of a card was pressed, the card is answered.
    public func permits(_ key: String) -> Bool { !answered.contains(key) }

    /// Call at the native mutation boundary, before AXPress; a failed preflight records none.
    public mutating func recordDispatch(_ key: String) {
        answered.insert(key)
    }

    /// Only an observed absence of that card releases its receipt.
    public mutating func observeAbsent(_ key: String) {
        answered.remove(key)
    }
}
