import AppKit
import ApplicationServices
import RemoteCore

struct AppTarget: Equatable {
    var bundleID: String
    var displayName: String
}

/// Captures only the foreground process and native focused-window identity.
/// No title, transcript, or other user text is retained for routing diagnostics.
struct ForegroundWindowHandle {
    let bundleID: String
    let pid: pid_t
    let window: AXUIElement

    var windowIdentity: String { String(CFHash(window)) }
    var identity: ForegroundTargetIdentity {
        ForegroundTargetIdentity(bundleID: bundleID, pid: pid, windowID: windowIdentity)
    }

    func matches(_ composer: ComposerHandle) -> Bool {
        bundleID == composer.bundleID && pid == composer.pid && CFEqual(window, composer.window)
    }
}

/// An AX object identity, not a guarantee that an application opened a particular chat URL.
struct ComposerHandle {
    let window: AXUIElement
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let windowIdentity: String
    let composerIdentity: String
    fileprivate let windowTitle: String
    fileprivate let document: String
    fileprivate let context: AXUIElement
    fileprivate let contextIdentity: String
}

enum TypelessObservation: String {
    case notRunning, recording, processing, unknown
}

enum NativeDictationObservation: String {
    case idle, recording, processing, unavailable
}

enum AccessibilityBridgeError: LocalizedError {
    case permissionRequired
    case unavailable(String)
    case targetChanged(String)
    case ambiguous(String)
    case modalPresent
    case operation(String, AXError)

    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "请先为 JoyCode 开启辅助功能权限。"
        case .unavailable(let detail): return detail
        case .targetChanged(let detail): return "目标已变化：\(detail)"
        case .ambiguous(let detail): return "无法唯一识别\(detail)，已停止操作。"
        case .modalPresent: return "目标窗口有弹窗或审批，已停止操作。"
        case .operation(let operation, let error):
            return "\(operation)失败（AX \(error.rawValue)）；操作结果可能未知，请检查界面。"
        }
    }
}

/// All writes are conditional on a freshly verified target. This file never requests AX trust.
/// Public AX attributes are used; no private app data, DOM injection, or clipboard is accessed.
@MainActor
final class AccessibilityBridge {
    private let typelessBundleID = "now.typeless.desktop"
    private let supportedApps = ["com.anthropic.claudefordesktop", "com.openai.codex"]
    private let codexBundleID = "com.openai.codex"
    private var ownedVoice: (handle: ComposerHandle, stopRequested: Bool, shortcut: VoiceShortcut)?
    private struct NativeDictationOwnership {
        let handle: ComposerHandle
        let control: AXUIElement
        // ChatGPT replaces the microphone with a separate recording toolbar. Its
        // original composer container, rather than a toolbar button, owns the turn.
        var scope: AXUIElement? = nil
        var stopRequested = false
        var cancelRequested = false
        // aria-hidden/inert recreates Chromium AX descendants after dictation.
        // This is a read-only completion target, never an action/ownership token.
        var settledEditor: AXUIElement? = nil
    }
    private var ownedNativeVoice: NativeDictationOwnership?
    /// Ownership is recorded before the only native start mutation. Absence after
    /// start throws proves no native recording request was emitted by this attempt.
    var hasNativeDictationOwnership: Bool { ownedNativeVoice != nil }
    var nativeCompletionRebuiltEditor: Bool {
        guard let owned = ownedNativeVoice, let editor = owned.settledEditor else { return false }
        return !CFEqual(editor, owned.handle.element)
    }

    /// Failure before dispatch leaves a verified recording available for the next
    /// physical X/B. An end request already emitted can never be retried this way.
    func canRetryNativeEnding(in handle: ComposerHandle) throws -> Bool {
        guard let owned = ownedNativeVoice, isSameComposer(owned.handle, handle),
              !owned.stopRequested, !owned.cancelRequested else { return false }
        return try nativeControlSnapshot(in: handle).observation == .recording
    }
    private var lastScrollAction = Date.distantPast
    private var lastScrollEvent: TimeInterval = 0
    private var scrollMotion = ScrollMotionIntegrator()
    private var scrollMotionTarget: ComposerHandle?
    private var lastTypelessShortcut: TimeInterval = 0
    private var accessibilityPreparation: [pid_t: AXError] = [:]
    private var accessibilityPreparationRequestedAt: [pid_t: TimeInterval] = [:]
    private(set) var lastVoiceControl = ""
    private(set) var lastNativeReadinessDiagnostic = "尚未检查"
    private(set) var lastNativeObservationDiagnostic = "尚未检查"
    private(set) var lastComposerDiagnostic = "尚未检查"
    private(set) var lastExposureDiagnostic = "stage=notChecked"
    private(set) var lastNativeActionDiagnostic = "stage=notRequested"
    private(set) var lastScrollDiagnostic = "尚未检查"
    private(set) var lastActualDelivery = "none"
    private struct ScrollDelivery {
        var calls = 0
        var invalidSkipped = 0
        var neutralSkipped = 0
        var eventRateThrottled = 0
        var actionRateThrottled = 0
        var axActionSucceeded = 0
        var scrollbarActionSucceeded = 0
        var cgPosted = 0
        var zeroPixelPosted = 0
        var failures = 0
        var lastMethod = "none"
        var lastOutcome = "neverCalled"
        var lastNormalized: Double = 0
        var lastPixel: Int32?
        var lastVerification = "notRun"
    }
    private var scrollDelivery = ScrollDelivery()
    /// Memory-only delivery accounting. A successful AX call or CG post does not prove movement.
    /// Reading this property performs no AX requests and exposes no target content or identity.
    var scrollDeliveryDiagnostic: String {
        let state = scrollDelivery
        let pixel = state.lastPixel.map { String($0) } ?? "n/a"
        return "calls=\(state.calls), invalidSkipped=\(state.invalidSkipped), neutralSkipped=\(state.neutralSkipped), eventRateThrottled=\(state.eventRateThrottled), actionRateThrottled=\(state.actionRateThrottled), axActionSucceeded=\(state.axActionSucceeded), scrollbarActionSucceeded=\(state.scrollbarActionSucceeded), cgPosted=\(state.cgPosted), zeroPixelPosted=\(state.zeroPixelPosted), failures=\(state.failures), lastMethod=\(state.lastMethod), lastOutcome=\(state.lastOutcome), normalized=\(state.lastNormalized), pixel=\(pixel), verify=\(state.lastVerification), lastActualDelivery=[\(lastActualDelivery)]"
    }
    private func recordActualScrollDelivery() {
        let pixel = scrollDelivery.lastPixel.map { String($0) } ?? "n/a"
        lastActualDelivery = "method=\(scrollDelivery.lastMethod), normalized=\(scrollDelivery.lastNormalized), pixel=\(pixel), verify=\(scrollDelivery.lastVerification)"
    }
    private struct MessageAreaTarget {
        let area: AXUIElement
        let pane: AXUIElement
        let kind: MessageViewport.Kind
        var discoveryDiagnostic = ""
    }
    private struct ScrollFailure: Error {
        let stage: String
        let reason: String
        var details: String = ""
        var diagnostic: String { "stage=\(stage), reason=\(reason)\(details.isEmpty ? "" : ", " + details)" }
        var error: AccessibilityBridgeError {
            .unavailable("消息滚动区域校验失败（\(diagnostic)）。")
        }
    }
    // Keep discovery separate from the voice handle: a transcript can appear or rerender later.
    // isSameComposer includes PID, window, composer, document and conversation-context identity.
    private var scrollDiscovery: (handle: ComposerHandle, attemptedAt: TimeInterval,
                                  result: Result<MessageAreaTarget, ScrollFailure>)?
    // Remote-control events use an app-owned state table, isolated from physical HID state.
    // Keep this source alive rather than repeatedly creating/releasing shared event sources.
    private let eventSource = CGEventSource(stateID: .privateState)

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Read the native focused window only. Capturing a target never activates an app.
    func captureForegroundWindow(bundleID: String? = nil) throws -> ForegroundWindowHandle {
        try requireTrust()
        guard let running = NSWorkspace.shared.frontmostApplication,
              let currentBundleID = running.bundleIdentifier,
              bundleID == nil || bundleID == currentBundleID else {
            throw AccessibilityBridgeError.targetChanged("指定应用不在前台")
        }
        let app = application(running.processIdentifier)
        guard let window = element(app, kAXFocusedWindowAttribute), role(window) == kAXWindowRole else {
            throw AccessibilityBridgeError.unavailable("前台应用尚未提供可识别的聚焦窗口。")
        }
        let target = ForegroundWindowHandle(bundleID: currentBundleID,
                                            pid: running.processIdentifier, window: window)
        try verifyForegroundWindow(target)
        return target
    }

    /// Check the real foreground again immediately before a focus or other UI mutation.
    func verifyForegroundWindow(_ target: ForegroundWindowHandle) throws {
        try requireTrust()
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == target.bundleID, front.processIdentifier == target.pid else {
            throw AccessibilityBridgeError.targetChanged("前台应用已改变，本次操作已停止")
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(target.window, &pid) == .success, pid == target.pid else {
            throw AccessibilityBridgeError.targetChanged("前台窗口已改变，本次操作已停止")
        }
        let focusedWindow = element(application(target.pid), kAXFocusedWindowAttribute)
        let current = focusedWindow.map {
            ForegroundTargetIdentity(bundleID: front.bundleIdentifier ?? "",
                                     pid: front.processIdentifier, windowID: String(CFHash($0)))
        }
        try ForegroundActionPolicy.validate(expected: target.identity, current: current)
        // The value identity is testable, but a hash never replaces the live AX object check.
        guard same(focusedWindow, target.window) else {
            throw AccessibilityBridgeError.targetChanged("前台窗口已改变，本次操作已停止")
        }
        // AX calls can block while the user switches apps. Do not trust the earlier process read.
        guard let latest = NSWorkspace.shared.frontmostApplication,
              latest.bundleIdentifier == target.bundleID, latest.processIdentifier == target.pid else {
            throw AccessibilityBridgeError.targetChanged("前台应用已改变，本次操作已停止")
        }
    }

    /// Identity conversion only; this does not assert that the composer is still foreground.
    func foregroundWindow(of composer: ComposerHandle) -> ForegroundWindowHandle {
        ForegroundWindowHandle(bundleID: composer.bundleID, pid: composer.pid, window: composer.window)
    }

    @discardableResult
    private func performInForeground<T>(_ handle: ComposerHandle, operation: () throws -> T) throws -> T {
        if handle.bundleID == codexBundleID, let owned = ownedNativeVoice {
            try verifyCodexDictationScope(handle, owned: owned, requireFocused: false)
        }
        return try performInForeground(window: foregroundWindow(of: handle), operation: operation)
    }

    /// The production mutation boundary shares the tested policy and adds live AX identity.
    @discardableResult
    private func performInForeground<T>(window: ForegroundWindowHandle, operation: () throws -> T) throws -> T {
        try ForegroundActionPolicy.withVerifiedTarget(expected: window.identity, current: {
            try self.verifyForegroundWindow(window)
            return window.identity
        }, operation: operation)
    }

    func activate(bundleID: String, url: URL? = nil) async throws {
        guard supportedApps.contains(bundleID),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw AccessibilityBridgeError.unavailable("未找到受支持的应用：\(bundleID)")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let url {
            // Opening a deep link is only a navigation request, never session verification.
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
        } else {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }
    }

    /// Restore only the captured live window. Never launch, navigate, or refocus its composer.
    func restoreOriginalWindow(_ handle: ComposerHandle) async throws {
        let running = try verifyRestorableWindow(handle)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == handle.pid,
           same(element(application(handle.pid), kAXFocusedWindowAttribute), handle.window) {
            return
        }
        guard actions(handle.window).contains(kAXRaiseAction),
              bool(handle.window, kAXMinimizedAttribute) != true else {
            throw AccessibilityBridgeError.unavailable("原会话窗口无法直接恢复，请手动返回该窗口。")
        }
        // Raise the original window before activation so another window is not selected by default.
        try check(AXUIElementPerformAction(handle.window, kAXRaiseAction as CFString), "恢复原会话窗口")
        _ = try verifyRestorableWindow(handle)
        let app = application(handle.pid)
        let activationWindow = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
        guard same(activationWindow, handle.window) else {
            throw AccessibilityBridgeError.unavailable("尚未确认原窗口可激活，请手动返回原会话。")
        }
        _ = running.activate(options: [])
        // Judge restoration by the actual target, even if the activation request returns false.
        // Activation is asynchronous. All remaining operations are reads of the original target.
        for _ in 0..<10 {
            try Task.checkCancellation()
            _ = try verifyRestorableWindow(handle)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == handle.pid,
               same(element(application(handle.pid), kAXFocusedWindowAttribute), handle.window) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AccessibilityBridgeError.unavailable("尚未确认原会话窗口已回到前台，请检查界面。")
    }

    private func verifyRestorableWindow(_ handle: ComposerHandle) throws -> NSRunningApplication {
        try requireTrust()
        guard supportedApps.contains(handle.bundleID),
              let running = NSRunningApplication(processIdentifier: handle.pid),
              !running.isTerminated, running.bundleIdentifier == handle.bundleID else {
            throw AccessibilityBridgeError.targetChanged("原应用已退出或进程不再匹配")
        }
        let app = application(handle.pid)
        guard role(handle.window) == kAXWindowRole,
              elements(app, kAXWindowsAttribute).contains(where: { CFEqual($0, handle.window) }) else {
            throw AccessibilityBridgeError.targetChanged("原会话窗口已关闭或不再属于原应用")
        }
        for node in [handle.window, handle.element, handle.context] {
            var pid: pid_t = 0
            guard AXUIElementGetPid(node, &pid) == .success, pid == handle.pid else {
                throw AccessibilityBridgeError.targetChanged("原窗口或会话的进程身份变化")
            }
        }
        guard belongs(handle.element, to: handle.window),
              composerScore(handle.element, bundleID: handle.bundleID) > 0 || isOwnedNativePrompt(handle.element, handle: handle),
              belongs(handle.context, to: handle.window),
              CFEqual(conversationContext(of: handle.element, window: handle.window), handle.context),
              string(handle.window, kAXTitleAttribute) == handle.windowTitle,
              documentIdentity(handle.window) == handle.document,
              contextIdentity(handle.context) == handle.contextIdentity else {
            throw AccessibilityBridgeError.targetChanged("原窗口内容或会话标识变化")
        }
        try rejectFocusedModal(app: app, window: handle.window)
        try rejectModalAncestors(of: handle.element, window: handle.window)
        return running
    }

    func focusComposer(bundleID: String, expectedWindow: ForegroundWindowHandle? = nil) throws -> ComposerHandle {
        let expected = try expectedWindow ?? captureForegroundWindow(bundleID: bundleID)
        guard expected.bundleID == bundleID else {
            throw AccessibilityBridgeError.targetChanged("输入框所属应用与本次前台目标不符")
        }
        try verifyForegroundWindow(expected)
        let handle = try locateComposer(bundleID: bundleID)
        guard expected.matches(handle) else {
            throw AccessibilityBridgeError.targetChanged("定位期间前台窗口变化，不会聚焦另一窗口")
        }
        try verifyForegroundWindow(expected)
        let app = application(handle.pid)
        if !same(element(app, kAXFocusedUIElementAttribute), handle.element) {
            guard isSettable(handle.element, kAXFocusedAttribute) else {
                throw AccessibilityBridgeError.unavailable("输入框不支持 AX 聚焦。")
            }
            try verify(handle, requireFocused: false)
            // Validate after the settable/identity AX queries, immediately before the write.
            try verifyForegroundWindow(expected)
            try performInForeground(window: expected) {
                try check(AXUIElementSetAttributeValue(handle.element, kAXFocusedAttribute as CFString, kCFBooleanTrue), "聚焦输入框")
            }
        }
        try verifyForegroundWindow(expected)
        try verify(handle)
        return handle
    }

    /// Discovers the composer without moving keyboard focus or rewriting an existing AX mode.
    func locateComposer(bundleID: String) throws -> ComposerHandle {
        try requireTrust()
        guard supportedApps.contains(bundleID) else {
            throw AccessibilityBridgeError.unavailable("此应用尚无输入框适配器。")
        }
        let expectedWindow = try captureForegroundWindow(bundleID: bundleID)
        let app = application(expectedWindow.pid)
        let window = expectedWindow.window
        try rejectFocusedModal(app: app, window: window)
        // Ask the renderer for text controls. Never materialize the conversation transcript.
        var webAreas = try existingWebRoots(in: window, pid: expectedWindow.pid)
        if webAreas.isEmpty {
            // Only a complete, successful shell scan can authorize initial enablement.
            // AX failures and an already readable renderer must never trigger this write.
            try requireTrust()
            try verifyForegroundWindow(expectedWindow)
            try rejectFocusedModal(app: app, window: window)
            try verifyForegroundWindow(expectedWindow)
            try prepareElectronAccessibility(app, pid: expectedWindow.pid, expectedWindow: expectedWindow)
            webAreas = try existingWebRoots(in: window, pid: expectedWindow.pid)
        }
        guard !webAreas.isEmpty else {
            throw AccessibilityBridgeError.unavailable("聊天页面尚未就绪。")
        }
        let nodes = try webAreas.flatMap { try searchControls(in: $0, key: "AXTextFieldSearchKey", limit: 33, allowUnsupported: true) }
        let composer: AXUIElement
        if bundleID == codexBundleID {
            composer = try selectCodexComposer(nodes, app: app, window: window)
        } else {
            let focused = element(app, kAXFocusedUIElementAttribute)
            var seen: [AXUIElement] = []
            let candidates = nodes.enumerated().compactMap { index, node -> ClaudeComposerSelection.Candidate? in
                guard !seen.contains(where: { CFEqual($0, node) }), composerScore(node) > 0,
                      belongs(node, to: window), isExposed(node, in: window) else { return nil }
                seen.append(node)
                let ancestors = ancestors(of: node, until: window)
                return .init(id: index, score: composerScore(node), isFocused: same(focused, node),
                             isSideChat: ancestors.contains { label($0) == "side chat" },
                             isInPrimaryPane: ancestors.contains { label($0) == "primary pane" })
            }
            let selection: ClaudeComposerSelection.Candidate?
            do { selection = try ClaudeComposerSelection.select(candidates) }
            catch { throw AccessibilityBridgeError.ambiguous("当前窗口的主聊天输入框") }
            guard let selection else {
                throw AccessibilityBridgeError.unavailable("未找到当前窗口可见的主聊天输入框（已检索 \(nodes.count) 个文本控件）；请打开聊天页面。")
            }
            composer = nodes[selection.id]
        }
        let context = conversationContext(of: composer, window: window)
        let handle = ComposerHandle(
            window: window, element: composer, pid: expectedWindow.pid, bundleID: bundleID,
            windowIdentity: String(CFHash(window)), composerIdentity: String(CFHash(composer)),
            windowTitle: string(window, kAXTitleAttribute), document: documentIdentity(window),
            context: context, contextIdentity: contextIdentity(context)
        )
        try verify(handle, requireFocused: false)
        try verifyForegroundWindow(expectedWindow)
        return handle
    }

    /// A Codex window also exposes read-only transcript text, inline question fields
    /// and editor/preview controls. None are accepted by vague "reply/message" hints.
    /// Logs contain only fixed label categories and booleans, never accessible names.
    private func selectCodexComposer(_ nodes: [AXUIElement], app: AXUIElement,
                                     window: AXUIElement) throws -> AXUIElement {
        let focused = element(app, kAXFocusedUIElementAttribute)
        var seen: [AXUIElement] = []
        var candidates: [CodexComposerSelection.Candidate] = []
        var diagnostics: [String] = []
        var knownCount = 0
        var editableCount = 0
        var visibleCount = 0
        for (index, node) in nodes.enumerated() {
            guard !seen.contains(where: { CFEqual($0, node) }), belongs(node, to: window) else { continue }
            seen.append(node)
            let evidence = composerEvidence(node)
            let known = CodexComposerSelection.recognizedLabel(evidence)
            let editable = isSettable(node, kAXValueAttribute)
            let visible = isExposed(node, in: window)
            if known != nil { knownCount += 1 }
            if editable { editableCount += 1 }
            if visible { visibleCount += 1 }
            let eligible = CodexComposerSelection.isEligible(evidence, isEditable: editable) && visible
            let path = eligible ? ancestors(of: node, until: window) : []
            let inMain = path.contains { string($0, kAXSubroleAttribute) == "AXLandmarkMain" }
            let secondary = path.contains { string($0, kAXSubroleAttribute) == "AXLandmarkComplementary" }
            let isFocused = focused.map { CFEqual($0, node) || belongs($0, to: node) } ?? false
            diagnostics.append("\(index):label=\(known?.rawValue ?? "other"),edit=\(editable),visible=\(visible),focus=\(isFocused),main=\(inMain),side=\(secondary)")
            if eligible {
                candidates.append(.init(id: index, recognized: true, isEditable: true,
                    isFocused: isFocused, isInMainPane: inMain, isSecondary: secondary))
            }
        }
        lastComposerDiagnostic = "adapter=codex, controls=\(nodes.count), unique=\(seen.count), known=\(knownCount), editable=\(editableCount), visible=\(visibleCount), eligible=\(candidates.count); "
            + diagnostics.prefix(12).joined(separator: "; ")
        let selection: CodexComposerSelection.Candidate?
        do { selection = try CodexComposerSelection.select(candidates) }
        catch {
            throw AccessibilityBridgeError.ambiguous("ChatGPT / Codex 聊天输入框（\(lastComposerDiagnostic)）")
        }
        guard let selection else {
            throw AccessibilityBridgeError.unavailable("未找到可编辑的 ChatGPT / Codex 聊天输入框（\(lastComposerDiagnostic)）")
        }
        lastComposerDiagnostic += "; selected=\(selection.id)"
        return nodes[selection.id]
    }

    func draft(in handle: ComposerHandle) throws -> String {
        try verify(handle, requireFocused: false)
        return try readDraftValue(handle)
    }

    /// Nil is a verified Typeless-owned processing transition, not a changed destination.
    func transcriptionDraft(in handle: ComposerHandle) throws -> String? {
        try requireTrust()
        guard let owned = ownedVoice, owned.stopRequested, isSameComposer(owned.handle, handle),
              let typeless = runningTypeless else {
            throw AccessibilityBridgeError.targetChanged("转写所有权或 Typeless 进程已丢失")
        }
        try verifyVoiceDestination(handle, typeless: typeless, checkExposure: false)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == typeless.processIdentifier { return nil }
        let observation = typelessStatus()
        if observation == .recording || observation == .processing { return nil }
        return try readDraftValue(handle)
    }

    private func readDraftValue(_ handle: ComposerHandle) throws -> String {
        try readDraftValue(from: handle.element)
    }

    private func readDraftValue(from editor: AXUIElement) throws -> String {
        guard let value = attribute(editor, kAXValueAttribute) else {
            throw AccessibilityBridgeError.unavailable("输入框未暴露草稿文本。")
        }
        if let text = value as? String { return text }
        if let text = value as? NSAttributedString { return text.string }
        throw AccessibilityBridgeError.unavailable("输入框草稿格式尚不支持。")
    }

    func verify(_ handle: ComposerHandle, requireFocused: Bool = true) throws {
        try requireTrust()
        let running = try frontApplication(bundleID: handle.bundleID)
        guard running.processIdentifier == handle.pid else {
            throw AccessibilityBridgeError.targetChanged("应用已经重新启动")
        }
        try verifyIdentity(handle, requireFocused: requireFocused)
    }

    func identityKey(of handle: ComposerHandle) -> String {
        "\(handle.bundleID):\(handle.pid):\(handle.windowIdentity):\(handle.composerIdentity)"
    }

    func isSameComposer(_ lhs: ComposerHandle, _ rhs: ComposerHandle) -> Bool {
        lhs.pid == rhs.pid && lhs.bundleID == rhs.bundleID
            && CFEqual(lhs.window, rhs.window) && CFEqual(lhs.element, rhs.element)
            && lhs.document == rhs.document && lhs.windowTitle == rhs.windowTitle
            && CFEqual(lhs.context, rhs.context) && lhs.contextIdentity == rhs.contextIdentity
    }

    func send(_ handle: ComposerHandle, expectedDraft: String, beforePress: () throws -> Void) throws {
        guard ownedVoice == nil, ownedNativeVoice == nil else {
            throw AccessibilityBridgeError.unavailable("语音尚未确认结束，请先确认转写已落地。")
        }
        try verify(handle)
        let nativeState = try nativeControlSnapshot(in: handle)
        guard nativeState.observation != .recording && nativeState.observation != .processing,
              !nativeState.unresolvedControlsPresent else {
            throw AccessibilityBridgeError.unavailable("原生语音仍在录音或处理，不能发送草稿。")
        }
        guard !(try draft(in: handle)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AccessibilityBridgeError.unavailable("草稿为空。")
        }
        // Search nearby composer containers only, never the window itself. Geometry and the
        // absence of another composer also prevent an unrelated Send button being selected.
        var scope = element(handle.element, kAXParentAttribute)
        for _ in 0..<7 {
            guard let container = scope, !CFEqual(container, handle.window), role(container) != "AXWebArea",
                  label(container) != "primary pane" else { break }
            if handle.bundleID == codexBundleID, isCodexConversationRegion(container) { break }
            let composers = try localComposerInputs(in: container, handle: handle)
            guard composers.count == 1, same(composers.first, handle.element) else {
                throw AccessibilityBridgeError.ambiguous("发送按钮所属的输入框")
            }
            let buttons = try searchControls(in: container, key: "AXButtonSearchKey", limit: 65)
                .filter { isSendButton($0, bundleID: handle.bundleID) && isNearComposer($0, composer: handle.element) }
            if buttons.count > 1 { throw AccessibilityBridgeError.ambiguous("发送按钮") }
            if let button = buttons.first {
                guard belongs(button, to: handle.window), bool(button, kAXEnabledAttribute) == true else {
                    throw AccessibilityBridgeError.unavailable("发送按钮不可用。")
                }
                try verify(handle)
                try requireExposed(button, in: handle.window)
                let latestNativeState = try nativeControlSnapshot(in: handle)
                guard latestNativeState.observation != .recording && latestNativeState.observation != .processing,
                      !latestNativeState.unresolvedControlsPresent else {
                    throw AccessibilityBridgeError.unavailable("原生语音状态变化，已取消发送。")
                }
                // A timeout can mean the action happened. Do not retry this non-idempotent action.
                try performInForeground(handle) {
                    try verify(handle)
                    guard isSendButton(button, bundleID: handle.bundleID),
                          bool(button, kAXEnabledAttribute) == true,
                          belongs(button, to: container), belongs(button, to: handle.window),
                          isNearComposer(button, composer: handle.element) else {
                        throw AccessibilityBridgeError.targetChanged("提交按钮的用途或所属输入区域变化，未发送")
                    }
                    try requireExposed(button, in: handle.window)
                    guard try readDraftValue(handle) == expectedDraft else {
                        throw AccessibilityBridgeError.targetChanged("提交前草稿已变化，未发送")
                    }
                    try verifyForegroundWindow(foregroundWindow(of: handle))
                    try beforePress()
                    try check(AXUIElementPerformAction(button, kAXPressAction as CFString), "发送草稿")
                }
                return
            }
            scope = element(container, kAXParentAttribute)
        }
        throw AccessibilityBridgeError.unavailable("未找到明确的 Send/发送按钮；不会回退为 Enter。")
    }

    /// Drop timing and fractional displacement at a gesture/target boundary. Keep the
    /// global AX rate limit intact, including when center/guard callbacks arrive rapidly.
    func resetScrollMotion() {
        scrollMotion.reset()
        scrollMotionTarget = nil
    }

    /// Positive values scroll up toward older messages, matching GameController's Y axis.
    func scroll(_ handle: ComposerHandle, normalized: Double) throws {
        scrollDelivery.calls += 1
        scrollDelivery.lastNormalized = normalized
        scrollDelivery.lastPixel = nil
        scrollDelivery.lastMethod = "none"
        scrollDelivery.lastOutcome = "pending"
        scrollDelivery.lastVerification = "notRun"
        guard normalized.isFinite else {
            resetScrollMotion()
            scrollDelivery.invalidSkipped += 1
            scrollDelivery.lastOutcome = "skippedInvalidInput"
            return
        }
        guard normalized != 0 else {
            resetScrollMotion()
            scrollDelivery.neutralSkipped += 1
            scrollDelivery.lastOutcome = "skippedNeutralInput"
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScrollEvent >= 1.0 / 30.0 else {
            scrollDelivery.eventRateThrottled += 1
            scrollDelivery.lastOutcome = "skippedEventRate"
            return
        }
        lastScrollEvent = now
        var phase = "initialVerification"
        do {
            scrollDelivery.lastVerification = "initialFailed"
            try verifyForScroll(handle, now: now) // Does not move keyboard focus.
            scrollDelivery.lastVerification = "initialPassed"
            phase = "viewport"
            scrollDelivery.lastVerification = "viewportFailed"
            let (target, viewport) = try resolveScrollTarget(handle, now: now)
            scrollDelivery.lastVerification = "viewportPassed"
            let area = target.area
            let amount = max(-1, min(1, normalized))
            phase = "hitTest"
            scrollDelivery.lastVerification = "hitTestFailed"
            let point = try scrollPoint(in: target, viewport: viewport, handle: handle)
            scrollDelivery.lastVerification = "hitTestPassed"
            let names = actions(area)
            let action = amount > 0 ? "AXScrollUp" : "AXScrollDown"
            if names.contains(action) {
                resetScrollMotion()
                phase = "axAction"
                scrollDelivery.lastMethod = action
                if try throttledScrollAction(area, action: action, amount: amount, handle: handle) {
                    scrollDelivery.axActionSucceeded += 1
                    scrollDelivery.lastOutcome = "axActionSucceeded"
                    recordActualScrollDelivery()
                } else {
                    scrollDelivery.actionRateThrottled += 1
                    scrollDelivery.lastOutcome = "skippedActionRate"
                }
            } else if let bar = element(area, kAXVerticalScrollBarAttribute),
                      actions(bar).contains(amount > 0 ? kAXDecrementAction : kAXIncrementAction) {
                resetScrollMotion()
                phase = "scrollbarAction"
                let barAction = amount > 0 ? kAXDecrementAction : kAXIncrementAction
                scrollDelivery.lastMethod = "scrollbar:\(barAction)"
                if try throttledScrollAction(bar, action: barAction, amount: amount, handle: handle) {
                    scrollDelivery.scrollbarActionSucceeded += 1
                    scrollDelivery.lastOutcome = "scrollbarActionSucceeded"
                    recordActualScrollDelivery()
                } else {
                    scrollDelivery.actionRateThrottled += 1
                    scrollDelivery.lastOutcome = "skippedActionRate"
                }
            } else {
                // AX coordinates and CGEvent.location both use top-left-relative display coordinates.
                // A fresh system-wide hit-test excludes overlays and nested code-block scroll views.
                phase = "cgEventCreation"
                scrollDelivery.lastMethod = "CGPostSession"
                if scrollMotionTarget.map({ isSameComposer($0, handle) }) != true {
                    resetScrollMotion()
                    scrollMotionTarget = handle
                }
                let pixel = scrollMotion.sample(normalized: amount, at: now)
                scrollDelivery.lastPixel = pixel
                guard pixel != 0 else {
                    scrollDelivery.lastOutcome = "accumulatingSubpixelMotion"
                    return
                }
                guard let source = eventSource,
                      let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                          wheel1: pixel, wheel2: 0, wheel3: 0) else {
                    throw AccessibilityBridgeError.unavailable("无法创建定向滚动事件。")
                }
                phase = "finalVerification"
                scrollDelivery.lastVerification = "finalFailed"
                try verifyForScroll(handle, now: now)
                scrollDelivery.lastVerification = "finalPassed"
                event.location = point
                // Let the login session associate the scroll event with the window/view
                // at the freshly verified point. This route also relocates the visible
                // pointer on the tested system; it does not change keyboard focus.
                try performInForeground(handle) { event.post(tap: .cgSessionEventTap) }
                scrollDelivery.cgPosted += 1
                if pixel == 0 { scrollDelivery.zeroPixelPosted += 1 }
                scrollDelivery.lastOutcome = pixel == 0 ? "postedZeroPixels" : "posted"
                recordActualScrollDelivery()
            }
        } catch {
            resetScrollMotion()
            scrollDelivery.failures += 1
            scrollDelivery.lastOutcome = "failed:\(phase)"
            throw error
        }
    }

    private enum NativeControlKind: String {
        case start = "Press and hold to record"
        case stop = "Stop dictation"
    }

    private struct NativeControlSnapshot {
        let observation: NativeDictationObservation
        let control: AXUIElement?
        let kind: NativeControlKind?
        let editable: Bool
        let enabled: Bool
        let pressable: Bool
        let supportedActions: [String]
        let scopeCount: Int
        var scope: AXUIElement? = nil
        var cancelControl: AXUIElement? = nil
        // Known recording/recovery controls with conflicting or incomplete state
        // block A. Merely lacking the optional dictation feature does not block A.
        var unresolvedControlsPresent = false
        var completionEditor: AXUIElement? = nil

        var actionDiagnostic: String {
            // Only bounded AX action identifiers, never attribute values or user text.
            let names = supportedActions.prefix(8).map { name -> String in
                guard name.hasPrefix("AX"), name.unicodeScalars.allSatisfy({
                    (48...57).contains($0.value) || (65...90).contains($0.value)
                        || (97...122).contains($0.value) || $0.value == 45 || $0.value == 95
                }) else { return "<nonstandard-action>" }
                return String(name.prefix(64))
            }
            return "actions=[\(names.joined(separator: ","))], actionCount=\(supportedActions.count)"
        }

        var diagnostic: String {
            "state=\(observation.rawValue), controls=\(control == nil ? 0 : 1), label=\(kind?.rawValue ?? "none"), enabled=\(enabled), AXPress=\(pressable), \(actionDiagnostic), editable=\(editable), localScopes=\(scopeCount)"
        }
    }

    /// Read only the captured composer and its nearby controls. Never discover a replacement
    /// composer when a renderer transition changes the original AX object identity.
    func nativeDictationStatus(in handle: ComposerHandle) throws -> NativeDictationObservation {
        try nativeControlSnapshot(in: handle).observation
    }

    /// Before recording, allow one Manual accessibility request and then read-only waiting.
    /// Ownership remains with startNativeDictation after the caller captures a fresh draft.
    func awaitNativeDictationReadiness(in handle: ComposerHandle,
                                      checkOperation: () throws -> Void) async throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + 3.5
        var outcome = "failed"
        var refreshUsed = false
        var reusedPending = false
        var refreshAX = "notRun"
        var readyNotBefore = startedAt
        var polls = 0
        var beforeActions = "unavailable"
        var afterActions = "notRun"
        var latestActions = "unavailable"
        var stage = "initialSnapshot"
        let previousManualAge = accessibilityPreparationRequestedAt[handle.pid].map {
            String(format: "%.3fs", max(0, startedAt - $0))
        } ?? "unknown"
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            lastNativeReadinessDiagnostic = "result=\(outcome), stage=\(stage), refreshUsed=\(refreshUsed), reusedPending=\(reusedPending), refreshAX=\(refreshAX), polls=\(polls), "
                + String(format: "elapsed=%.3fs, ", elapsed)
                + "previousManualRequestAge=\(previousManualAge), before={\(beforeActions)}, after={\(afterActions)}, latest={\(latestActions)}, observation={\(lastNativeObservationDiagnostic)}"
        }
        do {
            try Task.checkCancellation()
            try checkOperation()
            polls += 1
            let initial = try nativeReadinessSnapshot(in: handle, matching: nil)
            beforeActions = initial.actionDiagnostic
            latestActions = beforeActions
            guard let control = initial.control else {
                throw AccessibilityBridgeError.unavailable("原生录音按钮未就绪，尚未发出录音请求。")
            }
            if !initial.pressable {
                try checkOperation()
                try checkNativeReadinessBudget(deadline)
                let beforeRefresh = try nativeReadinessSnapshot(in: handle, matching: control, scope: initial.scope)
                polls += 1
                beforeActions = beforeRefresh.actionDiagnostic
                latestActions = beforeActions
                if !beforeRefresh.pressable {
                    stage = "prepareActions"
                    try checkOperation()
                    try checkNativeReadinessBudget(deadline)
                    let now = ProcessInfo.processInfo.systemUptime
                    if accessibilityPreparation[handle.pid] == .success,
                       let requestedAt = accessibilityPreparationRequestedAt[handle.pid],
                       now - requestedAt < 2 {
                        // Reasserting true would reset Electron's pending two-second debounce.
                        reusedPending = true
                        readyNotBefore = requestedAt + 2
                    } else {
                        // Chromium 156 serializes DefaultActionVerb only with extended properties;
                        // a readable basic tree can therefore omit AXPress. Electron 45.2.1's
                        // Manual setter requests complete mode after a two-second debounce.
                        // https://github.com/chromium/chromium/blob/156.0.8078.75/third_party/blink/renderer/modules/accessibility/ax_object.cc
                        // https://github.com/electron/electron/blob/v45.2.1/shell/browser/mac/electron_application.mm
                        refreshUsed = true
                        // A failed new request must not inherit a previous request's success.
                        accessibilityPreparation.removeValue(forKey: handle.pid)
                        accessibilityPreparationRequestedAt[handle.pid] = now
                        let result = try performInForeground(handle) {
                            AXUIElementSetAttributeValue(application(handle.pid),
                                "AXManualAccessibility" as CFString, kCFBooleanTrue)
                        }
                        refreshAX = String(result.rawValue)
                        try check(result, "刷新原生录音可访问性")
                        accessibilityPreparation[handle.pid] = result
                        readyNotBefore = now + 2
                    }
                }
            }

            // Prepare action capabilities only. Codex's final action gate warms and
            // verifies its exact hit after every composer/draft preflight is finished.
            while true {
                stage = "readinessSnapshot"
                try Task.checkCancellation()
                try checkOperation()
                try checkNativeReadinessBudget(deadline)
                let current = try nativeReadinessSnapshot(in: handle, matching: control, scope: initial.scope)
                polls += 1
                latestActions = current.actionDiagnostic
                if refreshUsed || reusedPending {
                    afterActions = current.actionDiagnostic
                }
                if current.pressable && ProcessInfo.processInfo.systemUptime >= readyNotBefore {
                    try checkOperation()
                    try checkNativeReadinessBudget(deadline)
                    try verifyNativeTarget(handle, requireFocused: true)
                    outcome = "ready"
                    return
                }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else {
                    outcome = "timeout"
                    throw AccessibilityBridgeError.unavailable("听写按钮动作能力尚未就绪，等待已结束；未发出录音请求（\(current.diagnostic)）。")
                }
                try await Task.sleep(for: .milliseconds(min(50, remaining * 1_000)))
            }
        } catch is CancellationError {
            outcome = "cancelled"
            throw CancellationError()
        } catch {
            if ProcessInfo.processInfo.systemUptime >= deadline { outcome = "timeout" }
            throw error
        }
    }

    /// Bound additional reads, not the time already spent inside an individual AX IPC.
    private func checkNativeReadinessBudget(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw AccessibilityBridgeError.unavailable("原生录音准备等待已结束，尚未发出录音请求。")
        }
    }

    private func nativeReadinessSnapshot(in handle: ComposerHandle,
                                         matching control: AXUIElement?, scope: AXUIElement? = nil) throws -> NativeControlSnapshot {
        guard ownedVoice == nil, ownedNativeVoice == nil else {
            throw AccessibilityBridgeError.unavailable("已有语音所有权，不能准备另一段原生录音。")
        }
        try verifyNativeTarget(handle, requireFocused: true)
        let snapshot = try nativeControlSnapshot(in: handle)
        guard snapshot.observation == .idle, snapshot.kind == .start,
              snapshot.control != nil, snapshot.enabled, snapshot.editable else {
            throw AccessibilityBridgeError.unavailable("准备期间原生语音不再空闲，尚未发出录音请求（\(snapshot.diagnostic)）。")
        }
        if let control {
            if handle.bundleID == codexBundleID {
                guard let scope, same(snapshot.scope, scope) else {
                    throw AccessibilityBridgeError.targetChanged("准备期间原听写区域的 AX 身份变化")
                }
            } else if !same(snapshot.control, control) {
                throw AccessibilityBridgeError.targetChanged("准备期间原生录音按钮的 AX 身份变化")
            }
        }
        try verifyNativeTarget(handle, requireFocused: true)
        return snapshot
    }

    func startNativeDictation(_ handle: ComposerHandle, expectedDraft: String,
                              checkOperation: () throws -> Void) async throws {
        lastNativeActionDiagnostic = "adapter=\(handle.bundleID == codexBundleID ? "codex" : "claude"), kind=start, stage=preflight, requested=false"
        guard ownedVoice == nil, ownedNativeVoice == nil else {
            throw AccessibilityBridgeError.unavailable("上一段语音尚未确认结束。")
        }
        let typeless = typelessStatus()
        guard typeless != .recording && typeless != .processing else {
            throw AccessibilityBridgeError.unavailable("Typeless 已在录音或转写，请先结束当前语音。")
        }
        try verifyNativeTarget(handle, requireFocused: true)
        let initial = try nativeControlSnapshot(in: handle)
        guard initial.observation == .idle, let control = initial.control,
              initial.kind == .start, initial.enabled, initial.pressable, initial.editable else {
            throw AccessibilityBridgeError.unavailable("原生录音按钮尚未就绪（\(initial.diagnostic)）。")
        }
        if !(try readDraftValue(handle)).isEmpty {
            guard let selection = selectedRange(handle.element), selection.length == 0 else {
                throw AccessibilityBridgeError.unavailable("草稿存在选区或无法确认插入点，请先取消选区。")
            }
        }
        try verifyNativeTarget(handle, requireFocused: true)
        let latest = try nativeControlSnapshot(in: handle)
        guard latest.observation == .idle, same(latest.control, control), latest.pressable else {
            throw AccessibilityBridgeError.targetChanged("原生录音控件在开始前发生变化（\(latest.diagnostic)）")
        }
        if handle.bundleID == codexBundleID {
            guard let scope = latest.scope else { throw AccessibilityBridgeError.targetChanged("听写局部区域已丢失") }
            try await performCodexNativeAction(control, kind: .dictate, in: handle, scope: scope,
                expectedDraft: expectedDraft, checkOperation: checkOperation) {
                self.ownedNativeVoice = NativeDictationOwnership(handle: handle, control: control, scope: scope)
                self.lastVoiceControl = "ChatGPT / Codex Dictate（AXPress）"
            }
            return
        }
        try requireNativeVisibility(control, in: handle.window, component: "开始录音按钮", hitTest: true)
        // AXPress is a semantic toggle in the verified Claude build. Retain ownership before
        // the request: a timeout can mean recording began, so retrying could stop/restart it.
        try performInForeground(handle) {
            try verifyNativeAction(control, kind: .start, in: handle)
            ownedNativeVoice = NativeDictationOwnership(handle: handle, control: control, scope: latest.scope)
            lastNativeActionDiagnostic = "adapter=claude, kind=start, requested=true"
            lastVoiceControl = handle.bundleID == codexBundleID ? "ChatGPT / Codex Dictate（AXPress）" : "Claude 原生 Press and hold to record（AXPress）"
            try check(AXUIElementPerformAction(control, kAXPressAction as CFString), "开始原生听写")
        }
    }

    func stopNativeDictation(_ handle: ComposerHandle, checkOperation: () throws -> Void) async throws {
        lastNativeActionDiagnostic = "adapter=\(handle.bundleID == codexBundleID ? "codex" : "claude"), kind=stop, stage=preflight, requested=false"
        guard var owned = ownedNativeVoice, isSameComposer(owned.handle, handle),
              !owned.stopRequested, !owned.cancelRequested else {
            throw AccessibilityBridgeError.unavailable("没有本应用拥有且尚未停止的原生录音。")
        }
        let snapshot = try nativeControlSnapshot(in: handle, readOnlyRecovery: true)
        if snapshot.observation == .idle, snapshot.editable {
            // The user may have stopped the owned recording directly in Claude. Adopt
            // that verified result without toggling the idle control back into recording.
            owned.settledEditor = ownedNativeVoice?.settledEditor
            owned.stopRequested = true
            ownedNativeVoice = owned
            lastVoiceControl = "原生语音已空闲（未发送 AXPress）"
            return
        }
        guard snapshot.observation == .recording, snapshot.kind == .stop,
              let control = snapshot.control, snapshot.enabled, snapshot.pressable else {
            throw AccessibilityBridgeError.unavailable("尚未确认可操作的 Stop dictation 按钮；不会重试切换。")
        }
        let latest = try nativeControlSnapshot(in: handle)
        guard latest.observation == .recording, same(latest.control, control), latest.pressable else {
            throw AccessibilityBridgeError.targetChanged("原生录音控件在停止前发生变化")
        }
        if handle.bundleID == codexBundleID {
            guard let scope = owned.scope else { throw AccessibilityBridgeError.targetChanged("听写局部区域已丢失") }
            try await performCodexNativeAction(control, kind: .stop, in: handle, scope: scope,
                expectedDraft: nil, checkOperation: checkOperation) {
                owned.stopRequested = true
                self.ownedNativeVoice = owned
                self.lastVoiceControl = "原生 Stop dictation（AXPress，只填入草稿）"
            }
            return
        }
        try requireNativeVisibility(control, in: handle.window, component: "停止录音按钮", hitTest: true)
        try performInForeground(handle) {
            try verifyNativeAction(control, kind: .stop, in: handle)
            owned.stopRequested = true
            ownedNativeVoice = owned
            lastNativeActionDiagnostic = "adapter=claude, kind=stop, requested=true"
            lastVoiceControl = "原生 Stop dictation（AXPress，只填入草稿）"
            try check(AXUIElementPerformAction(control, kAXPressAction as CFString), "停止原生听写")
        }
    }

    /// Idle + an editable original Prompt is the completion evidence. No transcript value
    /// is read during recording/processing, and a read never releases ownership by itself.
    func nativeTranscriptionDraft(in handle: ComposerHandle) throws -> String? {
        guard let owned = ownedNativeVoice, owned.stopRequested, !owned.cancelRequested,
              isSameComposer(owned.handle, handle) else {
            throw AccessibilityBridgeError.targetChanged("原生转写所有权已丢失或尚未请求停止")
        }
        let snapshot = try nativeControlSnapshot(in: handle)
        switch snapshot.observation {
        case .recording, .processing: return nil
        case .unavailable:
            throw AccessibilityBridgeError.unavailable("原生语音控件状态未知，无法确认转写完成。")
        case .idle:
            guard snapshot.editable else { return nil }
            return try readNativeCompletionDraft(in: handle, snapshot: snapshot, requireFocused: true)
        }
    }

    /// Reconcile only the captured native operation. Reading idle evidence never issues
    /// an action, changes the draft, releases ownership or grants send readiness.
    func nativeIdleDraft(in handle: ComposerHandle) throws -> String? {
        guard let owned = ownedNativeVoice, isSameComposer(owned.handle, handle) else {
            throw AccessibilityBridgeError.targetChanged("原生语音所有权或原始目标已丢失")
        }
        func confirmedIdleSnapshot() throws -> NativeControlSnapshot? {
            // The snapshot verifies front PID/window, context, modal absence and exact mic
            // identity. Keyboard focus is unnecessary for this read-only state recovery.
            let snapshot = try nativeControlSnapshot(in: handle, readOnlyRecovery: true)
            switch snapshot.observation {
            case .recording, .processing:
                return nil
            case .unavailable:
                throw AccessibilityBridgeError.unavailable("原生语音控件状态未知，无法确认空闲。")
            case .idle:
                guard snapshot.kind == .start, snapshot.enabled, snapshot.editable,
                      (handle.bundleID == codexBundleID || same(snapshot.control, owned.control)) else {
                    throw AccessibilityBridgeError.targetChanged("原生语音空闲控件或输入框不再匹配")
                }
                return snapshot
            }
        }
        guard let snapshot = try confirmedIdleSnapshot() else { return nil }
        let text = try readNativeCompletionDraft(in: handle, snapshot: snapshot, requireFocused: false)
        guard try confirmedIdleSnapshot() != nil else { return nil }
        return text
    }

    func cancelNativeDictation(_ handle: ComposerHandle, checkOperation: () throws -> Void) async throws {
        lastNativeActionDiagnostic = "adapter=\(handle.bundleID == codexBundleID ? "codex" : "claude"), kind=cancel, stage=preflight, requested=false"
        guard var owned = ownedNativeVoice, isSameComposer(owned.handle, handle),
              !owned.stopRequested, !owned.cancelRequested else {
            throw AccessibilityBridgeError.unavailable("没有本应用启动且仍处于录音阶段的原生语音。")
        }
        let snapshot = try nativeControlSnapshot(in: handle, readOnlyRecovery: true)
        if snapshot.observation == .idle, snapshot.editable {
            owned.settledEditor = ownedNativeVoice?.settledEditor
            owned.cancelRequested = true
            ownedNativeVoice = owned
            lastVoiceControl = "原生语音已空闲（等待取消结果核验）"
            return
        }
        guard snapshot.observation == .recording, snapshot.kind == .stop,
              snapshot.enabled, snapshot.pressable else {
            throw AccessibilityBridgeError.unavailable("未确认原生录音仍在进行，不会发送 Esc。")
        }
        if handle.bundleID == codexBundleID {
            guard let cancel = snapshot.cancelControl else {
                throw AccessibilityBridgeError.unavailable("未找到明确的 Cancel dictation 按钮；不会用 Esc 代替取消。")
            }
            let latest = try nativeControlSnapshot(in: handle)
            guard latest.observation == .recording, same(latest.cancelControl, cancel),
                  bool(cancel, kAXEnabledAttribute) == true, actions(cancel).contains(kAXPressAction) else {
                throw AccessibilityBridgeError.targetChanged("听写取消控件发生变化")
            }
            guard let scope = owned.scope else { throw AccessibilityBridgeError.targetChanged("听写局部区域已丢失") }
            try await performCodexNativeAction(cancel, kind: .cancel, in: handle, scope: scope,
                expectedDraft: nil, checkOperation: checkOperation) {
                owned.cancelRequested = true
                self.ownedNativeVoice = owned
                self.lastVoiceControl = "ChatGPT / Codex Cancel dictation（AXPress）"
            }
            return
        }
        try verifyNativeTarget(handle)
        let focused = element(application(handle.pid), kAXFocusedUIElementAttribute)
        // AXPress leaves focus on this exact microphone toggle in the tested Claude
        // build. Escape cancels from either it or the original Prompt, not other views.
        guard same(focused, handle.element) || same(focused, owned.control) else {
            throw AccessibilityBridgeError.targetChanged("输入焦点不在原生录音的 Prompt 或麦克风按钮")
        }
        // Both key edges go to the exact target process. Cancellation is a request; the
        // coordinator must confirm idle + unchanged draft before forgetting ownership.
        try postKey(53, flags: [], pid: handle.pid, expectedWindow: foregroundWindow(of: handle)) {
            owned.cancelRequested = true
            self.ownedNativeVoice = owned
            self.lastNativeActionDiagnostic = "adapter=claude, kind=cancel, requested=true"
            self.lastVoiceControl = "Claude 原生 Esc 取消（目标进程定向）"
        }
    }

    func nativeCancellationConfirmed(in handle: ComposerHandle, baseline: String) throws -> Bool {
        guard let owned = ownedNativeVoice, owned.cancelRequested, !owned.stopRequested,
              isSameComposer(owned.handle, handle) else {
            throw AccessibilityBridgeError.targetChanged("没有待确认的原生语音取消请求")
        }
        let snapshot = try nativeControlSnapshot(in: handle)
        guard snapshot.observation == .idle, snapshot.editable else { return false }
        return try readNativeCompletionDraft(in: handle, snapshot: snapshot, requireFocused: false) == baseline
    }

    /// Only reads the completed editor in the original pinned scope. The original
    /// operation handle remains unchanged; future actions must discover a fresh one.
    private func readNativeCompletionDraft(in handle: ComposerHandle, snapshot: NativeControlSnapshot,
                                            requireFocused: Bool) throws -> String {
        guard handle.bundleID == codexBundleID else {
            try verifyNativeTarget(handle, requireFocused: requireFocused)
            return try readDraftValue(handle)
        }
        try verifyNativeTarget(handle)
        guard let owned = ownedNativeVoice, let scope = owned.scope,
              snapshot.observation == .idle, snapshot.editable,
              let editor = snapshot.completionEditor,
              same(owned.settledEditor, editor) || (owned.settledEditor == nil && same(editor, handle.element)),
              belongs(editor, to: scope), belongs(editor, to: handle.window),
              CFEqual(conversationContext(of: editor, window: handle.window), handle.context),
              composerScore(editor, bundleID: handle.bundleID) > 0 else {
            throw AccessibilityBridgeError.targetChanged("原听写区域尚未恢复唯一的可编辑输入框")
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(editor, &pid) == .success, pid == handle.pid else {
            throw AccessibilityBridgeError.targetChanged("听写恢复输入框的进程变化")
        }
        try rejectModalAncestors(of: editor, window: handle.window)
        try requireNativeVisibility(editor, in: handle.window, component: "听写恢复输入框", hitTest: false)
        if requireFocused, !same(element(application(handle.pid), kAXFocusedUIElementAttribute), editor) {
            throw AccessibilityBridgeError.targetChanged("输入焦点不在听写恢复后的输入框")
        }
        let text = try readDraftValue(from: editor)
        try verifyNativeTarget(handle)
        return text
    }

    func forgetNativeDictationOwnership() { ownedNativeVoice = nil }

    /// Only fixed control labels, capability counts and state are returned; no draft text,
    /// message content, window title, conversation URL or AX tree enters diagnostics.
    func nativeVoiceControlCapabilities(in handle: ComposerHandle) throws -> String {
        let snapshot = try nativeControlSnapshot(in: handle)
        return "原生语音：\(snapshot.diagnostic)\n最近准备检查：\(lastNativeReadinessDiagnostic)"
    }

    /// The general composer matcher remains unchanged. Only a captured, owned native
    /// Prompt may be temporarily disabled, and every other identity check still applies.
    private func isOwnedNativePrompt(_ node: AXUIElement, handle: ComposerHandle) -> Bool {
        guard let owned = ownedNativeVoice, isSameComposer(owned.handle, handle),
              CFEqual(node, handle.element), bool(node, "AXHidden") != true,
              [kAXTextAreaRole, kAXTextFieldRole].contains(role(node)) else { return false }
        let identifier = string(node, kAXIdentifierAttribute).lowercased()
        return ["prompt-textarea", "chat-input"].contains(identifier)
            || [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"].contains {
                string(node, $0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "prompt"
            }
    }

    private func verifyNativeTarget(_ handle: ComposerHandle, requireFocused: Bool = false,
                                     checkExposure: Bool = true) throws {
        try requireTrust()
        if handle.bundleID == codexBundleID, let owned = ownedNativeVoice {
            try verifyCodexDictationScope(handle, owned: owned, requireFocused: requireFocused)
            return
        }
        guard supportedApps.contains(handle.bundleID) else {
            throw AccessibilityBridgeError.unavailable("此应用尚无原生语音适配器。")
        }
        let running = try frontApplication(bundleID: handle.bundleID)
        let app = application(handle.pid)
        guard running.processIdentifier == handle.pid,
              same(element(app, kAXFocusedWindowAttribute), handle.window),
              elements(app, kAXWindowsAttribute).contains(where: { CFEqual($0, handle.window) }),
              belongs(handle.element, to: handle.window), belongs(handle.context, to: handle.window),
              CFEqual(conversationContext(of: handle.element, window: handle.window), handle.context),
              composerScore(handle.element, bundleID: handle.bundleID) > 0 || isOwnedNativePrompt(handle.element, handle: handle),
              string(handle.window, kAXTitleAttribute) == handle.windowTitle,
              documentIdentity(handle.window) == handle.document,
              contextIdentity(handle.context) == handle.contextIdentity else {
            throw AccessibilityBridgeError.targetChanged("原生语音的窗口、输入框或会话身份变化")
        }
        for node in [handle.window, handle.element, handle.context] {
            var pid: pid_t = 0
            guard AXUIElementGetPid(node, &pid) == .success, pid == handle.pid else {
                throw AccessibilityBridgeError.targetChanged("原生语音目标的进程身份变化")
            }
        }
        try rejectFocusedModal(app: app, window: handle.window)
        try rejectModalAncestors(of: handle.element, window: handle.window)
        // During owned dictation Claude makes Prompt read-only and may put a listening
        // surface over it. Hit-testing is an action precondition, not recording-state
        // evidence. Keep strict exposure before start and when reading the final draft.
        let ownsPrompt = isOwnedNativePrompt(handle.element, handle: handle)
        try requireNativeVisibility(handle.element, in: handle.window, component: "原生听写 Prompt",
                                    hitTest: checkExposure && (!ownsPrompt || requireFocused))
        if requireFocused && !same(element(app, kAXFocusedUIElementAttribute), handle.element) {
            throw AccessibilityBridgeError.targetChanged("输入焦点不在原生录音的原始 Prompt")
        }
    }

    private func nativeControlKind(_ node: AXUIElement) -> NativeControlKind? {
        // Electron may expose a toggle as AXButton or AXCheckBox. Its exact accessible
        // name supplies intent; AXValue is deliberately never used to infer a toggle.
        guard [kAXButtonRole, kAXCheckBoxRole].contains(role(node)),
              bool(node, "AXHidden") != true else { return nil }
        let names = [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"].map {
            string(node, $0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let start = names.contains(NativeControlKind.start.rawValue.lowercased())
        let stop = names.contains(NativeControlKind.stop.rawValue.lowercased())
        guard start != stop else { return nil }
        return start ? .start : .stop
    }

    /// ChatGPT's editor stays mounted but is hidden/inert while its recording toolbar
    /// is shown. The captured window, web context and composer container must survive;
    /// a different container is never adopted. A recreated editor may be read only
    /// after an explicit end request and confirmed idle in this same pinned scope.
    private func verifyCodexDictationScope(_ handle: ComposerHandle,
                                           owned: NativeDictationOwnership,
                                           requireFocused: Bool) throws {
        guard isSameComposer(handle, owned.handle), let scope = owned.scope else {
            throw AccessibilityBridgeError.targetChanged("ChatGPT 听写区域所有权已丢失")
        }
        try verifyForegroundWindow(foregroundWindow(of: handle))
        guard belongs(scope, to: handle.window), belongs(handle.context, to: handle.window),
              string(handle.window, kAXTitleAttribute) == handle.windowTitle,
              documentIdentity(handle.window) == handle.document,
              contextIdentity(handle.context) == handle.contextIdentity,
              belongs(scope, to: handle.context) else {
            throw AccessibilityBridgeError.targetChanged("ChatGPT 听写的原窗口、会话或输入区域变化")
        }
        for node in [scope, handle.context] {
            var pid: pid_t = 0
            guard AXUIElementGetPid(node, &pid) == .success, pid == handle.pid else {
                throw AccessibilityBridgeError.targetChanged("ChatGPT 听写区域的进程身份变化")
            }
        }
        try rejectFocusedModal(app: application(handle.pid), window: handle.window)
        try rejectModalAncestors(of: scope, window: handle.window)
        try requireNativeVisibility(scope, in: handle.window, component: "原听写区域", hitTest: false)
        if requireFocused {
            guard belongs(handle.element, to: scope), composerScore(handle.element, bundleID: handle.bundleID) > 0,
                  same(element(application(handle.pid), kAXFocusedUIElementAttribute), handle.element) else {
                throw AccessibilityBridgeError.targetChanged("原听写输入框尚未恢复或焦点已变化")
            }
            try requireExposed(handle.element, in: handle.window)
        }
        try verifyForegroundWindow(foregroundWindow(of: handle))
    }

    private func codexDictationKind(_ node: AXUIElement) -> CodexDictationSemantics.Control? {
        CodexDictationSemantics.match(role: role(node),
            names: [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"].map { string(node, $0) },
            hidden: bool(node, "AXHidden"))
    }

    /// Chromium macOS calls CachingAsyncHitTest: the synchronous answer can be a
    /// coarse ancestor while the renderer computes the exact result asynchronously.
    /// Finish every other hit-test before this gate. Within it, only the captured
    /// button's center is probed, across run-loop turns, then AXPress is issued once.
    /// https://raw.githubusercontent.com/chromium/chromium/157.0.8103.39/ui/accessibility/platform/browser_accessibility_cocoa.mm
    private func performCodexNativeAction(_ control: AXUIElement, kind: CodexDictationSemantics.Control,
                                          in handle: ComposerHandle, scope: AXUIElement,
                                          expectedDraft: String?, checkOperation: () throws -> Void,
                                          beforePress: () -> Void) async throws {
        guard handle.bundleID == codexBundleID, [.dictate, .stop, .cancel].contains(kind) else {
            throw AccessibilityBridgeError.unavailable("不支持的听写动作")
        }
        let started = ProcessInfo.processInfo.systemUptime
        var polls = 0
        var hitSummary = "notChecked"
        var requested = false
        var outcome = "failed"
        defer {
            lastNativeActionDiagnostic = "adapter=codex, kind=\(kind.rawValue), outcome=\(outcome), polls=\(polls), requested=\(requested), "
                + String(format: "elapsed=%.3fs, ", ProcessInfo.processInfo.systemUptime - started)
                + "hit={\(hitSummary)}"
        }
        do {
            try await ReadinessActionGate.run(deadline: started + 1.5,
                now: { ProcessInfo.processInfo.systemUptime },
                wait: { try await Task.sleep(for: .milliseconds(50)) },
                validate: {
                    // No helper in this closure may hit-test another point: doing
                    // so would replace the cache we are warming for this button.
                    try checkOperation()
                    try self.verifyNativeTarget(handle, requireFocused: kind == .dictate, checkExposure: false)
                    guard self.belongs(scope, to: handle.window), self.belongs(control, to: scope),
                          self.codexDictationKind(control) == kind,
                          self.bool(control, kAXEnabledAttribute) == true,
                          self.actions(control).contains(kAXPressAction) else {
                        throw AccessibilityBridgeError.targetChanged("听写动作或原局部区域发生变化")
                    }
                    var pid: pid_t = 0
                    guard AXUIElementGetPid(control, &pid) == .success, pid == handle.pid else {
                        throw AccessibilityBridgeError.targetChanged("听写按钮的进程身份变化")
                    }
                    let editors = try self.localComposerInputs(in: scope, handle: handle, checkExposure: false)
                    if kind == .dictate {
                        guard self.ownedNativeVoice == nil, self.ownedVoice == nil,
                              editors.count == 1, self.same(editors.first, handle.element),
                              let expectedDraft, try self.readDraftValue(handle) == expectedDraft else {
                            throw AccessibilityBridgeError.targetChanged("开始听写前输入框或草稿已变化；未请求录音")
                        }
                        if !expectedDraft.isEmpty {
                            guard let selection = self.selectedRange(handle.element), selection.length == 0 else {
                                throw AccessibilityBridgeError.targetChanged("开始听写前草稿选区发生变化；未请求录音")
                            }
                        }
                    } else {
                        guard let owned = self.ownedNativeVoice, self.isSameComposer(owned.handle, handle),
                              self.same(owned.scope, scope), !owned.stopRequested, !owned.cancelRequested,
                              editors.isEmpty || (editors.count == 1 && self.same(editors.first, handle.element)) else {
                            throw AccessibilityBridgeError.targetChanged("听写所有权或原输入区域发生变化")
                        }
                    }
                    try self.rejectModalAncestors(of: control, window: handle.window)
                    try self.requireNativeVisibility(control, in: handle.window, component: "听写动作按钮", hitTest: false)
                    try self.verifyForegroundWindow(self.foregroundWindow(of: handle))
                },
                isReady: {
                    polls += 1
                    let result = self.isExposed(control, in: handle.window, fractions: [0.5])
                    hitSummary = self.lastExposureDiagnostic
                    return result
                },
                perform: {
                    // Keep this boundary free of composer/control hit tests. The
                    // exact last probe is followed only by ownership/window checks.
                    try checkOperation()
                    guard self.codexDictationKind(control) == kind,
                          self.bool(control, kAXEnabledAttribute) == true,
                          self.actions(control).contains(kAXPressAction) else {
                        throw AccessibilityBridgeError.targetChanged("听写按钮用途在点击前变化")
                    }
                    if let expectedDraft {
                        guard try self.readDraftValue(handle) == expectedDraft else {
                            throw AccessibilityBridgeError.targetChanged("草稿在点击前变化；未请求录音")
                        }
                        if !expectedDraft.isEmpty {
                            guard let selection = self.selectedRange(handle.element), selection.length == 0 else {
                                throw AccessibilityBridgeError.targetChanged("草稿选区在点击前变化；未请求录音")
                            }
                        }
                    }
                    try self.verifyForegroundWindow(self.foregroundWindow(of: handle))
                    beforePress()
                    requested = true
                    try self.check(AXUIElementPerformAction(control, kAXPressAction as CFString), "执行原生听写动作")
                })
            outcome = "requested"
        } catch ReadinessActionGate.GateError.timedOut {
            outcome = "hitTimeout"
            throw AccessibilityBridgeError.unavailable("听写按钮的精确命中尚未确认；未点击（\(hitSummary)）。")
        }
    }

    private func verifyNativeAction(_ control: AXUIElement, kind: NativeControlKind,
                                     in handle: ComposerHandle) throws {
        try verifyNativeTarget(handle, requireFocused: kind == .start)
        let matches = handle.bundleID == codexBundleID
            ? codexDictationKind(control) == (kind == .start ? .dictate : .stop)
            : nativeControlKind(control) == kind
        guard matches, bool(control, kAXEnabledAttribute) == true,
              actions(control).contains(kAXPressAction), belongs(control, to: handle.window) else {
            throw AccessibilityBridgeError.targetChanged("录音按钮用途已变化，未重复切换")
        }
        if handle.bundleID == codexBundleID, let scope = ownedNativeVoice?.scope,
           !belongs(control, to: scope) {
            throw AccessibilityBridgeError.targetChanged("录音按钮已离开原输入区域")
        }
        try requireNativeVisibility(control, in: handle.window, component: "原生听写按钮", hitTest: true)
        try verifyForegroundWindow(foregroundWindow(of: handle))
    }

    private func isLocalCodexScope(_ scope: AXUIElement, handle: ComposerHandle) throws -> Bool {
        guard !CFEqual(scope, handle.window), !isCodexConversationRegion(scope),
              try messageNodeKind(scope) == .container,
              let input = frame(handle.element), let bounds = frame(scope),
              [input.minX, input.minY, input.width, input.height,
               bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite }),
              input.width > 2, input.height > 2, bounds.width > 2, bounds.height > 2 else { return false }
        return bounds.height <= max(400, input.height + 220)
            && bounds.width <= input.width + 480 && bounds.intersects(input)
            && belongs(handle.element, to: scope) && belongs(scope, to: handle.window)
    }

    /// Include the local Body that contains the legacy recording bar as a sibling.
    /// Geometry is only an upper bound on traversal; exact editor/button semantics
    /// still determine scope. Never expand to a transcript, pane or another editor.
    private func codexDictationScope(around initial: AXUIElement, control: AXUIElement,
                                     handle: ComposerHandle) throws -> AXUIElement {
        guard try isLocalCodexScope(initial, handle: handle) else {
            throw AccessibilityBridgeError.unavailable("无法确认聊天输入框的局部听写区域")
        }
        var current = initial
        for _ in 0..<4 {
            guard let parent = element(current, kAXParentAttribute),
                  try isLocalCodexScope(parent, handle: handle) else { break }
            let editors = try localComposerInputs(in: parent, handle: handle)
            guard editors.count == 1, same(editors.first, handle.element) else { break }
            let controls = try searchControls(in: parent, key: "AXButtonSearchKey", limit: 65)
                .filter { codexDictationKind($0) != nil }
            guard controls.count == 1, same(controls.first, control) else { break }
            current = parent
        }
        return current
    }

    /// Indexed, composer-local lookup. Neither real-time voice nor the combined
    /// "Transcribe and send" action is a stop target. No keyboard fallback is used.
    private func codexDictationSnapshot(in handle: ComposerHandle, readOnlyRecovery: Bool = false) throws -> NativeControlSnapshot {
        try verifyNativeTarget(handle)
        let owned = ownedNativeVoice
        var scope = owned?.scope ?? element(handle.element, kAXParentAttribute)
        var scopeCount = 0
        for _ in 0..<10 {
            guard let container = scope, !CFEqual(container, handle.window) else { break }
            guard !isCodexConversationRegion(container) else { break }
            let kind = try messageNodeKind(container)
            guard kind == .container else { break }
            if owned == nil, try !isLocalCodexScope(container, handle: handle) { break }
            scopeCount += 1
            let composers = try localComposerInputs(in: container, handle: handle, checkExposure: owned == nil)
            let candidate = composers.count == 1 ? composers.first : nil
            let candidateEditable = candidate.map {
                composerScore($0, bundleID: handle.bundleID) > 0
            } ?? false
            let found = try searchControls(in: container, key: "AXButtonSearchKey", limit: 65)
                .compactMap { node -> (AXUIElement, CodexDictationSemantics.Control)? in
                    guard let kind = codexDictationKind(node) else { return nil }
                    return (node, kind)
                }
            if !found.isEmpty || owned != nil {
                for (node, _) in found {
                    var pid: pid_t = 0
                    guard AXUIElementGetPid(node, &pid) == .success, pid == handle.pid,
                          belongs(node, to: container), belongs(node, to: handle.window) else {
                        throw AccessibilityBridgeError.targetChanged("听写控件不属于原输入区域")
                    }
                    try rejectModalAncestors(of: node, window: handle.window)
                }
                let evidence = found.map {
                    CodexDictationSemantics.ControlEvidence(kind: $0.1, enabled: bool($0.0, kAXEnabledAttribute) == true)
                }
                let state = CodexDictationSemantics.classify(controls: evidence, composerEditable: candidateEditable,
                    owned: owned != nil, endingRequested: owned?.stopRequested == true || owned?.cancelRequested == true)
                let editorDecision = CodexDictationEditorPolicy.resolve(owned: owned != nil,
                    endingRequested: owned?.stopRequested == true || owned?.cancelRequested == true,
                    idle: state == .idle, editorCount: composers.count,
                    originalEditor: same(candidate, handle.element), recognizedEditor: candidateEditable,
                    settledEditorMatches: owned?.settledEditor.map { same(candidate, $0) },
                    readOnlyRecovery: readOnlyRecovery)
                guard editorDecision != .reject else {
                    lastNativeObservationDiagnostic = "adapter=codex, editor=rejected, count=\(composers.count), state=\(state), ending=\(owned?.stopRequested == true || owned?.cancelRequested == true)"
                    throw AccessibilityBridgeError.targetChanged("ChatGPT 听写区域的输入框身份变化")
                }
                let editable = candidateEditable && editorDecision != .waiting
                let observation: NativeDictationObservation
                switch state {
                case .idle: observation = .idle
                case .recording: observation = .recording
                case .processing: observation = .processing
                case .unavailable: observation = .unavailable
                }
                let actionKind: CodexDictationSemantics.Control? = state == .idle ? .dictate : (state == .recording ? .stop : nil)
                let control = found.first { $0.1 == actionKind }?.0
                if let control {
                    try requireNativeVisibility(control, in: handle.window, component: "ChatGPT 听写控件",
                                                hitTest: false)
                }
                // Read-only state discovery must not depend on a cache-warming hit
                // test. Action-read errors are distinct from a successful empty list:
                // only the latter can request one AXManual capability refresh.
                var supportedActions: [String] = []
                if let control {
                    var rawActions: CFArray?
                    let actionResult = AXUIElementCopyActionNames(control, &rawActions)
                    lastNativeObservationDiagnostic = "adapter=codex, stage=readActions, AX=\(actionResult.rawValue)"
                    try check(actionResult, "读取 ChatGPT 听写按钮动作")
                    guard let values = rawActions as? [String] else {
                        throw AccessibilityBridgeError.unavailable("ChatGPT 听写按钮动作列表格式无效。")
                    }
                    supportedActions = values
                }
                let ownedScope: AXUIElement
                if owned == nil, state == .idle, let control {
                    ownedScope = try codexDictationScope(around: container, control: control, handle: handle)
                } else { ownedScope = container }
                let snapshot = NativeControlSnapshot(observation: observation, control: control,
                    kind: state == .idle ? .start : (state == .recording ? .stop : nil),
                    editable: editable, enabled: control.map { bool($0, kAXEnabledAttribute) == true } ?? false,
                    pressable: supportedActions.contains(kAXPressAction), supportedActions: supportedActions,
                    scopeCount: scopeCount, scope: ownedScope,
                    cancelControl: found.first { $0.1 == .cancel }?.0,
                    unresolvedControlsPresent: state == .unavailable && !found.isEmpty,
                    completionEditor: editable ? candidate : nil)
                // Commit the read-only pin only after every snapshot read succeeds.
                // A failed observation must not permanently adopt an intermediate AX node.
                try verifyForegroundWindow(foregroundWindow(of: handle))
                if state == .idle, editable, var current = owned,
                   current.stopRequested || current.cancelRequested || readOnlyRecovery {
                    current.settledEditor = candidate
                    ownedNativeVoice = current
                }
                lastNativeObservationDiagnostic = "adapter=codex, matches=\(found.count), editor=\(editorDecision), \(snapshot.diagnostic)"
                return snapshot
            }
            scope = element(container, kAXParentAttribute)
        }
        let snapshot = NativeControlSnapshot(observation: .unavailable, control: nil, kind: nil,
            editable: false, enabled: false, pressable: false, supportedActions: [], scopeCount: scopeCount)
        lastNativeObservationDiagnostic = "adapter=codex, \(snapshot.diagnostic)"
        return snapshot
    }

    private func nativeControlSnapshot(in handle: ComposerHandle, readOnlyRecovery: Bool = false) throws -> NativeControlSnapshot {
        // A failed read must not leave the previous successful state in diagnostics.
        lastNativeObservationDiagnostic = "state=unconfirmed"
        if handle.bundleID == codexBundleID {
            return try codexDictationSnapshot(in: handle, readOnlyRecovery: readOnlyRecovery)
        }
        try verifyNativeTarget(handle)
        let editable = bool(handle.element, kAXEnabledAttribute) != false
            && isSettable(handle.element, kAXValueAttribute)
        var scope = element(handle.element, kAXParentAttribute)
        var scopeCount = 0
        for _ in 0..<7 {
            guard let container = scope, !CFEqual(container, handle.window) else { break }
            let kind: MessageNodeKind
            do { kind = try messageNodeKind(container) }
            catch { throw AccessibilityBridgeError.unavailable("原生语音局部结构不可读取。") }
            // Do not search a whole pane, transcript, history list or scroll region.
            guard kind == .container else { break }
            scopeCount += 1
            let composers = try searchControls(in: container, key: "AXTextFieldSearchKey", limit: 9)
                .filter { composerScore($0, bundleID: handle.bundleID) > 0 || isOwnedNativePrompt($0, handle: handle) }
            guard composers.count == 1, same(composers.first, handle.element) else {
                throw AccessibilityBridgeError.ambiguous("原生语音按钮所属的输入框")
            }
            let controls = try searchControls(in: container, key: "AXButtonSearchKey", limit: 65)
                .filter { nativeControlKind($0) != nil && isNearComposer($0, composer: handle.element) }
            guard controls.count <= 1 else {
                throw AccessibilityBridgeError.ambiguous("Claude 原生语音按钮")
            }
            if let control = controls.first, let controlKind = nativeControlKind(control) {
                var pid: pid_t = 0
                guard AXUIElementGetPid(control, &pid) == .success, pid == handle.pid,
                      belongs(control, to: container), belongs(control, to: handle.window) else {
                    throw AccessibilityBridgeError.targetChanged("原生语音控件不再属于原输入区域")
                }
                if let owned = ownedNativeVoice {
                    guard isSameComposer(owned.handle, handle), CFEqual(owned.control, control) else {
                        throw AccessibilityBridgeError.targetChanged("原生语音控件的 AX 身份变化")
                    }
                }
                try rejectModalAncestors(of: control, window: handle.window)
                // An owned status read retains exact AX identity and visible geometry.
                // Start/stop recheck actual pointer exposure immediately before AXPress.
                try requireNativeVisibility(control, in: handle.window, component: "原生听写麦克风",
                                            hitTest: ownedNativeVoice == nil)
                let enabled = bool(control, kAXEnabledAttribute) == true
                var actionNames: CFArray?
                try check(AXUIElementCopyActionNames(control, &actionNames), "读取 Claude 原生录音按钮动作")
                guard let supportedActions = actionNames as? [String] else {
                    throw AccessibilityBridgeError.unavailable("Claude 原生录音按钮返回的动作列表格式无效。")
                }
                let pressable = supportedActions.contains(kAXPressAction)
                let observation: NativeDictationObservation
                if !enabled { observation = .processing }
                else if controlKind == .stop { observation = .recording }
                else if editable { observation = .idle }
                else { observation = .processing }
                let snapshot = NativeControlSnapshot(observation: observation, control: control, kind: controlKind,
                                                     editable: editable, enabled: enabled, pressable: pressable,
                                                     supportedActions: supportedActions,
                                                     scopeCount: scopeCount)
                lastNativeObservationDiagnostic = snapshot.diagnostic
                return snapshot
            }
            scope = element(container, kAXParentAttribute)
        }
        let placeholder = string(handle.element, kAXPlaceholderValueAttribute).lowercased()
        let ownedListening = isOwnedNativePrompt(handle.element, handle: handle) && !editable
            && ["listening...", "listening…"].contains(placeholder)
        let snapshot = NativeControlSnapshot(observation: ownedListening ? .processing : .unavailable,
                                             control: nil, kind: nil, editable: editable, enabled: false,
                                             pressable: false, supportedActions: [], scopeCount: scopeCount)
        lastNativeObservationDiagnostic = snapshot.diagnostic
        return snapshot
    }

    /// This sends a toggle request; it does not claim Typeless accepted it or started recording.
    func triggerTypeless(_ handle: ComposerHandle, shortcut requestedShortcut: VoiceShortcut? = nil) throws {
        try requireTrust()
        guard ownedNativeVoice == nil else {
            throw AccessibilityBridgeError.unavailable("Claude 原生语音尚未确认结束，不能切换到 Typeless。")
        }
        guard let typeless = runningTypeless else {
            throw AccessibilityBridgeError.unavailable("请先启动 Typeless。")
        }
        if let owned = ownedVoice {
            guard isSameComposer(owned.handle, handle), !owned.stopRequested else {
                throw AccessibilityBridgeError.unavailable("上一段语音尚未结束或目标已变化。")
            }
            try verifyVoiceDestination(handle, typeless: typeless, checkExposure: false)
            if let finish = try typelessFinishButton() {
                try performInForeground(handle) {
                    try check(AXUIElementPerformAction(finish, kAXPressAction as CFString), "完成 Typeless 录音")
                }
                lastVoiceControl = "Typeless 录音条的完成按钮"
            } else {
                try postTypelessShortcut(owned.shortcut, expectedWindow: foregroundWindow(of: handle), beforePosting: {
                    try self.verifyVoiceDestination(handle, typeless: typeless, checkExposure: false)
                    return true
                })
                lastVoiceControl = "Typeless 快捷键（未找到可操作的完成控件）"
            }
            ownedVoice = (handle, true, owned.shortcut)
        } else {
            guard let requestedShortcut else {
                throw AccessibilityBridgeError.unavailable("请先设置语音快捷键。")
            }
            let shortcut = try requestedShortcut.validated()
            try verify(handle)
            let text = try draft(in: handle)
            if !text.isEmpty {
                guard let selection = selectedRange(handle.element), selection.length == 0 else {
                    throw AccessibilityBridgeError.unavailable("草稿存在选区或无法确认插入点，请先取消选区。")
                }
            }
            let observation = typelessStatus()
            guard observation != .recording && observation != .processing else {
                throw AccessibilityBridgeError.unavailable("Typeless 已在录音或转写，请先结束当前语音。")
            }
            try verify(handle)
            try postTypelessShortcut(shortcut, expectedWindow: foregroundWindow(of: handle), beforePosting: {
                try self.verify(handle)
                let latest = self.typelessStatus()
                guard latest != .recording && latest != .processing else {
                    throw AccessibilityBridgeError.unavailable("Typeless 已在录音或转写，取消本次开始请求。")
                }
                return true
            })
            lastVoiceControl = "Typeless 快捷键：\(shortcut.displayName)"
            ownedVoice = (handle, false, shortcut)
        }
    }

    /// A retry is safe only while Typeless positively reports that recording continues.
    /// Unknown/processing states must never receive a blind toggle that could restart recording.
    func retryStopIfStillRecording(_ handle: ComposerHandle) throws -> Bool {
        try requireTrust()
        guard let owned = ownedVoice, owned.stopRequested, isSameComposer(owned.handle, handle),
              let typeless = runningTypeless, typelessStatus() == .recording else { return false }
        try verifyVoiceDestination(handle, typeless: typeless, checkExposure: false)
        if let finish = try typelessFinishButton() {
            try performInForeground(handle) {
                try check(AXUIElementPerformAction(finish, kAXPressAction as CFString), "完成 Typeless 录音")
            }
            lastVoiceControl = "Typeless 录音条的完成按钮"
            return true
        }
        return try postTypelessShortcut(owned.shortcut, expectedWindow: foregroundWindow(of: handle), beforePosting: {
            guard self.typelessStatus() == .recording else { return false }
            try self.verifyVoiceDestination(handle, typeless: typeless, checkExposure: false)
            return true
        })
    }

    func cancelTypeless(_ handle: ComposerHandle) throws {
        try requireTrust()
        guard let owned = ownedVoice, !owned.stopRequested, isSameComposer(owned.handle, handle),
              let typeless = runningTypeless else {
            throw AccessibilityBridgeError.unavailable("没有本应用启动且仍处于录音阶段的语音；不会向其他应用发送 Esc。")
        }
        try verifyVoiceDestination(handle, typeless: typeless)
        if let cancel = try typelessBarButton(identifier: "close", description: "取消按钮") {
            try performInForeground(handle) {
                try check(AXUIElementPerformAction(cancel, kAXPressAction as CFString), "取消语音")
            }
            lastVoiceControl = "Typeless 录音条的取消按钮"
        } else {
            // The coordinator must only call this while its owned voice state is recording.
            // Use the global event stream so Typeless can consume its cancellation shortcut.
            // Posting directly to the agent PID could bypass Typeless's global event monitor.
            try verifyVoiceDestination(handle, typeless: typeless)
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard let pid = frontPID, pid == handle.pid else {
                throw AccessibilityBridgeError.targetChanged("无法确认 Esc 的接收应用")
            }
            try postKey(53, flags: [], pid: nil, expectedWindow: foregroundWindow(of: handle))
            lastVoiceControl = "Esc 取消快捷键（未找到可操作的取消控件）"
        }
        ownedVoice = nil
    }

    func forgetTypelessOwnership() { ownedVoice = nil }

    /// Observation is deliberately conservative: absence of a HUD never proves idle/completion.
    func typelessStatus() -> TypelessObservation {
        guard runningTypeless != nil else { return .notRunning }
        guard isTrusted else { return .unknown }
        if (try? typelessFinishButton()) != nil { return .recording }
        let nodes = ((try? typelessRecordingPages()) ?? []).flatMap { (try? descendants($0)) ?? [] }
        if nodes.contains(where: { string($0, kAXIdentifierAttribute) == "loading"
            && bool($0, "AXHidden") != true && (frame($0)?.width ?? 0) > 2 }) { return .processing }
        let labels = nodes.map(label)
        let processing = ["transcribing", "processing", "transcribing…", "processing…", "正在转写", "正在处理", "转写中"]
        if labels.contains(where: processing.contains) { return .processing }
        if labels.contains(where: recordingLabels.contains) { return .recording }
        return .unknown
    }

    /// DOM IDs are only hints: use them only when the installed app actually exposes AX nodes.
    /// Never click a guessed location or treat internal Electron IPC as an external API.
    private func typelessFinishButton() throws -> AXUIElement? {
        try typelessBarButton(identifier: "done", description: "完成按钮")
    }

    private func typelessBarButton(identifier: String, description: String) throws -> AXUIElement? {
        var candidates: [AXUIElement] = []
        for root in try typelessRecordingPages() {
            // Inspect only the recording bar, never Typeless history or its main settings page.
            let nodes = try descendants(root)
            let bars = nodes.filter { string($0, kAXIdentifierAttribute) == "floating-bar" }
            for bar in bars {
                let containers = nodes.filter { string($0, kAXIdentifierAttribute) == identifier && belongs($0, to: bar) }
                for container in containers {
                    // The identified span wraps the actual pressable button.
                    for button in try descendants(container) where role(button) == kAXButtonRole {
                        guard bool(button, kAXEnabledAttribute) == true, bool(button, "AXHidden") != true,
                              let rect = frame(button), rect.width > 2, rect.height > 2,
                              actions(button).contains(kAXPressAction),
                              !candidates.contains(where: { CFEqual($0, button) }) else { continue }
                        candidates.append(button)
                    }
                }
            }
        }
        if candidates.count > 1 { throw AccessibilityBridgeError.ambiguous("Typeless \(description)") }
        return candidates.first
    }

    private func typelessRecordingPages() throws -> [AXUIElement] {
        guard let running = runningTypeless else { return [] }
        let app = application(running.processIdentifier)
        if accessibilityPreparation[running.processIdentifier] == nil {
            // Even provider accessibility initialization is conditional on the agent's
            // current native window. A Typeless foreground HUD is not a routing exception.
            let expectedWindow: ForegroundWindowHandle
            if let ownedVoice { expectedWindow = foregroundWindow(of: ownedVoice.handle) }
            else if let ownedNativeVoice { expectedWindow = foregroundWindow(of: ownedNativeVoice.handle) }
            else { expectedWindow = try captureForegroundWindow(bundleID: "com.anthropic.claudefordesktop") }
            try prepareElectronAccessibility(app, pid: running.processIdentifier, expectedWindow: expectedWindow)
        }
        var pages: [AXUIElement] = []
        for window in elements(app, kAXWindowsAttribute) {
            for root in (try? webRoots(in: window)) ?? [] {
                let page = attribute(root, "AXURL").map { String(describing: $0) } ?? ""
                if URL(string: page)?.lastPathComponent == "floating-bar.html",
                   !pages.contains(where: { CFEqual($0, root) }) { pages.append(root) }
            }
        }
        return pages
    }

    /// Only capability counts are returned. No transcript, draft, history, or AX tree is logged.
    func voiceControlCapabilities() throws -> String {
        try requireTrust()
        guard runningTypeless != nil else { return "Typeless 未运行" }
        let pages = try typelessRecordingPages()
        let finishAvailable = try typelessFinishButton() != nil
        return "Typeless 控制检查：录音条页面 \(pages.count) 个；完成按钮\(finishAvailable ? "可直接操作" : "当前未暴露（空闲时可能不显示）")。开始仍使用已配置热键。"
    }

    func describeFocus(bundleID: String) throws -> String {
        try requireTrust()
        let running = try frontApplication(bundleID: bundleID)
        let app = application(running.processIdentifier)
        guard let focused = element(app, kAXFocusedUIElementAttribute) else {
            return "\(bundleID)：没有 AX 聚焦元素"
        }
        // Exclude values, labels and titles: diagnostic output must not contain user text.
        return "\(bundleID)：role=\(role(focused))，pid=\(running.processIdentifier)，composer=\(composerScore(focused, bundleID: bundleID) > 0)；滚动检查：\(lastScrollDiagnostic)"
    }

    private var runningTypeless: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: typelessBundleID).first
    }

    private let recordingLabels = ["recording", "listening", "recording…", "listening…", "正在录音", "录音中", "正在聆听"]

    private func requireTrust() throws {
        if !isTrusted { throw AccessibilityBridgeError.permissionRequired }
    }

    private func frontApplication(bundleID: String) throws -> NSRunningApplication {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID else {
            throw AccessibilityBridgeError.targetChanged("指定应用不在前台")
        }
        return app
    }

    private func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        return app
    }

    private func prepareElectronAccessibility(_ app: AXUIElement, pid: pid_t,
                                              expectedWindow: ForegroundWindowHandle) throws {
        guard accessibilityPreparation[pid] == nil else { return }
        // Public integration documented by Electron for third-party assistive applications.
        // This is performed only after a user action targets an authorized supported app.
        accessibilityPreparationRequestedAt[pid] = ProcessInfo.processInfo.systemUptime
        let result = try performInForeground(window: expectedWindow) {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        switch result {
        case .success, .attributeUnsupported, .notImplemented:
            accessibilityPreparation[pid] = result
        default:
            // Do not cache transient failures. The coordinator retries discovery with a limit.
            throw AccessibilityBridgeError.operation("初始化应用可访问性", result)
        }
    }

    private func verifyIdentity(_ handle: ComposerHandle, requireFocused: Bool, allowBackgroundWindow: Bool = false, checkExposure: Bool = true) throws {
        let app = application(handle.pid)
        let focusedWindow = element(app, kAXFocusedWindowAttribute)
            ?? (allowBackgroundWindow ? element(app, kAXMainWindowAttribute) : nil)
        guard same(focusedWindow, handle.window),
              belongs(handle.element, to: handle.window), composerScore(handle.element, bundleID: handle.bundleID) > 0 else {
            throw AccessibilityBridgeError.targetChanged("窗口或输入框不再匹配")
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(handle.element, &pid) == .success, pid == handle.pid,
              string(handle.window, kAXTitleAttribute) == handle.windowTitle,
              documentIdentity(handle.window) == handle.document,
              contextIdentity(handle.context) == handle.contextIdentity else {
            throw AccessibilityBridgeError.targetChanged("窗口内容或会话标识变化")
        }
        try rejectFocusedModal(app: app, window: handle.window)
        try rejectModalAncestors(of: handle.element, window: handle.window)
        if checkExposure { try requireExposed(handle.element, in: handle.window) }
        if requireFocused && !same(element(app, kAXFocusedUIElementAttribute), handle.element) {
            throw AccessibilityBridgeError.targetChanged("输入焦点不在已确认的聊天输入框")
        }
    }

    private func verifyVoiceDestination(_ handle: ComposerHandle, typeless: NSRunningApplication, checkExposure: Bool = true) throws {
        guard NSRunningApplication(processIdentifier: typeless.processIdentifier)?.bundleIdentifier == typelessBundleID else {
            throw AccessibilityBridgeError.targetChanged("Typeless 进程已变化")
        }
        // Provider ownership does not permit operations while its HUD or another app is foreground.
        try verifyForegroundWindow(foregroundWindow(of: handle))
        try verifyIdentity(handle, requireFocused: true, checkExposure: checkExposure)
        try verifyForegroundWindow(foregroundWindow(of: handle))
    }

    private func rejectFocusedModal(app: AXUIElement, window: AXUIElement) throws {
        guard bool(window, kAXModalAttribute) != true, elements(window, "AXSheets").isEmpty else {
            throw AccessibilityBridgeError.modalPresent
        }
        if let focused = element(app, kAXFocusedUIElementAttribute) {
            try rejectModalAncestors(of: focused, window: window)
        }
    }

    private func rejectModalAncestors(of element: AXUIElement, window: AXUIElement) throws {
        for node in [element] + ancestors(of: element, until: window) {
            if role(node) == kAXSheetRole || string(node, kAXSubroleAttribute) == kAXDialogSubrole || bool(node, kAXModalAttribute) == true {
                throw AccessibilityBridgeError.modalPresent
            }
        }
    }

    private func verifyForScroll(_ handle: ComposerHandle, now: TimeInterval) throws {
        try requireTrust()
        let running = try frontApplication(bundleID: handle.bundleID)
        let app = application(handle.pid)
        var pid: pid_t = 0
        guard running.processIdentifier == handle.pid,
              same(element(app, kAXFocusedWindowAttribute), handle.window),
              AXUIElementGetPid(handle.element, &pid) == .success, pid == handle.pid,
              belongs(handle.element, to: handle.window),
              composerScore(handle.element, bundleID: handle.bundleID) > 0,
              string(handle.window, kAXTitleAttribute) == handle.windowTitle,
              documentIdentity(handle.window) == handle.document,
              contextIdentity(handle.context) == handle.contextIdentity else {
            throw AccessibilityBridgeError.targetChanged("滚动目标窗口或输入框变化")
        }
        try rejectFocusedModal(app: app, window: handle.window)
        try rejectModalAncestors(of: handle.element, window: handle.window)
    }

    private func composerEvidence(_ node: AXUIElement) -> ComposerEvidence {
        ComposerEvidence(
            role: role(node), identifier: string(node, kAXIdentifierAttribute),
            title: string(node, kAXTitleAttribute), description: string(node, kAXDescriptionAttribute),
            label: string(node, "AXLabel"), placeholder: string(node, kAXPlaceholderValueAttribute),
            isEnabled: bool(node, kAXEnabledAttribute), isHidden: bool(node, "AXHidden")
        )
    }

    private func composerScore(_ node: AXUIElement, bundleID: String? = nil) -> Int {
        let evidence = composerEvidence(node)
        if bundleID == codexBundleID {
            return CodexComposerSelection.isEligible(evidence, isEditable: isSettable(node, kAXValueAttribute)) ? 100 : 0
        }
        return ComposerSemantics.score(evidence)
    }

    /// Discovery recognizes only known composers. Local ownership is stricter:
    /// any second editable input, even with an unknown name, makes the pairing
    /// ambiguous. Read-only transcript text cannot create a false second editor.
    private func localComposerInputs(in scope: AXUIElement, handle: ComposerHandle,
                                      checkExposure: Bool = true) throws -> [AXUIElement] {
        let nodes = try searchControls(in: scope, key: "AXTextFieldSearchKey", limit: 9)
        guard handle.bundleID == codexBundleID else { return nodes.filter { composerScore($0) > 0 } }
        var seen: [AXUIElement] = []
        var inputs: [AXUIElement] = []
        for node in nodes {
            guard !seen.contains(where: { CFEqual($0, node) }) else { continue }
            seen.append(node)
            guard belongs(node, to: scope), belongs(node, to: handle.window) else {
                throw AccessibilityBridgeError.targetChanged("局部输入控件不再属于原区域")
            }
            if bool(node, kAXEnabledAttribute) != false, bool(node, "AXHidden") != true,
               isSettable(node, kAXValueAttribute) {
                if checkExposure {
                    guard isExposed(node, in: handle.window) else { continue }
                } else {
                    try requireNativeVisibility(node, in: handle.window, component: "局部输入控件", hitTest: false)
                }
                inputs.append(node)
            }
        }
        return inputs
    }

    private func isSendButton(_ node: AXUIElement, bundleID: String) -> Bool {
        guard role(node) == kAXButtonRole, bool(node, "AXHidden") != true,
              actions(node).contains(kAXPressAction) else { return false }
        let identifier = string(node, kAXIdentifierAttribute).lowercased()
        if bundleID == codexBundleID {
            return CodexControlSemantics.isSend(role: role(node),
                names: [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"].map { string(node, $0) },
                identifier: identifier, hidden: bool(node, "AXHidden"))
        }
        return ["send", "send message", "send prompt", "发送", "发送消息", "提交消息"].contains(label(node))
            || ["send-button", "send-message-button", "composer-submit-button"].contains(identifier)
    }

    private enum MessageNodeKind: Equatable { case messages, primaryPane, sideChat, excluded, container, scrollArea, webRoot, leaf }

    /// Unlike the general optional-attribute helpers, a failed structure read must not become
    /// a missing sibling/pane or cause traversal through an unrecognized transcript boundary.
    private func messageStructureString(_ node: AXUIElement, _ name: String, required: Bool = false) throws -> String {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(node, name as CFString, &raw)
        if !required && (status == .attributeUnsupported || status == .noValue) { return "" }
        guard status == .success, let text = raw as? String, !required || !text.isEmpty else {
            throw ScrollFailure(stage: "structure", reason: "structureUnreadable",
                                details: "attribute=\(name), AX=\(status.rawValue)")
        }
        return text
    }

    private func messageStructureFailure(_ error: Error) -> ScrollFailure {
        (error as? ScrollFailure) ?? ScrollFailure(stage: "structure", reason: "structureUnreadable")
    }

    /// Only inspect structural labels; text controls and transcript descendants are terminal.
    /// Compare each attribute independently because Electron can put the name in AXDescription.
    private func messageNodeKind(_ node: AXUIElement) throws -> MessageNodeKind {
        let type = try messageStructureString(node, kAXRoleAttribute, required: true)
        if type == "AXWebArea" { return .webRoot }
        guard [kAXGroupRole, kAXListRole, kAXScrollAreaRole, kAXSplitGroupRole, "AXLayoutArea"].contains(type) else { return .leaf }
        let names = try [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel", kAXIdentifierAttribute]
            .map { try messageStructureString(node, $0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if names.contains("chat messages") { return .messages }
        if names.contains("primary pane") { return .primaryPane }
        if names.contains("side chat") { return .sideChat }
        let excluded = ["sidebar", "history", "sessions", "conversations", "session list", "conversation list", "侧栏", "会话列表", "历史记录"]
        if names.contains(where: { name in excluded.contains(where: name.contains) }) { return .excluded }
        return type == kAXScrollAreaRole ? .scrollArea : .container
    }

    private func messagePanePath(composer: AXUIElement, window: AXUIElement) throws -> [AXUIElement]? {
        var path: [AXUIElement] = []
        for ancestor in ancestors(of: composer, until: window) {
            if CFEqual(ancestor, window) { break }
            let kind = try messageNodeKind(ancestor)
            if kind == .webRoot { break }
            path.append(ancestor)
            if kind == .primaryPane || kind == .sideChat { return path }
            if kind == .messages || kind == .excluded { return nil }
        }
        return nil
    }

    private func messageViewport(_ target: MessageAreaTarget, handle: ComposerHandle) -> Result<CGRect, ScrollFailure> {
        if handle.bundleID == codexBundleID { return codexMessageViewport(target, handle: handle) }
        let kind: MessageNodeKind
        let currentPane: AXUIElement?
        let areaPane: AXUIElement?
        do {
            kind = try messageNodeKind(target.area)
            currentPane = try messagePanePath(composer: handle.element, window: handle.window)?.last
            areaPane = try messagePanePath(composer: target.area, window: handle.window)?.last
        } catch { return .failure(messageStructureFailure(error)) }
        let semanticsMatch: Bool
        switch target.kind {
        case .namedMessages: semanticsMatch = kind == .messages
        case .anonymousScrollArea: semanticsMatch = kind == .scrollArea
        }
        guard semanticsMatch, bool(target.area, "AXHidden") != true,
              bool(target.pane, "AXHidden") != true, bool(handle.element, "AXHidden") != true,
              belongs(target.area, to: handle.window), belongs(target.area, to: target.pane),
              !belongs(target.area, to: handle.element), !belongs(handle.element, to: target.area),
              let currentPane, let areaPane,
              CFEqual(currentPane, target.pane), CFEqual(areaPane, target.pane) else {
            return .failure(ScrollFailure(stage: "validation", reason: "staleOrWrongPane"))
        }
        guard let area = frame(target.area), let pane = frame(target.pane),
              let window = frame(handle.window), let composer = frame(handle.element) else {
            return .failure(ScrollFailure(stage: "geometry", reason: "frameUnavailable"))
        }
        return MessageViewport.resolve(area: area, pane: pane, window: window,
                                       composer: composer, kind: target.kind)
            .mapError { ScrollFailure(stage: "geometry", reason: $0.rawValue,
                                     details: "area=\(rectDiagnostic(area)), pane=\(rectDiagnostic(pane)), window=\(rectDiagnostic(window)), input=\(rectDiagnostic(composer))") }
    }

    private func rectDiagnostic(_ rect: CGRect) -> String {
        "[\(rect.origin.x.rounded()),\(rect.origin.y.rounded()),\(rect.size.width.rounded()),\(rect.size.height.rounded())]"
    }

    private func scrollError(_ failure: ScrollFailure) -> AccessibilityBridgeError {
        lastScrollDiagnostic = failure.diagnostic
        return failure.error
    }

    private func resolveScrollTarget(_ handle: ComposerHandle, now: TimeInterval) throws -> (MessageAreaTarget, CGRect) {
        if let cache = scrollDiscovery, isSameComposer(cache.handle, handle) {
            let validation = cache.result.flatMap { target in messageViewport(target, handle: handle).map { (target, $0) } }
            switch validation {
            case .success(let value): return value
            case .failure(var failure):
                if now - cache.attemptedAt < 0.75 {
                    failure.details += failure.details.isEmpty ? "retryThrottled=true" : ", retryThrottled=true"
                    throw scrollError(failure)
                }
            }
        }
        // A failed/invalid cached area can recover within the same verified voice destination.
        // Discovery is rate-limited independently from the 30 Hz scrolling event stream.
        let result = messageAreaNear(handle: handle)
        scrollDiscovery = (handle, now, result)
        switch result {
        case .failure(let failure): throw scrollError(failure)
        case .success(let target):
            switch messageViewport(target, handle: handle) {
            case .failure(let failure): throw scrollError(failure)
            case .success(let viewport):
                lastScrollDiagnostic = "stage=ready, \(target.discoveryDiagnostic), viewport=\(rectDiagnostic(viewport))"
                return (target, viewport)
            }
        }
    }

    private func isNearComposer(_ button: AXUIElement, composer: AXUIElement) -> Bool {
        guard let rect = frame(button), let input = frame(composer), rect.width > 0, rect.height > 0 else { return false }
        let dx = max(0, max(rect.minX - input.maxX, input.minX - rect.maxX))
        let dy = max(0, max(rect.minY - input.maxY, input.minY - rect.maxY))
        return hypot(dx, dy) <= 250 && abs(rect.midY - input.midY) <= max(input.height, 100)
    }

    private func throttledScrollAction(_ node: AXUIElement, action: String, amount: Double,
                                      handle: ComposerHandle) throws -> Bool {
        let interval = 0.08 / max(0.1, abs(amount))
        guard Date().timeIntervalSince(lastScrollAction) >= interval else { return false }
        try performInForeground(handle) {
            try check(AXUIElementPerformAction(node, action as CFString), "滚动消息")
        }
        lastScrollAction = Date()
        return true
    }

    private func scrollPoint(in target: MessageAreaTarget, viewport: CGRect, handle: ComposerHandle) throws -> CGPoint {
        let area = target.area
        let system = AXUIElementCreateSystemWide()
        var outside = 0
        var nested = 0
        var unreadable = 0
        for fraction in [0.35, 0.55, 0.75] {
            let point = CGPoint(x: viewport.minX + viewport.width * 0.6,
                                y: viewport.minY + viewport.height * fraction)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { unreadable += 1; continue }
            var pid: pid_t = 0
            guard AXUIElementGetPid(hit, &pid) == .success, pid == handle.pid,
                  belongs(hit, to: area), !belongs(hit, to: handle.element) else { outside += 1; continue }
            var ancestor: AXUIElement? = hit
            for _ in 0..<96 {
                guard let current = ancestor else { break }
                if CFEqual(current, area) {
                    lastScrollDiagnostic = "stage=ready, \(target.discoveryDiagnostic), viewport=\(rectDiagnostic(viewport)), hitTest=verified"
                    return point
                }
                guard let type = try? messageStructureString(current, kAXRoleAttribute, required: true) else {
                    unreadable += 1
                    break
                }
                if type == kAXScrollAreaRole {
                    nested += 1
                    break // Nested code block/table: do not scroll it by accident.
                }
                ancestor = element(current, kAXParentAttribute)
            }
        }
        throw scrollError(ScrollFailure(stage: "hitTest", reason: "noVerifiedPoint",
                                       details: "outside=\(outside), nested=\(nested), unreadable=\(unreadable), viewport=\(rectDiagnostic(viewport))"))
    }

    @discardableResult
    private func postTypelessShortcut(_ shortcut: VoiceShortcut, expectedWindow: ForegroundWindowHandle,
                                     beforePosting: (() throws -> Bool)? = nil) throws -> Bool {
        // Freeze the complete chord, including modifier sides and releases, before posting.
        // The event plan preserves the timing required by Typeless's key-state coalescing.
        guard let source = eventSource else {
            throw AccessibilityBridgeError.unavailable("无法创建 Typeless 快捷键事件。")
        }
        let planned = try ShortcutEventPlan.steps(for: shortcut)
        let events = try planned.map { step -> CGEvent in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: step.keyCode, keyDown: step.isKeyDown) else {
                throw AccessibilityBridgeError.unavailable("无法创建 Typeless 快捷键事件。")
            }
            if step.isModifier { event.type = .flagsChanged }
            event.flags = CGEventFlags(rawValue: step.flags)
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            return event
        }
        let now = ProcessInfo.processInfo.systemUptime
        let remainingDebounce = 0.35 - (now - lastTypelessShortcut)
        if remainingDebounce > 0 { Thread.sleep(forTimeInterval: remainingDebounce) }
        // A previous stop may finish during the debounce delay. Never retry using stale evidence.
        if let beforePosting, try !beforePosting() { return false }
        var held = Set<CGKeyCode>()
        var postedKeyDown = false
        defer {
            if postedKeyDown { lastTypelessShortcut = ProcessInfo.processInfo.systemUptime }
        }
        do {
            for (event, step) in zip(events, planned) {
                if step.isKeyDown {
                    // A new key-down must still belong to this invocation's foreground window.
                    try performInForeground(window: expectedWindow) {
                        event.post(tap: .cghidEventTap)
                        held.insert(step.keyCode)
                        postedKeyDown = true
                    }
                } else if held.contains(step.keyCode) {
                    // Always balance an already posted down, even if focus moved meanwhile.
                    event.post(tap: .cghidEventTap)
                    held.remove(step.keyCode)
                }
                if step.delayAfter > 0 { Thread.sleep(forTimeInterval: step.delayAfter) }
            }
        } catch {
            // Stop the shortcut, but never strand a modifier or key in the down state.
            // These are releases of this sequence only, not a new command to the new target.
            for (event, step) in zip(events, planned) where !step.isKeyDown && held.contains(step.keyCode) {
                event.post(tap: .cghidEventTap)
                held.remove(step.keyCode)
                if step.delayAfter > 0 { Thread.sleep(forTimeInterval: step.delayAfter) }
            }
            throw error
        }
        return true
    }

    private func postKey(_ code: CGKeyCode, flags: CGEventFlags, pid: pid_t?,
                         expectedWindow: ForegroundWindowHandle, beforePosting: (() -> Void)? = nil) throws {
        guard let source = eventSource,
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw AccessibilityBridgeError.unavailable("无法创建快捷键事件。")
        }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        up.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        try performInForeground(window: expectedWindow) {
            beforePosting?()
            if let pid { down.postToPid(pid); up.postToPid(pid) }
            else { down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap) }
        }
    }

    /// An empty result means a completely read native shell, never a failed AX read.
    /// Stop at renderer roots; do not enumerate conversation contents.
    private func existingWebRoots(in window: AXUIElement, pid: pid_t) throws -> [AXUIElement] {
        var queue = [window]
        var cursor = 0
        var seen: [AXUIElement] = []
        var roots: [AXUIElement] = []
        while cursor < queue.count {
            let node = queue[cursor]
            cursor += 1
            if seen.contains(where: { CFEqual($0, node) }) { continue }
            seen.append(node)
            var nodePID: pid_t = 0
            try check(AXUIElementGetPid(node, &nodePID), "读取 应用窗口外壳进程")
            guard nodePID == pid else {
                throw AccessibilityBridgeError.targetChanged("应用窗口外壳的进程身份变化")
            }
            var rawRole: CFTypeRef?
            try check(AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &rawRole),
                      "读取 应用窗口外壳类型")
            guard let nodeRole = rawRole as? String, !nodeRole.isEmpty else {
                throw AccessibilityBridgeError.unavailable("应用窗口外壳类型无效。")
            }
            if nodeRole == "AXWebArea" { roots.append(node); continue }
            var count: CFIndex = 0
            let countResult = AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count)
            if countResult == .attributeUnsupported || countResult == .noValue { continue }
            try check(countResult, "读取 应用窗口外壳子项数量")
            guard count >= 0, count <= 256 - queue.count else {
                throw AccessibilityBridgeError.unavailable("应用窗口外壳结构不受支持。")
            }
            if count == 0 { continue }
            var rawChildren: CFArray?
            try check(AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, count, &rawChildren),
                      "读取 应用窗口外壳子项")
            guard let children = rawChildren as? [AXUIElement], children.count == count else {
                throw AccessibilityBridgeError.unavailable("应用窗口外壳子项无效。")
            }
            var checkedCount: CFIndex = 0
            try check(AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &checkedCount),
                      "复核 应用窗口外壳子项数量")
            guard checkedCount == count else {
                throw AccessibilityBridgeError.targetChanged("应用窗口外壳子项在读取时变化")
            }
            queue.append(contentsOf: children)
        }
        return roots
    }

    /// Traverse the native window shell only, stopping at each renderer root.
    private func webRoots(in window: AXUIElement) throws -> [AXUIElement] {
        var queue = [window]
        var cursor = 0
        var seen: [AXUIElement] = []
        var roots: [AXUIElement] = []
        while cursor < queue.count {
            let node = queue[cursor]
            cursor += 1
            if seen.contains(where: { CFEqual($0, node) }) { continue }
            seen.append(node)
            if role(node) == "AXWebArea" { roots.append(node); continue }
            let children = elements(node, kAXChildrenAttribute)
            guard queue.count + children.count <= 256 else {
                throw AccessibilityBridgeError.unavailable("应用窗口外壳结构不受支持。")
            }
            queue.append(contentsOf: children)
        }
        guard !roots.isEmpty else {
            throw AccessibilityBridgeError.unavailable("聊天页面尚未就绪。")
        }
        return roots
    }

    /// Renderer-side indexed search: results contain controls, never a copied transcript tree.
    private func searchControls(in root: AXUIElement, key: String, limit: Int,
                                allowUnsupported: Bool = false) throws -> [AXUIElement] {
        let parameters: [String: Any] = [
            // Use the existing AX protocol values: SDKs differ in whether their
            // AppKit Swift imports expose the NSAccessibilitySearch* globals.
            "AXSearchKey": [key],
            "AXResultsLimit": limit,
            "AXDirection": "AXDirectionNext",
            "AXVisibleOnly": true
        ]
        var raw: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            root, "AXUIElementsForSearchPredicate" as CFString, parameters as CFDictionary, &raw)
        if allowUnsupported && [.parameterizedAttributeUnsupported, .attributeUnsupported, .notImplemented].contains(result) {
            return []
        }
        try check(result, "检索聊天输入控件")
        guard let nodes = raw as? [AXUIElement] else {
            throw AccessibilityBridgeError.unavailable("应用未返回有效的控件检索结果。")
        }
        do { try ClaudeComposerSelection.validateResultCount(count: nodes.count, limit: limit) }
        catch { throw AccessibilityBridgeError.unavailable("可见控件过多，无法唯一确认目标。") }
        let expectedRoles = key == "AXTextFieldSearchKey" ? [kAXTextAreaRole, kAXTextFieldRole]
            : [kAXButtonRole, kAXPopUpButtonRole, kAXCheckBoxRole]
        guard nodes.allSatisfy({ expectedRoles.contains(role($0)) }) else {
            throw AccessibilityBridgeError.unavailable("应用未按指定类型检索控件。")
        }
        return nodes
    }

    private func ancestors(of node: AXUIElement, until boundary: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var current = element(node, kAXParentAttribute)
        for _ in 0..<96 {
            guard let parent = current, !result.contains(where: { CFEqual($0, parent) }) else { break }
            result.append(parent)
            if CFEqual(parent, boundary) { break }
            current = element(parent, kAXParentAttribute)
        }
        return result
    }

    private func isExposed(_ node: AXUIElement, in window: AXUIElement,
                           fractions: [CGFloat] = [0.5, 0.2, 0.8]) -> Bool {
        lastExposureDiagnostic = "stage=boundsUnavailable"
        guard bool(node, "AXHidden") != true, let bounds = frame(node), let windowBounds = frame(window) else { return false }
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height,
               windowBounds.minX, windowBounds.minY, windowBounds.width, windowBounds.height].allSatisfy({ $0.isFinite }) else { return false }
        let rect = bounds.intersection(windowBounds)
        guard !rect.isNull, rect.width > 2, rect.height > 2 else { return false }
        var targetPID: pid_t = 0
        guard AXUIElementGetPid(node, &targetPID) == .success else {
            lastExposureDiagnostic = "stage=targetPIDUnavailable"
            return false
        }
        var observations: [String] = []
        let system = AXUIElementCreateSystemWide()
        for fraction in fractions {
            let point = CGPoint(x: rect.minX + rect.width * fraction, y: rect.midY)
            var hit: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
            guard status == .success, let hit else {
                observations.append("AX=\(status.rawValue),relation=noHit")
                continue
            }
            var hitPID: pid_t = 0
            let pidMatches = AXUIElementGetPid(hit, &hitPID) == .success && hitPID == targetPID
            let windowMatches = belongs(hit, to: window)
            let exact = CFEqual(hit, node)
            let descendant = !exact && belongs(hit, to: node)
            let ancestor = !exact && !descendant && belongs(node, to: hit)
            let relation = exact ? "exact" : (descendant ? "descendant" : (ancestor ? "ancestor" : "unrelated"))
            // Fixed structural roles only; never include labels, titles or text values.
            let rawRole = role(hit)
            let safeRole = ["AXApplication", "AXWindow", "AXGroup", "AXWebArea", "AXButton", "AXCheckBox",
                            "AXImage", "AXStaticText", "AXTextArea", "AXTextField", "AXScrollArea"].contains(rawRole) ? rawRole : "other"
            observations.append("AX=0,relation=\(relation),pid=\(pidMatches),window=\(windowMatches),role=\(safeRole)")
            lastExposureDiagnostic = "stage=hit, targetSize=\(bounds.width.rounded())x\(bounds.height.rounded()), samples=[\(observations.joined(separator: ";"))]"
            if pidMatches && windowMatches && (exact || descendant) { return true }
        }
        lastExposureDiagnostic = "stage=hit, targetSize=\(bounds.width.rounded())x\(bounds.height.rounded()), samples=[\(observations.joined(separator: ";"))]"
        return false
    }

    private func requireExposed(_ node: AXUIElement, in window: AXUIElement) throws {
        guard isExposed(node, in: window) else {
            throw AccessibilityBridgeError.unavailable("目标控件被遮挡或尚未显示，请关闭覆盖它的窗口。")
        }
    }

    private func requireNativeVisibility(_ node: AXUIElement, in window: AXUIElement,
                                         component: String, hitTest: Bool) throws {
        guard bool(node, "AXHidden") != true, let bounds = frame(node), let windowBounds = frame(window),
              [bounds.minX, bounds.minY, bounds.width, bounds.height,
               windowBounds.minX, windowBounds.minY, windowBounds.width, windowBounds.height]
                .allSatisfy({ $0.isFinite }),
              bounds.width > 2, bounds.height > 2, windowBounds.width > 2, windowBounds.height > 2 else {
            throw AccessibilityBridgeError.unavailable("\(component)：控件隐藏或几何范围无效。")
        }
        let visible = bounds.intersection(windowBounds)
        guard !visible.isNull, visible.width > 2, visible.height > 2 else {
            throw AccessibilityBridgeError.unavailable("\(component)：控件不在原窗口可见范围内。")
        }
        if hitTest && !isExposed(node, in: window) {
            throw AccessibilityBridgeError.unavailable("\(component)：未确认精确命中（\(lastExposureDiagnostic)）。")
        }
    }

    /// Walk only sibling branches on the composer's path to its selected pane. Wrappers may
    /// be arbitrarily deep within the unchanged total 128-node budget. Message/scroll regions
    /// are terminal: their contents, text values and code blocks are never enumerated.
    private func isCodexConversationRegion(_ node: AXUIElement) -> Bool {
        CodexControlSemantics.isConversationRegion(role: role(node),
            names: [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"].map { string(node, $0) },
            hidden: bool(node, "AXHidden"))
    }

    private func codexMessageViewport(_ target: MessageAreaTarget,
                                      handle: ComposerHandle) -> Result<CGRect, ScrollFailure> {
        // Default layout includes the composer footer in the named Conversation
        // region; compact layout puts that footer beside it under one local owner.
        guard isCodexConversationRegion(target.area),
              belongs(target.area, to: target.pane), belongs(handle.element, to: target.pane),
              belongs(target.pane, to: handle.window), !belongs(target.area, to: handle.element),
              bool(target.pane, "AXHidden") != true,
              let area = frame(target.area), let pane = frame(target.pane),
              let window = frame(handle.window), let composer = frame(handle.element) else {
            return .failure(ScrollFailure(stage: "validation", reason: "codexConversationChanged"))
        }
        return MessageViewport.resolve(area: area, pane: pane, window: window,
            composer: composer, kind: .namedMessages)
            .mapError { ScrollFailure(stage: "geometry", reason: $0.rawValue) }
    }

    private func codexMessageAreaNear(_ handle: ComposerHandle) -> Result<MessageAreaTarget, ScrollFailure> {
        let path = ancestors(of: handle.element, until: handle.window)
        let containingRegions = path.filter { isCodexConversationRegion($0) }
        if containingRegions.count > 1 {
            return .failure(ScrollFailure(stage: "discovery", reason: "ambiguousCodexConversation"))
        }
        if let area = containingRegions.first {
            var target = MessageAreaTarget(area: area, pane: area, kind: .namedMessages)
            if case .failure(let error) = codexMessageViewport(target, handle: handle) { return .failure(error) }
            target.discoveryDiagnostic = "adapter=codex, kind=conversationAncestor"
            return .success(target)
        }
        // Compact layout: only sibling branches of the captured editor path, with
        // a shared 96-node budget. Named regions are terminal; never walk their text.
        var child = handle.element
        var visited = 0
        for owner in path.prefix(10) {
            guard !CFEqual(owner, handle.window), role(owner) != "AXWebArea" else { break }
            do {
                guard try messageNodeKind(owner) == .container else { break }
                let children: [AXUIElement]
                switch messageChildren(owner, limit: 96 - visited) {
                case .failure(let error): return .failure(error)
                case .success(let result): children = result
                }
                guard children.contains(where: { CFEqual($0, child) }) else {
                    return .failure(ScrollFailure(stage: "discovery", reason: "composerPathChanged"))
                }
                var queue = children.filter { !CFEqual($0, child) }
                visited += children.count
                var cursor = 0
                var regions: [AXUIElement] = []
                while cursor < queue.count {
                    let node = queue[cursor]
                    cursor += 1
                    if isCodexConversationRegion(node) { regions.append(node); continue }
                    let kind = try messageNodeKind(node)
                    guard kind == .container, bool(node, "AXHidden") != true else { continue }
                    switch messageChildren(node, limit: 96 - visited) {
                    case .failure(let error): return .failure(error)
                    case .success(let descendants):
                        visited += descendants.count
                        queue.append(contentsOf: descendants)
                    }
                }
                guard regions.count <= 1 else {
                    return .failure(ScrollFailure(stage: "discovery", reason: "ambiguousCodexConversation"))
                }
                if let area = regions.first {
                    // Another editor under this owner makes the pairing ambiguous.
                    let editors = try localComposerInputs(in: owner, handle: handle)
                    guard editors.count == 1, same(editors.first, handle.element) else {
                        return .failure(ScrollFailure(stage: "discovery", reason: "ambiguousCodexComposer"))
                    }
                    var target = MessageAreaTarget(area: area, pane: owner, kind: .namedMessages)
                    if case .failure(let error) = codexMessageViewport(target, handle: handle) { return .failure(error) }
                    target.discoveryDiagnostic = "adapter=codex, kind=conversationSibling, visited=\(visited)"
                    return .success(target)
                }
            } catch { return .failure(messageStructureFailure(error)) }
            child = owner
        }
        return .failure(ScrollFailure(stage: "discovery", reason: "codexConversationUnavailable"))
    }

    private func messageAreaNear(handle: ComposerHandle) -> Result<MessageAreaTarget, ScrollFailure> {
        if handle.bundleID == codexBundleID { return codexMessageAreaNear(handle) }
        let selectedPath: [AXUIElement]?
        do { selectedPath = try messagePanePath(composer: handle.element, window: handle.window) }
        catch { return .failure(messageStructureFailure(error)) }
        guard let path = selectedPath, let pane = path.last else {
            return .failure(ScrollFailure(stage: "discovery", reason: "selectedPaneUnavailable"))
        }
        let limit = 128
        var seen = [handle.element] + path
        var queue: [(AXUIElement, Int)] = []
        var visited = seen.count
        var maxDepth = 0
        var named: [MessageAreaTarget] = []
        var anonymous: [MessageAreaTarget] = []
        var rejectedAnonymous = 0
        var lastGeometryReason = "none"
        func summary() -> String {
            "visited=\(visited), scheduled=\(seen.count), maxDepth=\(maxDepth), named=\(named.count), anonymous=\(anonymous.count), rejectedAnonymous=\(rejectedAnonymous), lastGeometry=\(lastGeometryReason)"
        }
        func failed(_ failure: ScrollFailure) -> Result<MessageAreaTarget, ScrollFailure> {
            var failure = failure
            failure.details = summary() + (failure.details.isEmpty ? "" : ", " + failure.details)
            return .failure(failure)
        }
        var childOnPath = handle.element
        for parent in path {
            let children: [AXUIElement]
            switch messageChildren(parent, limit: limit - seen.count + 1) {
            case .failure(let failure): return failed(failure)
            case .success(let value): children = value
            }
            guard children.contains(where: { CFEqual($0, childOnPath) }) else {
                return failed(ScrollFailure(stage: "discovery", reason: "composerPathChanged"))
            }
            for child in children where !CFEqual(child, childOnPath) {
                if seen.contains(where: { CFEqual($0, child) }) { continue }
                guard seen.count < limit else {
                    return failed(ScrollFailure(stage: "discovery", reason: "budgetExceeded"))
                }
                seen.append(child)
                queue.append((child, 1))
            }
            childOnPath = parent
        }
        var cursor = 0
        while cursor < queue.count {
            let (node, depth) = queue[cursor]
            cursor += 1
            visited += 1
            maxDepth = max(maxDepth, depth)
            guard bool(node, "AXHidden") != true else { continue }
            let kind: MessageNodeKind
            do { kind = try messageNodeKind(node) }
            catch { return failed(messageStructureFailure(error)) }
            switch kind {
            case .messages:
                named.append(MessageAreaTarget(area: node, pane: pane, kind: .namedMessages))
                continue
            case .sideChat, .primaryPane, .excluded, .webRoot, .leaf:
                continue
            case .scrollArea:
                let target = MessageAreaTarget(area: node, pane: pane, kind: .anonymousScrollArea)
                switch messageViewport(target, handle: handle) {
                case .success: anonymous.append(target)
                case .failure(let failure):
                    if failure.stage == "structure" || failure.reason == "frameUnavailable" { return failed(failure) }
                    rejectedAnonymous += 1
                    lastGeometryReason = failure.reason
                }
                continue
            case .container: break
            }
            let children: [AXUIElement]
            switch messageChildren(node, limit: limit - seen.count) {
            case .failure(let failure): return failed(failure)
            case .success(let value): children = value
            }
            for child in children {
                if seen.contains(where: { CFEqual($0, child) }) { continue }
                guard seen.count < limit else {
                    return failed(ScrollFailure(stage: "discovery", reason: "budgetExceeded"))
                }
                seen.append(child)
                queue.append((child, depth + 1))
            }
        }
        // A named container is stronger evidence than anonymous geometry. Multiple named
        // regions are ambiguous even if one currently has an unusable/offscreen viewport.
        guard named.count <= 1, !named.isEmpty || anonymous.count <= 1 else {
            return failed(ScrollFailure(stage: "discovery", reason: "ambiguousAreas"))
        }
        guard var target = named.first ?? anonymous.first else {
            return failed(ScrollFailure(stage: "discovery", reason: "noEligibleArea"))
        }
        if case .failure(let failure) = messageViewport(target, handle: handle) { return failed(failure) }
        target.discoveryDiagnostic = summary() + (named.isEmpty ? ", kind=anonymous" : ", kind=named")
        return .success(target)
    }

    /// Bound the child-reference read itself, not just the subsequent walk. Attribute errors
    /// and a changing child count mean discovery is incomplete, never a verified unique match.
    private func messageChildren(_ node: AXUIElement, limit: Int) -> Result<[AXUIElement], ScrollFailure> {
        var count: CFIndex = 0
        let status = AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count)
        if status == .attributeUnsupported || status == .noValue { return .success([]) }
        guard status == .success, count >= 0 else {
            return .failure(ScrollFailure(stage: "discovery", reason: "childrenUnreadable", details: "AX=\(status.rawValue)"))
        }
        guard count <= max(0, limit) else {
            return .failure(ScrollFailure(stage: "discovery", reason: "budgetExceeded", details: "childCount=\(count)"))
        }
        if count == 0 { return .success([]) }
        var raw: CFArray?
        let copied = AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, count, &raw)
        guard copied == .success, let children = raw as? [AXUIElement] else {
            return .failure(ScrollFailure(stage: "discovery", reason: "childrenUnreadable", details: "AX=\(copied.rawValue)"))
        }
        var checkedCount: CFIndex = 0
        guard children.count == count,
              AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &checkedCount) == .success,
              checkedCount == count else {
            return .failure(ScrollFailure(stage: "discovery", reason: "childrenChanged"))
        }
        return .success(children)
    }

    private func descendants(_ root: AXUIElement) throws -> [AXUIElement] {
        var output: [AXUIElement] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var seen: [CFHashCode: [AXUIElement]] = [:]
        while let (node, depth) = stack.popLast() {
            let hash = CFHash(node)
            if seen[hash]?.contains(where: { CFEqual($0, node) }) == true { continue }
            seen[hash, default: []].append(node)
            output.append(node)
            // Container names do not establish that their descendants lack a composer or dialog.
            // Keep the walk complete and bounded instead of pruning by display labels.
            var rawChildren: CFTypeRef?
            let childResult = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &rawChildren)
            guard childResult == .success || childResult == .attributeUnsupported || childResult == .noValue else {
                throw AccessibilityBridgeError.operation("读取界面树", childResult)
            }
            let children = (rawChildren as? [AXUIElement]) ?? []
            if output.count > 2_400 || (depth >= 96 && !children.isEmpty) {
                throw AccessibilityBridgeError.unavailable("AX 界面树超过安全扫描范围，不能排除歧义。")
            }
            stack.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return output
    }

    private func belongs(_ child: AXUIElement, to ancestor: AXUIElement) -> Bool {
        if CFEqual(child, ancestor) { return true }
        if role(ancestor) == kAXWindowRole, same(element(child, kAXWindowAttribute), ancestor) { return true }
        var parent = element(child, kAXParentAttribute)
        for _ in 0..<96 {
            guard let node = parent else { return false }
            if CFEqual(node, ancestor) { return true }
            parent = element(node, kAXParentAttribute)
        }
        return false
    }

    private func documentIdentity(_ window: AXUIElement) -> String {
        if let value = attribute(window, kAXDocumentAttribute) { return String(describing: value) }
        return ""
    }

    private func conversationContext(of composer: AXUIElement, window: AXUIElement) -> AXUIElement {
        var current = element(composer, kAXParentAttribute)
        for _ in 0..<96 {
            guard let node = current else { break }
            if role(node) == "AXWebArea" { return node }
            if CFEqual(node, window) { break }
            current = element(node, kAXParentAttribute)
        }
        return window
    }

    private func contextIdentity(_ node: AXUIElement) -> String {
        let url = attribute(node, "AXURL").map { String(describing: $0) } ?? ""
        return url + "\n" + string(node, kAXTitleAttribute) + "\n" + string(node, kAXDescriptionAttribute)
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

    private func selectedRange(_ node: AXUIElement) -> CFRange? {
        guard let value = attribute(node, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
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
            if !value.isEmpty { return value.lowercased() }
        }
        return ""
    }

    private func same(_ lhs: AXUIElement?, _ rhs: AXUIElement) -> Bool {
        lhs.map { CFEqual($0, rhs) } ?? false
    }

    private func actions(_ node: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(node, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private func isSettable(_ node: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(node, name as CFString, &result) == .success && result.boolValue
    }

    private func check(_ error: AXError, _ operation: String) throws {
        if error != .success { throw AccessibilityBridgeError.operation(operation, error) }
    }
}
