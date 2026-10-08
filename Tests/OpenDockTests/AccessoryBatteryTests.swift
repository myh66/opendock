import XCTest
@testable import OpenDock

final class AccessoryBatteryTests: XCTestCase {
    func testFullyChargedWinsOverConflictingChargingFlag() throws {
        let full = try XCTUnwrap(AccessoryBatteryReader.parse(["Product": "Synthetic Keyboard", "BatteryPercent": 96, "IsCharging": true, "IsCharged": true], id: "fixture"))
        XCTAssertTrue(full.isCharged)
        XCTAssertFalse(full.isCharging)
        XCTAssertEqual(full.status, "已充满")
        let percentFull = try XCTUnwrap(AccessoryBatteryReader.parse(["BatteryPercent": 100, "BatteryIsCharging": true], id: "fixture"))
        XCTAssertFalse(percentFull.isCharging)
        let unknown = try XCTUnwrap(AccessoryBatteryReader.parse(["BatteryPercent": 50], id: "fixture"))
        XCTAssertEqual(unknown.status, "充电状态不可用")
    }

    func testConnectedAccessoriesUseOnlyValidPublishedCapacity() throws {
        let charging = try XCTUnwrap(AccessoryBatteryReader.parse(["ProductName": "Synthetic Mouse", "Transport": "Bluetooth", "BatteryCurrentCapacity": 30, "BatteryMaxCapacity": 60, "BatteryIsCharging": true], id: "fixture"))
        XCTAssertEqual(charging.chargePercent, 50)
        XCTAssertTrue(charging.isCharging)
        XCTAssertFalse(charging.isCharged)
        XCTAssertEqual(charging.transport, "Bluetooth")
        for invalid: [String: Any] in [["BatteryPercent": 101], ["BatteryPercent": -1], ["BatteryPercent": Double.nan], ["BatteryPercent": true], ["BatteryLevel": 255], ["BatteryCurrentCapacity": 12, "BatteryMaxCapacity": 0], ["BatteryPercent": 50, "Connected": false]] {
            XCTAssertNil(AccessoryBatteryReader.parse(invalid, id: "fixture"))
        }
    }

    func testSharedHIDIdentityMergesNodesWithoutMergingIdenticallyNamedDevices() throws {
        let parent = try XCTUnwrap(AccessoryBatteryReader.parse(["Product": "Synthetic Mouse", "BatteryPercent": 90], id: "physical-1"))
        let event = try XCTUnwrap(AccessoryBatteryReader.parse(["Product": "Synthetic Mouse", "BatteryPercent": 96, "IsCharged": true, "IsCharging": true], id: "physical-1"))
        let secondDevice = try XCTUnwrap(AccessoryBatteryReader.parse(["Product": "Synthetic Mouse", "BatteryPercent": 50], id: "physical-2"))
        let devices = AccessoryBatteryReader.deduplicated([parent, event, secondDevice])
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first, event)
        XCTAssertFalse(devices[0].isCharging)
        XCTAssertEqual(devices[1], secondDevice)
    }
}
