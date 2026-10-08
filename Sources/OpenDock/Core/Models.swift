import Foundation

enum ProfileKind: String, Codable, CaseIterable, Identifiable {
    case custom, native
    var id: String { rawValue }
    var title: String { self == .custom ? "自定义 Dock" : "macOS Dock" }
    var symbol: String { self == .custom ? "square.grid.2x2" : "macwindow" }
}

enum ItemKind: String, Codable, CaseIterable { case app, folder, file, link, spacer, widget, appGroup }

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case clock, worldClock, calendar, reminders, focus, note, battery, system, weather
    case stopwatch, countdown, hydration, timeProgress, shortcut, nowPlaying, airDrop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clock: return "时钟"
        case .worldClock: return "世界时钟"
        case .calendar: return "日历"
        case .reminders: return "提醒事项"
        case .focus: return "专注计时"
        case .note: return "便签"
        case .battery: return "电池"
        case .system: return "系统状态"
        case .weather: return "天气"
        case .stopwatch: return "秒表"
        case .countdown: return "倒计时"
        case .hydration: return "饮水记录"
        case .timeProgress: return "时间进度"
        case .shortcut: return "快捷指令"
        case .nowPlaying: return "正在播放"
        case .airDrop: return "隔空投送"
        }
    }
    var symbol: String {
        switch self {
        case .clock: return "clock"
        case .worldClock: return "globe"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .focus: return "timer"
        case .note: return "note.text"
        case .battery: return "battery.100percent"
        case .system: return "waveform.path.ecg"
        case .weather: return "cloud.sun"
        case .stopwatch: return "stopwatch"
        case .countdown: return "hourglass"
        case .hydration: return "drop"
        case .timeProgress: return "chart.pie"
        case .shortcut: return "command"
        case .nowPlaying: return "music.note"
        case .airDrop: return "airplayaudio"
        }
    }
    var category: String {
        switch self {
        case .clock, .worldClock, .stopwatch, .countdown, .timeProgress: return "时间"
        case .focus, .note, .hydration, .calendar, .reminders: return "效率"
        case .battery, .system: return "系统"
        case .weather, .nowPlaying, .shortcut, .airDrop: return "生活"
        }
    }
    var detail: String {
        switch self {
        case .clock: return "留住当下，显示本地时间与日期。"
        case .worldClock: return "让另一个时区的时间近在手边。"
        case .calendar: return "连接系统日历，查看接下来的安排。"
        case .reminders: return "查看并完成系统提醒事项。"
        case .focus: return "给专注留出一段完整的时间。"
        case .note: return "随手记录，内容保存在本机。"
        case .battery: return "查看真实电量与供电状态。"
        case .system: return "掌握 CPU、内存和磁盘状态。"
        case .weather: return "通过 Open-Meteo 查看城市天气。"
        case .stopwatch: return "开始、暂停并记录经过的时间。"
        case .countdown: return "为下一件事设定倒计时。"
        case .hydration: return "记录喝水时间与每天的饮水量。"
        case .timeProgress: return "看看今天、这个月与今年的进度。"
        case .shortcut: return "一键运行你的 macOS 快捷指令。"
        case .nowPlaying: return "连接 Apple Music 或 Spotify。"
        case .airDrop: return "使用系统分享面板投送文件。"
        }
    }
}

struct DockItem: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: ItemKind
    var title: String
    var target: String
    var widget: WidgetKind?
    var configuration: [String: String]
    init(id: UUID = UUID(), kind: ItemKind, title: String = "", target: String = "", widget: WidgetKind? = nil, configuration: [String: String] = [:]) {
        self.id = id; self.kind = kind; self.title = title; self.target = target
        self.widget = widget; self.configuration = configuration
    }
}

struct DockProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var kind: ProfileKind
    var color: String
    var items: [DockItem]
    init(id: UUID = UUID(), name: String, kind: ProfileKind = .custom, color: String = "8B7BF4", items: [DockItem] = []) {
        self.id = id; self.name = name; self.kind = kind; self.color = color; self.items = items
    }
}

enum DockPosition: String, Codable, CaseIterable, Identifiable {
    case left, bottom, right
    var id: String { rawValue }
    var title: String { switch self { case .left: return "左侧"; case .bottom: return "底部"; case .right: return "右侧" } }
}
enum DockMaterial: String, Codable, CaseIterable, Identifiable {
    case frosted, dark, clear
    var id: String { rawValue }
    var title: String { switch self { case .frosted: return "磨砂"; case .dark: return "深色"; case .clear: return "通透" } }
}

struct DockSettings: Codable, Equatable {
    var position: DockPosition = .right
    var material: DockMaterial = .frosted
    var iconSize: Double = 44
    var autoHide: Bool = false
    var showRunningApps: Bool = true
    var magnification: Bool = true
    var showTrash: Bool = true
    var showCustomDock: Bool = true
    var displayIndex: Int = 0
    var launchAtLogin: Bool = false
    var clickToMinimize: Bool = false
}

struct DockArchive: Codable, Equatable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var profiles: [DockProfile]
    var activeCustomID: UUID?
    var activeNativeID: UUID?
    var settings: DockSettings = DockSettings()
    func validated() throws -> DockArchive {
        guard version == Self.currentVersion else { throw ArchiveError.unsupportedVersion }
        guard !profiles.isEmpty, profiles.count <= 100 else { throw ArchiveError.invalidProfiles }
        guard Set(profiles.map(\.id)).count == profiles.count else { throw ArchiveError.duplicateIDs }
        var ids = Set<UUID>()
        for profile in profiles {
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, profile.items.count <= 500 else { throw ArchiveError.invalidProfiles }
            for item in profile.items {
                guard ids.insert(item.id).inserted else { throw ArchiveError.duplicateIDs }
                if item.kind == .widget && item.widget == nil { throw ArchiveError.invalidProfiles }
                if profile.kind == .native && item.kind != .app && item.kind != .spacer { throw ArchiveError.invalidProfiles }
            }
        }
        guard settings.iconSize.isFinite, (24...80).contains(settings.iconSize), (0...32).contains(settings.displayIndex) else { throw ArchiveError.invalidSettings }
        if let id = activeCustomID, !profiles.contains(where: { $0.id == id && $0.kind == .custom }) { throw ArchiveError.invalidProfiles }
        if let id = activeNativeID, !profiles.contains(where: { $0.id == id && $0.kind == .native }) { throw ArchiveError.invalidProfiles }
        return self
    }
    func mergingProfiles(from other: DockArchive) throws -> DockArchive {
        let incoming = try other.validated()
        var result = self
        for var profile in incoming.profiles {
            profile.id = UUID()
            profile.items = profile.items.map { item in var copy = item; copy.id = UUID(); return copy }
            if result.profiles.contains(where: { $0.name == profile.name }) { profile.name += "（导入）" }
            result.profiles.append(profile)
        }
        return try result.validated()
    }
}

enum ArchiveError: LocalizedError {
    case unsupportedVersion, invalidProfiles, duplicateIDs, invalidSettings
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "备份版本不受支持，请更新 OpenDock。"
        case .invalidProfiles: return "布局数据不完整或超过允许数量。"
        case .duplicateIDs: return "备份包含重复标识，无法安全导入。"
        case .invalidSettings: return "备份中的 Dock 外观设置无效。"
        }
    }
}
