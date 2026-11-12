import Foundation
import XCTest
import RemoteCore

final class BluetoothBatteryReportTests: XCTestCase {
    private let targetName = "Xbox Wireless Controller"

    private func report(connected: [[String: Any]], disconnected: [[String: Any]] = []) -> Data {
        try! JSONSerialization.data(withJSONObject: ["SPBluetoothDataType": [
            ["device_connected": connected, "device_not_connected": disconnected]
        ]])
    }

    private func device(_ value: Any, name: String = "Xbox Wireless Controller") -> [String: Any] {
        [name: ["device_batteryLevelMain": value]]
    }

    func testConnectedTargetUsesExactNormalizedNameAndKeepsZero() {
        XCTAssertEqual(BluetoothBatteryReport.level(in: report(connected: [device("0%")]), matchingName: targetName), 0)
        XCTAssertEqual(BluetoothBatteryReport.level(in: report(connected: [device("100%", name: " xbox wireless controller ")]),
                                                    matchingName: targetName), 1)
        XCTAssertNil(BluetoothBatteryReport.level(in: report(connected: [device("100%")]),
                                                  matchingName: "Xbox Elite Wireless Controller"))
    }

    func testDisconnectedCachedLevelIsNeverUsed() {
        XCTAssertNil(BluetoothBatteryReport.level(in: report(connected: [], disconnected: [device("100%")]),
                                                  matchingName: targetName))
        XCTAssertEqual(BluetoothBatteryReport.level(in: report(connected: [device("30%")], disconnected: [device("100%")]),
                                                    matchingName: targetName), 0.3)
    }

    func testMultipleXboxDevicesAreAmbiguousEvenWithoutAnotherBattery() {
        for second in [device("20%"), ["Xbox Elite Wireless Controller": [:]]] as [[String: Any]] {
            XCTAssertNil(BluetoothBatteryReport.level(in: report(connected: [device("100%"), second]), matchingName: targetName))
        }
    }

    func testAnotherConnectedDeviceDoesNotInvalidateUniqueXbox() {
        let data = report(connected: [device("70%"), device("10%", name: "Keyboard")])
        XCTAssertEqual(BluetoothBatteryReport.level(in: data, matchingName: targetName), 0.7)
    }

    func testOnlyStrictIntegerPercentagesAreAccepted() {
        let invalid: [Any] = ["-1%", "101%", "0.5%", "NaN%", "50", "50 %", "+50%", "050%", "unknown", 50, NSNull()]
        for value in invalid {
            XCTAssertNil(BluetoothBatteryReport.level(in: report(connected: [device(value)]), matchingName: targetName), "\(value)")
        }
    }

    func testUnknownOrMalformedStructureFailsClosed() throws {
        let values: [Any] = [
            [:], ["SPBluetoothDataType": []], ["SPBluetoothDataType": "unknown"],
            ["SPBluetoothDataType": [["device_connected": device("100%")]]],
            ["SPBluetoothDataType": [["device_connected": [[targetName: "100%"]]]]],
            ["SPBluetoothDataType": [["device_connected": [[targetName: [:], "Keyboard": [:]]]]]]
        ]
        for value in values {
            let data = try JSONSerialization.data(withJSONObject: value)
            XCTAssertNil(BluetoothBatteryReport.level(in: data, matchingName: targetName))
        }
        XCTAssertNil(BluetoothBatteryReport.level(in: Data("not json".utf8), matchingName: targetName))
        XCTAssertNil(BluetoothBatteryReport.level(in: Data(repeating: 0x20, count: 1_048_577), matchingName: targetName))
    }

    func testSeparateAdaptersDoNotHideDuplicateNames() throws {
        let data = try JSONSerialization.data(withJSONObject: ["SPBluetoothDataType": [
            ["device_connected": [device("100%")]], ["device_connected": [device("20%")]]
        ]])
        XCTAssertNil(BluetoothBatteryReport.level(in: data, matchingName: targetName))
    }
}
