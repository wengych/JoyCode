import Foundation

/// A single, explicitly armed recording attempt. No event monitoring or persistence.
public struct ShortcutCapture {
    public enum Outcome: Equatable {
        case waiting
        case completed(VoiceShortcut)
        case invalid(String)
    }

    public private(set) var pressedModifiers: Set<ShortcutModifier> = []
    public private(set) var primaryKeyCode: UInt16?
    private var primaryKeyLabel: String?
    private var primaryIsDown = false
    private var chordModifiers: Set<ShortcutModifier> = []
    private var hasReleasedModifier = false

    public init() {}

    public mutating func reset() { self = ShortcutCapture() }

    public mutating func modifiersChanged(_ modifiers: Set<ShortcutModifier>) -> Outcome {
        let added = modifiers.subtracting(pressedModifiers)
        let removed = pressedModifiers.subtracting(modifiers)
        if !added.isEmpty && (hasReleasedModifier || primaryKeyCode != nil) {
            return fail("一次只录制一组快捷键；请松开所有按键后重新录制。")
        }
        pressedModifiers = modifiers
        if !removed.isEmpty { hasReleasedModifier = true }
        if primaryKeyCode == nil && !hasReleasedModifier { chordModifiers = modifiers }
        return finishIfReleased()
    }

    public mutating func keyDown(_ keyCode: UInt16, label: String?,
                                 modifiers: Set<ShortcutModifier>, isRepeat: Bool) -> Outcome {
        guard !isRepeat else { return .waiting }
        guard primaryKeyCode == nil, !hasReleasedModifier else {
            return fail("一次只录制一个主键；请松开所有按键后重新录制。")
        }
        guard modifiers == pressedModifiers else {
            return fail("修饰键状态不完整；请松开所有按键后重新录制。")
        }
        primaryKeyCode = keyCode
        primaryKeyLabel = label
        primaryIsDown = true
        chordModifiers = modifiers
        return .waiting
    }

    public mutating func keyUp(_ keyCode: UInt16) -> Outcome {
        guard primaryKeyCode == keyCode else { return .waiting }
        primaryIsDown = false
        return finishIfReleased()
    }

    private mutating func finishIfReleased() -> Outcome {
        guard pressedModifiers.isEmpty, !primaryIsDown,
              primaryKeyCode != nil || !chordModifiers.isEmpty else { return .waiting }
        let shortcut = VoiceShortcut(keyCode: primaryKeyCode, modifiers: Array(chordModifiers),
                                     keyLabel: primaryKeyLabel)
        reset()
        do { return .completed(try shortcut.validated()) }
        catch { return .invalid(error.localizedDescription) }
    }

    private mutating func fail(_ message: String) -> Outcome {
        reset()
        return .invalid(message)
    }
}
