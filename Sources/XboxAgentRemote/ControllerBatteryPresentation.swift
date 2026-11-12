import AppKit
import RemoteCore

/// One template image keeps the entire gauge visible in MenuBarExtra's label.
/// Template rendering follows the menu bar's light/dark appearance.
enum ControllerBatteryPresentation {
    static func text(for battery: ControllerBatterySnapshot) -> String {
        guard battery.isConnected else { return "未连接手柄" }
        let level = battery.percentage.map { "约 \($0)%" } ?? "电量未知"
        switch battery.powerState {
        case .charging: return "\(level) · 充电中"
        case .full: return "100% · 已充满"
        case .discharging: return battery.isLow ? "\(level) · 电量偏低" : level
        case .unknown:
            guard battery.percentage != nil else { return level }
            return "\(level)\(battery.isLow ? " · 电量偏低" : "") · 充电状态未知"
        }
    }

    static func detail(for battery: ControllerBatterySnapshot) -> String {
        guard battery.isConnected else { return "连接 Xbox 手柄后显示电量" }
        guard battery.level != nil else { return "手柄尚未上报可用电量；不会按 0% 显示" }
        if battery.source == .systemBluetooth {
            return "电量来自 macOS 蓝牙系统报告，约每 60 秒刷新；不代表充电状态"
        }
        return "电量为手柄上报的估计值，每 30 秒刷新；暂停遥控时仍更新"
    }

    /// Always occupies the original 18-point controller slot. A thin progress
    /// track lives inside its bottom edge; unknown readings keep the plain icon.
    static func icon(for battery: ControllerBatterySnapshot) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            if battery.isConnected, let level = battery.level {
                symbol("gamecontroller", in: NSRect(x: 0, y: 5, width: 18, height: 12))
                let track = NSRect(x: 1, y: 1, width: 16, height: 2)
                NSColor.black.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
                if level > 0 {
                    NSColor.black.setFill()
                    NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                                     width: track.width * level, height: track.height),
                                 xRadius: 1, yRadius: 1).fill()
                }
            } else {
                // No fabricated zero level or question mark on the menu bar.
                // Connection and reporting status remain available in the menu.
                symbol("gamecontroller", in: NSRect(x: 0, y: 2, width: 18, height: 14))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "JoyCode，手柄电量：\(text(for: battery))"
        return image
    }

    private static func symbol(_ name: String, in rect: NSRect) {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: rect.height, weight: .medium))?
            .draw(in: rect)
    }
}
