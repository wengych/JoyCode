import AppKit
import ApplicationServices
import RemoteCore

enum ChoiceCardError: LocalizedError {
    case agentRunning
    case unsupported(String)
    case ambiguous(String)
    case blocked
    case freeForm
    case notExposed
    case changed
    case operation(String, AXError)

    var errorDescription: String? {
        switch self {
        case .agentRunning: return "Agent 仍在运行，选项卡未回答。"
        case .unsupported(let detail): return "选项卡结构无法识别（\(detail)），未回答。"
        case .ambiguous(let detail): return "\(detail)不唯一，未回答。"
        case .blocked: return "这是审批或应用操作按钮（如合并、归档、提交），请用鼠标确认。"
        case .freeForm: return "该选项需要输入文字，请用语音或键盘回答。"
        case .notExposed: return "选项被遮挡或尚未显示，请让 Agent 窗口完整可见。"
        case .changed: return "选项卡已变化，未回答；请重新确认。"
        case .operation(let action, let error):
            return "\(action)失败（AX \(error.rawValue)）；结果可能未知，请检查界面，不会自动重试。"
        }
    }
}

/// A located, answerable card. Elements and the key stay in memory; labels are never kept.
struct ChoiceCard {
    enum Kind { case claudeNextStep, codexQuestion }

    let kind: Kind
    /// Opaque identity: window, options container and an in-memory label digest.
    let key: String
    let window: ForegroundWindowHandle
    let container: AXUIElement
    /// Answer buttons (Claude) or radio options (Codex), in visual order.
    let options: [AXUIElement]
    /// Claude: the Meta+Enter primary. Codex: checked, else the single recommended option.
    let defaultIndex: Int?
    /// Codex only: the single Submit / Continue / Next control of the panel; nil for an
    /// immediate-response panel (ChatGPT.app 26.1111 plan questions), where choosing answers.
    let advance: AXUIElement?
}

/// Locates and answers Claude Code's end-of-turn choice card and ChatGPT / Codex's
/// request-input panel by AX semantics only: no synthesized ⌘↩, no retries. Locating is
/// read-only; `press` re-verifies everything and issues each AXPress at most once.
@MainActor
final class ChoiceCardNavigator {
    private let stopLabels: Set<String> = ["stop", "stop response", "stop generating", "停止", "停止生成", "停止回复", "中止"]

    // MARK: Claude

    /// Claude 5.11492: the primary answer declares aria-keyshortcuts "Meta+Enter"; its parent
    /// AXGroup/AXApplicationGroup holds only the 1–2 answer buttons; the grandparent card
    /// holds the recap/question text and a Dismiss icon, between the last reply and its toolbar.
    func locateClaude(composer: AXUIElement, window: ForegroundWindowHandle) throws -> ChoiceCard? {
        guard let root = webArea(of: composer), let composerFrame = frame(composer) else {
            throw ChoiceCardError.unsupported("输入框位置未知")
        }
        let (after, afterStatus) = search(root, key: "AXButtonSearchKey", limit: 10,
                                          start: composer, direction: "AXDirectionNext")
        guard afterStatus == .success else { throw ChoiceCardError.operation("读取输入框按钮", afterStatus) }
        if after.contains(where: { stopLabels.contains(normalized(label($0))) }) { throw ChoiceCardError.agentRunning }

        let (before, beforeStatus) = search(root, key: "AXButtonSearchKey", limit: 10,
                                            start: composer, direction: "AXDirectionPrevious")
        guard beforeStatus == .success else { throw ChoiceCardError.operation("检索选项卡", beforeStatus) }
        // Nearest first: the first declared primary above the composer is the newest card.
        guard let primary = before.first(where: { button in
            guard let rect = frame(button), rect.maxY <= composerFrame.minY + 2 else { return false }
            return traits(button).hasShortcutHint
        }) else { return nil }

        guard let group = element(primary, kAXParentAttribute), role(group) == kAXGroupRole,
              string(group, kAXSubroleAttribute) == "AXApplicationGroup" else {
            throw ChoiceCardError.unsupported("选项分组")
        }
        let options = elements(group, kAXChildrenAttribute)
        guard (1...2).contains(options.count), options.allSatisfy({ role($0) == kAXButtonRole }) else {
            throw ChoiceCardError.unsupported("选项数量")
        }
        guard let card = element(group, kAXParentAttribute), role(card) == kAXGroupRole,
              !belongs(composer, to: card), cardHasText(card) else {
            throw ChoiceCardError.unsupported("卡片容器")
        }
        let ordered = options.sorted(by: visualOrder)
        switch NextStepCardSemantics.classify(ordered.map(traits)) {
        case .nextStep(let primaryIndex, _):
            try ordered.forEach(requirePressable)
            return ChoiceCard(kind: .claudeNextStep, key: key(window: window, container: group, options: ordered),
                              window: window, container: group, options: ordered,
                              defaultIndex: primaryIndex, advance: nil)
        case .blocked: throw ChoiceCardError.blocked
        case .sessionOffer, .unrecognized, .unsupportedCount: throw ChoiceCardError.unsupported("选项类型")
        }
    }

    // MARK: Codex

    /// ChatGPT.app 26.1111 request-input panel: radio options (one may carry a Recommended
    /// badge, pre-checked) plus at most one Submit / Continue / Next control. The observed plan
    /// question panel has none — Dismiss, an icon button and Skip only — and answers on choice.
    /// Multi-select, free-form and ambiguous panels are refused.
    func locateCodex(window: ForegroundWindowHandle) throws -> ChoiceCard? {
        guard bool(window.window, kAXModalAttribute) != true, elements(window.window, "AXSheets").isEmpty else {
            throw ChoiceCardError.unsupported("窗口有弹窗")
        }
        var groups: [(root: AXUIElement, group: AXUIElement)] = []
        for root in webRoots(in: window.window) {
            let (found, status) = search(root, key: "AXRadioGroupSearchKey", limit: 4)
            guard status == .success else { throw ChoiceCardError.operation("检索提问面板", status) }
            groups += found.map { (root, $0) }
        }
        guard !groups.isEmpty else { return nil }
        guard groups.count == 1, let only = groups.first else { throw ChoiceCardError.ambiguous("提问面板") }
        let root = only.root
        let group = only.group

        let controls = descendants(of: group, roles: [kAXRadioButtonRole, kAXCheckBoxRole], limit: 60)
        guard !controls.isEmpty else { throw ChoiceCardError.unsupported("选项") }
        guard controls.allSatisfy({ role($0) == kAXRadioButtonRole }) else { throw ChoiceCardError.unsupported("多选题") }
        let ordered = controls.sorted(by: visualOrder)

        // The panel is the nearest ancestor holding its own Skip / Dismiss controls; a forward
        // control, if any, must be there too and be the only one.
        var advance: AXUIElement?
        var panelFound = false
        var current = element(group, kAXParentAttribute)
        for _ in 0..<8 {
            guard let node = current, !CFEqual(node, root) else { break }
            let (buttons, status) = search(node, key: "AXButtonSearchKey", limit: 30)
            guard status == .success else { throw ChoiceCardError.operation("检索面板按钮", status) }
            let kinds = buttons.map { CodexRequestPanelSemantics.buttonKind(label: label($0)) }
            if kinds.contains(where: { $0 == .skip || $0 == .dismiss }) {
                panelFound = true
                let forward = kinds.filter { [.submit, .proceed, .next].contains($0) }.count
                if forward > 1 { throw ChoiceCardError.ambiguous("提交按钮") }
                advance = CodexRequestPanelSemantics.advanceButton(kinds).map { buttons[$0] }
                break
            }
            current = element(node, kAXParentAttribute)
        }
        guard panelFound else { throw ChoiceCardError.unsupported("提问面板") }

        let checked = ordered.map { (attribute($0, kAXValueAttribute) as? NSNumber)?.boolValue == true }
        let recommended = ordered.map { option in
            CodexRequestPanelSemantics.hasRecommendedBadge(childTexts: childTexts(option))
        }
        try ordered.forEach(requirePressable)
        return ChoiceCard(kind: .codexQuestion, key: key(window: window, container: group, options: ordered),
                          window: window, container: group, options: ordered,
                          defaultIndex: CodexRequestPanelSemantics.defaultOption(checked: checked, recommended: recommended),
                          advance: advance)
    }

    // MARK: Press

    /// `verify` re-checks the captured foreground window; `beforeCommit` records the receipt
    /// immediately before the committing AXPress. Nothing is retried.
    func press(_ card: ChoiceCard, option index: Int, verify: () throws -> Void,
               beforeCommit: () throws -> Void) async throws {
        guard card.options.indices.contains(index) else { throw ChoiceCardError.changed }
        let option = card.options[index]
        switch card.kind {
        case .claudeNextStep:
            try verifyStillPresent(card)
            try verify()
            try requireExposed(option, in: card.window.window)
            try requirePressable(option)
            try verify()
            try beforeCommit()
            try check(AXUIElementPerformAction(option, kAXPressAction as CFString), "回答选项卡")
        case .codexQuestion:
            guard !hasTextInput(option) else { throw ChoiceCardError.freeForm }
            let window = card.window.window
            guard let advance = card.advance else {
                // Immediate-response panel: choosing the option is the answer. If this build
                // turns out not to submit on choice, re-choosing the checked option is harmless.
                try verifyStillPresent(card)
                try verify()
                try requireExposed(option, in: window, within: window)
                try requirePressable(option)
                try verify()
                try beforeCommit()
                try check(AXUIElementPerformAction(option, kAXPressAction as CFString), "回答提问")
                return
            }
            if !isChecked(option) {
                try verifyStillPresent(card)
                try verify()
                // Codex draws option text outside the radio element and the panel sits in a
                // pointer-events overlay, so the center only has to hit this same window.
                try requireExposed(option, in: window, within: window)
                // Selecting a radio is idempotent and sends nothing by itself.
                try check(AXUIElementPerformAction(option, kAXPressAction as CFString), "选择选项")
                var selected = false
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(50))
                    try verifyStillPresent(card)
                    if isChecked(option) { selected = true; break }
                }
                // Never commit when the panel moved on by itself or did not take the selection.
                guard selected else { throw ChoiceCardError.changed }
            }
            try verifyStillPresent(card)
            try verify()
            guard CodexRequestPanelSemantics.buttonKind(label: label(advance)) != nil,
                  bool(advance, kAXEnabledAttribute) == true else { throw ChoiceCardError.changed }
            try requireExposed(advance, in: window, within: window)
            try requirePressable(advance)
            try verify()
            try beforeCommit()
            try check(AXUIElementPerformAction(advance, kAXPressAction as CFString), "提交回答")
        }
    }

    /// Read-only: whether the card's options container still holds the same options.
    func isPresent(_ card: ChoiceCard) -> Bool {
        (try? verifyStillPresent(card)) != nil
    }

    // MARK: Checks

    private func verifyStillPresent(_ card: ChoiceCard) throws {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(card.container, kAXRoleAttribute as CFString, &raw) == .success else {
            throw ChoiceCardError.changed
        }
        let current = card.kind == .claudeNextStep
            ? elements(card.container, kAXChildrenAttribute)
            : descendants(of: card.container, roles: [kAXRadioButtonRole, kAXCheckBoxRole], limit: 60)
        guard current.count == card.options.count,
              card.options.allSatisfy({ option in current.contains { CFEqual($0, option) } }),
              key(window: card.window, container: card.container, options: card.options.sorted(by: visualOrder)) == card.key else {
            throw ChoiceCardError.changed
        }
    }

    private func requirePressable(_ node: AXUIElement) throws {
        guard bool(node, kAXEnabledAttribute) == true, bool(node, "AXHidden") != true,
              actions(node).contains(kAXPressAction) else {
            throw ChoiceCardError.unsupported("选项不可用或未提供 AXPress")
        }
    }

    /// The center must hit the control itself or its content in the same window; with
    /// `within`, anything inside that container (e.g. a radio group's own labels) counts.
    private func requireExposed(_ node: AXUIElement, in window: AXUIElement, within container: AXUIElement? = nil) throws {
        guard let rect = frame(node), rect.width > 2, rect.height > 2, rect.midX.isFinite, rect.midY.isFinite else {
            throw ChoiceCardError.notExposed
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(rect.midX), Float(rect.midY), &hit) == .success,
              let hit, belongs(node, to: window) else {
            throw ChoiceCardError.notExposed
        }
        let onNode = CFEqual(hit, node) || belongs(hit, to: node)
        guard onNode || container.map({ belongs(hit, to: $0) }) == true else { throw ChoiceCardError.notExposed }
    }

    private func cardHasText(_ card: AXUIElement) -> Bool {
        var queue = elements(card, kAXChildrenAttribute).map { ($0, 1) }
        var visited = 0
        while !queue.isEmpty, visited < 60 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            let nodeRole = role(node)
            if nodeRole == kAXTextAreaRole || nodeRole == kAXTextFieldRole { return false }
            if nodeRole == kAXStaticTextRole { return true }
            if depth < 6 { queue += elements(node, kAXChildrenAttribute).map { ($0, depth + 1) } }
        }
        return false
    }

    private func hasTextInput(_ node: AXUIElement) -> Bool {
        !descendants(of: node, roles: [kAXTextAreaRole, kAXTextFieldRole], limit: 30).isEmpty
    }

    private func isChecked(_ node: AXUIElement) -> Bool {
        (attribute(node, kAXValueAttribute) as? NSNumber)?.boolValue == true
    }

    // MARK: Semantics helpers

    private func traits(_ button: AXUIElement) -> NextStepCardSemantics.ButtonTraits {
        let names = [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"].map { string(button, $0) } + childTexts(button)
        return NextStepCardSemantics.traits(names: names, keyShortcuts: string(button, "AXKeyShortcutsValue"))
    }

    private func childTexts(_ node: AXUIElement) -> [String] {
        var result: [String] = []
        var queue = elements(node, kAXChildrenAttribute).map { ($0, 1) }
        var visited = 0
        while !queue.isEmpty, visited < 16 {
            let (child, depth) = queue.removeFirst()
            visited += 1
            for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let value = attribute(child, name) as? String, !value.isEmpty { result.append(value) }
            }
            if depth < 3 { queue += elements(child, kAXChildrenAttribute).map { ($0, depth + 1) } }
        }
        return result
    }

    /// In-memory only: a re-render with the same answers keeps its key, a new card does not.
    private func key(window: ForegroundWindowHandle, container: AXUIElement, options: [AXUIElement]) -> String {
        var hasher = Hasher()
        for option in options {
            hasher.combine(label(option))
            hasher.combine(string(option, "AXKeyShortcutsValue"))
        }
        return "\(window.windowIdentity)|\(CFHash(container))|\(hasher.finalize())"
    }

    private func visualOrder(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        guard let left = frame(lhs), let right = frame(rhs) else { return false }
        if abs(left.midY - right.midY) > 4 { return left.midY < right.midY }
        return left.minX < right.minX
    }

    // MARK: AX reads

    private func webArea(of node: AXUIElement) -> AXUIElement? {
        var current = element(node, kAXParentAttribute)
        for _ in 0..<96 {
            guard let parent = current else { return nil }
            if role(parent) == "AXWebArea" { return parent }
            current = element(parent, kAXParentAttribute)
        }
        return nil
    }

    private func webRoots(in window: AXUIElement) -> [AXUIElement] {
        var queue = [window]
        var cursor = 0
        var roots: [AXUIElement] = []
        while cursor < queue.count, queue.count <= 256 {
            let node = queue[cursor]
            cursor += 1
            if role(node) == "AXWebArea" { roots.append(node); continue }
            queue.append(contentsOf: elements(node, kAXChildrenAttribute))
        }
        return roots
    }

    private func search(_ root: AXUIElement, key: String, limit: Int, start: AXUIElement? = nil,
                        direction: String = "AXDirectionNext") -> ([AXUIElement], AXError) {
        var parameters: [String: Any] = [
            "AXSearchKey": [key], "AXResultsLimit": limit, "AXDirection": direction, "AXVisibleOnly": true
        ]
        if let start { parameters["AXStartElement"] = start }
        var raw: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            root, "AXUIElementsForSearchPredicate" as CFString, parameters as CFDictionary, &raw)
        guard status == .success else { return ([], status) }
        return ((raw as? [AXUIElement]) ?? [], status)
    }

    private func descendants(of root: AXUIElement, roles: Set<String>, limit: Int) -> [AXUIElement] {
        var queue = elements(root, kAXChildrenAttribute).map { ($0, 1) }
        var visited = 0
        var result: [AXUIElement] = []
        while !queue.isEmpty, visited < limit {
            let (node, depth) = queue.removeFirst()
            visited += 1
            if roles.contains(role(node)) { result.append(node); continue }
            if depth < 6 { queue += elements(node, kAXChildrenAttribute).map { ($0, depth + 1) } }
        }
        return result
    }

    private func belongs(_ child: AXUIElement, to ancestor: AXUIElement) -> Bool {
        if CFEqual(child, ancestor) { return true }
        if role(ancestor) == kAXWindowRole, let window = element(child, kAXWindowAttribute), CFEqual(window, ancestor) {
            return true
        }
        var parent = element(child, kAXParentAttribute)
        for _ in 0..<96 {
            guard let node = parent else { return false }
            if CFEqual(node, ancestor) { return true }
            parent = element(node, kAXParentAttribute)
        }
        return false
    }

    private func frame(_ node: AXUIElement) -> CGRect? {
        guard let rawPosition = attribute(node, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = attribute(node, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let position = unsafeBitCast(rawPosition, to: AXValue.self)
        let size = unsafeBitCast(rawSize, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize,
              AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func actions(_ node: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(node, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
    }

    private func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func elements(_ node: AXUIElement, _ name: String) -> [AXUIElement] {
        (attribute(node, name) as? [AXUIElement]) ?? []
    }

    private func string(_ node: AXUIElement, _ name: String) -> String {
        (attribute(node, name) as? String) ?? ""
    }

    private func bool(_ node: AXUIElement, _ name: String) -> Bool? {
        (attribute(node, name) as? NSNumber)?.boolValue
    }

    private func role(_ node: AXUIElement) -> String { string(node, kAXRoleAttribute) }

    private func label(_ node: AXUIElement) -> String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"] {
            let value = string(node, name).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return ""
    }

    private func normalized(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func check(_ result: AXError, _ action: String) throws {
        if result != .success { throw ChoiceCardError.operation(action, result) }
    }
}
