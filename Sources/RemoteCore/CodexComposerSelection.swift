import Foundation

/// Codex composer metadata is separate from Claude's scored discovery hints.
/// Only complete labels evidenced in the installed app authorize recognition.
public enum CodexComposerSelection {
    public enum LabelCategory: String, CaseIterable, Hashable {
        case askChatGPT, workWithCodex, workWithChatGPT, doAnything
        case working, goal, plan, project, multipleKnown
    }

    public enum RejectionReason: String, Equatable {
        case unsupportedRole, hidden, disabled, notEditable, unrecognizedLabel, missingAccessibleName
    }

    public enum LabelSource: String, Equatable {
        case accessibleName, placeholder
    }

    public struct Candidate: Equatable {
        public let id: Int
        public let recognized: Bool
        public let isEditable: Bool
        public let isFocused: Bool
        public let isInMainPane: Bool
        public let isSecondary: Bool

        /// The adapter must reject unsupported roles, hidden/disabled controls and
        /// foreign windows before construction. Focus may include a verified descendant.
        public init(id: Int, recognized: Bool, isEditable: Bool, isFocused: Bool,
                    isInMainPane: Bool, isSecondary: Bool) {
            self.id = id
            self.recognized = recognized
            self.isEditable = isEditable
            self.isFocused = isFocused
            self.isInMainPane = isInMainPane
            self.isSecondary = isSecondary
        }
    }

    public enum SelectionError: Error, Equatable {
        case ambiguous
    }

    private static let labels: [String: LabelCategory] = [
        "ask chatgpt": .askChatGPT,
        "询问 chatgpt": .askChatGPT,
        "問問 chatgpt": .askChatGPT,
        "問 chatgpt": .askChatGPT,
        "work with codex": .workWithCodex,
        "和 codex 一起工作": .workWithCodex,
        "與 codex 協作": .workWithCodex,
        "work with chatgpt": .workWithChatGPT,
        "使用 chatgpt work": .workWithChatGPT,
        "與 chatgpt 一起工作": .workWithChatGPT,
        "與 chatgpt 協作": .workWithChatGPT,
        "do anything": .doAnything,
        "随心输入": .doAnything,
        "想做什麼都可以": .doAnything,
        "輸入任何任務": .doAnything,
        "working…": .working,
        "处理中…": .working,
        "處理中…": .working,
        "describe your goal, define measurable outcomes for best results": .goal,
        "描述你的目标，并设定可衡量的预期成果，以取得最佳效果": .goal,
        "描述你的目標，並設定可衡量的成果，以獲得最佳成效": .goal,
        "描述你的目標，並設定可衡量的成果，以取得最佳成效": .goal,
        "describe your task to generate a plan...": .plan,
        // This unusual translation is the installed app's literal string.
        "描述你的任务以生成套餐…": .plan,
        "描述你的任務以產生方案…": .plan,
        "描述你的任務以生成計劃...": .plan,
        "new chat in this project": .project,
        "此项目中的新聊天": .project,
        "此專案中的新對話": .project,
        "在此項目中開始新對話": .project
    ]

    /// The identifier alone is not evidence: installed Codex assets do not establish
    /// that `prompt-textarea` or `chat-input` identifies its main composer.
    public static func recognizedLabel(_ evidence: ComposerEvidence) -> LabelCategory? {
        recognition(evidence)?.category
    }

    /// Placeholder recognition is diagnostic only. The installed main composer has an
    /// explicit accessible name; an unnamed editor is never made eligible by a placeholder.
    public static func matchingSource(_ evidence: ComposerEvidence) -> LabelSource? {
        recognition(evidence)?.source
    }

    private static func recognition(_ evidence: ComposerEvidence) -> (category: LabelCategory, source: LabelSource)? {
        let names = [evidence.title, evidence.description, evidence.label]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let source: LabelSource = names.allSatisfy(\.isEmpty) ? .placeholder : .accessibleName
        let selected = source == .placeholder
            ? [evidence.placeholder.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] : names
        let found = Set(selected.compactMap { labels[$0] })
        guard !found.isEmpty else { return nil }
        let category: LabelCategory
        if found.count == 1, let only = found.first { category = only }
        else { category = .multipleKnown }
        return (category, source)
    }

    /// Editable requires an affirmative AXValue-settable result supplied by the adapter.
    /// A readable/focusable text area is not necessarily an input.
    public static func rejectionReason(for evidence: ComposerEvidence,
                                       isEditable: Bool) -> RejectionReason? {
        guard ["AXTextArea", "AXTextField"].contains(evidence.role) else { return .unsupportedRole }
        guard evidence.isHidden != true else { return .hidden }
        guard evidence.isEnabled != false else { return .disabled }
        guard isEditable else { return .notEditable }
        guard let source = matchingSource(evidence) else { return .unrecognizedLabel }
        guard source == .accessibleName else { return .missingAccessibleName }
        return nil
    }

    public static func isEligible(_ evidence: ComposerEvidence, isEditable: Bool) -> Bool {
        rejectionReason(for: evidence, isEditable: isEditable) == nil
    }

    /// Follow an actually focused eligible editor first. Without that evidence,
    /// prefer a unique main-pane editor, then a unique nonsecondary editor.
    /// Neither score, position nor traversal order breaks a remaining ambiguity.
    public static func select(_ candidates: [Candidate]) throws -> Candidate? {
        let eligible = candidates.filter { $0.recognized && $0.isEditable }
        let focused = eligible.filter(\.isFocused)
        if focused.count > 1 { throw SelectionError.ambiguous }
        if let only = focused.first { return only }

        let main = eligible.filter { $0.isInMainPane && !$0.isSecondary }
        if main.count > 1 { throw SelectionError.ambiguous }
        if let only = main.first { return only }

        let primary = eligible.filter { !$0.isSecondary }
        if primary.count > 1 { throw SelectionError.ambiguous }
        return primary.first
    }
}
