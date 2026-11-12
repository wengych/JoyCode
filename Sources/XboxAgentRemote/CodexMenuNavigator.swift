import AppKit
import ApplicationServices

enum CodexMenuNavigationError: LocalizedError {
    case permissionRequired
    case targetChanged
    case windowUnavailable
    case modalPresent
    case menuUnavailable
    case commandUnavailable
    case ambiguous
    case disabled
    case scanLimit
    case invalidStructure
    case operation(String, AXError)

    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "请先为 JoyCode 开启辅助功能权限。"
        case .targetChanged: return "ChatGPT / Codex 前台进程或窗口已变化，已停止切换。"
        case .windowUnavailable: return "ChatGPT / Codex 尚未提供聚焦窗口，请等待界面就绪。"
        case .modalPresent: return "ChatGPT / Codex 当前有弹窗或审批，请先处理后再切换会话。"
        case .menuUnavailable: return "未找到 ChatGPT / Codex 的原生“视图”菜单。"
        case .commandUnavailable: return "未找到 ChatGPT / Codex 的上一个／下一个侧边栏项目菜单。"
        case .ambiguous: return "ChatGPT / Codex 会话导航菜单不唯一，已停止操作。"
        case .disabled: return "ChatGPT / Codex 的会话导航菜单当前不可用。"
        case .scanLimit: return "ChatGPT / Codex 原生菜单超过可识别范围，已停止操作。"
        case .invalidStructure: return "ChatGPT / Codex 未返回完整有效的原生菜单结构。"
        case .operation(let action, let error):
            return "\(action)失败（AX \(error.rawValue)）；操作结果可能未知，请检查界面。"
        }
    }
}

/// Uses native View > Previous/Next Sidebar Item, not Previous/Next Tab.
/// Static evidence from installed app.asar (2026-11-12):
/// .vite/build/early-bootstrap-339-cb7e73ca5a71df7c.js defines previousThread/nextThread;
/// early-bootstrap-815-e030c49be4b9c405.js places them in View and dispatches once.
/// webview/assets/async/499225.6d2e47bea2.js cycles visible data-sidebar-cycle-item
/// rows, stops at boundaries, and leaves ordering/selection to the application.
/// This adapter never enters renderer children or reads conversation contents.
@MainActor
final class CodexMenuNavigator {
    private struct Target {
        let pid: pid_t
        let application: AXUIElement
        let window: AXUIElement
    }

    private let bundleID = "com.openai.codex"
    private let viewTitles: Set<String> = ["View", "视图", "檢視", "查看"]
    private let previousTitles: Set<String> = [
        "Previous Sidebar Item", "上一个侧边栏项目", "上一個側邊欄項目"
    ]
    private let nextTitles: Set<String> = [
        "Next Sidebar Item", "下一个侧边栏项目", "下一個側邊欄項目"
    ]
    private let menuRoles: Set<String> = [kAXMenuBarRole, kAXMenuBarItemRole, kAXMenuRole, kAXMenuItemRole]

    /// Sends one semantic navigation request. Success does not prove that the chat changed:
    /// the app can be at a sidebar boundary or have no eligible adjacent item.
    func stepSession(_ offset: Int, expectedWindow: ForegroundWindowHandle? = nil) throws {
        guard offset != 0 else { return }
        let target = try verifiedTarget()
        if let expectedWindow {
            guard expectedWindow.bundleID == bundleID, expectedWindow.pid == target.pid,
                  CFEqual(expectedWindow.window, target.window) else {
                throw CodexMenuNavigationError.targetChanged
            }
        }
        guard let menuBar = element(target.application, kAXMenuBarAttribute), role(menuBar) == kAXMenuBarRole else {
            throw CodexMenuNavigationError.menuUnavailable
        }
        var remaining = 255 // Shared across initial discovery and any one-time menu expansion.
        let topItems = try children(menuBar, remaining: &remaining)
        let matches = topItems.filter { role($0) == kAXMenuBarItemRole && viewTitles.contains(title($0)) }
        guard matches.count <= 1 else { throw CodexMenuNavigationError.ambiguous }
        guard let viewMenu = matches.first else { throw CodexMenuNavigationError.menuUnavailable }

        var nodes = try menuNodes(in: viewMenu, remaining: &remaining)
        var openedMenu = false
        if !nodes.contains(where: { role($0) == kAXMenuItemRole }) {
            _ = try verifiedTarget(expected: target)
            try verifyForegroundIdentity(target)
            try check(AXUIElementPerformAction(viewMenu, kAXPressAction as CFString), "展开 ChatGPT / Codex 视图菜单")
            openedMenu = true
            do { nodes = try menuNodes(in: viewMenu, remaining: &remaining) }
            catch {
                cancelOpenedMenu(viewMenu, nodes: nodes, target: target)
                throw error
            }
        }

        let command: AXUIElement
        do {
            let titles = offset < 0 ? previousTitles : nextTitles
            let matches = nodes.filter {
                role($0) == kAXMenuItemRole && titles.contains(title($0)) && bool($0, "AXHidden") != true
            }
            guard matches.count <= 1 else { throw CodexMenuNavigationError.ambiguous }
            guard let match = matches.first else { throw CodexMenuNavigationError.commandUnavailable }
            guard bool(match, kAXEnabledAttribute) == true else { throw CodexMenuNavigationError.disabled }
            _ = try verifiedTarget(expected: target)
            var commandPID: pid_t = 0
            guard AXUIElementGetPid(match, &commandPID) == .success, commandPID == target.pid else {
                throw CodexMenuNavigationError.targetChanged
            }
            command = match
        } catch {
            if openedMenu { cancelOpenedMenu(viewMenu, nodes: nodes, target: target) }
            throw error
        }

        // A timeout may still mean the command ran. Never repeat it or fall back to keys.
        try verifyForegroundIdentity(target)
        try check(AXUIElementPerformAction(command, kAXPressAction as CFString), "切换 ChatGPT / Codex 侧边栏会话")
    }

    private func verifiedTarget(expected: Target? = nil) throws -> Target {
        guard AXIsProcessTrusted() else { throw CodexMenuNavigationError.permissionRequired }
        guard let running = NSWorkspace.shared.frontmostApplication, running.bundleIdentifier == bundleID,
              expected == nil || expected?.pid == running.processIdentifier else {
            throw CodexMenuNavigationError.targetChanged
        }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let window = element(app, kAXFocusedWindowAttribute) else {
            throw CodexMenuNavigationError.windowUnavailable
        }
        if let expected, !CFEqual(expected.window, window) { throw CodexMenuNavigationError.targetChanged }
        guard bool(window, kAXModalAttribute) != true else { throw CodexMenuNavigationError.modalPresent }
        var sheets: CFTypeRef?
        let sheetsResult = AXUIElementCopyAttributeValue(window, "AXSheets" as CFString, &sheets)
        if sheetsResult == .success {
            guard let values = sheets as? [AXUIElement] else { throw CodexMenuNavigationError.invalidStructure }
            guard values.isEmpty else { throw CodexMenuNavigationError.modalPresent }
        } else if sheetsResult != .attributeUnsupported && sheetsResult != .noValue {
            try check(sheetsResult, "核验 ChatGPT / Codex 窗口弹窗")
        }

        // Inspect only the focused element's ancestor chain, never its descendants or value.
        var current = element(app, kAXFocusedUIElementAttribute)
        var seen: [AXUIElement] = []
        while let node = current {
            guard seen.count < 96 else { throw CodexMenuNavigationError.scanLimit }
            guard !seen.contains(where: { CFEqual($0, node) }) else { throw CodexMenuNavigationError.invalidStructure }
            seen.append(node)
            if role(node) == kAXSheetRole || [kAXDialogSubrole, "AXSystemDialog"].contains(string(node, kAXSubroleAttribute))
                || role(node) == "AXDialog" || bool(node, kAXModalAttribute) == true {
                throw CodexMenuNavigationError.modalPresent
            }
            if CFEqual(node, window) { break }
            current = element(node, kAXParentAttribute)
        }
        let target = Target(pid: running.processIdentifier, application: app, window: window)
        try verifyForegroundIdentity(target)
        return target
    }

    /// Short final check after potentially blocking AX reads, without reading chat contents.
    private func verifyForegroundIdentity(_ target: Target) throws {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == bundleID, front.processIdentifier == target.pid,
              let focused = element(target.application, kAXFocusedWindowAttribute),
              CFEqual(focused, target.window),
              let latest = NSWorkspace.shared.frontmostApplication,
              latest.bundleIdentifier == bundleID, latest.processIdentifier == target.pid else {
            throw CodexMenuNavigationError.targetChanged
        }
    }

    private func menuNodes(in root: AXUIElement, remaining: inout Int) throws -> [AXUIElement] {
        var nodes: [AXUIElement] = []
        var queue = [root]
        var cursor = 0
        while cursor < queue.count {
            let node = queue[cursor]
            cursor += 1
            guard !nodes.contains(where: { CFEqual($0, node) }), menuRoles.contains(role(node)) else { continue }
            nodes.append(node)
            queue.append(contentsOf: try children(node, remaining: &remaining))
        }
        return nodes
    }

    private func children(_ node: AXUIElement, remaining: inout Int) throws -> [AXUIElement] {
        var count: CFIndex = 0
        let result = AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count)
        if result == .attributeUnsupported || result == .noValue { return [] }
        try check(result, "读取 ChatGPT / Codex 原生菜单")
        guard count >= 0, count <= remaining else { throw CodexMenuNavigationError.scanLimit }
        guard count > 0 else { return [] }
        remaining -= count
        var values: CFArray?
        try check(AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, count, &values),
                  "读取 ChatGPT / Codex 原生菜单")
        guard let values = values as? [AXUIElement], values.count == count else {
            throw CodexMenuNavigationError.invalidStructure
        }
        return values
    }

    private func cancelOpenedMenu(_ menu: AXUIElement, nodes: [AXUIElement], target: Target) {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == bundleID, front.processIdentifier == target.pid else { return }
        for node in nodes.filter({ role($0) == kAXMenuRole }) + [menu] {
            var names: CFArray?
            if AXUIElementCopyActionNames(node, &names) == .success,
               (names as? [String])?.contains(kAXCancelAction) == true {
                guard (try? verifyForegroundIdentity(target)) != nil else { return }
                _ = AXUIElementPerformAction(node, kAXCancelAction as CFString)
                return
            }
        }
    }

    private func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
    }
    private func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private func string(_ node: AXUIElement, _ name: String) -> String { (attribute(node, name) as? String) ?? "" }
    private func bool(_ node: AXUIElement, _ name: String) -> Bool? { (attribute(node, name) as? NSNumber)?.boolValue }
    private func role(_ node: AXUIElement) -> String { string(node, kAXRoleAttribute) }
    private func title(_ node: AXUIElement) -> String {
        string(node, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func check(_ result: AXError, _ action: String) throws {
        if result != .success { throw CodexMenuNavigationError.operation(action, result) }
    }
}
