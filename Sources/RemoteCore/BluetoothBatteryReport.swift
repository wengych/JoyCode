import Foundation

/// Parses only connected devices from the public system_profiler JSON report.
/// A name is usable only when the entire report contains exactly one Xbox.
public enum BluetoothBatteryReport {
    public static func level(in data: Data, matchingName: String) -> Double? {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reports = root["SPBluetoothDataType"] as? [Any], !reports.isEmpty else { return nil }
        let target = normalizedName(matchingName)
        guard target.contains("xbox") else { return nil }
        var xboxEntries: [(name: String, details: [String: Any])] = []
        for item in reports {
            guard let report = item as? [String: Any] else { return nil }
            guard let connectedValue = report["device_connected"] else { continue }
            guard let connected = connectedValue as? [Any] else { return nil }
            for item in connected {
                guard let entry = item as? [String: Any], entry.count == 1,
                      let (rawName, value) = entry.first,
                      let details = value as? [String: Any] else { return nil }
                let name = normalizedName(rawName)
                if name.contains("xbox") { xboxEntries.append((name, details)) }
            }
        }
        guard xboxEntries.count == 1, let entry = xboxEntries.first, entry.name == target,
              let rawValue = entry.details["device_batteryLevelMain"] as? String else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasSuffix("%") else { return nil }
        let digits = String(value.dropLast())
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let percent = Int(digits), (0...100).contains(percent),
              digits == String(percent) else { return nil }
        return Double(percent) / 100
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
