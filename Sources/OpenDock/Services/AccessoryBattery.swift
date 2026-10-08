import Foundation
import IOKit
import IOKit.ps

struct AccessoryBatteryMetrics: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let transport: String?
    let chargePercent: Double
    let isCharging: Bool
    let isCharged: Bool
    let hasChargingState: Bool

    var status: String { isCharged ? "已充满" : (isCharging ? "正在充电" : (hasChargingState ? "未充电" : "充电状态不可用")) }
}

/// Reads only battery/name properties already published by connected HID services.
/// Does not open devices, pair Bluetooth accessories, or use private power-source APIs.
enum AccessoryBatteryReader {
    static func read() -> [AccessoryBatteryMetrics] {
        var result: [AccessoryBatteryMetrics] = []
        var seen = Set<UInt64>()
        for serviceClass in ["IOHIDDevice", "AppleDeviceManagementHIDEventService"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var entryID: UInt64 = 0
                let identified = IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS
                if identified, seen.insert(entryID).inserted {
                    var properties: [String: Any] = [:]
                    for key in propertyKeys {
                        if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() { properties[key] = value }
                    }
                    if let value = parse(properties, id: physicalIdentity(of: service, fallback: entryID)) { result.append(value) }
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
        }
        return deduplicated(result)
    }

    /// An event service and its HID parent can both publish the same battery.
    /// Parent identity avoids collecting serial numbers or merging unrelated names.
    private static func physicalIdentity(of service: io_registry_entry_t, fallback: UInt64) -> String {
        IOObjectRetain(service)
        var current = service
        defer { IOObjectRelease(current) }
        for _ in 0..<12 {
            if IOObjectConformsTo(current, "IOHIDDevice") != 0 {
                var identity: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(current, &identity) == KERN_SUCCESS { return String(identity) }
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { break }
            IOObjectRelease(current)
            current = parent
        }
        return String(fallback)
    }

    static func deduplicated(_ values: [AccessoryBatteryMetrics]) -> [AccessoryBatteryMetrics] {
        // Event-service readings arrive after general HID readings and take precedence
        // only when a shared public HID ancestor proves they are the same device.
        var devices: [String: AccessoryBatteryMetrics] = [:]
        for value in values { devices[value.id] = value }
        return devices.values.sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static let propertyKeys = ["Product", "ProductName", "Name", "Transport", "Connected", "BatteryPercent", "BatteryPercentage", "BatteryCurrentCapacity", "BatteryMaxCapacity", "BatteryIsCharging", "IsCharging", kIOPSIsChargingKey, "BatteryFullyCharged", "FullyCharged", "IsCharged", kIOPSIsChargedKey]

    static func parse(_ properties: [String: Any], id: String) -> AccessoryBatteryMetrics? {
        if (properties["Connected"] as? NSNumber)?.boolValue == false { return nil }
        func number(_ key: String) -> Double? {
            guard let value = properties[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        var percent = number("BatteryPercent") ?? number("BatteryPercentage")
        if percent == nil, let current = number("BatteryCurrentCapacity"), let maximum = number("BatteryMaxCapacity"), maximum > 0, current >= 0, current <= maximum { percent = current / maximum * 100 }
        guard let percent, (0...100).contains(percent) else { return nil }
        let name = ["Product", "ProductName", "Name"].compactMap { properties[$0] as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "电池外设"
        let explicitlyCharged = ["BatteryFullyCharged", "FullyCharged", "IsCharged", kIOPSIsChargedKey].contains { (properties[$0] as? NSNumber)?.boolValue == true }
        let charged = explicitlyCharged || percent >= 100
        let chargingFlags = ["BatteryIsCharging", "IsCharging", kIOPSIsChargingKey].compactMap { properties[$0] as? NSNumber }
        let charging = !charged && chargingFlags.contains { $0.boolValue }
        return AccessoryBatteryMetrics(id: id, name: String(name.prefix(160)), transport: properties["Transport"] as? String, chargePercent: percent, isCharging: charging, isCharged: charged, hasChargingState: !chargingFlags.isEmpty)
    }
}
