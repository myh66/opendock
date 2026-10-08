import AppKit
import EventKit
import Foundation
import IOKit.ps
import Darwin

struct BatteryReading {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
    var remainingMinutes: Int?

    static func read() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let remaining = description[kIOPSTimeToEmptyKey] as? Int
            let percent = min(100, max(0, Int(Double(current) / Double(maximum) * 100)))
            return BatteryReading(percent: percent,
                                  charging: percent < 100 && (description[kIOPSIsChargingKey] as? Bool ?? false),
                                  pluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                                  remainingMinutes: remaining.flatMap { $0 > 0 ? $0 : nil })
        }
        return nil
    }
}

struct SystemReading {
    var cpuPercent: Double?
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var diskFree: UInt64
    var diskTotal: UInt64
}

final class SystemSampler {
    private var previousCPU: [UInt64]?
    func read() -> SystemReading {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var cpu = host_cpu_load_info()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        var percentage: Double?
        if cpuResult == KERN_SUCCESS {
            let ticks = [UInt64(cpu.cpu_ticks.0), UInt64(cpu.cpu_ticks.1), UInt64(cpu.cpu_ticks.2), UInt64(cpu.cpu_ticks.3)]
            if let previous = previousCPU {
                let delta = zip(ticks, previous).map { $0 >= $1 ? $0 - $1 : 0 }
                let total = delta.reduce(0, +)
                if total > 0 { percentage = Double(total - delta[2]) / Double(total) * 100 }
            }
            previousCPU = ticks
        }
        var memory = vm_statistics64()
        var memoryCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let memoryResult = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(memoryCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &memoryCount)
            }
        }
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let usedPages = UInt64(memory.active_count) + UInt64(memory.wire_count) + UInt64(memory.compressor_page_count)
        let disk = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return SystemReading(cpuPercent: percentage,
                             memoryUsed: memoryResult == KERN_SUCCESS ? usedPages * UInt64(pageSize) : 0,
                             memoryTotal: ProcessInfo.processInfo.physicalMemory,
                             diskFree: (disk?[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0,
                             diskTotal: (disk?[.systemSize] as? NSNumber)?.uint64Value ?? 0)
    }
}

struct CalendarRow: Identifiable {
    var id: String
    var title: String
    var date: Date?
    var allDay: Bool = false
}

@MainActor final class WidgetRuntime: ObservableObject {
    @Published var battery: BatteryReading?
    @Published var system: SystemReading?
    @Published var calendarRows: [CalendarRow] = []
    @Published var reminderRows: [CalendarRow] = []
    @Published var accessMessage: String = ""
    @Published var busy = false
    @Published var message = ""
    @Published var musicTitle = ""
    @Published var musicArtist = ""
    @Published var musicState = ""
    @Published var shortcutNames: [String] = []
    @Published var weatherCities: [WeatherCity] = []
    private let eventStore = EKEventStore()
    private let sampler = SystemSampler()

    func observe(kind: WidgetKind) async {
        guard kind == .battery || kind == .system else { return }
        while !Task.isCancelled {
            if kind == .battery { battery = BatteryReading.read() }
            else { system = sampler.read() }
            do { try await Task.sleep(nanoseconds: kind == .battery ? 30_000_000_000 : 5_000_000_000) }
            catch { return }
        }
    }

    func authorization(_ reminders: Bool) -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: reminders ? .reminder : .event)
    }

    func connectCalendar(reminders: Bool) {
        let type: EKEntityType = reminders ? .reminder : .event
        let status = authorization(reminders)
        if status == .denied || status == .restricted {
            accessMessage = "访问未获允许。请在系统设置 → 隐私与安全性中允许 OpenDock 访问。"
            return
        }
        if status == .authorized { loadCalendar(reminders: reminders); return }
        busy = true
        let completion: @Sendable (Bool, Error?) -> Void = { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                if granted { self.loadCalendar(reminders: reminders) }
                else { self.accessMessage = error?.localizedDescription ?? "未授予访问权限。" }
            }
        }
        if #available(macOS 14.0, *) {
            if reminders { eventStore.requestFullAccessToReminders(completion: completion) }
            else { eventStore.requestFullAccessToEvents(completion: completion) }
        } else { eventStore.requestAccess(to: type, completion: completion) }
    }

    func loadCalendar(reminders: Bool) {
        guard authorization(reminders) == .authorized else { return }
        accessMessage = ""
        if reminders {
            busy = true
            let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            eventStore.fetchReminders(matching: predicate) { [weak self] reminders in
                Task { @MainActor in
                    guard let self else { return }
                    self.reminderRows = (reminders ?? []).sorted {
                        ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
                    }.prefix(30).map { CalendarRow(id: $0.calendarItemIdentifier, title: $0.title ?? "未命名提醒", date: $0.dueDateComponents?.date) }
                    self.busy = false
                }
            }
        } else {
            let start = Calendar.current.startOfDay(for: .now)
            let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(604800)
            let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
            calendarRows = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }.prefix(30).map {
                CalendarRow(id: $0.calendarItemIdentifier + String($0.startDate.timeIntervalSince1970), title: $0.title ?? "未命名日程", date: $0.startDate, allDay: $0.isAllDay)
            }
        }
    }

    func completeReminder(_ identifier: String) {
        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else { return }
        do {
            reminder.isCompleted = true
            try eventStore.save(reminder, commit: true)
            loadCalendar(reminders: true)
        } catch { accessMessage = error.localizedDescription }
    }

    func listShortcuts() {
        guard !busy else { return }
        busy = true; message = ""
        Task {
            let result = await WidgetCommand.run(executable: "/usr/bin/shortcuts", arguments: ["list"])
            busy = false
            if result.code == 0 {
                shortcutNames = result.output.split(separator: "\n").map(String.init).sorted()
                if shortcutNames.isEmpty { message = "没有快捷指令。请先在「快捷指令」App 中创建。" }
            } else { message = result.error }
        }
    }

    func runShortcut(_ name: String) {
        guard !busy, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true; message = "正在运行…"
        Task {
            let result = await WidgetCommand.run(executable: "/usr/bin/shortcuts", arguments: ["run", name])
            busy = false
            message = result.code == 0 ? "已运行「\(name)」。" : result.error
        }
    }

    /// Only called after an explicit Connect, Refresh, or playback-control click.
    func music(player: String, action: String? = nil) {
        guard !busy else { return }
        let app = player == "Spotify" ? "Spotify" : "Music"
        let bundleID = app == "Spotify" ? "com.spotify.client" : "com.apple.Music"
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            message = "尚未安装 \(app)。"; return
        }
        let command: String
        switch action {
        case "toggle": command = "playpause"
        case "next": command = "next track"
        case "previous": command = "previous track"
        default: command = ""
        }
        let script = """
        tell application "\(app)"
            \(command)
            set playbackState to player state as string
            if playbackState is "stopped" then return "stopped"
            return playbackState & linefeed & (name of current track) & linefeed & (artist of current track)
        end tell
        """
        busy = true; message = ""
        Task {
            let result = await WidgetCommand.run(executable: "/usr/bin/osascript", arguments: ["-e", script])
            busy = false
            if result.code == 0 {
                let rows = result.output.components(separatedBy: "\n")
                musicState = rows.first ?? ""
                musicTitle = rows.count > 1 ? rows[1] : "暂无正在播放的曲目"
                musicArtist = rows.count > 2 ? rows[2] : ""
            } else {
                message = result.error
                musicTitle = ""
            }
        }
    }

    func searchCities(_ query: String) async {
        guard !busy, query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
        busy = true; message = ""; weatherCities = []
        defer { busy = false }
        do {
            var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            url.queryItems = [URLQueryItem(name: "name", value: query), URLQueryItem(name: "count", value: "5"), URLQueryItem(name: "language", value: "zh"), URLQueryItem(name: "format", value: "json")]
            let data = try await WidgetNetwork.get(url.url!)
            weatherCities = try JSONDecoder().decode(WeatherSearch.self, from: data).results ?? []
            if weatherCities.isEmpty { message = "未找到城市，可尝试英文城市名。" }
        } catch { message = error.localizedDescription }
    }

    func fetchWeather(latitude: String, longitude: String) async -> WeatherCurrent? {
        guard !busy, Double(latitude) != nil, Double(longitude) != nil else { return nil }
        busy = true; message = ""
        defer { busy = false }
        do {
            var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            url.queryItems = [URLQueryItem(name: "latitude", value: latitude), URLQueryItem(name: "longitude", value: longitude), URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m"), URLQueryItem(name: "timezone", value: "auto")]
            return try JSONDecoder().decode(WeatherForecast.self, from: await WidgetNetwork.get(url.url!)).current
        } catch { message = error.localizedDescription; return nil }
    }
}

private enum WidgetNetwork {
    static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}

struct WeatherSearch: Decodable { var results: [WeatherCity]? }
struct WeatherCity: Decodable, Identifiable {
    var id: Int
    var name: String
    var latitude: Double
    var longitude: Double
    var country: String?
    var admin1: String?
    var label: String { [name, admin1, country].compactMap { $0 }.joined(separator: " · ") }
}
struct WeatherForecast: Decodable { var current: WeatherCurrent }
struct WeatherCurrent: Decodable {
    var time: String
    var temperature_2m: Double
    var relative_humidity_2m: Double
    var apparent_temperature: Double
    var weather_code: Int
    var wind_speed_10m: Double
}

enum WidgetCommand {
    struct Result { var code: Int32; var output: String; var error: String }
    static func run(executable: String, arguments: [String]) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                // Temporary files avoid deadlocks when a shortcut emits more than a pipe buffer.
                let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let out = base.appendingPathExtension("out"), err = base.appendingPathExtension("err")
                FileManager.default.createFile(atPath: out.path, contents: nil)
                FileManager.default.createFile(atPath: err.path, contents: nil)
                defer { try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: err) }
                do {
                    let output = try FileHandle(forWritingTo: out), errors = try FileHandle(forWritingTo: err)
                    defer { try? output.close(); try? errors.close() }
                    process.standardOutput = output; process.standardError = errors
                    try process.run()
                    // Cancel hung automation and commands after five minutes.
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
                    process.waitUntilExit()
                    timeout.cancel()
                    let text = (try? String(contentsOf: out, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let error = (try? String(contentsOf: err, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: Result(code: process.terminationStatus, output: String(text.prefix(8192)), error: error.isEmpty ? "操作未完成（退出码 \(process.terminationStatus)）。" : String(error.prefix(1000))))
                } catch { continuation.resume(returning: Result(code: -1, output: "", error: error.localizedDescription)) }
            }
        }
    }
}
