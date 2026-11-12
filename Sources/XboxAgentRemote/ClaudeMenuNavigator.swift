import AppKit
import ApplicationServices

enum ClaudeMenuNavigationError: LocalizedError {
    case permissionRequired
    case claudeNotFrontmost
    case targetChanged
    case windowUnavailable
    case modalPresent
    case menuUnavailable
    case codeRequired
    case ambiguous
    case disabled
    case scanLimit
    case operation(String, AXError)

    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "请先为 JoyCode 开启辅助功能权限。"
        case .claudeNotFrontmost: return "请先将 Claude 切到前台。"
        case .targetChanged: return "Claude 前台进程或窗口已变化，已停止切换。"
        case .windowUnavailable: return "Claude 尚未提供聚焦窗口，请等待界面就绪。"
        case .modalPresent: return "Claude 当前有弹窗或审批，请先处理后再切换会话。"
        case .menuUnavailable: return "未找到 Claude 的原生“转到”菜单。"
        case .codeRequired: return "请切到 Claude Code，再用方向键切换会话。"
        case .ambiguous: return "Claude 会话菜单不唯一，已停止操作。"
        case .disabled: return "Claude 的会话切换菜单当前不可用。"
        case .scanLimit: return "Claude 原生菜单超过可识别范围，已停止操作。"
        case .operation(let action, let error):
            return "\(action)失败（AX \(error.rawValue)）；操作结果可能未知，请检查界面。"
        }
    }
}

/// Uses Claude's native Go menu without reading session data or entering renderer children.
@MainActor
final class ClaudeMenuNavigator {
    private let bundleID = "com.anthropic.claudefordesktop"
    private let previousTitles: Set<String> = ["Previous Session", "上一个会话", "上一個工作階段"]
    private let nextTitles: Set<String> = ["Next Session", "下一个会话", "下一個工作階段"]
    private let menuRoles: Set<String> = [kAXMenuBarRole, kAXMenuBarItemRole, kAXMenuRole, kAXMenuItemRole]

    /// A negative offset selects the previous session; a positive offset selects the next.
    func stepSession(_ offset: Int, expectedWindow: ForegroundWindowHandle? = nil) throws {
        guard offset != 0 else { return }
        let (app, originalWindow) = try verifiedApplication(expectedWindow: expectedWindow)
        guard let menuBar = element(app, kAXMenuBarAttribute), role(menuBar) == kAXMenuBarRole else {
            throw ClaudeMenuNavigationError.menuUnavailable
        }
        var remaining = 127 // The native menu bar itself is the first of at most 128 nodes.
        let menuItems = try children(menuBar, remaining: &remaining)
        let goItems = menuItems.filter {
            role($0) == kAXMenuBarItemRole && ["Go", "转到", "前往"].contains(title($0))
        }
        guard goItems.count <= 1 else { throw ClaudeMenuNavigationError.ambiguous }
        guard let go = goItems.first else { throw ClaudeMenuNavigationError.menuUnavailable }

        var nodes = try menuNodes(in: go, remaining: &remaining)
        var openedMenu = false
        if !nodes.contains(where: { role($0) == kAXMenuItemRole }) {
            _ = try verifiedApplication(expectedWindow: originalWindow)
            try check(AXUIElementPerformAction(go, kAXPressAction as CFString), "展开 Claude 转到菜单")
            openedMenu = true
            do {
                nodes = try menuNodes(in: go, remaining: &remaining)
            } catch {
                cancelOpenedMenu(go, nodes: nodes, expectedWindow: originalWindow)
                throw error
            }
        }

        let target: AXUIElement
        do {
            let titles = offset < 0 ? previousTitles : nextTitles
            let matches = nodes.filter { role($0) == kAXMenuItemRole && titles.contains(title($0)) }
            guard matches.count <= 1 else { throw ClaudeMenuNavigationError.ambiguous }
            guard let match = matches.first else { throw ClaudeMenuNavigationError.codeRequired }
            guard bool(match, kAXEnabledAttribute) == true else { throw ClaudeMenuNavigationError.disabled }
            var commandPID: pid_t = 0
            guard AXUIElementGetPid(match, &commandPID) == .success, commandPID == originalWindow.pid else {
                throw ClaudeMenuNavigationError.targetChanged
            }
            _ = try verifiedApplication(expectedWindow: originalWindow)
            target = match
        } catch {
            if openedMenu { cancelOpenedMenu(go, nodes: nodes, expectedWindow: originalWindow) }
            throw error
        }

        // A timeout may still mean that Claude switched sessions. Never retry this action.
        try check(AXUIElementPerformAction(target, kAXPressAction as CFString), "切换 Claude Code 会话")
    }

    private func verifiedApplication(expectedWindow: ForegroundWindowHandle? = nil) throws
        -> (AXUIElement, ForegroundWindowHandle) {
        guard AXIsProcessTrusted() else { throw ClaudeMenuNavigationError.permissionRequired }
        guard let running = NSWorkspace.shared.frontmostApplication, running.bundleIdentifier == bundleID else {
            throw ClaudeMenuNavigationError.claudeNotFrontmost
        }
        if let expectedWindow,
           expectedWindow.bundleID != bundleID || expectedWindow.pid != running.processIdentifier {
            throw ClaudeMenuNavigationError.targetChanged
        }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let window = element(app, kAXFocusedWindowAttribute) else {
            throw ClaudeMenuNavigationError.windowUnavailable
        }
        if let expectedWindow, !CFEqual(window, expectedWindow.window) {
            throw ClaudeMenuNavigationError.targetChanged
        }
        guard bool(window, kAXModalAttribute) != true,
              ((attribute(window, "AXSheets") as? [AXUIElement]) ?? []).isEmpty else {
            throw ClaudeMenuNavigationError.modalPresent
        }
        var current = element(app, kAXFocusedUIElementAttribute)
        var seen: [AXUIElement] = []
        for _ in 0..<96 {
            guard let node = current, !seen.contains(where: { CFEqual($0, node) }) else { break }
            seen.append(node)
            if role(node) == kAXSheetRole || [kAXDialogSubrole, "AXSystemDialog"].contains(string(node, kAXSubroleAttribute))
                || role(node) == "AXDialog" || bool(node, kAXModalAttribute) == true {
                throw ClaudeMenuNavigationError.modalPresent
            }
            if CFEqual(node, window) { break }
            current = element(node, kAXParentAttribute)
        }
        // Modal/ancestor AX reads can block. Preserve the same foreground window at return.
        guard sameForegroundWindow(window, pid: running.processIdentifier) else {
            throw ClaudeMenuNavigationError.targetChanged
        }
        return (app, ForegroundWindowHandle(bundleID: bundleID, pid: running.processIdentifier, window: window))
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
            // Only native menu roles have their children read. AXWebArea is never traversed.
            queue.append(contentsOf: try children(node, remaining: &remaining))
        }
        return nodes
    }

    private func children(_ node: AXUIElement, remaining: inout Int) throws -> [AXUIElement] {
        var count: CFIndex = 0
        let result = AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count)
        if result == .attributeUnsupported || result == .noValue { return [] }
        try check(result, "读取 Claude 原生菜单")
        guard count <= remaining else { throw ClaudeMenuNavigationError.scanLimit }
        guard count > 0 else { return [] }
        remaining -= count
        var values: CFArray?
        try check(AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, count, &values),
                  "读取 Claude 原生菜单")
        return (values as? [AXUIElement]) ?? []
    }

    private func cancelOpenedMenu(_ go: AXUIElement, nodes: [AXUIElement], expectedWindow: ForegroundWindowHandle) {
        guard sameForegroundWindow(expectedWindow.window, pid: expectedWindow.pid) else { return }
        for node in nodes.filter({ role($0) == kAXMenuRole }) + [go] {
            var names: CFArray?
            if AXUIElementCopyActionNames(node, &names) == .success,
               (names as? [String])?.contains(kAXCancelAction) == true {
                guard sameForegroundWindow(expectedWindow.window, pid: expectedWindow.pid) else { return }
                _ = AXUIElementPerformAction(node, kAXCancelAction as CFString)
                return
            }
        }
    }

    private func sameForegroundWindow(_ window: AXUIElement, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == bundleID, front.processIdentifier == pid,
              let focused = element(app, kAXFocusedWindowAttribute),
              CFEqual(focused, window),
              let latest = NSWorkspace.shared.frontmostApplication else { return false }
        return latest.bundleIdentifier == bundleID && latest.processIdentifier == pid
    }

    private func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
    }

    private func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func string(_ node: AXUIElement, _ name: String) -> String {
        (attribute(node, name) as? String) ?? ""
    }

    private func bool(_ node: AXUIElement, _ name: String) -> Bool? {
        (attribute(node, name) as? NSNumber)?.boolValue
    }

    private func role(_ node: AXUIElement) -> String { string(node, kAXRoleAttribute) }
    private func title(_ node: AXUIElement) -> String {
        string(node, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func check(_ result: AXError, _ action: String) throws {
        if result != .success { throw ClaudeMenuNavigationError.operation(action, result) }
    }
}
