import AppKit
import EventKit
import Foundation
import Carbon
import Darwin

struct CalendarRow: Identifiable {
    var id: String
    var title: String
    var date: Date?
    var allDay: Bool = false
    var joinURL: URL?
}

struct CalendarSource: Identifiable { var id: String; var title: String; var account: String }

@MainActor final class WidgetRuntime: ObservableObject {
    @Published var calendarRows: [CalendarRow] = []
    @Published var reminderRows: [CalendarRow] = []
    @Published var calendarSources: [CalendarSource] = []
    @Published var accessMessage: String = ""
    @Published var busy = false
    @Published var message = ""
    @Published var musicTitle = ""
    @Published var musicArtist = ""
    @Published var musicState = ""
    @Published var musicDuration: Double = 0
    @Published var musicPosition: Double = 0
    @Published var musicArtwork: NSImage?
    @Published var musicConnected = false
    @Published var activeMusicPlayer = "Music"
    @Published var shortcutNames: [String] = []
    @Published var weatherCities: [WeatherCity] = []
    private let eventStore = EKEventStore()
    private var calendarSelection: [String]?
    private var artworkKey = ""

    func authorization(_ reminders: Bool) -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: reminders ? .reminder : .event)
    }

    func connectCalendar(reminders: Bool, selection: [String]? = nil) {
        let type: EKEntityType = reminders ? .reminder : .event
        let status = authorization(reminders)
        if status == .denied || status == .restricted {
            accessMessage = "访问未获允许。请在系统设置 → 隐私与安全性中允许 OpenDock 访问。"
            return
        }
        if status == .authorized { loadCalendar(reminders: reminders, selection: selection); return }
        busy = true
        let completion: @Sendable (Bool, Error?) -> Void = { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                if granted { self.loadCalendar(reminders: reminders, selection: selection) }
                else { self.accessMessage = error?.localizedDescription ?? "未授予访问权限。" }
            }
        }
        if #available(macOS 14.0, *) {
            if reminders { eventStore.requestFullAccessToReminders(completion: completion) }
            else { eventStore.requestFullAccessToEvents(completion: completion) }
        } else { eventStore.requestAccess(to: type, completion: completion) }
    }

    func loadCalendar(reminders: Bool, selection: [String]? = nil) {
        guard authorization(reminders) == .authorized else { return }
        calendarSelection = selection
        accessMessage = ""
        let sources = eventStore.calendars(for: reminders ? .reminder : .event)
        calendarSources = sources.map { CalendarSource(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title) }
        let selected = selection.map { ids in sources.filter { ids.contains($0.calendarIdentifier) } }
        if selected?.isEmpty == true { calendarRows = []; reminderRows = []; return }
        if reminders {
            busy = true
            let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: selected)
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
            let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: selected)
            calendarRows = eventStore.events(matching: predicate).filter { $0.endDate >= .now }.sorted { $0.startDate < $1.startDate }.prefix(30).map {
                CalendarRow(id: $0.calendarItemIdentifier + String($0.startDate.timeIntervalSince1970), title: $0.title ?? "未命名日程", date: $0.startDate, allDay: $0.isAllDay, joinURL: MeetingLink.parse(url: $0.url, location: $0.location, notes: $0.notes))
            }
        }
    }

    func completeReminder(_ identifier: String) {
        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else { return }
        do {
            reminder.isCompleted = true
            try eventStore.save(reminder, commit: true)
            loadCalendar(reminders: true, selection: calendarSelection)
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

    /// Background calls first check existing automation permission without requesting it.
    func music(player: String, action: String? = nil, automatic: Bool = false) {
        guard !busy else { return }
        let app = player == "Spotify" ? "Spotify" : "Music"
        let bundleID = app == "Spotify" ? "com.spotify.client" : "com.apple.Music"
        if automatic && (!WidgetAutomation.running(player: app) || !WidgetAutomation.allowed(bundleID: bundleID)) { return }
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
            set trackDuration to duration of current track
            \(app == "Spotify" ? "set trackDuration to trackDuration / 1000" : "")
            set artworkURL to ""
            \(app == "Spotify" ? "try\nset artworkURL to artwork url of current track\nend try" : "")
            return playbackState & linefeed & (name of current track) & linefeed & (artist of current track) & linefeed & (trackDuration as string) & linefeed & (player position as string) & linefeed & artworkURL
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
                musicDuration = rows.count > 3 ? Double(rows[3]) ?? 0 : 0
                musicPosition = rows.count > 4 ? Double(rows[4]) ?? 0 : 0
                activeMusicPlayer = app; musicConnected = true
                let key = app + musicTitle + musicArtist
                if key != artworkKey {
                    artworkKey = key; musicArtwork = nil
                    if app == "Spotify", rows.count > 5, let url = URL(string: rows[5]), url.scheme == "https" {
                        if let data = try? await WidgetNetwork.get(url), artworkKey == key { musicArtwork = NSImage(data: data) }
                    } else if app == "Music", musicState != "stopped", !automatic || WidgetAutomation.allowed(bundleID: bundleID) {
                        let file = FileManager.default.temporaryDirectory.appendingPathComponent("opendock-art-\(UUID().uuidString).image")
                        let artScript = """
                        tell application "Music"
                            try
                                set artworkData to raw data of artwork 1 of current track
                                set outputFile to open for access POSIX file "\(file.path)" with write permission
                                set eof outputFile to 0
                                write artworkData to outputFile
                                close access outputFile
                            end try
                        end tell
                        """
                        _ = await WidgetCommand.run(executable: "/usr/bin/osascript", arguments: ["-e", artScript])
                        if artworkKey == key { musicArtwork = NSImage(contentsOf: file) }
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            } else {
                message = result.error
                musicTitle = ""
            }
        }
    }

    func observeMusic(sources: [String], enabled: Bool) async {
        guard enabled else { return }
        while !Task.isCancelled {
            let running = sources.filter { WidgetAutomation.running(player: $0) }
            if running.isEmpty { musicTitle = ""; musicArtwork = nil; musicState = "" }
            else if let player = running.first(where: { WidgetAutomation.allowed(bundleID: $0 == "Spotify" ? "com.spotify.client" : "com.apple.Music") }) { music(player: player, automatic: true) }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
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

    func fetchWeather(latitude: String, longitude: String, fahrenheit: Bool = false) async -> WeatherForecast? {
        guard !busy, Double(latitude) != nil, Double(longitude) != nil else { return nil }
        busy = true; message = ""
        defer { busy = false }
        do {
            var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            url.queryItems = [URLQueryItem(name: "latitude", value: latitude), URLQueryItem(name: "longitude", value: longitude), URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m"), URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"), URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"), URLQueryItem(name: "forecast_days", value: "7"), URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"), URLQueryItem(name: "wind_speed_unit", value: fahrenheit ? "mph" : "kmh"), URLQueryItem(name: "timezone", value: "auto")]
            return try JSONDecoder().decode(WeatherForecast.self, from: await WidgetNetwork.get(url.url!))
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
struct WeatherForecast: Codable {
    var current: WeatherCurrent
    var hourly: WeatherHourly?
    var daily: WeatherDaily?
    var timezone: String?
}
struct WeatherHourly: Codable { var time: [String]; var temperature_2m: [Double?]; var precipitation_probability: [Int?]; var weather_code: [Int?] }
struct WeatherDaily: Codable { var time: [String]; var temperature_2m_max: [Double?]; var temperature_2m_min: [Double?]; var precipitation_probability_max: [Int?]; var weather_code: [Int?] }
struct WeatherCurrent: Codable {
    var time: String
    var temperature_2m: Double
    var relative_humidity_2m: Double
    var apparent_temperature: Double
    var weather_code: Int
    var wind_speed_10m: Double
}

enum WidgetAutomation {
    static func running(player: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == (player == "Spotify" ? "com.spotify.client" : "com.apple.Music") }
    }
    static func allowed(bundleID: String) -> Bool {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let result = bytes.withUnsafeBytes { AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, bytes.count, &target) }
        guard result == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) == noErr
    }
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
                    let timeout = DispatchWorkItem {
                        if process.isRunning {
                            process.terminate()
                            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                        }
                    }
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
