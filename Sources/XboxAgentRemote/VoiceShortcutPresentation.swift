import Foundation
import RemoteCore

extension VoiceShortcut {
    var displayName: String {
        guard let shortcut = try? validated() else { return "无效快捷键，请重新录制" }
        var parts = shortcut.modifiers.map { modifier -> String in
            switch modifier {
            case .leftControl: return "左 Control"
            case .rightControl: return "右 Control"
            case .leftShift: return "左 Shift"
            case .rightShift: return "右 Shift"
            case .leftOption: return "左 Option"
            case .rightOption: return "右 Option"
            case .leftCommand: return "左 Command"
            case .rightCommand: return "右 Command"
            case .function: return "Fn"
            }
        }
        if let code = shortcut.keyCode {
            let names: [UInt16: String] = [
                36: "Return", 48: "Tab", 49: "Space", 50: "`", 51: "Delete",
                64: "F17", 76: "Enter", 79: "F18", 80: "F19", 90: "F20",
                96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
                103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
                111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up",
                117: "Forward Delete", 118: "F4", 119: "End", 120: "F2",
                121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
            ]
            let label = String((shortcut.keyLabel ?? "").filter { character in
                character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            }.prefix(16))
            parts.append(names[code] ?? (label.isEmpty ? "按键 \(code)" : label.uppercased()))
        }
        return parts.joined(separator: " + ")
    }
}
