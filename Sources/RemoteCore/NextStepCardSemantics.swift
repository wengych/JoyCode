import Foundation

/// Recognizes Claude Code's end-of-turn choice cards from accessible button names.
/// Names are compared in memory only; traits and classifications carry no label text,
/// so they are safe to log. Unknown or risky shapes classify as non-actionable.
public enum NextStepCardSemantics {
    public struct ButtonTraits: Equatable {
        public let hasCommandGlyph: Bool
        public let hasReturnGlyph: Bool
        /// Exactly a fixed "New session" / "Do it here" style offer label.
        public let isSessionOffer: Bool
        /// A permission prompt word or a fixed app action (merge, archive, commit…).
        public let isBlocked: Bool

        public init(hasCommandGlyph: Bool, hasReturnGlyph: Bool, isSessionOffer: Bool, isBlocked: Bool) {
            self.hasCommandGlyph = hasCommandGlyph
            self.hasReturnGlyph = hasReturnGlyph
            self.isSessionOffer = isSessionOffer
            self.isBlocked = isBlocked
        }

        /// The primary option shows a ⌘↩ hint next to its label.
        public var hasShortcutHint: Bool { hasCommandGlyph && hasReturnGlyph }
    }

    public enum Classification: Equatable {
        /// `primaryIndex` is in document order among the card's buttons.
        case nextStep(primaryIndex: Int, optionCount: Int)
        case sessionOffer(optionCount: Int)
        case blocked
        case unsupportedCount(Int)
        case unrecognized

        public var diagnosticName: String {
            switch self {
            case .nextStep(let primary, let count): return "nextStep(primary=\(primary),of=\(count))"
            case .sessionOffer(let count): return "sessionOffer(of=\(count))"
            case .blocked: return "blocked"
            case .unsupportedCount(let count): return "unsupportedCount(\(count))"
            case .unrecognized: return "unrecognized"
            }
        }
    }

    private static let commandGlyphs = ["⌘"]
    private static let returnGlyphs = ["↩", "⏎", "↵", "⌤"]
    private static let returnWords = ["return", "enter"]

    private static let sessionOfferLabels: Set<String> = [
        "new session", "do it here",
        "新会话", "新建会话", "新对话", "在这里做", "在此处做", "就在这里做",
        "新工作階段", "在這裡做"
    ]
    /// Permission prompts must never be answered by a controller button.
    private static let approvalWords = [
        "allow", "deny", "approve", "reject", "always",
        "允许", "拒绝", "批准", "始终", "允許", "拒絕", "總是"
    ]
    /// Fixed app-action labels that act instead of sending a reply.
    private static let appActionLabels: Set<String> = [
        "commit", "create pr", "create pull request", "merge", "archive", "verify",
        "fix ci", "address comments", "resolve conflicts",
        "提交", "创建 pr", "合并", "归档", "验证", "修复 ci", "处理评论", "解决冲突"
    ]

    /// `names` are every accessible name source of one button (title, description,
    /// AXLabel and descendant static text). Each is inspected independently.
    /// `keyShortcuts` is the button's `aria-keyshortcuts` (AXKeyShortcutsValue). In Claude
    /// 5.11492 the visible ⌘↩ glyphs are hidden from AX and the primary option instead
    /// declares "Meta+Enter"; it is never treated as a label.
    public static func traits(names: [String], keyShortcuts: String = "") -> ButtonTraits {
        let lowered = names.map { $0.lowercased() }
        let declared = keyShortcuts.lowercased().split(separator: " ").contains { shortcut in
            let keys = shortcut.split(separator: "+").map(String.init)
            return keys.count == 2 && keys.contains("meta") && (keys.contains("enter") || keys.contains("return"))
        }
        let hasCommand = declared || lowered.contains { name in commandGlyphs.contains(where: name.contains) }
        // A spelled-out key only counts beside a ⌘ glyph, never on its own.
        let hasReturn = declared || lowered.contains { name in returnGlyphs.contains(where: name.contains) }
            || (hasCommand && lowered.contains { name in returnWords.contains(where: name.contains) })
        let labels = names.map(normalizedLabel).filter { !$0.isEmpty }
        let isOffer = !labels.isEmpty && labels.allSatisfy(sessionOfferLabels.contains)
        let isBlocked = lowered.contains { name in approvalWords.contains(where: name.contains) }
            || labels.contains(where: appActionLabels.contains)
        return ButtonTraits(hasCommandGlyph: hasCommand, hasReturnGlyph: hasReturn,
                            isSessionOffer: isOffer, isBlocked: isBlocked)
    }

    /// `buttons` must be in document order and belong to one card container.
    public static func classify(_ buttons: [ButtonTraits]) -> Classification {
        guard (1...2).contains(buttons.count) else { return .unsupportedCount(buttons.count) }
        if buttons.contains(where: \.isBlocked) { return .blocked }
        let hinted = buttons.indices.filter { buttons[$0].hasShortcutHint }
        if hinted.count == 1 { return .nextStep(primaryIndex: hinted[0], optionCount: buttons.count) }
        if hinted.isEmpty, buttons.allSatisfy(\.isSessionOffer) {
            return .sessionOffer(optionCount: buttons.count)
        }
        return .unrecognized
    }

    /// Drops shortcut glyphs and surrounding space so "Do it here ⌘↩" compares as a label.
    private static func normalizedLabel(_ name: String) -> String {
        var value = name.lowercased()
        for glyph in commandGlyphs + returnGlyphs { value = value.replacingOccurrences(of: glyph, with: "") }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
