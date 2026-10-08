import XCTest
@testable import OpenDock

final class SystemMetricsTests: XCTestCase {
    func testPerCoreUsageSeparatesIdleAndBusyTicks() {
        let old = [CPUTicks(user: 100, system: 30, idle: 200, nice: 10), CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let current = [CPUTicks(user: 140, system: 40, idle: 240, nice: 10), CPUTicks(user: 0, system: 0, idle: 100, nice: 0)]
        let usage = SystemMetrics.cpuUsage(previous: old, current: current)
        XCTAssertEqual(usage[0], 50.0 / 90, accuracy: 0.00001)
        XCTAssertEqual(usage[1], 0)
        XCTAssertTrue(SystemMetrics.cpuUsage(previous: [], current: current).isEmpty)
    }

    func testCPUCounterRolloverDoesNotCreateNegativeUsage() {
        let old = CPUTicks(user: UInt64(UInt32.max) - 4, system: 0, idle: 100, nice: 0)
        let current = CPUTicks(user: 5, system: 0, idle: 110, nice: 0)
        XCTAssertEqual(SystemMetrics.cpuUsage(previous: [old], current: [current])[0], 0.5, accuracy: 0.00001)
    }

    func testNetworkRatesUseElapsedTimeAndResetBaselines() {
        XCTAssertEqual(SystemMetrics.rate(current: 4000, previous: 1000, interval: 2), 1500)
        XCTAssertEqual(SystemMetrics.rate(current: 5, previous: 1000, interval: 2), 0)
        XCTAssertEqual(SystemMetrics.rate(current: 4000, previous: 1000, interval: 0), 0)
        XCTAssertEqual(SystemMetrics.rate(current: 4000, previous: 1000, interval: .infinity), 0)
    }
}
