import XCTest
import RemoteCore

final class ControllerBatterySnapshotTests: XCTestCase {
    func testUnsupportedAndDefaultReadingsAreNotAnEmptyBattery() {
        for level in [nil, 0.0] as [Double?] {
            let snapshot = ControllerBatterySnapshot(isConnected: true, level: level, powerState: .unknown)
            XCTAssertTrue(snapshot.isConnected)
            XCTAssertNil(snapshot.level)
            XCTAssertNil(snapshot.percentage)
            XCTAssertFalse(snapshot.isLow)
        }
    }

    func testValidLevelDoesNotRequireKnownChargingState() {
        let snapshot = ControllerBatterySnapshot(isConnected: true, level: 0.65, powerState: .unknown)
        XCTAssertEqual(snapshot.percentage, 65)
        XCTAssertEqual(snapshot.powerState, .unknown)
        XCTAssertFalse(snapshot.isLow)
    }

    func testInvalidMeasurementsCannotBecomeZeroOrFullBars() {
        for level in [-0.01, 1.01, .nan, .infinity, -.infinity] {
            let snapshot = ControllerBatterySnapshot(isConnected: true, level: level, powerState: .discharging)
            XCTAssertNil(snapshot.level)
            XCTAssertNil(snapshot.percentage)
            XCTAssertFalse(snapshot.isLow)
        }
    }

    func testKnownDischargingZeroIsActuallyEmpty() {
        let snapshot = ControllerBatterySnapshot(isConnected: true, level: 0, powerState: .discharging)
        XCTAssertEqual(snapshot.level, 0)
        XCTAssertEqual(snapshot.percentage, 0)
        XCTAssertTrue(snapshot.isLow)
    }

    func testLowBatteryMatchesDisplayedPercentageAndChargingSuppressesWarning() {
        XCTAssertTrue(ControllerBatterySnapshot(isConnected: true, level: 0.20, powerState: .discharging).isLow)
        XCTAssertFalse(ControllerBatterySnapshot(isConnected: true, level: 0.21, powerState: .discharging).isLow)
        XCTAssertFalse(ControllerBatterySnapshot(isConnected: true, level: 0.05, powerState: .charging).isLow)
    }

    func testFullStateIsAnExplicitFullCharge() {
        let snapshot = ControllerBatterySnapshot(isConnected: true, level: 0, powerState: .full)
        XCTAssertEqual(snapshot.level, 1)
        XCTAssertEqual(snapshot.percentage, 100)
        XCTAssertFalse(snapshot.isLow)
    }

    func testDisconnectDiscardsPreviousLevelAndChargingState() {
        for state in [ControllerBatterySnapshot.PowerState.discharging, .charging, .full] {
            let snapshot = ControllerBatterySnapshot(isConnected: false, level: 0.8, powerState: state)
            XCTAssertEqual(snapshot, .disconnected)
            XCTAssertNil(snapshot.percentage)
            XCTAssertFalse(snapshot.isLow)
        }
    }

    func testBluetoothZeroIsTrustedButDoesNotInventChargingState() {
        let native = ControllerBatterySnapshot(isConnected: true, level: 0, powerState: .unknown)
        let bluetooth = ControllerBatterySnapshot(isConnected: true, level: 0, powerState: .unknown,
                                                   source: .systemBluetooth)
        XCTAssertNil(native.level)
        XCTAssertEqual(bluetooth.percentage, 0)
        XCTAssertTrue(bluetooth.isLow)
        XCTAssertEqual(bluetooth.source, .systemBluetooth)
    }

    func testBluetoothPercentageCannotEstablishFullOrChargingState() {
        for state in [ControllerBatterySnapshot.PowerState.charging, .full] {
            let snapshot = ControllerBatterySnapshot(isConnected: true, level: 0.55, powerState: state,
                                                     source: .systemBluetooth)
            XCTAssertEqual(snapshot.percentage, 55)
            XCTAssertEqual(snapshot.powerState, .unknown)
        }
        let snapshot = ControllerBatterySnapshot(isConnected: true, level: 1, powerState: .unknown,
                                                 source: .systemBluetooth)
        XCTAssertEqual(snapshot.percentage, 100)
        XCTAssertEqual(snapshot.powerState, .unknown)
    }

    func testDisconnectClearsBluetoothSourceAsWellAsValue() {
        XCTAssertEqual(ControllerBatterySnapshot(isConnected: false, level: 0.8, powerState: .unknown,
                                                 source: .systemBluetooth), .disconnected)
    }
}
