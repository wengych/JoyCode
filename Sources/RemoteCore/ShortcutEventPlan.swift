import Foundation

/// One synthetic transition. Flags describe the modifier state after this transition.
/// The bridge creates all events before posting and keeps the complete sequence synchronous.
public struct ShortcutEventStep: Equatable {
    public let keyCode: UInt16
    public let isKeyDown: Bool
    public let isModifier: Bool
    public let flags: UInt64
    public let delayAfter: TimeInterval

    public init(keyCode: UInt16, isKeyDown: Bool, isModifier: Bool, flags: UInt64, delayAfter: TimeInterval) {
        self.keyCode = keyCode
        self.isKeyDown = isKeyDown
        self.isModifier = isModifier
        self.flags = flags
        self.delayAfter = delayAfter
    }
}

/// Pure event planning: this type neither creates CGEvents nor changes input state.
public enum ShortcutEventPlan {
    public static func steps(for shortcut: VoiceShortcut) throws -> [ShortcutEventStep] {
        let shortcut = try shortcut.validated()
        var held: [ShortcutModifier] = []
        var result: [ShortcutEventStep] = []

        for modifier in shortcut.modifiers {
            held.append(modifier)
            let holdsCompleteChord = shortcut.keyCode == nil && held.count == shortcut.modifiers.count
            result.append(ShortcutEventStep(
                keyCode: modifier.eventKeyCode, isKeyDown: true, isModifier: true,
                flags: flags(for: held), delayAfter: holdsCompleteChord ? 0.08 : 0.025
            ))
        }

        if let keyCode = shortcut.keyCode {
            let chordFlags = flags(for: held)
            result.append(ShortcutEventStep(
                keyCode: keyCode, isKeyDown: true, isModifier: false,
                flags: chordFlags, delayAfter: 0.08
            ))
            result.append(ShortcutEventStep(
                keyCode: keyCode, isKeyDown: false, isModifier: false,
                flags: chordFlags, delayAfter: held.isEmpty ? 0 : 0.025
            ))
        }

        while let modifier = held.popLast() {
            result.append(ShortcutEventStep(
                keyCode: modifier.eventKeyCode, isKeyDown: false, isModifier: true,
                flags: flags(for: held), delayAfter: held.isEmpty ? 0 : 0.025
            ))
        }

        return result
    }

    private static func flags(for held: [ShortcutModifier]) -> UInt64 {
        // Recompute from held keys: releasing one side must preserve the generic
        // modifier flag when the opposite side of the same modifier is still held.
        held.reduce(0) { $0 | $1.eventFlags }
    }
}

private extension ShortcutModifier {
    // Physical virtual-key codes from the macOS SDK HIToolbox/Events.h.
    var eventKeyCode: UInt16 {
        switch self {
        case .leftControl: return 0x3B
        case .rightControl: return 0x3E
        case .leftShift: return 0x38
        case .rightShift: return 0x3C
        case .leftOption: return 0x3A
        case .rightOption: return 0x3D
        case .leftCommand: return 0x37
        case .rightCommand: return 0x36
        case .function: return 0x3F
        }
    }

    // Device-independent NX_*MASK plus side-specific NX_DEVICE*KEYMASK values
    // from the macOS SDK IOKit/hidsystem/IOLLEvent.h. Fn has no side-specific bit.
    var eventFlags: UInt64 {
        switch self {
        case .leftControl: return 0x00040000 | 0x00000001
        case .rightControl: return 0x00040000 | 0x00002000
        case .leftShift: return 0x00020000 | 0x00000002
        case .rightShift: return 0x00020000 | 0x00000004
        case .leftOption: return 0x00080000 | 0x00000020
        case .rightOption: return 0x00080000 | 0x00000040
        case .leftCommand: return 0x00100000 | 0x00000008
        case .rightCommand: return 0x00100000 | 0x00000010
        case .function: return 0x00800000
        }
    }
}
