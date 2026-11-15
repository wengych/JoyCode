import Foundation

/// Recognizes controls of ChatGPT / Codex's request-input panel (plan "Implement this
/// plan?" prompt and `request_user_input` questions). Strings come from ChatGPT.app
/// 26.1111 (`requestInputPanel.*`); labels are compared in memory only and a result
/// never carries label text. Unknown shapes are non-actionable.
public enum CodexRequestPanelSemantics {
    public enum ButtonKind: String, Equatable, CaseIterable {
        case submit, proceed, next, nextQuestion, previousQuestion, skip, dismiss
    }

    private static let exactLabels: [ButtonKind: Set<String>] = [
        .submit: ["submit", "提交", "送信する", "제출"],
        .proceed: ["continue", "继续", "繼續", "続行", "계속"],
        .next: ["next", "下一步", "次へ", "다음"],
        .nextQuestion: ["next question", "下一个问题", "下一個問題", "下一題", "次の質問", "다음 질문"],
        .previousQuestion: ["previous question", "上一个问题", "上一條問題", "上一題", "前の質問", "이전 질문"],
        .skip: ["skip", "跳过", "跳過", "略過", "スキップする", "건너뛰기"]
    ]
    /// Dismiss may carry a countdown ("Dismiss, 5 seconds remaining"), so match its prefix.
    private static let dismissPrefixes = ["dismiss", "忽略", "解除", "閉じる", "무시"]
    private static let recommendedBadges: Set<String> = ["recommended", "推荐", "推薦", "おすすめ", "추천"]

    /// Key caps rendered inside a button's name, e.g. the primary action is "Submit ⏎".
    private static let keyCaps = ["⏎", "↩", "↵", "⌤", "⌘"]

    public static func buttonKind(label: String) -> ButtonKind? {
        var value = label.lowercased()
        for cap in keyCaps { value = value.replacingOccurrences(of: cap, with: "") }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let kind = exactLabels.first(where: { $0.value.contains(value) })?.key { return kind }
        if dismissPrefixes.contains(where: { value == $0 || value.hasPrefix($0 + ",") || value.hasPrefix($0 + "，") }) {
            return .dismiss
        }
        return nil
    }

    /// The badge is its own text node inside the option; an option label that merely
    /// mentions "recommended" in a sentence does not count.
    public static func hasRecommendedBadge(childTexts: [String]) -> Bool {
        childTexts.contains { recommendedBadges.contains($0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The option a confirm press applies: the single checked option, else the single
    /// recommended one. Several checked or recommended options are ambiguous.
    public static func defaultOption(checked: [Bool], recommended: [Bool]) -> Int? {
        guard checked.count == recommended.count, !checked.isEmpty else { return nil }
        let checkedIndices = checked.indices.filter { checked[$0] }
        if checkedIndices.count == 1 { return checkedIndices[0] }
        guard checkedIndices.isEmpty else { return nil }
        let recommendedIndices = recommended.indices.filter { recommended[$0] }
        return recommendedIndices.count == 1 ? recommendedIndices[0] : nil
    }

    /// The single forward control that commits the current question. Skip, dismiss and
    /// question paging never count; two forward controls are ambiguous.
    public static func advanceButton(_ kinds: [ButtonKind?]) -> Int? {
        let forward = kinds.indices.filter { [.submit, .proceed, .next].contains(kinds[$0]) }
        return forward.count == 1 ? forward[0] : nil
    }
}
