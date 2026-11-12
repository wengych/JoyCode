import AppKit
import SwiftUI
import RemoteCore

@MainActor
struct ShortcutRecorderSheet: View {
    let initial: VoiceShortcut
    let onSave: (VoiceShortcut) -> Void
    let onCancel: () -> Void
    @StateObject private var recorder: ShortcutRecorderModel

    init(initial: VoiceShortcut, onSave: @escaping (VoiceShortcut) -> Void,
         onCancel: @escaping () -> Void) {
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        _recorder = StateObject(wrappedValue: ShortcutRecorderModel(onCancel: onCancel))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("录制语音快捷键").font(.title2.bold())
            LabeledContent("当前保存", value: initial.displayName)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: recorder.isRecording ? "record.circle" : "keyboard")
                        .foregroundStyle(recorder.isRecording ? .red : .secondary)
                    Text(recorder.isRecording ? recorder.liveLabel : (recorder.draft?.displayName ?? "尚未录制"))
                        .font(.system(.title3, design: .monospaced).weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(recorder.status).font(.callout).foregroundStyle(.secondary)
                ShortcutCaptureHost(model: recorder).frame(height: 1)
                Button(recorder.isRecording ? "停止录制" : "开始录制") {
                    if recorder.isRecording { recorder.stop(message: "录制已停止；原配置未更改。") }
                    else { recorder.start() }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            Text("支持普通按键组合，以及仅修饰键的组合（区分左右，支持 Fn）。按完后松开全部按键，再检查并保存；Esc 取消。")
                .font(.callout).foregroundStyle(.secondary)
            Text("此设置窗口打开期间，手柄遥控暂停。本地录制无法阻止 Typeless 的全局热键；若它开始听写，请先手动取消。窗口失焦会立即停止录制，返回后可重新录制或保存已有预览。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { recorder.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard let draft = recorder.draft else { return }
                    do {
                        let validated = try draft.validated()
                        recorder.stop(message: "")
                        onSave(validated)
                    } catch { recorder.status = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.isRecording || recorder.draft == nil)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onDisappear { recorder.stop(message: "") }
    }
}

@MainActor
private final class ShortcutRecorderModel: ObservableObject {
    @Published var draft: VoiceShortcut?
    @Published var isRecording = false
    @Published var liveLabel = "请按下快捷键…"
    @Published var status = "点击“开始录制”后，按下你在 Typeless 中配置的实际快捷键。"
    weak var captureView: ShortcutCaptureView?
    private let onCancel: () -> Void
    private var activationTask: Task<Void, Never>?
    private var activationID: UUID?
    var isPreparing: Bool { activationID != nil }

    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }

    func start() {
        stop(message: "正在激活录制窗口…")
        guard let captureView, let window = captureView.window,
              window.isVisible, !captureView.isHiddenOrHasHiddenAncestor else {
            status = "录制控件尚未就绪，请稍后重试。"
            return
        }
        let requestID = UUID()
        activationID = requestID
        if !NSApp.isActive { NSApp.activate() }
        activationTask = Task { @MainActor [weak self, weak captureView, weak window] in
            guard let self, let captureView, let window else { return }
            @MainActor func requestIsCurrent() -> Bool {
                !Task.isCancelled && self.activationID == requestID
                    && self.captureView === captureView && captureView.window === window
                    && window.isVisible && !captureView.isHiddenOrHasHiddenAncestor
            }
            defer {
                if self.activationID == requestID {
                    self.activationTask = nil
                    self.activationID = nil
                }
            }
            // Activation is asynchronous. Only the current request may bring
            // this exact sheet forward or install its local event monitor.
            for attempt in 0...10 {
                guard requestIsCurrent() else { return }
                if NSApp.isActive {
                    if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                    if window.isKeyWindow {
                        captureView.beginRecording()
                        return
                    }
                } else if attempt == 2 {
                    // Workspace coordinates activation when a background app's
                    // direct activation request was not honored.
                    let appURL = Bundle.main.bundleURL
                    guard appURL.pathExtension == "app" else {
                        self.status = "请点击此设置窗口，再开始录制。"
                        return
                    }
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.createsNewApplicationInstance = false
                    configuration.allowsRunningApplicationSubstitution = false
                    configuration.addsToRecentItems = false
                    configuration.promptsUserIfNeeded = false
                    do {
                        let running = try await NSWorkspace.shared.openApplication(
                            at: appURL, configuration: configuration)
                        guard requestIsCurrent() else { return }
                        guard running.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                            self.status = "无法激活录制窗口，请点击此窗口后重试。"
                            return
                        }
                    } catch {
                        guard requestIsCurrent() else { return }
                        self.status = "无法激活录制窗口，请点击此窗口后重试。"
                        return
                    }
                }
                guard attempt < 10 else { break }
                do { try await Task.sleep(nanoseconds: 50_000_000) }
                catch { return }
            }
            self.status = "请点击此设置窗口，再开始录制。"
        }
    }

    func stop(message: String) {
        activationID = nil
        activationTask?.cancel()
        activationTask = nil
        captureView?.endRecording()
        isRecording = false
        liveLabel = "请按下快捷键…"
        status = message
    }

    func cancel() {
        stop(message: "")
        onCancel()
    }

    func receive(_ outcome: ShortcutCapture.Outcome, live: VoiceShortcut) {
        switch outcome {
        case .waiting:
            liveLabel = live.keyCode == nil && live.modifiers.isEmpty ? "请按下快捷键…" : live.displayName
        case .completed(let shortcut):
            stop(message: "已录制，尚未保存。确认与 Typeless 设置一致后点击“保存”。")
            draft = shortcut
        case .invalid(let message):
            stop(message: message)
        }
    }
}

@MainActor
private struct ShortcutCaptureHost: NSViewRepresentable {
    let model: ShortcutRecorderModel

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.model = model
        model.captureView = view
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureView, context: Context) {}

    static func dismantleNSView(_ nsView: ShortcutCaptureView, coordinator: ()) {
        nsView.endRecording()
        nsView.removeObservers()
    }
}

/// Captures only while this sheet's view is the key window's first responder.
/// A local monitor is necessary to catch Command combinations before menu dispatch.
@MainActor
private final class ShortcutCaptureView: NSView {
    weak var model: ShortcutRecorderModel?
    private var monitor: Any?
    private var capture = ShortcutCapture()
    private var functionIsDown = false
    private var primaryLabel: String?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else {
            endRecording()
            return
        }
        NotificationCenter.default.addObserver(self, selector: #selector(lostFocus),
                                               name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(lostFocus),
                                               name: NSApplication.didResignActiveNotification, object: NSApp)
    }

    override func resignFirstResponder() -> Bool {
        if monitor != nil { model?.stop(message: "焦点已离开录制区域，录制已停止；原配置未更改。") }
        return super.resignFirstResponder()
    }

    func removeObservers() { NotificationCenter.default.removeObserver(self) }

    func beginRecording() {
        guard let window, window.isKeyWindow, NSApp.isActive else {
            model?.status = "请先回到此设置窗口，再开始录制。"
            return
        }
        let held = NSEvent.modifierFlags.intersection([.shift, .control, .option, .command, .function])
        guard held.isEmpty else {
            model?.status = "请松开全部修饰键，再点击“开始录制”。"
            return
        }
        endRecording()
        guard window.makeFirstResponder(self) else {
            model?.status = "无法取得录制焦点，请重新打开设置窗口。"
            return
        }
        model?.isRecording = true
        model?.liveLabel = "请按下快捷键…"
        model?.status = "正在录制：按下组合后松开所有按键。Esc 取消。"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.receive(event)
        }
    }

    func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capture.reset()
        functionIsDown = false
        primaryLabel = nil
    }

    @objc private func lostFocus(_ notification: Notification) {
        guard monitor != nil || model?.isPreparing == true else { return }
        model?.stop(message: "窗口已失焦，录制已停止；已有预览保留，原配置未更改。")
    }

    private func receive(_ event: NSEvent) -> NSEvent? {
        guard monitor != nil else { return event }
        guard let window, event.window === window, window.isKeyWindow,
              NSApp.isActive, window.firstResponder === self else {
            model?.stop(message: "焦点已离开，录制已停止；原配置未更改。")
            return event
        }
        if event.type == .keyDown, event.keyCode == 53 {
            model?.cancel()
            return nil
        }
        if event.type == .keyDown, event.isARepeat { return nil }

        if event.type == .flagsChanged {
            guard Self.modifierKeyCodes.contains(event.keyCode) else {
                model?.stop(message: "此修饰键无法可靠录制。请松开按键后重新录制；Caps Lock 不支持。")
                return nil
            }
            if event.keyCode == 63 { functionIsDown = event.modifierFlags.contains(.function) }
        }
        guard var modifiers = Self.physicalModifiers(from: event.modifierFlags) else {
            model?.stop(message: "无法确定左右修饰键；请松开所有按键后重新录制。")
            return nil
        }
        // Function-key events also carry .function. Only a physical Fn (keycode 63)
        // flagsChanged event establishes Fn as part of the recorded chord.
        if functionIsDown { modifiers.insert(.function) }
        let outcome: ShortcutCapture.Outcome
        switch event.type {
        case .flagsChanged:
            outcome = capture.modifiersChanged(modifiers)
        case .keyDown:
            primaryLabel = Self.keyLabel(for: event)
            outcome = capture.keyDown(event.keyCode, label: primaryLabel, modifiers: modifiers, isRepeat: false)
        case .keyUp:
            guard modifiers == capture.pressedModifiers else {
                model?.stop(message: "按键状态已变化；请松开所有按键后重新录制。")
                return nil
            }
            outcome = capture.keyUp(event.keyCode)
        default:
            return event
        }
        model?.receive(outcome, live: VoiceShortcut(keyCode: capture.primaryKeyCode,
                                                   modifiers: Array(capture.pressedModifiers), keyLabel: primaryLabel))
        return nil
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    private static func physicalModifiers(from flags: NSEvent.ModifierFlags) -> Set<ShortcutModifier>? {
        // Device flags from the macOS SDK's IOKit/hidsystem/IOLLEvent.h.
        let masks: [(ShortcutModifier, UInt)] = [
            (.leftControl, 0x00000001), (.rightControl, 0x00002000),
            (.leftShift, 0x00000002), (.rightShift, 0x00000004),
            (.leftOption, 0x00000020), (.rightOption, 0x00000040),
            (.leftCommand, 0x00000008), (.rightCommand, 0x00000010)
        ]
        let result = Set(masks.compactMap { flags.rawValue & $0.1 != 0 ? $0.0 : nil })
        let groups: [(NSEvent.ModifierFlags, Set<ShortcutModifier>)] = [
            (.control, [.leftControl, .rightControl]), (.shift, [.leftShift, .rightShift]),
            (.option, [.leftOption, .rightOption]), (.command, [.leftCommand, .rightCommand])
        ]
        guard groups.allSatisfy({ flags.contains($0.0) == !result.isDisjoint(with: $0.1) }) else { return nil }
        return result
    }

    private static func keyLabel(for event: NSEvent) -> String? {
        let names: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 71: "Clear", 76: "Enter",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
            105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
            114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4",
            119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→",
            125: "↓", 126: "↑", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        if let name = names[event.keyCode] { return name }
        guard let text = event.charactersIgnoringModifiers, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return String(text.prefix(16)).uppercased()
    }
}
