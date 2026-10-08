import AppKit
import EventKit
import SwiftUI

struct WidgetTile: View {
    let item: DockItem
    var compact: Bool = false
    let onUpdate: (DockItem) -> Void
    @StateObject private var runtime = WidgetRuntime()
    @State private var presented = false
    @State private var config: [String: String] = [:]
    @State private var cityQuery = ""
    @State private var timezoneSearch = ""
    @State private var durationMinutes = "25"
    @State private var waterAmount = "250"
    @State private var waterGoal = "2000"
    @State private var shortcutName = ""
    @State private var showClearNote = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: WidgetKind { item.widget ?? .clock }
    private var timeSensitive: Bool {
        switch kind {
        case .clock, .worldClock: return true
        case .focus, .countdown: return WidgetState.number(config, "deadline") > Date.now.timeIntervalSince1970
        case .stopwatch: return WidgetState.number(config, "started") > 0
        default: return false
        }
    }

    var body: some View {
        Button {
            // The custom Dock uses a nonactivating panel; activation permits typing in popovers.
            NSApp.activate(ignoringOtherApps: true)
            presented.toggle()
        } label: {
            TimelineView(.periodic(from: .now, by: timeSensitive ? 1 : 60)) { context in
                HStack(spacing: 9) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: compact ? 18 : 21, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary(at: context.date))
                            .font(.system(size: 13, weight: .semibold, design: timeSensitive ? .monospaced : .default))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(subtitle(at: context.date))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .frame(width: compact ? 132 : 140, height: 58)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.1)))
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .buttonStyle(.plain)
        .help("\(kind.title)：\(kind.detail)")
        .accessibilityLabel(kind.title)
        .accessibilityValue(summary(at: .now))
        .popover(isPresented: $presented, arrowEdge: compact ? .leading : .bottom) {
            popover
        }
        .onAppear { synchronize() }
        .onChange(of: item.configuration) { updated in
            if config != updated { config = updated }
        }
        .task(id: kind) { await runtime.observe(kind: kind) }
    }

    private var tint: Color {
        switch kind {
        case .clock, .worldClock, .timeProgress: return .indigo
        case .focus, .stopwatch, .countdown: return .orange
        case .hydration, .weather: return .cyan
        case .battery, .system: return .green
        case .calendar, .reminders: return .pink
        default: return .purple
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: kind.symbol).foregroundStyle(tint)
                Text(kind.title).font(.headline)
                Spacer()
                Button { presented = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("关闭")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { widgetControls }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 430)
            if runtime.busy { ProgressView().controlSize(.small) }
            if !runtime.message.isEmpty { Text(runtime.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .padding(18)
        .frame(width: 338)
        .onExitCommand { presented = false }
        .background {
            Button("关闭小组件") { presented = false }.keyboardShortcut("w", modifiers: .command).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .onAppear {
            synchronize()
            if kind == .calendar { runtime.loadCalendar(reminders: false) }
            if kind == .reminders { runtime.loadCalendar(reminders: true) }
        }
    }

    @ViewBuilder private var widgetControls: some View {
        switch kind {
        case .clock, .worldClock: clockControls
        case .focus, .countdown: countdownControls
        case .stopwatch: stopwatchControls
        case .note: noteControls
        case .hydration: hydrationControls
        case .timeProgress: progressControls
        case .battery: batteryControls
        case .system: systemControls
        case .calendar: calendarControls(reminders: false)
        case .reminders: calendarControls(reminders: true)
        case .weather: weatherControls
        case .shortcut: shortcutControls
        case .nowPlaying: musicControls
        case .airDrop: airDropControls
        }
    }

    private var clockControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.periodic(from: .now, by: timeSensitive ? 1 : 60)) { context in
                Text(clockText(context.date, format: "HH:mm:ss")).font(.system(size: 36, weight: .light, design: .monospaced))
                Text(clockText(context.date, format: "yyyy年M月d日 EEEE")).foregroundStyle(.secondary)
            }
            if kind == .worldClock {
                Text("时区").font(.caption).foregroundStyle(.secondary)
                TextField("搜索城市或时区，例如 Shanghai", text: $timezoneSearch)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredTimezones.prefix(30), id: \.self) { identifier in
                            Button {
                                set("timezone", identifier)
                                timezoneSearch = ""
                            } label: {
                                HStack {
                                    Text(identifier.replacingOccurrences(of: "_", with: " ")).lineLimit(1)
                                    Spacer()
                                    if config["timezone"] == identifier { Image(systemName: "checkmark") }
                                }.padding(.vertical, 4)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: 155)
                Text(config["timezone"] ?? TimeZone.current.identifier).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("使用 Mac 当前时区：\(TimeZone.current.identifier)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var filteredTimezones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        return timezoneSearch.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(timezoneSearch) }
    }

    private var countdownControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.periodic(from: .now, by: timeSensitive ? 1 : 60)) { context in
                let remaining = WidgetState.remaining(config, at: context.date, defaultDuration: defaultDuration)
                Text(WidgetState.durationText(remaining)).font(.system(size: 42, weight: .light, design: .monospaced))
                if remaining == 0 { Label("计时已完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                else if WidgetState.number(config, "deadline") > 0 { Text("进行中").foregroundStyle(.secondary) }
                else { Text("点击开始计时").foregroundStyle(.secondary) }
            }
            HStack {
                TextField("分钟", text: $durationMinutes).frame(width: 65)
                Text("分钟").foregroundStyle(.secondary)
                Button("设定") {
                    let parsed = Double(durationMinutes)
                    let minutes = min(1440, max(1, parsed?.isFinite == true ? parsed! : (kind == .focus ? 25 : 5)))
                    update(["duration": String(minutes * 60), "remaining": String(minutes * 60), "deadline": ""])
                    durationMinutes = String(Int(minutes))
                }.disabled(WidgetState.number(config, "deadline") > 0)
            }
            HStack {
                Button(WidgetState.number(config, "deadline") > 0 ? "暂停" : "开始") {
                    if WidgetState.number(config, "deadline") > 0 {
                        update(["remaining": String(WidgetState.remaining(config, at: .now, defaultDuration: defaultDuration)), "deadline": ""])
                    } else {
                        let remaining = WidgetState.remaining(config, at: .now, defaultDuration: defaultDuration)
                        set("deadline", String(Date.now.timeIntervalSince1970 + (remaining > 0 ? remaining : defaultDuration)))
                    }
                }.buttonStyle(.borderedProminent).tint(tint)
                Button("重置") { update(["deadline": "", "remaining": String(defaultDuration)]) }
            }
            Text("计时按实际时间推进，关闭面板或重新打开 App 后仍可恢复。到时在此处显示完成状态。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var defaultDuration: Double { WidgetState.boundedNumber(config, "duration", default: kind == .focus ? 1500 : 300, range: 60...86400) }

    private var stopwatchControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.periodic(from: .now, by: timeSensitive ? 1 : 60)) { context in
                Text(WidgetState.durationText(WidgetState.elapsed(config, at: context.date)))
                    .font(.system(size: 42, weight: .light, design: .monospaced))
            }
            HStack {
                Button(WidgetState.number(config, "started") > 0 ? "暂停" : "开始") {
                    if WidgetState.number(config, "started") > 0 { update(["elapsed": String(WidgetState.elapsed(config, at: .now)), "started": ""]) }
                    else { set("started", String(Date.now.timeIntervalSince1970)) }
                }.buttonStyle(.borderedProminent).tint(tint)
                Button("计次") {
                    let laps = (config["laps"] ?? "").split(separator: "|").map(String.init)
                    let updated = Array((laps + [WidgetState.durationText(WidgetState.elapsed(config, at: .now))]).suffix(50))
                    set("laps", updated.joined(separator: "|"))
                }
                Button("重置") { update(["elapsed": "0", "started": "", "laps": ""]) }
            }
            ForEach(Array((config["laps"] ?? "").split(separator: "|").enumerated()), id: \.offset) { offset, lap in
                HStack { Text("第 \(offset + 1) 次").foregroundStyle(.secondary); Spacer(); Text(String(lap)).monospacedDigit() }
            }
        }
    }

    private var noteControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: Binding(get: { config["note"] ?? "" }, set: { set("note", String($0.prefix(20000))) }))
                .font(.body).frame(height: 200)
                .padding(7).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if (config["note"] ?? "").isEmpty { Text("记录一个想法…").foregroundStyle(.tertiary).padding(12).allowsHitTesting(false) }
                }
            HStack {
                Text("自动保存在本机").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清空") { showClearNote = true }.disabled((config["note"] ?? "").isEmpty)
            }
        }.confirmationDialog("清空这条便签？", isPresented: $showClearNote) { Button("清空便签", role: .destructive) { set("note", "") } }
    }

    private var hydrationControls: some View {
        let entries = WidgetState.hydration(config)
        let today = entries.filter { Calendar.current.isDateInToday(Date(timeIntervalSince1970: $0.timestamp)) }
        let total = WidgetState.hydrationTotal(entries, at: .now)
        let goal = WidgetState.boundedNumber(config, "waterGoal", default: 2000, range: 1...10000)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(total)").font(.system(size: 38, weight: .light)).monospacedDigit()
                Text("/ \(Int(goal)) ml").foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, Double(total) / goal)).tint(tint)
            HStack {
                TextField("饮水量", text: $waterAmount).frame(width: 65)
                Text("ml").foregroundStyle(.secondary)
                Button("记录") {
                    let amount = min(5000, max(1, Int(waterAmount) ?? 250))
                    set("waterHistory", WidgetState.encodedWater(entries + [WaterEntry(timestamp: Date.now.timeIntervalSince1970, milliliters: amount)]))
                }.buttonStyle(.borderedProminent).tint(tint)
            }
            HStack {
                Text("每日目标")
                TextField("目标", text: $waterGoal).frame(width: 65)
                Text("ml")
                Button("保存") { let goal = min(10000, max(1, Int(waterGoal) ?? 2000)); set("waterGoal", String(goal)); waterGoal = String(goal) }
            }.font(.caption)
            if today.isEmpty { Text("今天还没有饮水记录。").foregroundStyle(.secondary) }
            ForEach(today.reversed()) { entry in
                HStack {
                    Text(Date(timeIntervalSince1970: entry.timestamp), style: .time).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(entry.milliliters) ml").monospacedDigit()
                    Button { set("waterHistory", WidgetState.encodedWater(entries.filter { $0.id != entry.id })) } label: { Image(systemName: "arrow.uturn.backward") }.help("撤销这次记录")
                }.font(.caption)
            }
            Text("记录按本地日期统计；每日目标由你设定。保留最近 2,000 次记录。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var progressControls: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 17) {
                ForEach(["今天", "本月", "今年"], id: \.self) { title in
                    let component: Calendar.Component = title == "今天" ? .day : (title == "本月" ? .month : .year)
                    let value = WidgetState.progress(component, at: context.date)
                    HStack { Text(title); Spacer(); Text(String(format: "%.1f%%", value * 100)).monospacedDigit().foregroundStyle(.secondary) }
                    ProgressView(value: value).tint(tint)
                }
                Text("依据 Mac 当前日历与时区计算。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var batteryControls: some View {
        if let battery = runtime.battery {
            Text("\(battery.percent)%").font(.system(size: 42, weight: .light)).monospacedDigit()
            ProgressView(value: Double(battery.percent) / 100).tint(tint)
            Label(battery.charging ? "正在充电" : (battery.pluggedIn ? "连接电源" : "使用电池"), systemImage: battery.pluggedIn ? "bolt.fill" : "battery.100percent")
            if let minutes = battery.remainingMinutes { Text("系统估算剩余 \(minutes / 60) 小时 \(minutes % 60) 分钟").font(.caption).foregroundStyle(.secondary) }
            Text("来自 macOS 电源信息，每 30 秒刷新。").font(.caption).foregroundStyle(.secondary)
        } else { unavailable("未检测到电池", detail: "台式 Mac 或不提供电池信息的设备会显示此状态。", symbol: "powerplug") }
    }

    @ViewBuilder private var systemControls: some View {
        if let reading = runtime.system {
            metric("CPU", value: reading.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "采样中", progress: (reading.cpuPercent ?? 0) / 100)
            metric("内存使用估算", value: "\(bytes(reading.memoryUsed)) / \(bytes(reading.memoryTotal))", progress: Double(reading.memoryUsed) / Double(max(1, reading.memoryTotal)))
            metric("磁盘可用", value: "\(bytes(reading.diskFree)) / \(bytes(reading.diskTotal))", progress: Double(reading.diskFree) / Double(max(1, reading.diskTotal)))
            Text("每 5 秒读取系统统计。内存使用估算为活动、固定与压缩页；磁盘读取用户目录所在卷。").font(.caption).foregroundStyle(.secondary)
            Button("打开活动监视器") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
        } else { ProgressView("正在读取系统状态…") }
    }

    private func metric(_ title: String, value: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title); Spacer(); Text(value).monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
            ProgressView(value: min(1, max(0, progress))).tint(tint)
        }
    }

    @ViewBuilder private func calendarControls(reminders: Bool) -> some View {
        let authorized = runtime.authorization(reminders) == .authorized
        let rows = reminders ? runtime.reminderRows : runtime.calendarRows
        if authorized {
            HStack { Text(reminders ? "未完成提醒（最多 30 条）" : "未来 7 天（最多 30 条）").font(.caption).foregroundStyle(.secondary); Spacer(); Button("刷新") { runtime.loadCalendar(reminders: reminders) } }
            if rows.isEmpty && !runtime.busy { unavailable(reminders ? "没有未完成提醒" : "未来 7 天没有日程", detail: "读取已允许访问的系统账户。", symbol: kind.symbol) }
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 10) {
                    if reminders { Button { runtime.completeReminder(row.id) } label: { Image(systemName: "circle") }.buttonStyle(.plain).help("完成提醒") }
                    else { Image(systemName: "calendar").foregroundStyle(tint) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).font(.callout)
                        if let date = row.date { Text(row.allDay ? date.formatted(date: .abbreviated, time: .omitted) + " 全天" : date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 4)
            }
        } else {
            unavailable("连接系统\(reminders ? "提醒事项" : "日历")", detail: "点击后，macOS 会请求访问权限。数据只在本机读取。", symbol: kind.symbol)
            Button("允许访问") { runtime.connectCalendar(reminders: reminders) }.buttonStyle(.borderedProminent)
            Button("打开隐私设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(reminders ? "Reminders" : "Calendars")")!) }
        }
        if !runtime.accessMessage.isEmpty { Text(runtime.accessMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        Button("打开\(reminders ? "提醒事项" : "日历") App") { NSWorkspace.shared.open(URL(fileURLWithPath: reminders ? "/System/Applications/Reminders.app" : "/System/Applications/Calendar.app")) }
    }

    @ViewBuilder private var weatherControls: some View {
        if let temperature = Double(config["weatherTemperature"] ?? "") {
            Text(config["weatherCity"] ?? "已选择城市").font(.headline)
            Text(String(format: "%.0f°", temperature)).font(.system(size: 42, weight: .light))
            Text(weatherDescription(Int(config["weatherCode"] ?? "") ?? -1)).foregroundStyle(.secondary)
            if let feels = Double(config["weatherFeels"] ?? ""), let humidity = Double(config["weatherHumidity"] ?? ""), let wind = Double(config["weatherWind"] ?? "") {
                Text(String(format: "体感 %.0f°C · 湿度 %.0f%% · 风速 %.0f km/h", feels, humidity, wind)).font(.caption).foregroundStyle(.secondary)
            }
            if let fetched = Double(config["weatherFetched"] ?? "") { Text("更新于 \(Date(timeIntervalSince1970: fetched).formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            Button("更新天气") { Task { await refreshWeather() } }.disabled(runtime.busy)
            Divider()
        } else {
            Text("选择城市后获取天气。").foregroundStyle(.secondary)
        }
        HStack {
            TextField("城市，例如 上海 / Shanghai", text: $cityQuery).onSubmit { Task { await runtime.searchCities(cityQuery) } }
            Button("搜索") { Task { await runtime.searchCities(cityQuery) } }.disabled(runtime.busy || cityQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
        }
        ForEach(runtime.weatherCities) { city in
            Button {
                // Clear the previous city's data before fetching so failure never relabels old values.
                update(["weatherCity": city.name, "weatherLatitude": String(city.latitude), "weatherLongitude": String(city.longitude), "weatherTemperature": "", "weatherFetched": ""])
                runtime.weatherCities = []
                Task { await refreshWeather() }
            } label: { HStack { Image(systemName: "mappin"); Text(city.label).lineLimit(2); Spacer() } }.buttonStyle(.plain)
                .padding(.vertical, 4)
        }
        Link("天气：Open-Meteo · 地名：GeoNames", destination: URL(string: "https://open-meteo.com/")!).font(.caption)
        Text("只在搜索或更新时联网；向服务发送城市名称或所选坐标。天气值为模型估算，更新前保留上次结果。").font(.caption).foregroundStyle(.secondary)
    }

    private var shortcutControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("快捷指令名称", text: $shortcutName).onChange(of: shortcutName) { set("shortcutName", $0) }
            HStack {
                Button("运行") { set("shortcutName", shortcutName); runtime.runShortcut(shortcutName) }
                    .buttonStyle(.borderedProminent).disabled(runtime.busy || shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("读取快捷指令列表") { runtime.listShortcuts() }.disabled(runtime.busy)
            }
            ForEach(runtime.shortcutNames, id: \.self) { name in
                Button { shortcutName = name; set("shortcutName", name) } label: {
                    HStack { Text(name).lineLimit(1); Spacer(); if name == shortcutName { Image(systemName: "checkmark") } }
                }.buttonStyle(.plain).padding(.vertical, 4)
            }
            Text("通过 macOS shortcuts 命令运行；快捷指令本身可能弹出授权或交互界面。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var musicControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("播放器", selection: Binding(get: { config["musicPlayer"] ?? "Music" }, set: { set("musicPlayer", $0); runtime.musicTitle = ""; runtime.musicArtist = ""; runtime.musicState = "" })) {
                Text("Apple Music").tag("Music")
                Text("Spotify").tag("Spotify")
            }.pickerStyle(.segmented)
            if runtime.musicTitle.isEmpty {
                unavailable("连接播放器", detail: "连接或控制时会请求 macOS 自动化权限。", symbol: "music.note")
            } else {
                Text(runtime.musicTitle).font(.title3).textSelection(.enabled)
                if !runtime.musicArtist.isEmpty { Text(runtime.musicArtist).foregroundStyle(.secondary) }
                Text(runtime.musicState == "playing" ? "正在播放" : runtime.musicState == "paused" ? "已暂停" : "已停止").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    Button { runtime.music(player: config["musicPlayer"] ?? "Music", action: "previous") } label: { Image(systemName: "backward.end.fill") }.help("上一首")
                    Button { runtime.music(player: config["musicPlayer"] ?? "Music", action: "toggle") } label: { Image(systemName: runtime.musicState == "playing" ? "pause.fill" : "play.fill") }.help("播放或暂停")
                    Button { runtime.music(player: config["musicPlayer"] ?? "Music", action: "next") } label: { Image(systemName: "forward.end.fill") }.help("下一首")
                }.disabled(runtime.busy)
            }
            Button(runtime.musicTitle.isEmpty ? "连接" : "刷新曲目信息") { runtime.music(player: config["musicPlayer"] ?? "Music") }.disabled(runtime.busy)
            Text("支持已安装的 Apple Music 与 Spotify。曲目信息仅在点击连接、刷新或播放控制时读取。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var airDropControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            unavailable("投送文件", detail: "选择文件后打开 macOS 原生隔空投送面板。接收方需要开启隔空投送。", symbol: "airplayaudio")
            Button("选择文件并隔空投送") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                panel.begin { response in
                    guard response == .OK else { return }
                    guard let sharing = NSSharingService(named: .sendViaAirDrop), sharing.canPerform(withItems: panel.urls) else {
                        runtime.message = "当前设备无法使用隔空投送。"; return
                    }
                    sharing.perform(withItems: panel.urls)
                }
            }.buttonStyle(.borderedProminent)
            Button("在访达中打开隔空投送") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")) }
        }
    }

    private func unavailable(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(tint)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }

    private func summary(at date: Date) -> String {
        switch kind {
        case .clock, .worldClock: return clockText(date, format: "HH:mm")
        case .focus, .countdown: return WidgetState.durationText(WidgetState.remaining(config, at: date, defaultDuration: defaultDuration))
        case .stopwatch: return WidgetState.durationText(WidgetState.elapsed(config, at: date))
        case .hydration: return "\(WidgetState.hydrationTotal(WidgetState.hydration(config), at: date)) ml"
        case .note: return (config["note"] ?? "").isEmpty ? "记下想法" : String((config["note"] ?? "").split(separator: "\n").first ?? "便签")
        case .battery: return runtime.battery.map { "\($0.percent)%" } ?? "电源状态"
        case .system: return runtime.system?.cpuPercent.map { String(format: "CPU %.0f%%", $0) } ?? "系统状态"
        case .timeProgress: return String(format: "今天 %.0f%%", WidgetState.progress(.day, at: date) * 100)
        case .weather: return Double(config["weatherTemperature"] ?? "").map { String(format: "%.0f°C", $0) } ?? "选择城市"
        case .calendar: return runtime.calendarRows.isEmpty ? clockText(date, format: "M月d日") : (runtime.calendarRows.first?.title ?? "日历")
        case .reminders: return runtime.reminderRows.isEmpty ? "提醒事项" : "\(runtime.reminderRows.count) 条待办"
        case .shortcut: return config["shortcutName"].flatMap { $0.isEmpty ? nil : $0 } ?? "快捷指令"
        case .nowPlaying: return runtime.musicTitle.isEmpty ? "连接播放器" : runtime.musicTitle
        case .airDrop: return "隔空投送"
        }
    }

    private func subtitle(at date: Date) -> String {
        switch kind {
        case .clock: return clockText(date, format: "M月d日 EEE")
        case .worldClock: return (config["timezone"] ?? TimeZone.current.identifier).components(separatedBy: "/").last?.replacingOccurrences(of: "_", with: " ") ?? "世界时钟"
        case .weather:
            if let fetched = Double(config["weatherFetched"] ?? ""), date.timeIntervalSince1970 - fetched > 3600 { return "缓存 · 点击更新" }
            return config["weatherCity"] ?? "天气"
        case .battery: return runtime.battery?.charging == true ? "正在充电" : "电池"
        case .nowPlaying: return runtime.musicArtist.isEmpty ? "正在播放" : runtime.musicArtist
        default: return kind.title
        }
    }

    private func clockText(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = kind == .worldClock ? TimeZone(identifier: config["timezone"] ?? "") ?? .current : .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func bytes(_ count: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(count, UInt64(Int64.max))), countStyle: .memory) }

    private func synchronize() {
        config = item.configuration
        cityQuery = config["weatherCity"] ?? ""
        durationMinutes = String(Int(defaultDuration / 60))
        waterGoal = String(Int(WidgetState.boundedNumber(config, "waterGoal", default: 2000, range: 1...10000)))
        shortcutName = config["shortcutName"] ?? ""
    }

    private func set(_ key: String, _ value: String) { update([key: value]) }
    private func update(_ values: [String: String]) {
        config.merge(values) { _, new in new }
        var changed = item
        changed.configuration = config
        onUpdate(changed)
    }

    private func refreshWeather() async {
        guard let result = await runtime.fetchWeather(latitude: config["weatherLatitude"] ?? "", longitude: config["weatherLongitude"] ?? "") else { return }
        update(["weatherTemperature": String(result.temperature_2m), "weatherFeels": String(result.apparent_temperature), "weatherHumidity": String(result.relative_humidity_2m), "weatherWind": String(result.wind_speed_10m), "weatherCode": String(result.weather_code), "weatherObserved": result.time, "weatherFetched": String(Date.now.timeIntervalSince1970)])
    }

    private func weatherDescription(_ code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "大部晴朗"
        case 2: return "多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55: return "毛毛雨"
        case 56, 57: return "冻毛毛雨"
        case 61, 63, 65: return "雨"
        case 66, 67: return "冻雨"
        case 71, 73, 75, 77: return "雪"
        case 80, 81, 82: return "阵雨"
        case 85, 86: return "阵雪"
        case 95, 96, 99: return "雷雨"
        default: return "天气代码 \(code)"
        }
    }
}
