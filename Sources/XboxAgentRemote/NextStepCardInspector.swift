import AppKit
import ApplicationServices
import notify
import os
import RemoteCore

enum NextStepCardProbeError: LocalizedError {
    case permissionRequired
    case claudeNotFrontmost
    case claudeNotRunning
    case windowUnavailable
    case webAreaUnavailable
    case composerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "请先为 JoyCode 开启辅助功能权限。"
        case .claudeNotFrontmost: return "等待时间内目标应用没有切到前台。"
        case .claudeNotRunning: return "目标应用没有运行。"
        case .windowUnavailable: return "目标应用尚未提供聚焦窗口。"
        case .webAreaUnavailable: return "目标窗口中没有找到页面区域。"
        case .composerUnavailable(let detail): return "未能确定 Claude 输入框（\(detail)）。"
        }
    }
}

/// Read-only probe of Claude Code's end-of-turn choice card (the next-step box and the
/// "New session / Do it here" offer), to learn its real AX shape before any controller
/// binding presses it. It never performs an AX action, writes an attribute, moves focus
/// or posts input. Labels, drafts and transcript text are compared in memory only; the
/// report holds roles, counts, flags, geometry and app-defined DOM hooks, so it goes to
/// the public unified log (`bash logs.sh`) like other JoyCode diagnostics.
@MainActor
final class NextStepCardInspector: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastReport = ""

    /// Development trigger: `notifyutil -p local.weng.XboxAgentRemote.inspectCard` runs one
    /// probe of the frontmost Claude window. A Darwin notification carries no payload, so it
    /// can only start this same read-only report; it never activates or changes any app.
    static let probeNotification = "local.weng.XboxAgentRemote.inspectCard"
    /// Same, for the ChatGPT / Codex request-input panel.
    static let codexProbeNotification = "local.weng.XboxAgentRemote.inspectCard.codex"
    private var notifyToken: Int32 = NOTIFY_TOKEN_INVALID
    private var codexNotifyToken: Int32 = NOTIFY_TOKEN_INVALID

    private let claudeBundleID = "com.anthropic.claudefordesktop"
    private let codexBundleID = "com.openai.codex"
    private let logger = Logger(subsystem: "local.weng.XboxAgentRemote", category: "cardInspector")
    private let stopLabels: Set<String> = ["stop", "stop response", "stop generating", "停止", "停止生成", "停止回复", "中止"]
    private let sendLabels: Set<String> = ["send", "send message", "send prompt", "发送", "发送消息", "提交消息"]

    /// Lives for the app's lifetime (a scene @StateObject), so the registration is never cancelled.
    init() {
        // Read-only, so a scripted probe need not steal focus: it reads the target
        // window in place and reports whether that app was frontmost.
        notify_register_dispatch(Self.probeNotification, &notifyToken, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.inspect(trigger: "notify", requireFrontmost: false) }
            }
        }
        notify_register_dispatch(Self.codexProbeNotification, &codexNotifyToken, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.inspect(trigger: "notify-codex", requireFrontmost: false, bundleID: self.codexBundleID) }
            }
        }
    }

    /// Waits for the target (Claude by default) to be frontmost, so the probe can be started
    /// from the settings window or the menu bar, then inspects its focused window exactly once.
    func inspect(waitSeconds: Double = 6, trigger: String = "manual", requireFrontmost: Bool = true,
                 bundleID: String? = nil) async {
        let target = bundleID ?? claudeBundleID
        guard !isRunning else {
            logger.notice("选项卡诊断已在进行，忽略 trigger=\(trigger, privacy: .public)")
            return
        }
        isRunning = true
        defer { isRunning = false }
        lastReport = "等待 \(target == codexBundleID ? "ChatGPT / Codex" : "Claude") 切到前台（最多 \(Int(waitSeconds)) 秒）…"
        let probeID = "\(trigger)-" + String(UUID().uuidString.prefix(8))
        var lines: [String]
        do {
            let pid = requireFrontmost ? try await waitForFront(target, seconds: waitSeconds) : try running(target)
            lines = target == codexBundleID ? probeCodex(pid: pid) : probe(pid: pid)
        } catch is CancellationError {
            lines = ["已取消"]
        } catch {
            lines = ["失败：\(error.localizedDescription)"]
        }
        lines.insert("选项卡诊断 \(probeID)（只读，不含文字）", at: 0)
        for line in lines { logger.notice("[\(probeID, privacy: .public)] \(line, privacy: .public)") }
        lastReport = lines.joined(separator: "\n")
    }

    private func waitForFront(_ bundleID: String, seconds: Double) async throws -> pid_t {
        guard AXIsProcessTrusted() else { throw NextStepCardProbeError.permissionRequired }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleID {
                // Let activation settle so the focused window really is Claude's.
                try await Task.sleep(for: .milliseconds(300))
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier {
                    return front.processIdentifier
                }
            } else {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw NextStepCardProbeError.claudeNotFrontmost
    }

    private func running(_ bundleID: String) throws -> pid_t {
        guard AXIsProcessTrusted() else { throw NextStepCardProbeError.permissionRequired }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw NextStepCardProbeError.claudeNotRunning
        }
        return app.processIdentifier
    }

    private func probe(pid: pid_t) -> [String] {
        do { return try probeLines(pid: pid) }
        catch { return ["失败：\(error.localizedDescription)"] }
    }

    private func probeCodex(pid: pid_t) -> [String] {
        do { return try probeCodexLines(pid: pid) }
        catch { return ["失败：\(error.localizedDescription)"] }
    }

    /// ChatGPT / Codex request-input panel: each radio group, its options, and the
    /// nearest ancestor holding the panel's own buttons (classified, never read out).
    private func probeCodexLines(pid: pid_t) throws -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let window = [kAXFocusedWindowAttribute, kAXMainWindowAttribute].lazy
                .compactMap({ self.element(app, $0) }).first(where: { self.role($0) == kAXWindowRole }) else {
            throw NextStepCardProbeError.windowUnavailable
        }
        let modal = bool(window, kAXModalAttribute) == true || !elements(window, "AXSheets").isEmpty
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let enhanced = bool(app, "AXEnhancedUserInterface").map(String.init) ?? "nil"
        let manual = bool(app, "AXManualAccessibility").map(String.init) ?? "nil"
        let roots = webRoots(in: window)
        var lines = ["窗口：codexFrontmost=\(frontmost)，webAreas=\(roots.count)，modalOrSheet=\(modal)，enhancedUI=\(enhanced)，manualAX=\(manual)"]
        guard !roots.isEmpty else { throw NextStepCardProbeError.webAreaUnavailable }
        var groupCount = 0
        for (rootIndex, root) in roots.enumerated() {
            let (groups, groupStatus) = search(root, key: "AXRadioGroupSearchKey", limit: 8)
            let (fields, fieldStatus) = search(root, key: "AXTextFieldSearchKey", limit: 12)
            let composers = fields.filter { ComposerSemantics.score(evidence($0)) > 0 }.count
            lines.append("web\(rootIndex)：radioGroupAX=\(groupStatus.rawValue)，radioGroups=\(groups.count)，textInputs=\(fields.count)，composerLike=\(composers)，fieldAX=\(fieldStatus.rawValue)")
            for (groupIndex, group) in groups.enumerated() {
                groupCount += 1
                let options = descendants(of: group, roles: [kAXRadioButtonRole, kAXCheckBoxRole], limit: 40)
                lines.append("  g\(groupIndex) role=\(roleTag(group))，options=\(options.count)，frame=\(frame(group).map(describe) ?? "nil")\(domHooks(group))")
                var checked: [Bool] = []
                var recommended: [Bool] = []
                for (optionIndex, option) in options.enumerated() {
                    let childTexts = nameSources(option).filter { $0.key == "child" }.map(\.value)
                    let badge = CodexRequestPanelSemantics.hasRecommendedBadge(childTexts: childTexts)
                    let value = attribute(option, kAXValueAttribute) as? NSNumber
                    checked.append(value?.boolValue == true)
                    recommended.append(badge)
                    let childRoles = Dictionary(grouping: elements(option, kAXChildrenAttribute).map(roleTag), by: { $0 })
                        .map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: "+")
                    let size = frame(option).map { "\(number($0.width))x\(number($0.height))" } ?? "nil"
                    lines.append("    o\(optionIndex) role=\(roleTag(option))，checked=\(value.map { String($0.intValue) } ?? "nil")，enabled=\(bool(option, kAXEnabledAttribute).map(String.init) ?? "nil")，focused=\(bool(option, kAXFocusedAttribute).map(String.init) ?? "nil")，press=\(actions(option).contains(kAXPressAction))，actions=\(actions(option).count)，nameLen=\(label(option).count)，recommendedBadge=\(badge)，nameSources=\(Set(nameSources(option).map(\.key)).sorted().joined(separator: "/"))，children=\(childRoles.isEmpty ? "0" : childRoles)，hit=\(hitRelation(option, window: window))[\(hitDetail(option, container: group))]，size=\(size)\(domHooks(option))")
                }
                let defaultOption = CodexRequestPanelSemantics.defaultOption(checked: checked, recommended: recommended)
                lines.append("    defaultOption=\(defaultOption.map { "o\($0)" } ?? "none")")
                var current = element(group, kAXParentAttribute)
                for level in 1...8 {
                    guard let node = current, !CFEqual(node, root) else { break }
                    let (buttons, buttonStatus) = search(node, key: "AXButtonSearchKey", limit: 30)
                    let kinds = buttons.map { CodexRequestPanelSemantics.buttonKind(label: label($0)) }
                    let known = zip(buttons, kinds).compactMap { pair -> String? in
                        guard let kind = pair.1 else { return nil }
                        let enabled = bool(pair.0, kAXEnabledAttribute).map(String.init) ?? "nil"
                        return "\(kind.rawValue)(enabled=\(enabled),press=\(actions(pair.0).contains(kAXPressAction)),hit=\(hitRelation(pair.0, window: window)))"
                    }
                    let inputs = search(node, key: "AXTextFieldSearchKey", limit: 6).0.count
                    let advance = CodexRequestPanelSemantics.advanceButton(kinds)
                    if level == 1 {
                        // Panel chrome shape only: flags for a fixed word list, never the label.
                        let words = ["submit", "continue", "next", "send", "answer", "minimize", "collapse", "close",
                                     "rate", "feedback", "提交", "继续", "下一", "发送", "收起", "关闭"]
                        for (buttonIndex, button) in buttons.enumerated() {
                            let name = label(button).lowercased()
                            let flags = words.filter { name.contains($0) }.joined(separator: "/")
                            let size = frame(button).map { "\(number($0.width))x\(number($0.height))" } ?? "nil"
                            lines.append("      btn\(buttonIndex) kind=\(kinds[buttonIndex]?.rawValue ?? "unknown")，nameLen=\(name.count)，ascii=\(name.unicodeScalars.allSatisfy(\.isASCII))，keyCap=\(name.contains("⏎"))，words=[\(flags)]，nameSources=\(Set(nameSources(button).map(\.key)).sorted().joined(separator: "/"))，keyShortcuts=\(string(button, "AXKeyShortcutsValue").isEmpty ? "none" : "present")，enabled=\(bool(button, kAXEnabledAttribute).map(String.init) ?? "nil")，size=\(size)")
                        }
                        let all = descendants(of: node, roles: [kAXButtonRole], limit: 120)
                        lines.append("      allButtonsIncludingHidden=\(all.count)，hiddenOrOffscreen=\(all.filter { b in !buttons.contains { CFEqual($0, b) } }.count)")
                    }
                    lines.append("    L\(level) role=\(roleTag(node))，kids=\(elements(node, kAXChildrenAttribute).count)，buttons=\(buttons.count)(AX=\(buttonStatus.rawValue))，known=[\(known.joined(separator: ","))]，advance=\(advance != nil)，inputs=\(inputs)，frame=\(frame(node).map(describe) ?? "nil")\(domHooks(node))")
                    if advance != nil { break }
                    current = element(node, kAXParentAttribute)
                }
            }
        }
        lines.append("结论：radioGroups=\(groupCount)")
        let handle = ForegroundWindowHandle(bundleID: codexBundleID, pid: pid, window: window)
        lines.append(dryRun { try ChoiceCardNavigator().locateCodex(window: handle) })
        return lines
    }

    private func descendants(of root: AXUIElement, roles: Set<String>, limit: Int) -> [AXUIElement] {
        var queue = elements(root, kAXChildrenAttribute).map { ($0, 1) }
        var visited = 0
        var result: [AXUIElement] = []
        while !queue.isEmpty, visited < limit {
            let (node, depth) = queue.removeFirst()
            visited += 1
            if roles.contains(role(node)) { result.append(node); continue }
            if depth < 5 { queue += elements(node, kAXChildrenAttribute).map { ($0, depth + 1) } }
        }
        return result
    }

    private func probeLines(pid: pid_t) throws -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        // A background app still reports its last key window; fall back to its main window.
        guard let window = [kAXFocusedWindowAttribute, kAXMainWindowAttribute].lazy
                .compactMap({ self.element(app, $0) }).first(where: { self.role($0) == kAXWindowRole }) else {
            throw NextStepCardProbeError.windowUnavailable
        }
        var lines: [String] = []
        let modal = bool(window, kAXModalAttribute) == true || !elements(window, "AXSheets").isEmpty
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let roots = webRoots(in: window)
        lines.append("窗口：claudeFrontmost=\(frontmost)，webAreas=\(roots.count)，modalOrSheet=\(modal)")
        guard !roots.isEmpty else { throw NextStepCardProbeError.webAreaUnavailable }

        // Composer: same discovery hint as the bridge, then focused > single > bottom-most.
        var composers: [(root: AXUIElement, node: AXUIElement)] = []
        var fieldStatuses: [Int32] = []
        for root in roots {
            let (fields, status) = search(root, key: "AXTextFieldSearchKey", limit: 12)
            fieldStatuses.append(status.rawValue)
            for field in fields where ComposerSemantics.score(evidence(field)) > 0 {
                composers.append((root, field))
            }
        }
        let focused = composers.filter { bool($0.node, kAXFocusedAttribute) == true }
        let chosen: (root: AXUIElement, node: AXUIElement)
        let rule: String
        if focused.count == 1 {
            chosen = focused[0]; rule = "focused"
        } else if composers.count == 1 {
            chosen = composers[0]; rule = "single"
        } else if let lowest = composers.max(by: { (frame($0.node)?.maxY ?? -1) < (frame($1.node)?.maxY ?? -1) }) {
            chosen = lowest; rule = "bottomMost"
        } else {
            throw NextStepCardProbeError.composerUnavailable("candidates=0，fieldSearchAX=\(fieldStatuses)")
        }
        guard let composerFrame = frame(chosen.node) else {
            throw NextStepCardProbeError.composerUnavailable("输入框没有几何范围")
        }
        // Only emptiness is reported; the draft itself is never kept or logged.
        let draftEmpty = ((attribute(chosen.node, kAXValueAttribute) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        lines.append("输入框：candidates=\(composers.count)，focusedCandidates=\(focused.count)，chosen=\(rule)，draftEmpty=\(draftEmpty)，frame=\(describe(composerFrame))，fieldSearchAX=\(fieldStatuses)")

        let (after, afterStatus) = search(chosen.root, key: "AXButtonSearchKey", limit: 10,
                                          start: chosen.node, direction: "AXDirectionNext")
        let afterLabels = after.map { normalized(label($0)) }
        lines.append("输入框之后：AX=\(afterStatus.rawValue)，buttons=\(after.count)，stop=\(afterLabels.contains(where: stopLabels.contains))，send=\(afterLabels.contains(where: sendLabels.contains))")

        let (backward, beforeStatus) = search(chosen.root, key: "AXButtonSearchKey", limit: 8,
                                              start: chosen.node, direction: "AXDirectionPrevious")
        var before = backward
        var mode = "backward(AX=\(beforeStatus.rawValue))"
        if beforeStatus != .success {
            let (all, allStatus) = search(chosen.root, key: "AXButtonSearchKey", limit: 150)
            let above = all.filter { (frame($0)?.maxY ?? .infinity) <= composerFrame.minY + 2 }
            before = Array(above.suffix(8).reversed())
            mode += " → forward(AX=\(allStatus.rawValue)，total=\(all.count)，above=\(above.count))"
        }
        lines.append("输入框之前：search=\(mode)，buttons=\(before.count)（按返回顺序）")

        var parents: [AXUIElement] = []
        for (index, button) in before.enumerated() {
            var parentTag = "p?"
            if let parent = element(button, kAXParentAttribute) {
                if let known = parents.firstIndex(where: { CFEqual($0, parent) }) {
                    parentTag = "p\(known)"
                } else {
                    parents.append(parent)
                    parentTag = "p\(parents.count - 1)"
                }
            }
            lines.append("  b\(index) parent=\(parentTag)，" + describeButton(button, composerFrame: composerFrame, window: window))
        }

        guard let nearest = nearestAbove(before, composerFrame: composerFrame) else {
            lines.append("结论：输入框上方没有可见按钮")
            return lines
        }
        // Icon toolbars sit nearest the composer; a card's text buttons are wider.
        let wide = before.indices.filter { (frame(before[$0])?.width ?? 0) >= 60 }
        let nearestWide = wide.min { (frame(before[$0])?.maxY ?? 0) > (frame(before[$1])?.maxY ?? 0) }
        var anchors = [nearest]
        if let nearestWide, nearestWide != nearest { anchors.append(nearestWide) }
        var candidateLevel: String?
        for anchor in anchors {
            lines.append("按钮 b\(anchor) 的祖先链（遇到包含输入框的祖先即停）：")
            var current = element(before[anchor], kAXParentAttribute)
            for level in 1...8 {
                guard let node = current, !CFEqual(node, chosen.root) else { break }
                let containsComposer = belongs(chosen.node, to: node)
                let inside = before.indices.filter { belongs(before[$0], to: node) }
                let visual = inside.sorted { visualOrder(before[$0], before[$1]) }
                let classification = NextStepCardSemantics.classify(visual.map { traits(before[$0]) })
                let content = contentSummary(node, excluding: inside.map { before[$0] })
                let nodeFrame = frame(node).map(describe) ?? "nil"
                lines.append("  L\(level) role=\(roleTag(node))，kids=\(elements(node, kAXChildrenAttribute).count)，foundButtons=[\(visual.map { "b\($0)" }.joined(separator: ","))]，class=\(classification.diagnosticName)，\(content)，containsComposer=\(containsComposer)，frame=\(nodeFrame)\(domHooks(node))")
                if candidateLevel == nil, !containsComposer {
                    switch classification {
                    case .nextStep, .sessionOffer: candidateLevel = "b\(anchor) L\(level) \(classification.diagnosticName)"
                    default: break
                    }
                }
                if containsComposer { break }
                current = element(node, kAXParentAttribute)
            }
        }
        lines.append("结论：候选卡片=\(candidateLevel ?? "无")")
        let handle = ForegroundWindowHandle(bundleID: claudeBundleID, pid: pid, window: window)
        lines.append(dryRun { try ChoiceCardNavigator().locateClaude(composer: chosen.node, window: handle) })
        return lines
    }

    /// Runs the production locator read-only and reports what Y would press, never pressing.
    private func dryRun(_ locate: () throws -> ChoiceCard?) -> String {
        do {
            guard let card = try locate() else { return "Y 预演：没有可回答的选项卡" }
            let primary = card.defaultIndex.map { "第 \($0 + 1) 项" } ?? "无（需在 Agent 里先选好）"
            return "Y 预演：kind=\(card.kind)，options=\(card.options.count)，默认=\(primary)，advance=\(card.advance != nil)"
        } catch {
            return "Y 预演：拒绝（\(error.localizedDescription)）"
        }
    }

    // MARK: - Description (no label text)

    private func describeButton(_ button: AXUIElement, composerFrame: CGRect, window: AXUIElement) -> String {
        let sources = nameSources(button)
        let buttonTraits = traits(button)
        let hintIn = Set(sources.filter { $0.value.contains("⌘") }.map(\.key)).sorted()
        let helpHint = string(button, kAXHelpAttribute).contains("⌘")
        let childRoles = Dictionary(grouping: elements(button, kAXChildrenAttribute).map(roleTag), by: { $0 })
            .map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: "+")
        var geometry = "frame=nil"
        if let rect = frame(button) {
            let overlap = rect.maxX > composerFrame.minX && rect.minX < composerFrame.maxX
            geometry = "size=\(number(rect.width))x\(number(rect.height))，aboveComposerBy=\(number(composerFrame.minY - rect.maxY))，xOverlap=\(overlap)"
        }
        let enabled = bool(button, kAXEnabledAttribute).map(String.init) ?? "nil"
        let hidden = bool(button, "AXHidden").map(String.init) ?? "nil"
        // aria-keyshortcuts is author-defined (e.g. "Meta+Enter"), never user text.
        let shortcuts = string(button, "AXKeyShortcutsValue")
        let shortcutTag = shortcuts.isEmpty ? "none"
            : (shortcuts.count <= 32 && shortcuts.unicodeScalars.allSatisfy { $0.isASCII || "⌘↩⏎⇧⌥⌃".unicodeScalars.contains($0) }
               ? shortcuts : "present")
        return "role=\(roleTag(button))，enabled=\(enabled)，hidden=\(hidden)，press=\(actions(button).contains(kAXPressAction))，"
            + "nameLen=\(label(button).count)，keyShortcuts=\(shortcutTag)，"
            + "hint=\(buttonTraits.hasShortcutHint)[⌘ in \(hintIn.isEmpty ? "none" : hintIn.joined(separator: "/"))]，helpHint=\(helpHint)，"
            + "offer=\(buttonTraits.isSessionOffer)，blocked=\(buttonTraits.isBlocked)，"
            + "nameSources=\(Set(sources.map(\.key)).sorted().joined(separator: "/"))，children=\(childRoles.isEmpty ? "0" : childRoles)，"
            + "hit=\(hitRelation(button, window: window))，\(geometry)\(domHooks(button))"
    }

    /// Accessible name sources of a button, kept in memory for comparison only.
    private func nameSources(_ node: AXUIElement) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        for (key, name) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute), ("label", "AXLabel")] {
            let value = string(node, name)
            if !value.isEmpty { result.append((key, value)) }
        }
        var queue = elements(node, kAXChildrenAttribute).map { ($0, 1) }
        var visited = 0
        while !queue.isEmpty, visited < 12 {
            let (child, depth) = queue.removeFirst()
            visited += 1
            for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let value = attribute(child, name) as? String, !value.isEmpty { result.append(("child", value)) }
            }
            if depth < 3 { queue += elements(child, kAXChildrenAttribute).map { ($0, depth + 1) } }
        }
        return result
    }

    private func traits(_ button: AXUIElement) -> NextStepCardSemantics.ButtonTraits {
        NextStepCardSemantics.traits(names: nameSources(button).map(\.value),
                                     keyShortcuts: string(button, "AXKeyShortcutsValue"))
    }

    /// Bounded scan of a candidate container: text outside its buttons is counted, never read out.
    private func contentSummary(_ node: AXUIElement, excluding buttons: [AXUIElement]) -> String {
        var queue = elements(node, kAXChildrenAttribute).map { ($0, 1) }
        var scanned = 0
        var texts = 0
        var hintRoles: Set<String> = []
        var allButtons = 0
        var inputs = 0
        while !queue.isEmpty, scanned < 80 {
            let (child, depth) = queue.removeFirst()
            scanned += 1
            if buttons.contains(where: { CFEqual($0, child) }) { allButtons += 1; continue }
            let childRole = role(child)
            switch childRole {
            case kAXButtonRole, kAXPopUpButtonRole, kAXCheckBoxRole: allButtons += 1; continue
            case kAXTextAreaRole, kAXTextFieldRole: inputs += 1; continue
            case kAXStaticTextRole: texts += 1
            default: break
            }
            // Only whether a shortcut glyph exists and on which role; never the text.
            let names = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
                .compactMap { attribute(child, $0) as? String }
            if names.contains(where: { $0.contains("⌘") || $0.contains("↩") || $0.contains("⏎") }) {
                hintRoles.insert(childRole)
            }
            if depth < 6 { queue += elements(child, kAXChildrenAttribute).map { ($0, depth + 1) } }
        }
        let truncated = !queue.isEmpty ? "+" : ""
        let hint = hintRoles.isEmpty ? "none" : hintRoles.sorted().joined(separator: "/")
        return "scanned=\(scanned)\(truncated)，staticTexts=\(texts)，allButtons=\(allButtons)，inputs=\(inputs)，hintOutsideButtons=\(hint)"
    }

    private func nearestAbove(_ buttons: [AXUIElement], composerFrame: CGRect) -> Int? {
        buttons.indices
            .compactMap { index -> (Int, CGFloat)? in
                guard let rect = frame(buttons[index]), rect.maxY <= composerFrame.minY + 2 else { return nil }
                return (index, composerFrame.minY - rect.maxY)
            }
            .min { $0.1 < $1.1 }?.0
    }

    private func visualOrder(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        guard let left = frame(lhs), let right = frame(rhs) else { return false }
        if abs(left.midY - right.midY) > 4 { return left.midY < right.midY }
        return left.minX < right.minX
    }

    private func hitRelation(_ node: AXUIElement, window: AXUIElement) -> String {
        guard let rect = frame(node), rect.width > 2, rect.height > 2,
              rect.midX.isFinite, rect.midY.isFinite else { return "noFrame" }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(system, Float(rect.midX), Float(rect.midY), &hit)
        guard status == .success, let hit else { return "AX\(status.rawValue)" }
        if CFEqual(hit, node) { return "exact" }
        if belongs(hit, to: node) { return "descendant" }
        if belongs(node, to: hit) { return "ancestor" }
        return belongs(hit, to: window) ? "otherInWindow" : "outsideWindow"
    }

    /// Role of the element hit at the node's center and whether it lies inside `container`.
    private func hitDetail(_ node: AXUIElement, container: AXUIElement) -> String {
        guard let rect = frame(node), rect.midX.isFinite, rect.midY.isFinite else { return "noFrame" }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(rect.midX), Float(rect.midY), &hit) == .success,
              let hit else { return "noHit" }
        return "hitRole=\(roleTag(hit)),inGroup=\(belongs(hit, to: container))"
    }

    /// App-defined hooks only: ASCII identifier-like tokens, nothing user-authored.
    private func domHooks(_ node: AXUIElement) -> String {
        var parts: [String] = []
        if let id = token(string(node, kAXIdentifierAttribute)) { parts.append("axId=\(id)") }
        if let id = token(string(node, "AXDOMIdentifier")) { parts.append("domId=\(id)") }
        let rawClasses = (attribute(node, "AXDOMClassList") as? [String]) ?? []
        let classes = rawClasses.compactMap(token).prefix(24)
        if !classes.isEmpty { parts.append("domClass(\(classes.count)/\(rawClasses.count))=\(classes.joined(separator: "."))") }
        return parts.isEmpty ? "" : "，" + parts.joined(separator: "，")
    }

    private func token(_ raw: String) -> String? {
        guard (1...40).contains(raw.count),
              raw.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        else { return nil }
        return raw
    }

    private func roleTag(_ node: AXUIElement) -> String {
        let subrole = string(node, kAXSubroleAttribute)
        return subrole.isEmpty ? role(node) : "\(role(node))/\(subrole)"
    }

    private func describe(_ rect: CGRect) -> String {
        "\(number(rect.minX)),\(number(rect.minY)) \(number(rect.width))x\(number(rect.height))"
    }

    private func number(_ value: CGFloat) -> String {
        value.isFinite ? String(Int(value.rounded())) : "nan"
    }

    private func normalized(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AX reads

    /// Visible-only renderer search; returns the AX status so unsupported keys show up.
    private func search(_ root: AXUIElement, key: String, limit: Int, start: AXUIElement? = nil,
                        direction: String = "AXDirectionNext") -> ([AXUIElement], AXError) {
        var parameters: [String: Any] = [
            "AXSearchKey": [key],
            "AXResultsLimit": limit,
            "AXDirection": direction,
            "AXVisibleOnly": true
        ]
        if let start { parameters["AXStartElement"] = start }
        var raw: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            root, "AXUIElementsForSearchPredicate" as CFString, parameters as CFDictionary, &raw)
        guard status == .success else { return ([], status) }
        return ((raw as? [AXUIElement]) ?? [], status)
    }

    /// Native window shell only, stopping at each renderer root.
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

    private func evidence(_ node: AXUIElement) -> ComposerEvidence {
        ComposerEvidence(
            role: role(node), identifier: string(node, kAXIdentifierAttribute),
            title: string(node, kAXTitleAttribute), description: string(node, kAXDescriptionAttribute),
            label: string(node, "AXLabel"), placeholder: string(node, kAXPlaceholderValueAttribute),
            isEnabled: bool(node, kAXEnabledAttribute), isHidden: bool(node, "AXHidden")
        )
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
}
