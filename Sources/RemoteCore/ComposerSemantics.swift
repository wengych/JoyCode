/// Accessibility metadata used to recognize a composer without reading its draft.
/// A positive score is a discovery hint; callers must still verify the live target.
public struct ComposerEvidence {
    public let role: String
    public let identifier: String
    public let title: String
    public let description: String
    public let label: String
    public let placeholder: String
    public let isEnabled: Bool?
    public let isHidden: Bool?

    public init(
        role: String = "",
        identifier: String = "",
        title: String = "",
        description: String = "",
        label: String = "",
        placeholder: String = "",
        isEnabled: Bool? = nil,
        isHidden: Bool? = nil
    ) {
        self.role = role
        self.identifier = identifier
        self.title = title
        self.description = description
        self.label = label
        self.placeholder = placeholder
        self.isEnabled = isEnabled
        self.isHidden = isHidden
    }
}

public enum ComposerSemantics {
    public static func score(_ evidence: ComposerEvidence) -> Int {
        guard evidence.role == "AXTextArea" || evidence.role == "AXTextField",
              evidence.isEnabled != false, evidence.isHidden != true else { return 0 }

        let identifier = evidence.identifier.lowercased()
        if identifier == "prompt-textarea" || identifier == "chat-input" { return 120 }

        // Inspect every field independently: a generic title must not hide a useful
        // description, and separate fields must not manufacture a matching phrase.
        let hints = [identifier, evidence.title, evidence.description, evidence.label, evidence.placeholder]
            .map { $0.lowercased() }
        func containsAny(_ terms: [String]) -> Bool {
            hints.contains { hint in terms.contains(where: hint.contains) }
        }

        if containsAny(["search", "find", "rename", "搜索", "查找", "重命名", "password"]) { return 0 }
        if containsAny([
            "message claude", "reply to claude", "ask codex", "ask anything", "send a message",
            "message composer", "chat input", "输入消息", "发送消息", "向 claude", "向 codex",
            // aria-label / placeholder strings verified in the installed ChatGPT desktop bundle.
            "work with codex", "和 codex 一起工作", "do anything", "随心输入",
            "ask chatgpt", "询问 chatgpt", "work with chatgpt", "使用 chatgpt work",
            "與 codex 協作", "問問 chatgpt", "問 chatgpt", "想做什麼都可以", "輸入任何任務"
        ]) { return 95 }
        if containsAny(["prompt", "composer", "message", "reply", "消息", "提问", "回复"]) { return 75 }
        return 0
    }
}
