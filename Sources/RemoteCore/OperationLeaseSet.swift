import Foundation

/// Tracks nested work without allowing an invalidated old operation to release
/// the busy state of a newer one. The owner serializes access on its executor.
public struct OperationLeaseSet {
    private var tokens: Set<UUID> = []

    public init() {}

    public var isBusy: Bool { !tokens.isEmpty }

    public mutating func begin() -> UUID {
        let token = UUID()
        tokens.insert(token)
        return token
    }

    public mutating func end(_ token: UUID) {
        tokens.remove(token)
    }

    public mutating func invalidate() {
        tokens.removeAll()
    }
}
