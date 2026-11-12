/// Chooses among already inspected Claude text controls without accessing AX state.
/// Callers must still verify the selected control's live identity and visibility.
public enum ClaudeComposerSelection {
    public struct Candidate: Equatable {
        public let id: Int
        public let score: Int
        public let isFocused: Bool
        public let isSideChat: Bool
        public let isInPrimaryPane: Bool

        public init(id: Int, score: Int, isFocused: Bool, isSideChat: Bool, isInPrimaryPane: Bool) {
            self.id = id
            self.score = score
            self.isFocused = isFocused
            self.isSideChat = isSideChat
            self.isInPrimaryPane = isInPrimaryPane
        }
    }

    public enum SelectionError: Error, Equatable {
        case ambiguous
        case resultLimitReached(count: Int, limit: Int)
    }

    public static func select(_ candidates: [Candidate]) throws -> Candidate? {
        let eligible = candidates.filter { $0.score > 0 }
        let focused = eligible.filter(\.isFocused)
        if focused.count == 1 { return focused[0] }

        let mainCandidates = eligible.filter { !$0.isSideChat }
        let primaryCandidates = mainCandidates.filter(\.isInPrimaryPane)
        let ranked = (primaryCandidates.isEmpty ? mainCandidates : primaryCandidates)
            .sorted { $0.score > $1.score }
        guard let best = ranked.first else { return nil }
        if ranked.count > 1, best.score - ranked[1].score <= 15 {
            throw SelectionError.ambiguous
        }
        return best
    }

    /// A full result page cannot establish that all matching controls were inspected.
    public static func validateResultCount(count: Int, limit: Int) throws {
        if count >= limit {
            throw SelectionError.resultLimitReached(count: count, limit: limit)
        }
    }
}
