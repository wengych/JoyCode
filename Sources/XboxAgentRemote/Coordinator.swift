import AppKit
import Combine
import RemoteCore

extension AgentID {
    var name: String { self == .chatGPT ? "ChatGPT / Codex" : "Claude" }
    var bundleID: String { self == .chatGPT ? "com.openai.codex" : "com.anthropic.claudefordesktop" }
    static var supportedAgents: [AgentID] { [.claude, .chatGPT] }
    // Voice/foreground support does not validate saved-session deep links.
    static var bookmarkAgents: [AgentID] { [.claude] }
    static func from(bundleID: String?) -> AgentID? {
        supportedAgents.first { $0.bundleID == bundleID }
    }
}

enum ShortcutRecordingScope: Identifiable, Equatable {
    case global
    case application(AgentID)

    var id: String {
        switch self {
        case .global: return "global"
        case .application(let agent): return agent.bundleID
        }
    }
    var title: String {
        switch self {
        case .global: return "全局默认"
        case .application(let agent): return agent.name
        }
    }
}

@MainActor
final class Coordinator: ObservableObject {
    let controller = ControllerService()
    private let bridge = AccessibilityBridge()
    private let menuNavigator = ClaudeMenuNavigator()
    private let codexMenuNavigator = CodexMenuNavigator()
    private let hud = StatusHUD()
    @Published private(set) var configuration = RemoteConfiguration.defaults
    @Published private(set) var state = RemoteState() {
        didSet { if state.voicePhase == .uncertain { bridge.resetScrollMotion() } }
    }
    @Published private(set) var selectedAgent: AgentID = .claude
    @Published private(set) var isEnabled = false
    @Published private(set) var hasAccessibility = false
    @Published private(set) var isBusy = false {
        didSet { if isBusy { bridge.resetScrollMotion() } }
    }
    @Published private(set) var status = "诊断模式：按手柄可检查输入，尚未控制其他 App"
    @Published private(set) var retainedDraft = ""
    @Published private(set) var retainedDraftLabel = ""
    @Published private(set) var recentEvents: [String] = []
    @Published private(set) var shortcutRecordingScope: ShortcutRecordingScope?
    private var handle: ComposerHandle?
    private var transcriptionTask: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var scrollBlocked = false {
        didSet { if scrollBlocked { bridge.resetScrollMotion() } }
    }
    private var scrollGestureBundleID: String?
    private var scrollHandle: ComposerHandle?
    private var lastScrollError: String?
    // Preserve the last nonzero path across center callbacks and opening the diagnostic UI.
    private var scrollNonzeroReceivedCount: UInt64 = 0
    private var scrollBridgeCallCount: UInt64 = 0
    private var scrollBridgeReturnedCount: UInt64 = 0
    private var lastNonzeroScrollValue = 0.0
    private var lastNonzeroScrollAt: TimeInterval?
    private var scrollDispatchDiagnostic = "stage=notReceived"
    private var operationGeneration: UInt = 0
    private var busyOperations = OperationLeaseSet()
    private var cancelNeedsConfirmation = false
    private var ownedVoiceBackend: VoiceBackend?
    private var voiceBaseline: String?
    private var lastSendAttempt = Date.distantPast
    private var submissionGuard = SubmissionAttemptGuard()
    private var submittedHandles: [String: ComposerHandle] = [:]
    private var submissionObservationTasks: [String: Task<Void, Never>] = [:]
    private let configurationKey = "remote.configuration.v1"
    private let eventTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var voiceLabel: String {
        switch state.voicePhase {
        case .idle: return "待命"
        case .recording: return "已请求录音"
        case .transcribing: return "等待文字"
        case .uncertain: return "状态待确认"
        }
    }
    var voiceBackendLabel: String {
        ownedVoiceBackend?.displayName
            ?? (try? configuration.resolveVoiceBackend(forBundleID: selectedAgent.bundleID).displayName)
            ?? "语音来源配置无效"
    }
    var voiceTargetName: String {
        if state.isTargetLocked, let handle { return agentName(in: handle) }
        return selectedAgent.name
    }
    var targetLabel: String {
        let title = configuration.sessions.first { $0.id == state.selectedSessionID }?.title
        return "\(selectedAgent.name) · \(title ?? "当前屏幕会话")"
    }
    var inputConfigRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.lastPathComponent == "InputConfig.app"
        }
    }
    var isRecordingShortcut: Bool { shortcutRecordingScope != nil }
    var canChangeTarget: Bool { !state.isTargetLocked && !isBusy && !isRecordingShortcut }
    var canEditShortcuts: Bool { canChangeTarget }
    var canActivateTarget: Bool {
        isEnabled && hasAccessibility && !inputConfigRunning && canChangeTarget
    }
    var canReturnToCurrentAgent: Bool {
        isEnabled && hasAccessibility && !inputConfigRunning && !isBusy && !isRecordingShortcut
            && state.isTargetLocked && handle?.bundleID == selectedAgent.bundleID
    }

    init() {
        if let value = UserDefaults.standard.string(forKey: "remote.selectedAgent"),
           let agent = AgentID(rawValue: value), AgentID.supportedAgents.contains(agent) {
            selectedAgent = agent
        }
        if let data = UserDefaults.standard.data(forKey: configurationKey) {
            do { configuration = try JSONDecoder().decode(RemoteConfiguration.self, from: data) }
            catch { status = "会话配置无法读取，请重新登记；原数据未覆盖" }
        }
        hasAccessibility = bridge.isTrusted
        controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }.store(in: &subscriptions)
        controller.onAction = { [weak self] action in
            MainActor.assumeIsolated { self?.receiveControllerAction(action) }
        }
        controller.onScroll = { [weak self] value in
            MainActor.assumeIsolated { self?.scroll(value) }
        }
        controller.onDisconnect = { [weak self] in
            MainActor.assumeIsolated { self?.disconnected() }
        }
        controller.start()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        hasAccessibility = bridge.isTrusted
        if !hasAccessibility && isEnabled { disable(reason: "辅助功能权限已失效，遥控已停用") }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func enable() {
        guard !isRecordingShortcut else { report("请先保存或取消快捷键录制"); return }
        refreshPermissions()
        guard hasAccessibility else { report("先在系统设置中为 JoyCode 开启辅助功能权限"); return }
        guard !inputConfigRunning else { report("InputConfig 仍在运行；先退出它，避免一次按键触发两次"); return }
        guard !state.isTargetLocked else { report("请先确认语音已停止，再复位状态"); return }
        isEnabled = true
        controller.enabled = true
        report("遥控已启用 · X 语音 / A 发送 / B 取消")
    }

    func quitInputConfigAndEnable() async {
        guard !state.isTargetLocked else { report("请先结束当前语音操作"); return }
        let generation = operationGeneration
        for app in NSWorkspace.shared.runningApplications where app.bundleURL?.lastPathComponent == "InputConfig.app" {
            _ = app.terminate()
        }
        for _ in 0..<20 {
            guard generation == operationGeneration, !Task.isCancelled else { return }
            if !inputConfigRunning { enable(); return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard generation == operationGeneration, !Task.isCancelled else { return }
        report("InputConfig 尚未退出，请在它的菜单中退出后重试")
    }

    private func beginBusyOperation() -> UUID {
        let token = busyOperations.begin()
        isBusy = busyOperations.isBusy
        return token
    }

    private func endBusyOperation(_ token: UUID) {
        busyOperations.end(token)
        isBusy = busyOperations.isBusy
    }

    private func clearScrollTarget() {
        bridge.resetScrollMotion()
        scrollHandle = nil
        scrollGestureBundleID = nil
        lastScrollError = nil
        scrollBlocked = true
    }

    /// Retire every waiter before another operation can take ownership of busy state.
    private func invalidatePendingOperations() {
        operationGeneration &+= 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        submissionObservationTasks.values.forEach { $0.cancel() }
        submissionObservationTasks.removeAll()
        busyOperations.invalidate()
        isBusy = busyOperations.isBusy
        clearScrollTarget()
    }

    /// Only call after a confirmed result, or proof that no native request was issued.
    private func clearVoiceTracking() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        bridge.forgetTypelessOwnership()
        bridge.forgetNativeDictationOwnership()
        ownedVoiceBackend = nil
        voiceBaseline = nil
        cancelNeedsConfirmation = false
        handle = nil
        clearScrollTarget()
    }

    private func interruptVoiceTracking() {
        guard state.isTargetLocked else { return }
        if ownedVoiceBackend == .nativeDictation && !bridge.hasNativeDictationOwnership {
            // Native ownership is installed immediately before AXPress. Unlike the
            // Typeless path, its absence proves that this start never reached the app.
            state.confirmVoiceStopped()
            clearVoiceTracking()
        } else {
            state.markUncertain()
        }
    }

    private func reportNativeEndingFailure(_ error: Error, generation: UInt,
                                            expectedWindow: ForegroundWindowHandle,
                                            cancelling: Bool) {
        guard generation == operationGeneration else { return }
        if ownedVoiceBackend == .nativeDictation, state.voicePhase == .recording,
           let original = handle {
            do {
                try validateOrdinaryWindow(expectedWindow, action: cancelling ? .cancel : .voice)
                if try bridge.canRetryNativeEnding(in: original) {
                    report("尚未发出\(cancelling ? "取消" : "结束")请求，原录音仍在进行；可按 \(cancelling ? "B" : "X") 重试：\(error.localizedDescription)", showHUD: true)
                    return
                }
            } catch { /* Unconfirmed state must remain locked; never retry automatically. */ }
        }
        state.markUncertain()
        report(error.localizedDescription, showHUD: true)
    }

    func disable(reason: String = "遥控已停用，仍可查看手柄输入") {
        invalidatePendingOperations()
        controller.enabled = false
        isEnabled = false
        interruptVoiceTracking()
        report(reason)
    }

    func confirmStopped() {
        invalidatePendingOperations()
        state.confirmVoiceStopped()
        try? useVisibleSession()
        clearVoiceTracking()
        report("已按你的确认复位；下一次 X 会重新校验输入框")
    }

    private func ordinaryAction(_ action: ControllerAction) -> ForegroundAction? {
        switch action {
        case .voice: return .voice
        case .send: return .send
        case .cancel: return .cancel
        case .previousSession, .nextSession: return .session
        case .selectClaude, .activateCodex: return nil
        }
    }

    private func validateOrdinaryWindow(_ window: ForegroundWindowHandle, action: ForegroundAction) throws {
        _ = try ForegroundActionPolicy.resolve(action: action, foregroundBundleID: window.bundleID,
                                               voicePhase: state.voicePhase, ownedBundleID: handle?.bundleID)
        try bridge.verifyForegroundWindow(window)
        if state.isTargetLocked {
            guard let handle, window.matches(handle) else { throw RemoteCoreError.targetMismatch }
        }
    }

    private func captureOrdinaryWindow(_ action: ForegroundAction) throws -> ForegroundWindowHandle {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Resolve before AX access: unsupported foreground apps are never inspected or activated.
        _ = try ForegroundActionPolicy.resolve(action: action, foregroundBundleID: bundleID,
                                               voicePhase: state.voicePhase, ownedBundleID: handle?.bundleID)
        let window = try bridge.captureForegroundWindow(bundleID: bundleID)
        try validateOrdinaryWindow(window, action: action)
        return window
    }

    /// Capture at the button edge, before scheduling async work. No title or draft is logged.
    private func receiveControllerAction(_ action: ControllerAction) {
        guard isEnabled, controller.isConnected, !isRecordingShortcut else { return }
        let front = NSWorkspace.shared.frontmostApplication
        recordEvent("手柄动作=\(action)，前台=\(front?.bundleIdentifier ?? "none")，pid=\(front?.processIdentifier ?? 0)，语音=\(state.voicePhase)")
        guard !inputConfigRunning else { disable(reason: "检测到 InputConfig，已停用遥控，避免重复触发"); return }
        guard !isBusy else { report("正在处理上一次操作，请稍候"); return }
        do {
            let window = try ordinaryAction(action).map { try captureOrdinaryWindow($0) }
            if let window { recordEvent("按键目标 window=\(window.windowIdentity)，pid=\(window.pid)") }
            let generation = operationGeneration
            let phase = state.voicePhase
            Task { @MainActor [weak self] in
                guard let self, generation == self.operationGeneration, phase == self.state.voicePhase else { return }
                await self.perform(action, expectedWindow: window)
            }
        } catch { report(error.localizedDescription, showHUD: true) }
    }

    private func perform(_ action: ControllerAction, expectedWindow: ForegroundWindowHandle?) async {
        guard isEnabled, controller.isConnected, !isRecordingShortcut else { return }
        guard !inputConfigRunning else { disable(reason: "检测到 InputConfig，已停用遥控，避免重复触发"); return }
        guard !isBusy else { report("正在处理上一次操作，请稍候"); return }
        if let ordinary = ordinaryAction(action) {
            do {
                guard let expectedWindow else { throw ForegroundActionPolicyError.targetUnavailable }
                try validateOrdinaryWindow(expectedWindow, action: ordinary)
            } catch { report(error.localizedDescription, showHUD: true); return }
        }
        switch action {
        case .voice: if let expectedWindow { await toggleVoice(in: expectedWindow) }
        case .send: if let expectedWindow { await sendDraft(in: expectedWindow) }
        case .cancel: if let expectedWindow { await cancelVoice(in: expectedWindow) }
        case .selectClaude: await selectAgent(.claude)
        case .activateCodex: await activateCodex()
        case .previousSession: if let expectedWindow { await stepSession(-1, in: expectedWindow) }
        case .nextSession: if let expectedWindow { await stepSession(1, in: expectedWindow) }
        }
    }

    /// Settings actions obey the same foreground rule; only explicit activation controls switch apps.
    func voiceFromSettings(cancel: Bool = false) async {
        guard isEnabled, hasAccessibility, !isRecordingShortcut, !isBusy, !inputConfigRunning else { return }
        do {
            let window = try captureOrdinaryWindow(cancel ? .cancel : .voice)
            if cancel { await cancelVoice(in: window) } else { await toggleVoice(in: window) }
        } catch { report(error.localizedDescription, showHUD: true) }
    }

    private func rememberDraft() {
        guard let handle, let text = try? bridge.draft(in: handle), !text.isEmpty else { return }
        retainedDraft = text
        retainedDraftLabel = targetLabel
    }

    /// An explicit shoulder action may clear an obsolete uncertainty lock, but only
    /// by reading the owned window that is already frontmost. Never activate to probe.
    private func reconcileBeforeExplicitActivation() async -> Bool {
        guard state.voicePhase == .uncertain, ownedVoiceBackend == .nativeDictation,
              !isBusy, !isRecordingShortcut, isEnabled, hasAccessibility, bridge.isTrusted,
              !inputConfigRunning, let original = handle else { return true }
        let generation = operationGeneration
        do {
            try bridge.verifyForegroundWindow(bridge.foregroundWindow(of: original))
            if try await reconcileNativeIdle() { return true }
            return generation == operationGeneration
        } catch is CancellationError { return false }
        catch {
            guard generation == operationGeneration else { return false }
            recordEvent("激活前未能确认原生听写空闲，保留锁定：\(error.localizedDescription)")
            return true
        }
    }

    private func returnToOwnedAgent(_ agent: AgentID) async {
        guard agent == selectedAgent else { report("录音或转写期间不能切换 Agent", showHUD: true); return }
        guard !isBusy else { report("正在打开目标，请稍候"); return }
        guard isEnabled else { report("请先启用遥控，再返回原会话"); return }
        guard hasAccessibility, bridge.isTrusted else { report("请先为 JoyCode 开启辅助功能权限"); return }
        guard !inputConfigRunning else { report("InputConfig 仍在运行；先退出它，避免重复触发"); return }
        let generation = operationGeneration
        if await returnToLockedTarget(), generation == operationGeneration, state.voicePhase == .uncertain,
           ownedVoiceBackend == .nativeDictation {
            do {
                if !(try await reconcileNativeIdle()) {
                    report("已返回原会话；原生听写仍未确认空闲，请先结束录音，再按 X 检查", showHUD: true)
                }
            } catch is CancellationError { }
            catch {
                guard generation == operationGeneration else { return }
                report("无法核验原生听写：\(error.localizedDescription)；可按 B 进入手动复位确认", showHUD: true)
            }
        }
    }

    func selectAgent(_ agent: AgentID) async {
        guard !isRecordingShortcut else { report("快捷键录制期间遥控暂停"); return }
        guard AgentID.supportedAgents.contains(agent) else { report("该 Agent 尚未适配"); return }
        // Codex activation intentionally leaves its current input focus unchanged.
        if agent == .chatGPT { await activateCodex(); return }
        guard await reconcileBeforeExplicitActivation() else { return }
        if state.isTargetLocked {
            await returnToOwnedAgent(agent)
            return
        }
        guard canChangeTarget else { report("录音或转写期间不能切换 Agent", showHUD: true); return }
        guard canActivateTarget else { report("请先启用遥控，再激活 \(agent.name)"); return }
        rememberDraft()
        selectedAgent = agent
        rememberSelectedAgent()
        await activate(agent, session: nil)
    }

    /// Explicit activation only; ordinary controls capture the foreground separately.
    func activateCodex() async {
        guard !isRecordingShortcut else { report("快捷键录制期间遥控暂停"); return }
        guard await reconcileBeforeExplicitActivation() else { return }
        if state.isTargetLocked {
            await returnToOwnedAgent(.chatGPT)
            return
        }
        guard !isBusy else { report("正在打开目标，请稍候"); return }
        guard canActivateTarget, bridge.isTrusted else { report("请先启用遥控，再激活 Codex"); return }
        let generation = operationGeneration
        let bundleID = AgentID.chatGPT.bundleID
        scrollBlocked = true
        scrollHandle = nil
        scrollGestureBundleID = nil
        handle = nil
        let busyLease = beginBusyOperation()
        defer { endBusyOperation(busyLease) }
        do {
            try checkOperation(generation, requireEnabled: true)
            // Invalidate cached send readiness while keeping saved bookmarks and actual drafts.
            try useVisibleSession()
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw RemoteError.message("未找到 Codex，请先安装或打开 Codex")
            }
            let openConfiguration = NSWorkspace.OpenConfiguration()
            openConfiguration.activates = true
            let running = try await NSWorkspace.shared.openApplication(at: appURL, configuration: openConfiguration)
            // Opening is a request; verify the actual foreground process without inspecting its UI.
            for _ in 0..<20 {
                try checkOperation(generation, requireEnabled: true)
                if let front = NSWorkspace.shared.frontmostApplication,
                   front.bundleIdentifier == bundleID, front.processIdentifier == running.processIdentifier {
                    selectedAgent = .chatGPT
                    rememberSelectedAgent()
                    report("Codex 已激活 · LB 返回 Claude")
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try checkOperation(generation, requireEnabled: true)
            throw RemoteError.message("已请求激活 Codex，但尚未确认它已到前台；请再按 RB")
        } catch is CancellationError { }
        catch {
            guard generation == operationGeneration else { return }
            report(error.localizedDescription, showHUD: true)
        }
    }

    @discardableResult
    private func returnToLockedTarget() async -> Bool {
        guard let handle, handle.bundleID == selectedAgent.bundleID else {
            report("原会话窗口记录已丢失；请检查录音后确认复位", showHUD: true)
            return false
        }
        let generation = operationGeneration
        let busyLease = beginBusyOperation()
        defer { endBusyOperation(busyLease) }
        do {
            try checkOperation(generation, requireEnabled: true)
            try await bridge.restoreOriginalWindow(handle)
            try checkOperation(generation, requireEnabled: true)
            switch state.voicePhase {
            case .recording:
                report("已返回原会话；录音状态保持锁定 · X 结束 / B 取消")
            case .transcribing:
                report("已返回原会话；仍在等待转写，请确认文字落地")
            case .uncertain:
                report(cancelNeedsConfirmation
                    ? "已返回原会话；确认录音已关闭后，再按 B 复位"
                    : "已返回原会话；X 检查原生空闲状态，B 进入手动复位确认")
            case .idle:
                report("已返回原会话；语音状态已恢复待命")
            }
            return true
        } catch is CancellationError { }
        catch {
            guard generation == operationGeneration else { return false }
            report(error.localizedDescription, showHUD: true)
        }
        return false
    }

    func selectSession(_ session: SavedSession) async {
        guard AgentID.bookmarkAgents.contains(session.agent) else { report("目前仅支持打开 Claude 普通 Chat 保存入口；旧 Codex 入口仍保留"); return }
        guard canChangeTarget else { report("先结束或取消语音，再切换会话", showHUD: true); return }
        guard canActivateTarget else { report("请先启用遥控，再打开 Claude 会话"); return }
        rememberDraft()
        selectedAgent = session.agent
        rememberSelectedAgent()
        await activate(session.agent, session: session)
    }

    private func activate(_ agent: AgentID, session: SavedSession?) async {
        guard AgentID.supportedAgents.contains(agent), canActivateTarget else { return }
        if let session, !AgentID.bookmarkAgents.contains(session.agent) { return }
        let generation = operationGeneration
        scrollBlocked = true
        let busyLease = beginBusyOperation()
        defer { endBusyOperation(busyLease) }
        handle = nil
        do {
            let url: URL?
            if let session {
                url = try SessionDeepLink.validatedURL(for: session)
                try state.selectSession(session.id, configuration: &configuration)
            } else {
                url = nil
                try state.selectCurrentSession(for: agent, configuration: &configuration)
            }
            persist()
            try await bridge.activate(bundleID: agent.bundleID, url: url)
            try checkOperation(generation, requireEnabled: true)
            handle = try await awaitComposer(bundleID: agent.bundleID, generation: generation)
            if let session {
                report("已请求打开「\(session.title)」；确认屏幕会话后按 X 说话")
            } else {
                report("\(agent.name) 输入框已聚焦 · X 开始语音")
            }
        } catch is CancellationError { }
        catch {
            guard generation == operationGeneration else { return }
            report(error.localizedDescription, showHUD: true)
        }
    }

    private func stepSession(_ offset: Int, in expectedWindow: ForegroundWindowHandle) async {
        guard offset != 0 else { return }
        guard canChangeTarget else { report("语音进行中，会话已锁定", showHUD: true); return }
        guard canActivateTarget else { report("请先启用遥控"); return }
        // Session navigation follows the captured foreground app, never the remembered
        // voice target. Never activate another app as a navigation fallback.
        let front = NSWorkspace.shared.frontmostApplication
        let target: SessionNavigationTarget
        do {
            guard let resolved = try SessionNavigationTarget.resolve(
                foregroundBundleID: front?.bundleIdentifier, voicePhase: state.voicePhase) else {
                report("请先切到 Claude 或 ChatGPT / Codex，再用方向键切会话")
                return
            }
            target = resolved
        } catch { report(error.localizedDescription, showHUD: true); return }
        guard let front else { return }
        let generation = operationGeneration
        let busyLease = beginBusyOperation()
        defer { endBusyOperation(busyLease) }
        do {
            try checkOperation(generation, requireEnabled: true)
            try validateOrdinaryWindow(expectedWindow, action: .session)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier else {
                throw RemoteError.message("前台应用已改变，本次没有切换会话")
            }
            if let agent = AgentID.from(bundleID: expectedWindow.bundleID) {
                selectedAgent = agent
                rememberSelectedAgent()
            }
            let previous: ComposerHandle?
            if target == .claude {
                rememberDraft()
                previous = try? bridge.locateComposer(bundleID: target.bundleID)
            } else { previous = nil }
            handle = nil
            scrollHandle = nil
            scrollGestureBundleID = nil
            scrollBlocked = true
            try useVisibleSession()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier else {
                throw RemoteError.message("前台应用已改变，本次没有切换会话")
            }
            switch target {
            case .claude: try menuNavigator.stepSession(offset, expectedWindow: expectedWindow)
            case .codex:
                try codexMenuNavigator.stepSession(offset, expectedWindow: expectedWindow)
                report(offset < 0 ? "已请求 ChatGPT / Codex 切换上一侧边栏项目"
                                 : "已请求 ChatGPT / Codex 切换下一侧边栏项目")
                return
            }
            // The native menu action is issued once. Only wait for its result; never repeat it.
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(150))
                try checkOperation(generation, requireEnabled: true)
                try bridge.verifyForegroundWindow(expectedWindow)
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier else {
                    report("前台应用已改变，已停止检查会话切换结果")
                    return
                }
                let next: ComposerHandle
                do { next = try bridge.focusComposer(bundleID: target.bundleID, expectedWindow: expectedWindow) }
                catch {
                    guard isComposerNotReady(error) else { throw error }
                    continue
                }
                if let previous, bridge.isSameComposer(previous, next) { continue }
                handle = next
                report(offset < 0 ? "已切换到上一会话" : "已切换到下一会话")
                return
            }
            report("已请求 Claude 切换会话，尚未观察到会话变化；没有重复操作")
        } catch is CancellationError { }
        catch {
            guard generation == operationGeneration else { return }
            report(error.localizedDescription, showHUD: true)
        }
    }

    private func awaitComposer(bundleID: String, generation: UInt,
                               expectedWindow: ForegroundWindowHandle? = nil) async throws -> ComposerHandle {
        var lastError: Error?
        var captured = expectedWindow
        for _ in 0..<20 {
            try checkOperation(generation, requireEnabled: true)
            if let captured { try bridge.verifyForegroundWindow(captured) }
            do {
                if captured == nil { captured = try bridge.captureForegroundWindow(bundleID: bundleID) }
                return try bridge.focusComposer(bundleID: bundleID, expectedWindow: captured)
            }
            catch {
                guard isComposerNotReady(error) else { throw error }
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        try checkOperation(generation, requireEnabled: true)
        if let captured { try bridge.verifyForegroundWindow(captured) }
        throw lastError ?? RemoteError.message("目标输入框尚未就绪")
    }

    private func isComposerNotReady(_ error: Error) -> Bool {
        // A detected window change, modal, or ambiguous/failed mutation is terminal.
        // Do not resume the old request if the user happens to switch back later.
        guard let bridgeError = error as? AccessibilityBridgeError else { return false }
        if case .unavailable = bridgeError { return true }
        return false
    }

    private func checkOperation(_ generation: UInt, requireEnabled: Bool = false) throws {
        try Task.checkCancellation()
        guard generation == operationGeneration else { throw CancellationError() }
        if requireEnabled {
            guard isEnabled else { throw CancellationError() }
            guard bridge.isTrusted else {
                disable(reason: "辅助功能权限已失效，遥控已停用")
                throw CancellationError()
            }
            guard !inputConfigRunning else {
                disable(reason: "检测到 InputConfig，遥控已停用，避免重复触发")
                throw CancellationError()
            }
        }
    }

    private func rememberSelectedAgent() {
        UserDefaults.standard.set(selectedAgent.rawValue, forKey: "remote.selectedAgent")
    }

    private func agentName(in handle: ComposerHandle) -> String {
        AgentID.from(bundleID: handle.bundleID)?.name ?? "当前 Agent"
    }

    private func useVisibleSession() throws {
        // Clear only the current identity claim; keep the user's saved restore bookmark.
        var temporary = configuration
        try state.selectCurrentSession(for: selectedAgent, configuration: &temporary)
    }

    private func makeSnapshot(_ handle: ComposerHandle, text: String, stable: Bool, focused: Bool = true) -> ComposerSnapshot {
        ComposerSnapshot(target: ComposerTarget(
            sessionID: state.selectedSessionID,
            applicationBundleID: handle.bundleID,
            windowID: handle.windowIdentity,
            composerID: handle.composerIdentity
        ), text: text, isFocused: focused, isStable: stable)
    }

    /// Release an uncertainty lock only after repeated evidence from the exact owned
    /// native target. This action does not start another recording or approve a send.
    private func reconcileNativeIdle() async throws -> Bool {
        guard state.voicePhase == .uncertain, ownedVoiceBackend == .nativeDictation,
              let original = handle else { return false }
        let generation = operationGeneration
        let busyLease = beginBusyOperation()
        defer { endBusyOperation(busyLease) }
        var lastText: String?
        var stableSamples = 0
        for sampleIndex in 0..<12 {
            try checkOperation(generation, requireEnabled: true)
            guard state.voicePhase == .uncertain, ownedVoiceBackend == .nativeDictation,
                  let current = handle, bridge.isSameComposer(current, original) else {
                throw CancellationError()
            }
            guard let text = try bridge.nativeIdleDraft(in: original) else { return false }
            stableSamples = text == lastText ? stableSamples + 1 : 1
            lastText = text
            if stableSamples >= 5 {
                try checkOperation(generation, requireEnabled: true)
                try state.reconcileConfirmedNativeIdle(with: makeSnapshot(original, text: text, stable: true, focused: false))
                operationGeneration &+= 1
                clearVoiceTracking()
                report("已确认 \(agentName(in: original)) 原生听写空闲，草稿保留；已恢复待命，再按 X 开始")
                return true
            }
            if sampleIndex < 11 { try await Task.sleep(for: .milliseconds(250)) }
        }
        return false
    }

    private func toggleVoice(in expectedWindow: ForegroundWindowHandle) async {
        hud.hide()
        do { try validateOrdinaryWindow(expectedWindow, action: .voice) }
        catch { report(error.localizedDescription, showHUD: true); return }
        switch state.voicePhase {
        case .idle:
            let generation = operationGeneration
            let busyLease = beginBusyOperation()
            defer { endBusyOperation(busyLease) }
            do {
                let front = try ForegroundActionPolicy.resolve(action: .voice,
                    foregroundBundleID: expectedWindow.bundleID, voicePhase: state.voicePhase,
                    ownedBundleID: handle?.bundleID)
                selectedAgent = front
                rememberSelectedAgent()
                let next = try await awaitComposer(bundleID: expectedWindow.bundleID,
                    generation: generation, expectedWindow: expectedWindow)
                if next.bundleID == AgentID.chatGPT.bundleID {
                    recordEvent("输入框定位：\(bridge.lastComposerDiagnostic)")
                }
                try checkOperation(generation, requireEnabled: true)
                try validateOrdinaryWindow(expectedWindow, action: .voice)
                // A bookmark launch and an AX object are not proof of a conversation ID.
                // X explicitly acts on the visible composer; keep restore bookmarks separately.
                try useVisibleSession()
                // A local configuration error must remain editable; no voice request exists yet.
                let backend = try configuration.resolveVoiceBackend(forBundleID: next.bundleID)
                let shortcut = backend == .typeless
                    ? try configuration.resolveVoiceShortcut(forBundleID: next.bundleID) : nil
                if backend == .nativeDictation {
                    defer { if generation == operationGeneration { recordEvent("原生听写准备：\(bridge.lastNativeReadinessDiagnostic)") } }
                    try await bridge.awaitNativeDictationReadiness(in: next) {
                        try self.checkOperation(generation, requireEnabled: true)
                        try self.validateOrdinaryWindow(expectedWindow, action: .voice)
                    }
                }
                try checkOperation(generation, requireEnabled: true)
                try validateOrdinaryWindow(expectedWindow, action: .voice)
                // Read after readiness awaits: physical typing during preparation must
                // become part of the protected baseline, never an outdated comparison.
                let before = try bridge.draft(in: next)
                try state.begin(with: makeSnapshot(next, text: before, stable: false))
                handle = next
                ownedVoiceBackend = backend
                voiceBaseline = before
                do {
                    switch backend {
                    case .nativeDictation:
                        do {
                            defer { if generation == operationGeneration { recordEvent("原生开始动作：\(bridge.lastNativeActionDiagnostic)") } }
                            try await bridge.startNativeDictation(next, expectedDraft: before) {
                                try self.checkOperation(generation, requireEnabled: true)
                                try self.validateOrdinaryWindow(expectedWindow, action: .voice)
                            }
                        }
                        var started = false
                        var observationCounts: [String: Int] = [:]
                        defer {
                            if generation == operationGeneration {
                                let counts = observationCounts.keys.sorted().map { "\($0)=\(observationCounts[$0]!)" }.joined(separator: ",")
                                recordEvent("原生开始观察：\(counts)；\(bridge.lastNativeObservationDiagnostic)")
                            }
                        }
                        for _ in 0..<30 {
                            try await Task.sleep(for: .milliseconds(100))
                            try checkOperation(generation, requireEnabled: true)
                            let observation = try bridge.nativeDictationStatus(in: next)
                            observationCounts[observation.rawValue, default: 0] += 1
                            if observation == .recording {
                                started = true
                                break
                            }
                        }
                        if !started {
                            state.markUncertain()
                            if try await reconcileNativeIdle() { return }
                        }
                        guard started else { throw RemoteError.message("尚未确认原生听写开始，请检查 \(agentName(in: next))；不会重复点击或切换语音来源。") }
                    case .typeless:
                        try bridge.triggerTypeless(next, shortcut: shortcut)
                    case .unknown:
                        throw RemoteError.message("不支持的语音来源")
                    }
                }
                catch is CancellationError { throw CancellationError() }
                catch {
                    if generation == operationGeneration {
                        if backend == .nativeDictation && !bridge.hasNativeDictationOwnership {
                            // Validation failed before AXPress. Preserve the draft and
                            // allow retry instead of locking a recording that never began.
                            try state.cancelRecording(confirmed: true)
                            clearVoiceTracking()
                            throw RemoteError.message("原生听写未开始，未发出录音请求，可重试：\(error.localizedDescription)")
                        }
                        state.markUncertain()
                    }
                    throw error
                }
                report(backend == .nativeDictation
                    ? "\(agentName(in: next)) 原生听写中 · X 结束 / B 取消"
                    : "已请求 Typeless 开始 · X 结束 / B 取消")
            } catch is CancellationError {
                if generation == operationGeneration { interruptVoiceTracking() }
            }
            catch {
                guard generation == operationGeneration else { return }
                report(error.localizedDescription, showHUD: true)
            }
        case .recording:
            let generation = operationGeneration
            let busyLease = beginBusyOperation()
            defer { endBusyOperation(busyLease) }
            do {
                guard let handle else { throw RemoteError.message("语音目标已丢失") }
                if ownedVoiceBackend == .nativeDictation {
                    defer { if generation == operationGeneration { recordEvent("原生结束动作：\(bridge.lastNativeActionDiagnostic)") } }
                    try await bridge.stopNativeDictation(handle) {
                        try self.checkOperation(generation, requireEnabled: true)
                        try self.validateOrdinaryWindow(expectedWindow, action: .voice)
                    }
                }
                else { try bridge.triggerTypeless(handle) }
                try checkOperation(generation, requireEnabled: true)
                try state.stop()
                report("已请求结束：\(bridge.lastVoiceControl)。等待草稿，A 暂不发送")
                watchTranscription(handle, backend: ownedVoiceBackend ?? .typeless)
            } catch is CancellationError {
                if generation == operationGeneration { interruptVoiceTracking() }
            }
            catch {
                reportNativeEndingFailure(error, generation: generation,
                                          expectedWindow: expectedWindow, cancelling: false)
            }
        case .transcribing:
            do {
                if ownedVoiceBackend == .nativeDictation {
                    report("正在等待 \(voiceTargetName) 原生转写完成；不重复启动录音")
                } else if let handle, try bridge.retryStopIfStillRecording(handle) {
                    report("检测到 Typeless 仍在录音，已再次请求结束")
                } else {
                    report("等待转写；未确认仍在录音，因此不重复切换 Typeless")
                }
            } catch { state.markUncertain(); report(error.localizedDescription, showHUD: true) }
        case .uncertain:
            let generation = operationGeneration
            do {
                if try await reconcileNativeIdle() { return }
                try checkOperation(generation, requireEnabled: true)
                report("尚未确认听写空闲；请先结束录音，再按 X 检查，或按 B 进入手动复位确认", showHUD: true)
            } catch is CancellationError { }
            catch {
                guard generation == operationGeneration else { return }
                report("无法核验原生听写：\(error.localizedDescription)；可按 B 进入手动复位确认", showHUD: true)
            }
        }
    }

    private func watchTranscription(_ handle: ComposerHandle, backend: VoiceBackend) {
        transcriptionTask?.cancel()
        let generation = operationGeneration
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            var lastText: String?
            var stableSamples = 0
            for _ in 0..<180 {
                do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation() }
                catch { return }
                do {
                    try checkOperation(generation, requireEnabled: true)
                    guard state.voicePhase == .transcribing, ownedVoiceBackend == backend,
                          let current = self.handle, bridge.isSameComposer(current, handle) else { return }
                    let observedText = backend == .nativeDictation
                        ? try bridge.nativeTranscriptionDraft(in: handle)
                        : try bridge.transcriptionDraft(in: handle)
                    guard let text = observedText else {
                        lastText = nil
                        stableSamples = 0
                        continue
                    }
                    if text == lastText { stableSamples += 1 } else { lastText = text; stableSamples = 0 }
                    let snapshot = makeSnapshot(handle, text: text, stable: stableSamples >= 4)
                    if backend == .nativeDictation, stableSamples >= 4 {
                        try state.completeConfirmedDictation(with: snapshot)
                    } else {
                        state.observe(snapshot)
                    }
                    if state.voicePhase == .idle {
                        let unchanged = text == voiceBaseline
                        if backend == .nativeDictation && bridge.nativeCompletionRebuiltEditor {
                            // Completion text is safe to keep, but the old AX identity
                            // must not confer send readiness on the rebuilt editor.
                            try useVisibleSession()
                        }
                        clearVoiceTracking()
                        report(unchanged ? "听写已结束，没有新增文字" : "文字已出现并稳定；检查后按 A 发送")
                        return
                    }
                } catch is CancellationError { return }
                catch {
                    guard generation == operationGeneration, state.voicePhase == .transcribing else { return }
                    transcriptionTask = nil
                    state.markUncertain()
                    report("语音目标或输入框发生变化；已锁定后续操作：\(error.localizedDescription)", showHUD: true)
                    return
                }
            }
            guard generation == operationGeneration, state.voicePhase == .transcribing,
                  ownedVoiceBackend == backend,
                  let current = self.handle, bridge.isSameComposer(current, handle) else { return }
            transcriptionTask = nil
            state.markUncertain()
            report("未确认听写完成；请检查\(voiceBackendLabel)，手动停止后复位", showHUD: true)
        }
    }

    private func cancelVoice(in expectedWindow: ForegroundWindowHandle) async {
        do { try validateOrdinaryWindow(expectedWindow, action: .cancel) }
        catch { report(error.localizedDescription, showHUD: true); return }
        if state.voicePhase == .uncertain {
            if cancelNeedsConfirmation { confirmStopped(); return }
            let generation = operationGeneration
            do { if try await reconcileNativeIdle() { return } }
            catch is CancellationError { return }
            catch { recordEvent("手动复位前自动核验失败：\(error.localizedDescription)") }
            guard generation == operationGeneration, state.voicePhase == .uncertain else { return }
            cancelNeedsConfirmation = true
            report("请先确认录音及转写已停止；确认后再按 B 复位。当前草稿保留", showHUD: true)
            return
        }
        guard state.voicePhase == .recording, let handle else {
            report(state.voicePhase == .idle ? "当前没有本应用发起的录音"
                : "正在转写，暂不支持 B 取消；可在原 App 取消，遥控器会继续核验结束状态", showHUD: state.voicePhase != .idle)
            return
        }
        let generation = operationGeneration
        do {
            if ownedVoiceBackend == .nativeDictation {
                guard let baseline = voiceBaseline else { throw RemoteError.message("原生听写的草稿记录已丢失") }
                let busyLease = beginBusyOperation()
                defer { endBusyOperation(busyLease) }
                do {
                    defer { if generation == operationGeneration { recordEvent("原生取消动作：\(bridge.lastNativeActionDiagnostic)") } }
                    try await bridge.cancelNativeDictation(handle) {
                        try self.checkOperation(generation, requireEnabled: true)
                        try self.validateOrdinaryWindow(expectedWindow, action: .cancel)
                    }
                }
                var confirmedSamples = 0
                for _ in 0..<30 {
                    try await Task.sleep(for: .milliseconds(100))
                    try checkOperation(generation, requireEnabled: true)
                    if try bridge.nativeCancellationConfirmed(in: handle, baseline: baseline) {
                        confirmedSamples += 1
                        if confirmedSamples >= 3 {
                            try state.cancelRecording(confirmed: true)
                            if bridge.nativeCompletionRebuiltEditor { try useVisibleSession() }
                            clearVoiceTracking()
                            report("\(agentName(in: handle)) 原生听写已取消，原草稿保持不变")
                            return
                        }
                    } else { confirmedSamples = 0 }
                }
                try state.cancelRecording(confirmed: false)
                cancelNeedsConfirmation = true
                report("已请求取消；请检查 \(agentName(in: handle)) 录音与草稿，确认后再按 B 复位", showHUD: true)
                return
            }
            try bridge.cancelTypeless(handle)
            try state.cancelRecording(confirmed: false)
            cancelNeedsConfirmation = true
            report("取消请求已发出；确认 Typeless 录音已关闭后，再按 B 复位", showHUD: true)
        } catch is CancellationError {
            if generation == operationGeneration { interruptVoiceTracking() }
        }
        catch {
            reportNativeEndingFailure(error, generation: generation,
                                      expectedWindow: expectedWindow, cancelling: true)
        }
    }

    private func sendDraft(in expectedWindow: ForegroundWindowHandle) async {
        guard state.voicePhase == .idle else { report("录音或转写尚未完成，A 未发送，也不会排队", showHUD: true); return }
        guard Date().timeIntervalSince(lastSendAttempt) > 1.5 else { report("上一条发送刚触发，请先检查会话"); return }
        let generation = operationGeneration
        let busyLease = beginBusyOperation()
        defer { endBusyOperation(busyLease) }
        do {
            try validateOrdinaryWindow(expectedWindow, action: .send)
            let agent = try ForegroundActionPolicy.resolve(action: .send,
                foregroundBundleID: expectedWindow.bundleID, voicePhase: state.voicePhase,
                ownedBundleID: handle?.bundleID)
            let current = try bridge.focusComposer(bundleID: expectedWindow.bundleID, expectedWindow: expectedWindow)
            if current.bundleID == AgentID.chatGPT.bundleID {
                recordEvent("输入框定位：\(bridge.lastComposerDiagnostic)")
            }
            let agentChanged = selectedAgent != agent
            let composerChanged = handle.map { !bridge.isSameComposer($0, current) } ?? false
            let readyTargetChanged = state.readyDraft.map {
                $0.target != makeSnapshot(current, text: "", stable: false).target
            } ?? false
            selectedAgent = agent
            rememberSelectedAgent()
            if agentChanged || composerChanged || readyTargetChanged {
                self.handle = current
                try useVisibleSession()
                report("当前 \(agent.name) 输入框已变化；请检查草稿，再按 A 发送", showHUD: true)
                return
            }
            let text = try bridge.draft(in: current)
            let receiptTarget = submittedHandles.first { bridge.isSameComposer($0.value, current) }?.key
                ?? UUID().uuidString
            observeSubmissionDraft(target: receiptTarget, text: text)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                report("输入框为空，没有发送"); return
            }
            guard submissionGuard.permits(target: receiptTarget, text: text) else {
                report("已请求提交这份草稿，结果尚未确认；未重复发送，请先检查 Agent", showHUD: true)
                return
            }
            try await Task.sleep(for: .milliseconds(250))
            try checkOperation(generation, requireEnabled: true)
            try validateOrdinaryWindow(expectedWindow, action: .send)
            try bridge.verify(current)
            guard try bridge.draft(in: current) == text else {
                throw RemoteError.message("草稿仍在变化，请等文字稳定后再按 A")
            }
            let snapshot = makeSnapshot(current, text: text, stable: true)
            if state.readyDraft == nil { try state.acceptManualDraft(snapshot) }
            else { state.observe(snapshot) }
            _ = try state.validatedReadyDraft(for: snapshot)
            try validateOrdinaryWindow(expectedWindow, action: .send)
            try bridge.send(current, expectedDraft: text) {
                try self.checkOperation(generation, requireEnabled: true)
                // Consume and record immediately before AXPress, including requests
                // whose native result later times out. Preflight failure records none.
                _ = try self.state.consumeReadyDraft(for: snapshot)
                self.submissionGuard.recordDispatch(target: receiptTarget, text: text)
                self.submittedHandles[receiptTarget] = current
                self.lastSendAttempt = Date()
                self.observeSubmissionResult(in: current, target: receiptTarget, submittedText: text,
                                             generation: generation)
            }
            handle = current
            report("已点击当前输入框的发送按钮")
        } catch is CancellationError { }
        catch {
            guard generation == operationGeneration else { return }
            report(error.localizedDescription, showHUD: true)
        }
    }

    /// Observe acknowledgement without holding the controller busy or issuing another
    /// action. An unchanged/unknown result retains the duplicate guard across resets.
    private func observeSubmissionResult(in original: ComposerHandle, target: String,
                                          submittedText: String, generation: UInt) {
        submissionObservationTasks[target]?.cancel()
        submissionObservationTasks[target] = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<20 {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                    try checkOperation(generation, requireEnabled: true)
                    guard submittedHandles[target].map({ self.bridge.isSameComposer($0, original) }) == true else { return }
                    let currentText = try bridge.draft(in: original)
                    observeSubmissionDraft(target: target, text: currentText)
                    if currentText != submittedText { return }
                } catch { return }
            }
        }
    }

    private func observeSubmissionDraft(target: String, text: String) {
        submissionGuard.observe(target: target, text: text)
        if !submissionGuard.hasPending(target: target) {
            submittedHandles.removeValue(forKey: target)
            submissionObservationTasks.removeValue(forKey: target)?.cancel()
        }
    }

    private func scroll(_ value: Double) {
        guard value != 0 else {
            bridge.resetScrollMotion()
            scrollBlocked = false
            scrollGestureBundleID = nil
            scrollHandle = nil
            lastScrollError = nil
            return
        }
        scrollNonzeroReceivedCount &+= 1
        lastNonzeroScrollValue = value
        lastNonzeroScrollAt = ProcessInfo.processInfo.systemUptime
        guard !isRecordingShortcut else { bridge.resetScrollMotion(); scrollDispatchDiagnostic = "guard=shortcutRecording"; return }
        guard isEnabled else { bridge.resetScrollMotion(); scrollDispatchDiagnostic = "guard=disabled"; return }
        guard !isBusy else { bridge.resetScrollMotion(); scrollDispatchDiagnostic = "guard=busy"; return }
        guard !scrollBlocked else { bridge.resetScrollMotion(); scrollDispatchDiagnostic = "guard=blockedUntilCenter"; return }
        guard state.voicePhase != .uncertain else { bridge.resetScrollMotion(); scrollDispatchDiagnostic = "guard=voiceUncertain"; return }
        // ChatGPT hides its editor while dictating; scrolling resumes after the
        // original editable composer has returned and dictation is confirmed idle.
        guard !(state.voicePhase != .idle && ownedVoiceBackend == .nativeDictation
                && handle?.bundleID == AgentID.chatGPT.bundleID) else {
            bridge.resetScrollMotion()
            scrollDispatchDiagnostic = "guard=codexDictationActive"
            return
        }
        guard !inputConfigRunning else {
            bridge.resetScrollMotion()
            scrollDispatchDiagnostic = "guard=inputConfigRunning"
            disable(reason: "检测到 InputConfig，遥控已停用")
            return
        }
        guard let front = try? ForegroundActionPolicy.resolve(action: .scroll,
                foregroundBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                voicePhase: state.voicePhase, ownedBundleID: handle?.bundleID) else {
            bridge.resetScrollMotion()
            scrollDispatchDiagnostic = "guard=unsupportedForeground"
            if scrollGestureBundleID != nil { scrollBlocked = true }
            return
        }
        if let bundleID = scrollGestureBundleID, bundleID != front.bundleID {
            bridge.resetScrollMotion()
            scrollDispatchDiagnostic = "guard=gestureTargetChanged"
            scrollBlocked = true
            return
        }
        scrollGestureBundleID = front.bundleID
        guard !state.isTargetLocked || front == selectedAgent else {
            bridge.resetScrollMotion()
            scrollDispatchDiagnostic = "guard=lockedTargetMismatch"
            return
        }
        var deliveryStage = "selectingHandle"
        do {
            let target: ComposerHandle
            let source: String
            if state.isTargetLocked, let handle { target = handle; source = "lockedHandle" }
            else if let cached = scrollHandle { target = cached; source = "cachedHandle" }
            else {
                deliveryStage = "locatingComposer"
                scrollDispatchDiagnostic = "stage=locatingComposer"
                let window = try captureOrdinaryWindow(.scroll)
                target = try bridge.locateComposer(bundleID: front.bundleID)
                try validateOrdinaryWindow(window, action: .scroll)
                guard window.matches(target) else { throw RemoteCoreError.targetMismatch }
                scrollHandle = target
                source = "newHandle"
            }
            try validateOrdinaryWindow(bridge.foregroundWindow(of: target), action: .scroll)
            deliveryStage = "bridgeCall"
            scrollDispatchDiagnostic = "stage=bridgeCall, source=\(source)"
            scrollBridgeCallCount &+= 1
            try bridge.scroll(target, normalized: value)
            scrollBridgeReturnedCount &+= 1
            // A normal return can mean rate limiting; the bridge records actual delivery.
            scrollDispatchDiagnostic = "stage=bridgeReturned, source=\(source)"
        } catch {
            scrollDispatchDiagnostic = "stage=error, during=\(deliveryStage)"
            bridge.resetScrollMotion()
            scrollBlocked = true
            if lastScrollError != error.localizedDescription {
                lastScrollError = error.localizedDescription
                report("滚动停止：\(error.localizedDescription)", showHUD: true)
            }
        }
    }

    private func disconnected() {
        invalidatePendingOperations()
        interruptVoiceTracking()
        if state.isTargetLocked {
            report("手柄断开；请手动停止当前听写，再确认复位", showHUD: true)
        } else { report("手柄已断开；重连后需要先松开按键、摇杆回中") }
    }

    func addSession(agent: AgentID, title: String, link: String) -> Bool {
        guard AgentID.bookmarkAgents.contains(agent) else { report("目前仅支持登记 Claude 普通 Chat 保存入口"); return false }
        guard canChangeTarget else { report("请先结束当前操作，再登记会话"); return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { report("请填写会话名称"); return false }
        let session = SavedSession(agent: agent, title: title, deepLink: link.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            _ = try SessionDeepLink.validatedURL(for: session)
            guard !configuration.sessions.contains(where: { $0.deepLink == session.deepLink }) else { report("这个会话已经登记"); return false }
            configuration.sessions.append(session)
            persist()
            report("已登记「\(title)」；点击“打开”进入此会话")
            return true
        } catch RemoteCoreError.invalidDeepLink {
            report("仅接受 Claude 普通 Chat 链接：claude://claude.ai/chat/<ID>；暂不支持 Code 本地会话链接")
            return false
        } catch { report(error.localizedDescription); return false }
    }

    func removeSession(_ session: SavedSession) {
        guard canChangeTarget, AgentID.bookmarkAgents.contains(session.agent) else { return }
        configuration.sessions.removeAll { $0.id == session.id }
        if configuration.lastSessionIDs[session.agent.rawValue] == session.id {
            configuration.lastSessionIDs.removeValue(forKey: session.agent.rawValue)
        }
        if state.selectedSessionID == session.id { try? state.selectCurrentSession(for: session.agent, configuration: &configuration) }
        persist()
    }

    func moveSession(_ session: SavedSession, delta: Int) {
        guard canChangeTarget, AgentID.bookmarkAgents.contains(session.agent) else { return }
        let group = configuration.sessions.indices.filter { configuration.sessions[$0].agent == session.agent }
        guard let position = group.firstIndex(where: { configuration.sessions[$0].id == session.id }), group.indices.contains(position + delta) else { return }
        configuration.sessions.swapAt(group[position], group[position + delta])
        persist()
    }

    func copyRetainedDraft() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(retainedDraft, forType: .string)
        report("离开会话时的草稿已复制；请自行选择粘贴位置")
    }

    func inspectTarget() {
        do { report(try bridge.describeFocus(bundleID: selectedAgent.bundleID)) }
        catch { report(error.localizedDescription) }
    }

    func shortcut(for scope: ShortcutRecordingScope) -> VoiceShortcut {
        switch scope {
        case .global: return configuration.defaultVoiceShortcut
        case .application(let agent):
            return configuration.applicationProfiles[agent.bundleID]?.voiceShortcut ?? configuration.defaultVoiceShortcut
        }
    }

    func beginShortcutRecording(_ scope: ShortcutRecordingScope) {
        guard canEditShortcuts else { report("请先结束当前语音或目标操作，再录制快捷键"); return }
        if case .application(let agent) = scope, !AgentID.supportedAgents.contains(agent) { return }
        operationGeneration &+= 1
        shortcutRecordingScope = scope
        controller.enabled = false
        scrollBlocked = false
        scrollHandle = nil
        scrollGestureBundleID = nil
        hud.hide()
        report("正在录制\(scope.title)语音快捷键，手柄动作已暂停")
    }

    func saveRecordedShortcut(_ value: VoiceShortcut) {
        guard let scope = shortcutRecordingScope else { return }
        do {
            let shortcut = try value.validated()
            switch scope {
            case .global: configuration.defaultVoiceShortcut = shortcut
            case .application(let agent):
                var profile = configuration.applicationProfiles[agent.bundleID] ?? ApplicationProfile()
                profile.voiceShortcut = shortcut
                configuration.applicationProfiles[agent.bundleID] = profile
            }
            persist()
            endShortcutRecording()
            report("已保存\(scope.title)语音快捷键：\(shortcut.displayName)")
        } catch { report(error.localizedDescription) }
    }

    func cancelShortcutRecording() {
        guard isRecordingShortcut else { return }
        endShortcutRecording()
        report("已取消录制，原快捷键保持不变")
    }

    private func endShortcutRecording() {
        shortcutRecordingScope = nil
        guard isEnabled else { controller.enabled = false; return }
        guard bridge.isTrusted else {
            disable(reason: "辅助功能权限已失效，遥控保持停用")
            return
        }
        guard !inputConfigRunning else {
            disable(reason: "检测到 InputConfig，遥控保持停用，避免重复触发")
            return
        }
        // Re-enabling re-arms only released inputs, so keys held during capture cannot fire.
        controller.enabled = true
    }

    func inheritGlobalShortcut(for agent: AgentID) {
        guard canEditShortcuts, AgentID.supportedAgents.contains(agent) else { return }
        var profile = configuration.applicationProfiles[agent.bundleID] ?? ApplicationProfile()
        profile.voiceShortcut = nil
        configuration.applicationProfiles[agent.bundleID] = profile
        persist()
        report("\(agent.name) 已改为使用全局语音快捷键")
    }

    func resetDefaultShortcut() {
        guard canEditShortcuts else { return }
        configuration.defaultVoiceShortcut = .defaultVoice
        persist()
        report("全局语音快捷键已恢复为 \(VoiceShortcut.defaultVoice.displayName)")
    }

    func setDefaultVoiceBackend(_ backend: VoiceBackend) {
        guard canChangeTarget else { return }
        do {
            configuration.defaultVoiceBackend = try backend.validated()
            persist()
            report("默认语音来源：\(backend.displayName)")
        } catch { report(error.localizedDescription) }
    }

    func setVoiceBackend(_ backend: VoiceBackend?, for agent: AgentID) {
        guard canChangeTarget, AgentID.supportedAgents.contains(agent) else { return }
        do {
            var profile = configuration.applicationProfiles[agent.bundleID] ?? ApplicationProfile()
            profile.voiceBackend = try backend?.validated()
            configuration.applicationProfiles[agent.bundleID] = profile
            persist()
            report("\(agent.name)语音来源：\(backend?.displayName ?? "使用全局默认")")
        } catch { report(error.localizedDescription) }
    }

    func inspectVoiceControls() async {
        guard !isBusy, !state.isTargetLocked, !isRecordingShortcut else { return }
        let generation = operationGeneration
        let busyLease = beginBusyOperation()
        defer { endBusyOperation(busyLease) }
        do {
            let window = try captureOrdinaryWindow(.voice)
            let backend = try configuration.resolveVoiceBackend(forBundleID: window.bundleID)
            if backend == .nativeDictation {
                try checkOperation(generation)
                let current = try bridge.locateComposer(bundleID: window.bundleID)
                try validateOrdinaryWindow(window, action: .voice)
                guard window.matches(current) else { throw RemoteCoreError.targetMismatch }
                report(try bridge.nativeVoiceControlCapabilities(in: current))
            } else {
                report(try bridge.voiceControlCapabilities())
            }
        }
        catch { report(error.localizedDescription) }
    }

    /// Explicit inspection reads only cached counters, including when this window is frontmost.
    /// Never perform a fresh AX lookup or replace the last nonzero dispatch evidence here.
    func inspectScroll() {
        let age = lastNonzeroScrollAt.map {
            String(format: "%.1fs", max(0, ProcessInfo.processInfo.systemUptime - $0))
        } ?? "none"
        let dispatch = "\(scrollDispatchDiagnostic), nonzeroReceived=\(scrollNonzeroReceivedCount), bridgeCalls=\(scrollBridgeCallCount), bridgeReturned=\(scrollBridgeReturnedCount), "
            + String(format: "lastNonzero=%.4f, ", lastNonzeroScrollValue)
            + "lastNonzeroAge=\(age), enabled=\(isEnabled), busy=\(isBusy), blocked=\(scrollBlocked), locked=\(state.isTargetLocked), voice=\(state.voicePhase)"
        report("滚动诊断（内存快照）\n控制器：\(controller.scrollDiagnostic)\n分发：\(dispatch)\n投递：\(bridge.scrollDeliveryDiagnostic)\n区域：\(bridge.lastScrollDiagnostic)")
    }

    private func persist() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(configuration), forKey: configurationKey) }
        catch { report("保存会话配置失败：\(error.localizedDescription)") }
    }

    private func report(_ text: String, showHUD: Bool = false) {
        status = text
        recordEvent(text)
        if showHUD { hud.show(title: "遥控提示", message: text) }
        else { hud.hide() }
    }

    private func recordEvent(_ text: String) {
        let event = "[\(eventTimeFormatter.string(from: Date()))] \(text)"
        recentEvents.insert(event, at: 0)
        // Preserve full messages, including quiet successes, in a bounded diagnostic history.
        recentEvents = Array(recentEvents.prefix(200))
    }
}

enum RemoteError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
