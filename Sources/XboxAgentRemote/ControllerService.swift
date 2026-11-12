import AppKit
import Combine
import GameController
import RemoteCore

enum ControllerAction: Equatable {
    case voice
    case send
    case cancel
    case selectClaude
    case activateCodex
    case previousSession
    case nextSession
}

/// Monitors one Xbox without activating a window or synthesizing keyboard input.
/// Published state and callbacks are delivered on the main thread.
final class ControllerService: ObservableObject {
    @Published private(set) var controllerName: String?
    @Published private(set) var isConnected = false
    @Published private(set) var lastInput = "等待 Xbox 手柄"
    @Published private(set) var battery = ControllerBatterySnapshot.disconnected

    var onAction: ((ControllerAction) -> Void)?
    /// Positive values scroll toward older content (up); negative values scroll down.
    var onScroll: ((Double) -> Void)?
    var onDisconnect: (() -> Void)?

    var enabled: Bool {
        get { onMain { isEnabled } }
        set { onMain { setEnabled(newValue) } }
    }

    private struct ButtonState {
        let input: GCControllerButtonInput
        let action: ControllerAction
        let label: String
        var isPressed: Bool
        var isArmed: Bool
    }

    private let deadZone = 0.18
    private var isEnabled = false
    private var isMonitoring = false
    private var selectedController: GCController?
    private var observers: [NSObjectProtocol] = []
    private var buttons: [ObjectIdentifier: ButtonState] = [:]
    private var connectionGeneration: UInt = 0
    private var scrollTimer: DispatchSourceTimer?
    private var batteryTimer: DispatchSourceTimer?
    private let bluetoothBatteryReader = BluetoothBatteryReader()
    private var bluetoothBatteryRequestID: UUID?
    private var bluetoothBatteryLastAttemptAt: TimeInterval?
    private var bluetoothBatteryCache: (snapshot: ControllerBatterySnapshot, observedAt: TimeInterval)?
    private var rawScrollY = 0.0
    private var scrollIsArmed = false
    private var lastStickDiagnosticAt: TimeInterval = 0
    private var lastStickDiagnosticValue = 0.0
    private var previousBackgroundMonitoring: Bool?
    // Memory-only counters: timer activity must not trigger UI publication at 60 Hz.
    private var scrollTimerTickCount: UInt64 = 0
    private var scrollEmissionCount: UInt64 = 0
    private var scrollNonzeroEmissionCount: UInt64 = 0
    private var scrollMissingCallbackCount: UInt64 = 0
    private var lastDeflectedScrollY = 0.0
    private var lastNonzeroScrollEmission = 0.0
    private var lastNonzeroScrollEmissionAt: TimeInterval?
    private var lastScrollTimerGate = "notStarted"

    /// Reads only this service's cached state; never queries AX or foreground applications.
    var scrollDiagnostic: String {
        onMain {
            let age = lastNonzeroScrollEmissionAt.map {
                String(format: "%.1fs", max(0, ProcessInfo.processInfo.systemUptime - $0))
            } ?? "none"
            return "enabled=\(isEnabled), connected=\(isConnected), monitoring=\(isMonitoring), callback=\(onScroll != nil), timer=\(scrollTimer != nil), armed=\(scrollIsArmed), "
                + String(format: "raw=%.4f, lastDeflectedRaw=%.4f, lastNonzero=%.4f, ", rawScrollY, lastDeflectedScrollY, lastNonzeroScrollEmission)
                + "lastNonzeroAge=\(age), ticks=\(scrollTimerTickCount), emitted=\(scrollEmissionCount), nonzeroEmitted=\(scrollNonzeroEmissionCount), missingCallback=\(scrollMissingCallbackCount), timerGate=\(lastScrollTimerGate)"
        }
    }

    func start() {
        onMain {
            guard !isMonitoring else { return }
            isMonitoring = true
            previousBackgroundMonitoring = GCController.shouldMonitorBackgroundEvents
            GCController.shouldMonitorBackgroundEvents = true

            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                    self?.selectControllerIfNeeded()
                    self?.refreshBattery()
                },
                center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] notification in
                    guard let controller = notification.object as? GCController else { return }
                    self?.controllerDisconnected(controller)
                }
            ]
            selectControllerIfNeeded()
        }
    }

    func stop() {
        onMain {
            isMonitoring = false
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            detachController()
            if let previousBackgroundMonitoring {
                GCController.shouldMonitorBackgroundEvents = previousBackgroundMonitoring
            }
            previousBackgroundMonitoring = nil
            lastInput = "手柄监听已停止"
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        scrollTimer?.cancel()
        batteryTimer?.cancel()
        bluetoothBatteryReader.cancel()
        // Do not capture self in cleanup: callbacks may outlive the owner briefly.
        let inputs = buttons.values.map(\.input)
        let stick = selectedController?.extendedGamepad?.rightThumbstick
        let backgroundMonitoring = previousBackgroundMonitoring
        let cleanup = {
            inputs.forEach { $0.pressedChangedHandler = nil }
            stick?.valueChangedHandler = nil
            if let backgroundMonitoring {
                GCController.shouldMonitorBackgroundEvents = backgroundMonitoring
            }
        }
        if Thread.isMainThread {
            cleanup()
        } else {
            DispatchQueue.main.async(execute: cleanup)
        }
    }

    private func onMain<T>(_ operation: () -> T) -> T {
        if Thread.isMainThread { return operation() }
        return DispatchQueue.main.sync(execute: operation)
    }

    private func setEnabled(_ value: Bool) {
        guard isEnabled != value else { return }
        isEnabled = value
        if value {
            refreshInputGates()
            startScrollTimerIfNeeded()
            lastInput = isConnected ? "遥控已启用" : "等待 Xbox 手柄"
        } else {
            stopScrolling()
            lastInput = "遥控已暂停"
        }
    }

    private func selectControllerIfNeeded(excluding disconnected: GCController? = nil) {
        guard isMonitoring, selectedController == nil else { return }
        let candidates = GCController.controllers().filter { $0 !== disconnected }
        guard let controller = candidates.first(where: Self.isXbox),
              let gamepad = controller.extendedGamepad else {
            lastInput = candidates.isEmpty ? "等待 Xbox 手柄" : "检测到其他手柄，仅接受 Xbox"
            return
        }

        selectedController = controller
        connectionGeneration &+= 1
        let generation = connectionGeneration
        controller.handlerQueue = .main
        controllerName = controller.vendorName ?? controller.productCategory
        isConnected = true
        startBatteryMonitoring(generation: generation)

        bind(gamepad.buttonX, to: .voice, label: "X · 语音", generation: generation)
        bind(gamepad.buttonA, to: .send, label: "A · 发送", generation: generation)
        bind(gamepad.buttonB, to: .cancel, label: "B · 取消", generation: generation)
        bind(gamepad.leftShoulder, to: .selectClaude, label: "LB · Claude", generation: generation)
        bind(gamepad.rightShoulder, to: .activateCodex, label: "RB · Codex", generation: generation)
        bind(gamepad.dpad.up, to: .previousSession, label: "↑ · 上一个会话", generation: generation)
        bind(gamepad.dpad.down, to: .nextSession, label: "↓ · 下一个会话", generation: generation)

        // Menu, Home, Share, and their system gestures are deliberately untouched.
        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, _, y in
            guard let self, self.isMonitoring, self.connectionGeneration == generation else { return }
            self.updateScrollInput(Double(y))
        }
        refreshInputGates()
        startScrollTimerIfNeeded()
        lastInput = isEnabled ? "Xbox 已连接，遥控已启用" : "Xbox 已连接，遥控已暂停"
    }

    private static func isXbox(_ controller: GCController) -> Bool {
        guard let gamepad = controller.extendedGamepad, !controller.isSnapshot else { return false }
        // Do not adopt generic extended gamepads just because they have ABXY buttons.
        return gamepad is GCXboxGamepad || controller.productCategory.lowercased().contains("xbox")
    }

    private func startBatteryMonitoring(generation: UInt) {
        batteryTimer?.cancel()
        refreshBattery()
        // Battery is a copied snapshot, not a live input or a documented change
        // notification. Poll gently even while remote actions are paused.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: .seconds(30), leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.isMonitoring, self.isConnected,
                  self.connectionGeneration == generation else { return }
            self.refreshBattery()
        }
        batteryTimer = timer
        timer.resume()
    }

    private func refreshBattery() {
        guard let controller = selectedController, isMonitoring else {
            publishBattery(.disconnected)
            return
        }
        let native = nativeBattery(for: controller)
        if native.level != nil {
            bluetoothBatteryCache = nil
            cancelBluetoothBatteryRead()
            publishBattery(native)
            return
        }
        // A name alone is not an identity. Never borrow one controller's reading
        // when either the live GC list or the Bluetooth report is ambiguous.
        guard isUniqueConnectedXbox(controller),
              let name = controller.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            bluetoothBatteryCache = nil
            cancelBluetoothBatteryRead()
            publishBattery(native)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if bluetoothBatteryRequestID == nil,
           bluetoothBatteryLastAttemptAt.map({ now - $0 >= 60 }) ?? true {
            let requestID = UUID()
            let generation = connectionGeneration
            bluetoothBatteryRequestID = requestID
            let started = bluetoothBatteryReader.read(matchingName: name) { [weak self] level in
                guard let self, self.bluetoothBatteryRequestID == requestID else { return }
                self.bluetoothBatteryRequestID = nil
                guard self.isMonitoring, self.isConnected,
                      self.connectionGeneration == generation, self.selectedController === controller else { return }

                // Read GC again after the subprocess, so a newly available native
                // value always wins over a slower Bluetooth result.
                let currentNative = self.nativeBattery(for: controller)
                guard currentNative.level == nil else {
                    self.bluetoothBatteryCache = nil
                    self.publishBattery(currentNative)
                    return
                }
                guard self.isUniqueConnectedXbox(controller),
                      controller.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines) == name,
                      let level else {
                    self.bluetoothBatteryCache = nil
                    self.publishBattery(currentNative)
                    return
                }
                let snapshot = ControllerBatterySnapshot(isConnected: true, level: level,
                                                         powerState: .unknown, source: .systemBluetooth)
                self.bluetoothBatteryCache = (snapshot, ProcessInfo.processInfo.systemUptime)
                self.publishBattery(snapshot)
            }
            if started {
                bluetoothBatteryLastAttemptAt = now
            } else {
                bluetoothBatteryRequestID = nil
            }
        }
        // A 30-second GC poll must not flash away a still-current fallback. Keep
        // the previous result during its bounded refresh, then clear it on failure.
        if let cached = bluetoothBatteryCache,
           now - cached.observedAt < 60 || bluetoothBatteryRequestID != nil {
            publishBattery(cached.snapshot)
        } else {
            bluetoothBatteryCache = nil
            publishBattery(native)
        }
    }

    private func nativeBattery(for controller: GCController) -> ControllerBatterySnapshot {
        let reading = controller.battery
        let powerState: ControllerBatterySnapshot.PowerState
        switch reading?.batteryState {
        case .discharging?: powerState = .discharging
        case .charging?: powerState = .charging
        case .full?: powerState = .full
        default: powerState = .unknown
        }
        return ControllerBatterySnapshot(isConnected: true, level: reading.map { Double($0.batteryLevel) },
                                         powerState: powerState)
    }

    private func isUniqueConnectedXbox(_ controller: GCController) -> Bool {
        let candidates = GCController.controllers().filter(Self.isXbox)
        return candidates.count == 1 && candidates.first === controller && selectedController === controller
    }

    private func cancelBluetoothBatteryRead() {
        bluetoothBatteryRequestID = nil
        bluetoothBatteryReader.cancel()
    }

    private func publishBattery(_ snapshot: ControllerBatterySnapshot) {
        if snapshot != battery { battery = snapshot }
    }

    private func bind(_ input: GCControllerButtonInput, to action: ControllerAction, label: String, generation: UInt) {
        let id = ObjectIdentifier(input)
        buttons[id] = ButtonState(input: input, action: action, label: label,
                                  isPressed: input.isPressed, isArmed: !input.isPressed)
        input.pressedChangedHandler = { [weak self] _, _, pressed in
            guard let self, self.isMonitoring, self.connectionGeneration == generation else { return }
            self.buttonChanged(id, pressed: pressed)
        }
    }

    private func buttonChanged(_ id: ObjectIdentifier, pressed: Bool) {
        guard var state = buttons[id], state.isPressed != pressed else { return }
        state.isPressed = pressed
        let shouldFire = pressed && state.isArmed && isEnabled
        // A release arms exactly one future rising edge; a hold never repeats.
        state.isArmed = !pressed
        buttons[id] = state
        if pressed {
            lastInput = state.label + (isEnabled ? "" : "（仅诊断）")
        }
        guard shouldFire else { return }
        onAction?(state.action)
    }

    private func refreshInputGates() {
        for id in Array(buttons.keys) {
            guard var state = buttons[id] else { continue }
            state.isPressed = state.input.isPressed
            state.isArmed = !state.isPressed
            buttons[id] = state
        }
        rawScrollY = Double(selectedController?.extendedGamepad?.rightThumbstick.yAxis.value ?? 0)
        // A deflected stick at connect/re-enable must return to center first.
        scrollIsArmed = abs(rawScrollY) <= deadZone
    }

    private func updateScrollInput(_ value: Double) {
        rawScrollY = value.isFinite ? min(1, max(-1, value)) : 0
        if abs(rawScrollY) > deadZone { lastDeflectedScrollY = rawScrollY }
        let now = Date.timeIntervalSinceReferenceDate
        let enteredDeadZone = abs(rawScrollY) <= deadZone && abs(lastStickDiagnosticValue) > deadZone
        if enteredDeadZone || (now - lastStickDiagnosticAt >= 0.15 && abs(rawScrollY - lastStickDiagnosticValue) >= 0.04) {
            lastStickDiagnosticAt = now
            lastStickDiagnosticValue = rawScrollY
            lastInput = String(format: "右摇杆 Y %+.2f", rawScrollY) + (isEnabled ? "" : "（仅诊断）")
        }
        if abs(rawScrollY) <= deadZone {
            scrollIsArmed = true
            if isEnabled { emitScroll(0) }
        }
    }

    private func startScrollTimerIfNeeded() {
        guard isMonitoring, isEnabled, isConnected, scrollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.scrollTimerTickCount &+= 1
            guard self.isMonitoring, self.isEnabled, self.isConnected else {
                self.lastScrollTimerGate = "inactive"
                return
            }
            let magnitude = abs(self.rawScrollY)
            guard self.scrollIsArmed, magnitude > self.deadZone else {
                self.lastScrollTimerGate = self.scrollIsArmed ? "deadZone" : "awaitingCenter"
                self.emitScroll(0)
                return
            }
            let normalized = min(1, (magnitude - self.deadZone) / (1 - self.deadZone))
            let curved = normalized * normalized
            self.lastScrollTimerGate = "emittingNonzero"
            self.emitScroll(self.rawScrollY >= 0 ? curved : -curved)
        }
        scrollTimer = timer
        lastScrollTimerGate = "started"
        timer.resume()
    }

    private func emitScroll(_ value: Double) {
        guard let onScroll else { scrollMissingCallbackCount &+= 1; return }
        scrollEmissionCount &+= 1
        if value != 0 {
            scrollNonzeroEmissionCount &+= 1
            lastNonzeroScrollEmission = value
            lastNonzeroScrollEmissionAt = ProcessInfo.processInfo.systemUptime
        }
        onScroll(value)
    }

    private func stopScrolling() {
        scrollTimer?.cancel()
        scrollTimer = nil
        rawScrollY = 0
        scrollIsArmed = false
        lastScrollTimerGate = "stopped"
        emitScroll(0)
    }

    private func detachController() {
        connectionGeneration &+= 1
        batteryTimer?.cancel()
        batteryTimer = nil
        cancelBluetoothBatteryRead()
        bluetoothBatteryCache = nil
        bluetoothBatteryLastAttemptAt = nil
        buttons.values.forEach { $0.input.pressedChangedHandler = nil }
        buttons.removeAll()
        selectedController?.extendedGamepad?.rightThumbstick.valueChangedHandler = nil
        selectedController = nil
        controllerName = nil
        isConnected = false
        if battery != .disconnected { battery = .disconnected }
        stopScrolling()
    }

    private func controllerDisconnected(_ controller: GCController) {
        guard selectedController === controller else {
            refreshBattery()
            return
        }
        detachController()
        lastInput = "Xbox 手柄已断开"
        onDisconnect?()
        // Keep the first selection until it disconnects, then accept one other Xbox.
        selectControllerIfNeeded(excluding: controller)
    }
}
