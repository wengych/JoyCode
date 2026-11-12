import Foundation

/// Physical modifier keys are distinct even when macOS reports the same aggregate flag.
/// Declaration order is also the canonical order used in persisted shortcuts.
public enum ShortcutModifier: String, Codable, CaseIterable {
    case leftControl
    case rightControl
    case leftShift
    case rightShift
    case leftOption
    case rightOption
    case leftCommand
    case rightCommand
    case function
}

public enum VoiceShortcutError: Error, Equatable, LocalizedError {
    case emptyCombination
    case invalidKeyCode(UInt16)
    case modifierUsedAsPrimary
    case escapeReservedForCancellation

    public var errorDescription: String? {
        switch self {
        case .emptyCombination:
            return "快捷键至少需要一个按键或修饰键。"
        case .invalidKeyCode:
            return "这个按键的键码不受支持，请重新录制。"
        case .modifierUsedAsPrimary:
            return "修饰键必须保存为修饰键组合，不能作为普通按键。"
        case .escapeReservedForCancellation:
            return "Esc 用于取消录制，不能作为语音快捷键。"
        }
    }
}

/// A physical macOS shortcut. keyLabel is presentation metadata, never executable input.
/// A nil keyCode represents a modifier-only shortcut, such as right Option or Fn.
public struct VoiceShortcut: Codable, Equatable {
    public var keyCode: UInt16?
    public var modifiers: [ShortcutModifier]
    public var keyLabel: String?

    public init(keyCode: UInt16?, modifiers: [ShortcutModifier], keyLabel: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public static let defaultVoice = VoiceShortcut(keyCode: 50, modifiers: [.leftOption], keyLabel: "`")

    /// Validate at recording/save time and again immediately before dispatching events.
    /// Decoding intentionally does not call this: one invalid setting must not erase sessions.
    public func validated() throws -> VoiceShortcut {
        let normalizedModifiers = ShortcutModifier.allCases.filter { modifiers.contains($0) }
        guard keyCode != nil || !normalizedModifiers.isEmpty else { throw VoiceShortcutError.emptyCombination }

        if let keyCode {
            if (54...63).contains(keyCode) { throw VoiceShortcutError.modifierUsedAsPrimary }
            if keyCode == 53 { throw VoiceShortcutError.escapeReservedForCancellation }
            guard Self.supportedPrimaryKeyCodes.contains(keyCode) else {
                throw VoiceShortcutError.invalidKeyCode(keyCode)
            }
        }

        return VoiceShortcut(keyCode: keyCode, modifiers: normalizedModifiers, keyLabel: keyLabel)
    }

    // Physical key codes from the macOS SDK Events.h. This deliberately excludes
    // unassigned key codes, modifier/lock keys, Escape, and power/media-only events.
    // Keeping this data in the core avoids AppKit/Carbon dependencies in the model.
    private static let supportedPrimaryKeyCodes: Set<UInt16> = Set(0...51).union([
        64, 65, 67, 69, 71, 75, 76, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88,
        89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104,
        105, 106, 107, 109, 110, 111, 113, 114, 115, 116, 117, 118, 119, 120,
        121, 122, 123, 124, 125, 126
    ])
}

public struct ApplicationProfile: Codable, Equatable {
    /// Nil means inherit the current global shortcut, including later global edits.
    public var voiceShortcut: VoiceShortcut?
    /// Nil means inherit the current global backend, including later global edits.
    public var voiceBackend: VoiceBackend?

    public init(voiceShortcut: VoiceShortcut? = nil, voiceBackend: VoiceBackend? = nil) {
        self.voiceShortcut = voiceShortcut
        self.voiceBackend = voiceBackend
    }
}
