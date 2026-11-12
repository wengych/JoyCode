/// A display-safe snapshot; an absent/default reading is not an empty battery.
public struct ControllerBatterySnapshot: Equatable, Sendable {
    public enum PowerState: Equatable, Sendable {
        case unknown
        case discharging
        case charging
        case full
    }

    public let isConnected: Bool
    public let level: Double?
    public let powerState: PowerState

    public static let disconnected = ControllerBatterySnapshot(
        isConnected: false, level: nil, powerState: .unknown
    )

    public init(isConnected: Bool, level: Double?, powerState: PowerState) {
        self.isConnected = isConnected
        self.powerState = isConnected ? powerState : .unknown
        guard isConnected else {
            self.level = nil
            return
        }
        // GameController defines full as plugged in and 100% charged.
        if powerState == .full {
            self.level = 1
        } else if let level, level.isFinite, (0...1).contains(level),
                  !(powerState == .unknown && level == 0) {
            self.level = level
        } else {
            // GCDeviceBattery defaults to level 0 with state unknown. Do not
            // present that default, an unsupported reading, or invalid data as 0%.
            self.level = nil
        }
    }

    public var percentage: Int? {
        level.map { Int(($0 * 100).rounded()) }
    }

    public var isLow: Bool {
        guard let percentage, powerState != .charging, powerState != .full else { return false }
        return percentage <= 20
    }
}
