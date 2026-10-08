import Combine
import Darwin
import Foundation
import IOKit
import IOKit.ps

struct CPUTicks: Equatable, Sendable {
    let user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
}

struct BatteryMetrics: Sendable {
    let chargePercent: Double
    let isCharging: Bool
    let isOnAC: Bool
    let cycleCount: Int?
    let healthPercent: Double?
    let voltageVolts: Double?
    let currentAmps: Double?
    let powerWatts: Double?
}

struct NetworkInterfaceMetrics: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let addresses: [String]
    let isUp: Bool
    let receivedBytes: UInt64
    let sentBytes: UInt64
    var receivedBytesPerSecond: Double = 0
    var sentBytesPerSecond: Double = 0
}

struct SystemMetricsSnapshot: Sendable {
    var sampledAt: Date?
    var cpuHasSample = false
    var cpuTotal: Double = 0
    var cpuPerCore: [Double] = []
    var memoryUsedBytes: UInt64 = 0
    var memoryTotalBytes: UInt64 = 0
    var memoryWiredBytes: UInt64 = 0
    var memoryCompressedBytes: UInt64 = 0
    var memoryFileCacheBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var memoryPressure = "无法读取"
    var loadAverage: [Double] = []
    var thermalState = "无法读取"
    var uptime: TimeInterval = 0
    var battery: BatteryMetrics?
    var network: [NetworkInterfaceMetrics] = []
}

/// Public Mach, sysctl, IOKit, and interface counters. Monitoring starts only
/// when a system widget asks for it. No shell tools or privileged helpers run.
@MainActor
final class SystemMetrics: ObservableObject {
    static let shared = SystemMetrics()
    @Published private(set) var snapshot = SystemMetricsSnapshot()
    private var timer: Timer?
    private var previousCPU: [CPUTicks] = []
    private var previousNetwork: [String: NetworkInterfaceMetrics] = [:]
    private var previousUptime: TimeInterval?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer?.tolerance = 0.3
    }

    func stop() { timer?.invalidate(); timer = nil; previousCPU = []; previousNetwork = [:]; previousUptime = nil }

    func refresh() {
        var value = SystemMetricsSnapshot()
        value.sampledAt = Date(); value.uptime = ProcessInfo.processInfo.systemUptime
        let currentCPU = Self.readCPUTicks()
        value.cpuHasSample = !previousCPU.isEmpty && currentCPU.count == previousCPU.count
        if value.cpuHasSample {
            value.cpuPerCore = Self.cpuUsage(previous: previousCPU, current: currentCPU)
            value.cpuTotal = value.cpuPerCore.isEmpty ? 0 : value.cpuPerCore.reduce(0, +) / Double(value.cpuPerCore.count)
        }
        previousCPU = currentCPU
        Self.readMemory(into: &value)
        var averages = [Double](repeating: 0, count: 3)
        let averageCount = getloadavg(&averages, 3)
        if averageCount > 0 { value.loadAverage = Array(averages.prefix(Int(averageCount))) }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: value.thermalState = "正常"
        case .fair: value.thermalState = "较高"
        case .serious: value.thermalState = "严重"
        case .critical: value.thermalState = "临界"
        @unknown default: value.thermalState = "未知"
        }
        value.battery = Self.readBattery()
        value.network = Self.readNetwork()
        if let previousUptime {
            let interval = value.uptime - previousUptime
            for index in value.network.indices {
                guard let previous = previousNetwork[value.network[index].name] else { continue }
                value.network[index].receivedBytesPerSecond = Self.rate(current: value.network[index].receivedBytes, previous: previous.receivedBytes, interval: interval)
                value.network[index].sentBytesPerSecond = Self.rate(current: value.network[index].sentBytes, previous: previous.sentBytes, interval: interval)
            }
        }
        previousNetwork = Dictionary(uniqueKeysWithValues: value.network.map { ($0.name, $0) }); previousUptime = value.uptime
        snapshot = value
    }

    nonisolated static func cpuUsage(previous: [CPUTicks], current: [CPUTicks]) -> [Double] {
        guard previous.count == current.count else { return [] }
        return zip(previous, current).map { previous, current in
            // Kernel CPU counters are 32-bit even on 64-bit machines.
            func delta(_ current: UInt64, _ old: UInt64) -> UInt64 {
                current >= old ? current - old : (UInt64(UInt32.max) - old + current + 1)
            }
            let busy = delta(current.user, previous.user) + delta(current.system, previous.system) + delta(current.nice, previous.nice)
            let total = busy + delta(current.idle, previous.idle)
            return total == 0 ? 0 : min(1, Double(busy) / Double(total))
        }
    }

    nonisolated static func rate(current: UInt64, previous: UInt64, interval: TimeInterval) -> Double {
        guard current >= previous, interval > 0, interval.isFinite else { return 0 }
        return Double(current - previous) / interval
    }

    private static func readCPUTicks() -> [CPUTicks] {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var processors: natural_t = 0
        var data: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processors, &data, &count) == KERN_SUCCESS, let data else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: data)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        return (0..<Int(processors)).map { index in
            let offset = index * Int(CPU_STATE_MAX)
            return CPUTicks(user: UInt64(UInt32(bitPattern: data[offset + Int(CPU_STATE_USER)])),
                            system: UInt64(UInt32(bitPattern: data[offset + Int(CPU_STATE_SYSTEM)])),
                            idle: UInt64(UInt32(bitPattern: data[offset + Int(CPU_STATE_IDLE)])),
                            nice: UInt64(UInt32(bitPattern: data[offset + Int(CPU_STATE_NICE)])))
        }
    }

    private static func readMemory(into value: inout SystemMetricsSnapshot) {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        value.memoryTotalBytes = ProcessInfo.processInfo.physicalMemory
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        if status == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let allocated = UInt64(info.active_count) + UInt64(info.inactive_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
            let reclaimable = UInt64(info.purgeable_count) + UInt64(info.external_page_count)
            value.memoryUsedBytes = min(value.memoryTotalBytes, (allocated > reclaimable ? allocated - reclaimable : 0) * page)
            value.memoryWiredBytes = UInt64(info.wire_count) * page
            value.memoryCompressedBytes = UInt64(info.compressor_page_count) * page
            value.memoryFileCacheBytes = UInt64(info.external_page_count) * page
        }
        var pressure: Int32 = 0, pressureSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0 {
            value.memoryPressure = pressure == 1 ? "正常" : pressure == 2 ? "警告" : pressure == 4 ? "严重" : "未知"
        }
        var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { value.swapUsedBytes = swap.xsu_used }
    }

    private static func readBattery() -> BatteryMetrics? {
        guard let opaque = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(opaque)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        guard let description = sources.compactMap({ IOPSGetPowerSourceDescription(opaque, $0)?.takeUnretainedValue() as? [String: Any] }).first(where: { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }),
              let current = description[kIOPSCurrentCapacityKey] as? Double,
              let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { return nil }
        var registry: [String: Any] = [:]
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS { registry = properties?.takeRetainedValue() as? [String: Any] ?? [:] }
        }
        func number(_ key: String) -> Double? { (registry[key] as? NSNumber)?.doubleValue }
        let design = number("DesignCapacity"), actualMax = number("AppleRawMaxCapacity") ?? number("MaxCapacity")
        let health = design.flatMap { design -> Double? in guard design > 0, let actualMax, actualMax > 100 else { return nil }; return min(100, actualMax / design * 100) }
        let voltage = number("Voltage").map { $0 / 1000 }, amps = (registry["Amperage"] as? NSNumber).map { Double($0.int64Value) / 1000 }
        let watts = voltage.flatMap { volts in amps.map { $0 * volts } }
        return BatteryMetrics(chargePercent: min(100, max(0, current / maximum * 100)), isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                              isOnAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                              cycleCount: (registry["CycleCount"] as? NSNumber)?.intValue, healthPercent: health, voltageVolts: voltage, currentAmps: amps, powerWatts: watts)
    }

    private static func readNetwork() -> [NetworkInterfaceMetrics] {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return [] }
        defer { freeifaddrs(first) }
        var addresses: [String: Set<String>] = [:], flags: [String: Bool] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let item = pointer {
            let value = item.pointee, name = String(cString: value.ifa_name)
            if name != "lo0" {
                flags[name] = value.ifa_flags & UInt32(IFF_UP) != 0 && value.ifa_flags & UInt32(IFF_RUNNING) != 0
                if let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { addresses[name, default: []].insert(String(cString: host)) }
                }
            }
            pointer = value.ifa_next
        }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else { return [] }
        var counters: [String: (UInt64, UInt64)] = [:]
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let message = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let length = Int(message.ifm_msglen)
                guard length > 0, offset + length <= size else { break }
                if message.ifm_type == UInt8(RTM_IFINFO2), length >= MemoryLayout<if_msghdr2>.size {
                    let extended = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(extended.ifm_index), &name) != nil { counters[String(cString: name)] = (extended.ifm_data.ifi_ibytes, extended.ifm_data.ifi_obytes) }
                }
                offset += length
            }
        }
        return flags.map { name, up in
            let bytes = counters[name] ?? (0, 0)
            return NetworkInterfaceMetrics(name: name, addresses: Array(addresses[name] ?? []).sorted(), isUp: up, receivedBytes: bytes.0, sentBytes: bytes.1)
        }.sorted {
            if $0.isUp != $1.isUp { return $0.isUp }
            if $0.name.hasPrefix("en") != $1.name.hasPrefix("en") { return $0.name.hasPrefix("en") }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    deinit { timer?.invalidate() }
}
