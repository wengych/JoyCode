import AppKit
import SwiftUI
import RemoteCore

@main
struct RemoteApp: App {
    @StateObject private var coordinator = Coordinator()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("JoyCode", id: "main") {
            RemoteView(model: coordinator)
                .frame(minWidth: 780, minHeight: 680)
        }
        .defaultSize(width: 900, height: 780)
        MenuBarExtra("JoyCode", systemImage: "gamecontroller") {
            RemoteMenu(model: coordinator)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct RemoteMenu: View {
    @ObservedObject var model: Coordinator
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.isRecordingShortcut ? "录制快捷键 · 遥控暂停" : (model.isEnabled ? "遥控已启用 · \(model.voiceLabel)" : "仅诊断手柄输入"))
        Text(model.controller.controllerName ?? "未连接 Xbox 手柄")
        Text(model.status)
        Divider()
        Button("显示遥控设置") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(model.isEnabled ? "停用遥控" : "启用遥控") {
            if model.isEnabled { model.disable() } else { model.enable() }
        }
        Divider()
        Button("退出") { NSApp.terminate(nil) }
    }
}

private struct RemoteView: View {
    @ObservedObject var model: Coordinator
    @State private var newAgent: AgentID = .claude
    @State private var sessionTitle = ""
    @State private var sessionLink = ""
    @State private var showReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    if let icon = NSImage(named: NSImage.Name("AppIcon")) {
                        Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("JoyCode").font(.largeTitle.bold())
                        Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版") · 所有操作以当前激活窗口为准").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(model.isRecordingShortcut ? "录制中 · 遥控暂停" : (model.isEnabled ? "已启用" : "诊断模式"),
                          systemImage: model.isEnabled && !model.isRecordingShortcut ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundStyle(model.isEnabled && !model.isRecordingShortcut ? .green : .secondary)
                }

                GroupBox("设备与权限") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("手柄", value: model.controller.controllerName ?? "未连接 Xbox 手柄")
                        LabeledContent("最近输入", value: model.controller.lastInput)
                        LabeledContent("辅助功能", value: model.hasAccessibility ? "已授权" : "未授权")
                        HStack {
                            if !model.hasAccessibility {
                                Button("打开辅助功能设置") { model.openAccessibilitySettings() }
                                Button("刷新") { model.refreshPermissions() }
                            }
                            if model.isEnabled {
                                Button("停用遥控") { model.disable() }
                            } else if model.inputConfigRunning {
                                Button("退出 InputConfig 并接管手柄") { Task { await model.quitInputConfigAndEnable() } }
                                    .disabled(!model.hasAccessibility)
                            } else {
                                Button("启用遥控") { model.enable() }.disabled(!model.hasAccessibility)
                            }
                            Spacer()
                            Button("隐藏此窗口") { NSApp.hide(nil) }
                        }
                        Text("首次运行只检查手柄输入。授权后接管会退出 InputConfig，避免重复触发；原有预设保留。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("操作目标：当前激活窗口").font(.headline)
                        Spacer()
                        Text(model.voiceLabel).foregroundStyle(.secondary)
                    }
                    Text(model.status).textSelection(.enabled)
                    if model.state.voicePhase != .idle {
                        Button("我已手动停止听写，复位状态…") { showReset = true }
                    }
                    Text("\(model.voiceTargetName) 语音来源：\(model.voiceBackendLabel)。听写结束后保留草稿，检查后按 A 发送。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("在 Claude 或 ChatGPT / Codex 当前窗口按 X 开始／结束，按 B 取消。只有 LB／RB 或明确的“激活／打开”按钮会切换窗口；其他操作不支持时停在当前窗口。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                GroupBox("语音来源") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("全局默认", selection: Binding(get: { model.configuration.defaultVoiceBackend },
                                                              set: { model.setDefaultVoiceBackend($0) })) {
                            ForEach(VoiceBackend.supported, id: \.self) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }
                        ForEach(AgentID.supportedAgents, id: \.rawValue) { agent in
                            Picker(agent.name, selection: Binding(get: { model.configuration.applicationProfiles[agent.bundleID]?.voiceBackend },
                                                                 set: { model.setVoiceBackend($0, for: agent) })) {
                                Text("使用全局默认").tag(Optional<VoiceBackend>.none)
                                ForEach(VoiceBackend.supported, id: \.self) { backend in
                                    Text(backend.displayName).tag(Optional(backend))
                                }
                            }
                        }
                        Text("原生听写直接使用 Agent 的麦克风入口；需要 Typeless 时可单独选择。录音途中保持同一语音来源。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6).disabled(!model.canChangeTarget)
                }

                GroupBox("Typeless 快捷键（可选）") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("全局默认").font(.headline)
                                Text(model.configuration.defaultVoiceShortcut.displayName).textSelection(.enabled)
                            }
                            Spacer()
                            Button("录制默认快捷键") { model.beginShortcutRecording(.global) }
                            Button("恢复初始值") { model.resetDefaultShortcut() }
                        }
                        Divider()
                        ForEach(AgentID.supportedAgents, id: \.rawValue) { agent in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agent.name).font(.headline)
                                    let hasOverride = model.configuration.applicationProfiles[agent.bundleID]?.voiceShortcut != nil
                                    Text("\(hasOverride ? "独立设置" : "使用全局默认") · \(model.shortcut(for: .application(agent)).displayName)")
                                        .foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                Button("录制覆盖") { model.beginShortcutRecording(.application(agent)) }
                                if model.configuration.applicationProfiles[agent.bundleID]?.voiceShortcut != nil {
                                    Button("使用全局默认") { model.inheritGlobalShortcut(for: agent) }
                                }
                            }
                        }
                        Text("请与 Typeless 的“按一下开始／按一下结束”快捷键保持一致。保存只修改遥控器；录制期间暂停手柄动作，保存或取消后恢复。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .disabled(!model.canEditShortcuts)
                }

                GroupBox("按键") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        binding("X", "当前 Agent 窗口开始 / 结束语音；不切换应用")
                        binding("A", "发送当前 Agent 窗口的草稿；输入框变化时先提示确认")
                        binding("B", "仅在本段语音的原窗口仍在前台时取消或确认复位")
                        binding("LB", "激活并聚焦 Claude，保留当前会话")
                        binding("RB", "激活 Codex，保留当前窗口的输入焦点")
                        binding("方向键 ↑ ↓", "切换前台 Claude 会话 / ChatGPT / Codex 侧栏项目")
                        binding("右摇杆 ↑ ↓", "滚动当前 Agent 窗口回复区；切窗即停、松开停止")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                HStack {
                    Button("激活 Codex") { Task { await model.activateCodex() } }
                        .disabled(!(model.canActivateTarget || (model.selectedAgent == .chatGPT && model.canReturnToCurrentAgent)))
                    Text("切到目标 Agent 后，用方向键 ↑ / ↓ 切会话")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("检查滚动") { model.inspectScroll() }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Claude 会话快捷入口").font(.title2.bold())
                    Text("方向键直接切换 Claude Code 会话，无需登记。下方可另存普通 Chat 快捷入口，点击“打开”跳转。")
                        .foregroundStyle(.secondary)
                    ForEach(AgentID.bookmarkAgents, id: \.rawValue) { agent in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(agent.name).font(.headline)
                                Spacer()
                                Button("激活 Claude") { Task { await model.selectAgent(agent) } }
                                    .disabled(!(model.canActivateTarget || (agent == model.selectedAgent && model.canReturnToCurrentAgent)))
                            }
                            let sessions = model.configuration.sessions.filter { $0.agent == agent }
                            if sessions.isEmpty {
                                Text("尚未登记；激活时保留该 App 当前会话").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(sessions) { session in
                                HStack(spacing: 8) {
                                    Image(systemName: model.state.selectedSessionID == session.id ? "circle.fill" : "circle")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(session.title).lineLimit(1)
                                    Spacer()
                                    Button("打开") { Task { await model.selectSession(session) } }
                                        .disabled(!model.canActivateTarget)
                                    Button("上移") { model.moveSession(session, delta: -1) }
                                    Button("下移") { model.moveSession(session, delta: 1) }
                                    Button("移除入口") { model.removeSession(session) }
                                }.disabled(!model.canChangeTarget)
                            }
                        }.padding(.vertical, 5)
                    }
                    Divider()
                    HStack {
                        Picker("Agent", selection: $newAgent) {
                            ForEach(AgentID.bookmarkAgents, id: \.rawValue) { agent in Text(agent.name).tag(agent) }
                        }.frame(width: 240)
                        TextField("会话名称", text: $sessionTitle)
                    }
                    HStack {
                        TextField("claude://claude.ai/chat/会话 ID", text: $sessionLink)
                        Button("添加入口") {
                            if model.addSession(agent: newAgent, title: sessionTitle, link: sessionLink) {
                                sessionTitle = ""; sessionLink = ""
                            }
                        }.disabled(!model.canChangeTarget)
                    }
                    Text("普通 Chat：取会话 ID，填入 claude://claude.ai/chat/<ID>。打开后先确认屏幕会话，再按 X；链接打开不代表实际会话 ID 已核验。旧 Codex 会话入口保留在本机，暂不显示；RB 直接激活 Codex 当前窗口。")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }

                if !model.retainedDraft.isEmpty {
                    DisclosureGroup("离开会话时的草稿备份 · \(model.retainedDraftLabel)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.retainedDraft).textSelection(.enabled).lineLimit(12)
                            Button("复制草稿") { model.copyRetainedDraft() }
                            Text("只保留最近一次非空草稿，退出应用即清除；不会自动覆盖任何输入框。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !model.recentEvents.isEmpty {
                    DisclosureGroup("最近操作记录") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(model.recentEvents.enumerated()), id: \.offset) { _, event in
                                Text(event).font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("本地应用，无服务器、无 API Key。App 更新可能改变可访问性结构；遇到无法识别的输入框、模态窗口或回复区会停止该动作并提示。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }
        .sheet(item: Binding(get: { model.shortcutRecordingScope }, set: { scope in
            if scope == nil { model.cancelShortcutRecording() }
        }), onDismiss: { model.cancelShortcutRecording() }) { scope in
            ShortcutRecorderSheet(initial: model.shortcut(for: scope),
                                  onSave: { model.saveRecordedShortcut($0) },
                                  onCancel: { model.cancelShortcutRecording() })
        }
        .alert("确认听写已停止？", isPresented: $showReset) {
            Button("已停止，复位") { model.confirmStopped() }
            Button("返回检查", role: .cancel) {}
        } message: {
            Text("复位只清除遥控器的内部状态。请先确认所选语音来源的录音及转写都已结束。")
        }
    }

    private func binding(_ key: String, _ explanation: String) -> some View {
        GridRow {
            Text(key).font(.system(.body, design: .monospaced).bold())
            Text(explanation)
        }
    }
}

@MainActor
final class StatusHUD {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    func show(title: String, message: String) {
        hide()
        if panel == nil {
            let panel = PassiveStatusPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 76),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.bold()).lineLimit(1)
                Text(message).font(.caption).lineLimit(2)
            }.padding(12).frame(width: 360, height: 76, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        )
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 376, y: frame.maxY - 92))
        }
        panel.orderFrontRegardless()
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)); try Task.checkCancellation() }
            catch { return }
            self?.hide()
        }
    }
}

private final class PassiveStatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
