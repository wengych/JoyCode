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
        return "电量为手柄上报的估计值，每 30 秒刷新；暂停遥控时仍更新"
    }

    static func menuBarImage(for battery: ControllerBatterySnapshot) -> NSImage {
        makeImage(for: battery, includeController: true)
    }

    static func batteryImage(for battery: ControllerBatterySnapshot) -> NSImage {
        makeImage(for: battery, includeController: false)
    }

    private static func makeImage(for battery: ControllerBatterySnapshot,
                                  includeController: Bool) -> NSImage {
        let showsGauge = battery.isConnected || !includeController
        let offset: CGFloat = includeController ? 22 : 0
        let width: CGFloat = showsGauge ? offset + 34 : 18
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            if includeController {
                symbol("gamecontroller", in: NSRect(x: 0, y: 2, width: 18, height: 14))
            }
            guard showsGauge else { return true }
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let outline = NSBezierPath(roundedRect: NSRect(x: offset + 0.5, y: 3.5, width: 22, height: 11),
                                       xRadius: 2, yRadius: 2)
            outline.lineWidth = 1
            outline.stroke()
            NSBezierPath(roundedRect: NSRect(x: offset + 24, y: 7, width: 2, height: 4),
                         xRadius: 0.7, yRadius: 0.7).fill()
            if battery.isConnected, let level = battery.level {
                if level > 0 {
                    NSBezierPath(roundedRect: NSRect(x: offset + 2.5, y: 5.5,
                                                     width: 18 * level, height: 7),
                                 xRadius: 0.7, yRadius: 0.7).fill()
                }
            } else {
                symbol(battery.isConnected ? "questionmark" : "minus",
                       in: NSRect(x: offset + 7.5, y: 5, width: 8, height: 8))
            }
            if battery.powerState == .charging {
                symbol("bolt.fill", in: NSRect(x: offset + 28, y: 3, width: 6, height: 12))
            } else if battery.isLow {
                symbol("exclamationmark", in: NSRect(x: offset + 29, y: 4, width: 4, height: 10))
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
