import Foundation

/// Classifies observed labels only. The platform adapter must establish the current
/// composer scope, live identity, visibility, geometry, enabled state and AX actions.
public enum CodexControlSemantics {
    private enum Submission: Hashable {
        case send
        case queue
        case steer
    }

    private static let submissionLabels: [String: Submission] = [
        "send": .send, "发送": .send, "傳送": .send,
        "queue": .queue, "排队": .queue, "加入佇列": .queue,
        "steer": .steer, "引导": .steer, "引導": .steer
    ]

    private static let nonSubmissionLabels: Set<String> = [
        "stop", "停止", "resume", "继续", "繼續", "恢復",
        "transcribe and send", "转录并发送", "轉錄並傳送",
        "start voice chat"
    ]

    /// Queue and Steer are the composer's current submission modes, not a request
    /// to change modes. Conflicting recognized actions are never resolved arbitrarily.
    /// An identifier alone cannot authorize a send or override an opposing label.
    public static func isSend(role: String, names: [String], identifier: String? = nil,
                              hidden: Bool? = nil) -> Bool {
        guard role == "AXButton", hidden != true else { return false }
        let normalized = names.map(normalize)
        guard !normalized.contains(where: nonSubmissionLabels.contains) else { return false }
        // Dictation controls, including stop/cancel/retry, are separate from submitting
        // the reviewed draft even if another AX name happens to say "Send".
        guard !normalized.contains(where: {
            CodexDictationSemantics.match(role: role, names: [$0], hidden: hidden) != nil
        }) else { return false }
        let submissions = Set(normalized.compactMap { submissionLabels[$0] })
        return submissions.count == 1
    }

    public static func isConversationRegion(role: String, names: [String],
                                            hidden: Bool? = nil) -> Bool {
        guard ["AXGroup", "AXScrollArea"].contains(role), hidden != true else { return false }
        return names.map(normalize).contains { ["conversation", "对话", "對話"].contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
