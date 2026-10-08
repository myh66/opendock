import AppKit
import EventKit
import SwiftUI
import UniformTypeIdentifiers

struct WidgetTile: View {
    let item: DockItem
    var compact: Bool = false
    let onUpdate: (DockItem) -> Void
    var onDuplicate: (() -> Void)? = nil
    var onPopoverChanged: ((Bool) -> Void)? = nil
    var forceVisible: Bool = false
    @StateObject private var runtime = WidgetRuntime()
    @StateObject private var location = WidgetLocation()
    @ObservedObject private var coordinator = WidgetPopoverCoordinator.shared
    @StateObject private var metrics = WidgetMetricState()
    @State private var metricsLeaseID = UUID()
    @State private var presented = false
    @State private var config: [String: String] = [:]
    @State private var cityQuery = ""
    @State private var timezoneSearch = ""
    @State private var durationMinutes = "25"
    @State private var waterAmount = "250"
    @State private var waterGoal = "2000"
    @State private var shortcutName = ""
    @State private var showClearNote = false
    @State private var alarmDate = Date.now.addingTimeInterval(3600)
    @State private var alarmTitle = "闹钟"
    @State private var waterDrink = "水"
    @State private var undoneWater: WaterEntry?
    @State private var musicRevision = 0
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
        Group {
            if [.stock, .watchlist, .stripe, .paddle, .shopify, .aiLimits, .aiActivity].contains(kind) {
                IntegrationWidgetTile(item: item, compact: compact, onUpdate: onUpdate)
            } else if shouldHideMusic {
                EmptyView()
            } else { localTile }
        }
        .onAppear { synchronize() }
        .onChange(of: item.configuration) { updated in if config != updated { config = updated } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in if kind == .nowPlaying { musicRevision += 1 } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in if kind == .nowPlaying { musicRevision += 1 } }
    }

    private var localTile: some View {
        Button {
            // The custom Dock uses a nonactivating panel; activation permits typing in popovers.
            NSApp.activate(ignoringOtherApps: true)
            presented.toggle()
        } label: {
            TimelineView(WidgetTimeline(kind: kind, configuration: config)) { context in
                HStack(spacing: 9) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: compact ? 18 : 21, weight: .medium))
                        .foregroundStyle(noteTextColor ?? tint)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary(at: context.date))
                            .font(.system(size: 13, weight: .semibold, design: timeSensitive ? .monospaced : .default))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(subtitle(at: context.date))
                            .font(.system(size: 10))
                            .foregroundStyle(noteTextColor?.opacity(0.65) ?? .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .frame(width: compact ? 132 : 140, height: 58)
                .foregroundStyle(noteTextColor ?? .primary)
                .background(noteBackground ?? tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
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
        .onAppear {
            synchronize()
            if [.system, .network, .battery].contains(kind) { metrics.start(owner: metricsLeaseID) }
        }
        .onChange(of: item.configuration) { updated in
            if config != updated { config = updated }
        }
        .task(id: "\(config["musicConnected"] ?? "")\(config["musicAutoRefresh"] ?? "true")\(selectedMusicSources)") {
            if kind == .nowPlaying { await runtime.observeMusic(sources: selectedMusicSources, enabled: config["musicConnected"] == "true" && config["musicAutoRefresh"] != "false") }
        }
        .task(id: "\(config["weatherRefresh"] ?? "0")\(config["weatherLatitude"] ?? "")\(config["weatherUnit"] ?? "celsius")") {
            if kind == .weather { await weatherAutomaticRefresh() }
        }
        .onChange(of: runtime.musicConnected) { connected in if connected { set("musicConnected", "true") } }
        .onChange(of: location.coordinate?.latitude) { _ in
            guard let coordinate = location.coordinate else { return }
            update(["weatherCity": "当前位置", "weatherLatitude": String(coordinate.latitude), "weatherLongitude": String(coordinate.longitude), "weatherTemperature": "", "weatherForecast": ""])
            Task { await refreshWeather() }
        }
        .onChange(of: presented) { open in
            if open { coordinator.activeID = item.id }
            else if coordinator.activeID == item.id { coordinator.activeID = nil }
            onPopoverChanged?(open)
        }
        .onChange(of: coordinator.activeID) { active in if active != item.id { presented = false } }
        .onDisappear { onPopoverChanged?(false); metrics.stop(); if coordinator.activeID == item.id { coordinator.activeID = nil }; presented = false }
        .onChange(of: kind) { value in if [.system, .network, .battery].contains(value) { metrics.start(owner: metricsLeaseID) } else { metrics.stop() } }
        .contextMenu {
            Button("自定义小组件…") { NSApp.activate(ignoringOtherApps: true); presented = true }
            if let onDuplicate { Button("复制小组件", action: onDuplicate) }
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.url.identifier], isTargeted: nil) { providers in
            guard kind == .airDrop else { return false }
            receiveDrop(providers); return true
        }
    }

    private var tint: Color {
        switch kind {
        case .clock, .worldClock, .timeProgress: return .indigo
        case .focus, .stopwatch, .countdown, .alarm: return .orange
        case .hydration, .weather: return .cyan
        case .battery, .system, .network: return .green
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
            if kind == .calendar { runtime.loadCalendar(reminders: false, selection: calendarSelection) }
            if kind == .reminders { runtime.loadCalendar(reminders: true, selection: calendarSelection) }
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
        case .alarm: alarmControls
        case .network: networkControls
        case .stock, .watchlist, .stripe, .paddle, .shopify, .aiLimits, .aiActivity: EmptyView()
        }
    }

    private var clockControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(WidgetTimeline(kind: kind, configuration: config)) { context in
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
            TimelineView(WidgetTimeline(kind: kind, configuration: config)) { context in
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
                }.disabled(WidgetState.number(config, "deadline") > Date.now.timeIntervalSince1970)
            }
            HStack {
                Button(WidgetState.number(config, "deadline") > Date.now.timeIntervalSince1970 ? "暂停" : "开始") {
                    if WidgetState.number(config, "deadline") > Date.now.timeIntervalSince1970 {
                        update(["remaining": String(WidgetState.remaining(config, at: .now, defaultDuration: defaultDuration)), "deadline": ""])
                        LocalWidgetNotifications.shared.cancel(id: item.id, channel: "timer")
                    } else {
                        let remaining = WidgetState.remaining(config, at: .now, defaultDuration: defaultDuration)
                        let date = Date.now.addingTimeInterval(remaining > 0 ? remaining : defaultDuration)
                        set("deadline", String(date.timeIntervalSince1970))
                        if config["timerNotification"] == "true" { Task { await scheduleTimer(date) } }
                    }
                }.buttonStyle(.borderedProminent).tint(tint)
                Button("重置") { update(["deadline": "", "remaining": String(defaultDuration)]); LocalWidgetNotifications.shared.cancel(id: item.id, channel: "timer") }
            }
            Toggle("结束时发送系统通知", isOn: Binding(get: { config["timerNotification"] == "true" }, set: { enabled in
                if enabled {
                    Task {
                        do {
                            try await LocalWidgetNotifications.shared.enable()
                            set("timerNotification", "true")
                            let deadline = WidgetState.number(config, "deadline")
                            if deadline > Date.now.timeIntervalSince1970 { await scheduleTimer(Date(timeIntervalSince1970: deadline)) }
                        } catch { runtime.message = error.localizedDescription }
                    }
                } else { set("timerNotification", "false"); LocalWidgetNotifications.shared.cancel(id: item.id, channel: "timer") }
            }))
            Text("计时按实际时间推进，暂停时停止更新。启用通知后，系统可在 App 退出时提醒；显示和声音遵循 macOS 通知与专注模式设置。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var defaultDuration: Double { WidgetState.boundedNumber(config, "duration", default: kind == .focus ? 1500 : 300, range: 60...86400) }

    private var alarmControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("闹钟名称", text: $alarmTitle).onChange(of: alarmTitle) { set("alarmTitleDraft", $0) }
            DatePicker("时间", selection: $alarmDate, displayedComponents: [.date, .hourAndMinute]).onChange(of: alarmDate) { set("alarmDraft", String($0.timeIntervalSince1970)) }
            Text("重复星期（不选择则只响一次）").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                    let selected = alarmDays.contains(day)
                    Button {
                        var days = alarmDays
                        if selected { days.remove(day) } else { days.insert(day) }
                        set("alarmWeekdaysDraft", days.sorted().map(String.init).joined(separator: ","))
                    } label: { Text([1:"日",2:"一",3:"二",4:"三",5:"四",6:"五",7:"六"][day] ?? "").frame(width: 28, height: 27).background(selected ? tint.opacity(0.2) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain)
                }
            }
            HStack {
                Button("保存并启用闹钟") {
                    Task {
                        do {
                            try await LocalWidgetNotifications.shared.enable()
                            try await LocalWidgetNotifications.shared.alarm(id: item.id, date: alarmDate, weekdays: alarmDays, title: alarmTitle)
                            update(["alarmEnabled": "true", "alarmTime": String(alarmDate.timeIntervalSince1970), "alarmWeekdays": alarmDays.sorted().map(String.init).joined(separator: ","), "alarmTitle": alarmTitle])
                            runtime.message = "闹钟已交由 macOS 排程。"
                        } catch { runtime.message = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent)
                if config["alarmEnabled"] == "true" { Button("停用") { set("alarmEnabled", "false"); LocalWidgetNotifications.shared.cancel(id: item.id, channel: "alarm") } }
            }
            Text("系统通知会在 App 退出后继续提醒。响铃与横幅受 macOS 通知设置、专注模式和系统休眠状态影响。一次性闹钟不会重复。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var alarmDays: Set<Int> { Set((config["alarmWeekdaysDraft"] ?? config["alarmWeekdays"] ?? "").split(separator: ",").compactMap { Int($0) }.filter { (1...7).contains($0) }) }

    private var stopwatchControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(WidgetTimeline(kind: kind, configuration: config)) { context in
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
            Picker("便签颜色", selection: Binding(get: { config["noteColor"] ?? "yellow" }, set: { set("noteColor", $0) })) {
                ForEach(["yellow", "pink", "blue", "green", "white", "black", "translucent"], id: \.self) { color in Text(noteColorName(color)).tag(color) }
            }
            TextEditor(text: Binding(get: { config["note"] ?? "" }, set: { set("note", String($0.prefix(20000))) }))
                .font(.body).frame(height: 200)
                .scrollContentBackground(.hidden).foregroundStyle(noteTextColor ?? .primary)
                .padding(7).background(noteBackground ?? Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
        let drinks = config["waterGoalUnit"] == "drinks"
        let drinkGoal = WidgetState.boundedNumber(config, "waterDrinkGoal", default: 8, range: 1...100)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(drinks ? "\(today.count)" : "\(total)").font(.system(size: 38, weight: .light)).monospacedDigit()
                Text(drinks ? "/ \(Int(drinkGoal)) 杯" : "/ \(Int(goal)) ml").foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, drinks ? Double(today.count) / drinkGoal : Double(total) / goal)).tint(tint)
            Picker("饮品", selection: $waterDrink) { ForEach(["水", "茶", "咖啡", "其他"], id: \.self) { Text($0).tag($0) } }.onChange(of: waterDrink) { set("waterDrink", $0) }
            HStack {
                TextField("可不填", text: $waterAmount).frame(width: 85)
                Text("ml（选填）").font(.caption).foregroundStyle(.secondary)
                Button("记录") {
                    let amount = Int(waterAmount).map { min(5000, max(1, $0)) }
                    set("waterHistory", WidgetState.encodedWater(entries + [WaterEntry(timestamp: Date.now.timeIntervalSince1970, milliliters: amount, drink: waterDrink)]))
                }.buttonStyle(.borderedProminent).tint(tint).disabled(config["waterLoggingPaused"] == "true")
            }
            Toggle("暂停记录", isOn: boolBinding("waterLoggingPaused"))
            Picker("目标单位", selection: Binding(get: { config["waterGoalUnit"] ?? "ml" }, set: { set("waterGoalUnit", $0); waterGoal = $0 == "drinks" ? String(Int(drinkGoal)) : String(Int(goal)) })) { Text("毫升").tag("ml"); Text("杯数").tag("drinks") }.pickerStyle(.segmented)
            HStack {
                Text("每日目标")
                TextField("目标", text: $waterGoal).frame(width: 65)
                Text(drinks ? "杯" : "ml")
                Button("保存") { let goal = min(drinks ? 100 : 10000, max(1, Int(waterGoal) ?? (drinks ? 8 : 2000))); set(drinks ? "waterDrinkGoal" : "waterGoal", String(goal)); waterGoal = String(goal) }
            }.font(.caption)
            hydrationReminderControls
            Toggle("显示历史记录", isOn: boolBinding("waterShowHistory", default: true))
            if today.isEmpty { Text("今天还没有饮水记录。").foregroundStyle(.secondary) }
            if config["waterShowHistory"] != "false" {
                let days = Set(entries.map { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: $0.timestamp)) }).sorted(by: >)
                ForEach(days, id: \.self) { day in
                    let dayEntries = entries.filter { Calendar.current.isDate(Date(timeIntervalSince1970: $0.timestamp), inSameDayAs: day) }
                    Text("\(day.formatted(date: .abbreviated, time: .omitted)) · \(dayEntries.count) 杯 · \(WidgetState.hydrationTotal(dayEntries, at: day)) ml").font(.caption).foregroundStyle(.secondary)
                    ForEach(dayEntries.reversed()) { entry in
                        HStack {
                            Text(Date(timeIntervalSince1970: entry.timestamp), style: .time).foregroundStyle(.secondary)
                            Text(entry.drink)
                            Spacer()
                            Text(entry.milliliters.map { "\($0) ml" } ?? "未填容量").monospacedDigit()
                            Button { undoneWater = entry; set("waterHistory", WidgetState.encodedWater(entries.filter { $0.id != entry.id })) } label: { Image(systemName: "trash") }.help("删除这次记录")
                        }.font(.caption)
                    }
                }
            }
            if let undo = undoneWater {
                Button("撤销删除") { set("waterHistory", WidgetState.encodedWater((entries + [undo]).sorted { $0.timestamp < $1.timestamp })); undoneWater = nil }
            }
            Text("未填容量的记录计入杯数，不计入毫升。记录与通知独立；保留最近 2,000 次记录。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hydrationReminderControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("饮水通知", isOn: Binding(get: { config["waterReminder"] == "true" }, set: { enabled in
                if enabled { Task { do { try await LocalWidgetNotifications.shared.enable(); set("waterReminder", "true"); await scheduleWaterReminder() } catch { runtime.message = error.localizedDescription } } }
                else { set("waterReminder", "false"); LocalWidgetNotifications.shared.cancel(id: item.id, channel: "water") }
            }))
            HStack {
                Picker("间隔", selection: Binding(get: { config["waterReminderInterval"] ?? "60" }, set: { set("waterReminderInterval", $0); Task { await scheduleWaterReminder() } })) {
                    ForEach([30, 60, 90, 120, 180, 240], id: \.self) { Text("\($0) 分钟").tag(String($0)) }
                }
            }
            HStack {
                Picker("开始", selection: Binding(get: { config["waterReminderStart"] ?? "8" }, set: { set("waterReminderStart", $0); Task { await scheduleWaterReminder() } })) { ForEach(0..<24) { Text("\($0):00").tag(String($0)) } }
                Picker("结束", selection: Binding(get: { config["waterReminderEnd"] ?? "22" }, set: { set("waterReminderEnd", $0); Task { await scheduleWaterReminder() } })) { ForEach(1...24, id: \.self) { Text("\($0):00").tag(String($0)) } }
            }.font(.caption)
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
        if let battery = metrics.snapshot.battery {
            Text(String(format: "%.0f%%", battery.chargePercent)).font(.system(size: 42, weight: .light)).monospacedDigit()
            ProgressView(value: battery.chargePercent / 100).tint(tint)
            Label(battery.isCharging && battery.chargePercent < 100 ? "正在充电" : (battery.isOnAC ? "连接电源" : "使用电池"), systemImage: battery.isOnAC ? "bolt.fill" : "battery.100percent")
            if let cycles = battery.cycleCount { Text("循环次数：\(cycles)") }
            if let health = battery.healthPercent { Text(String(format: "电池健康估算：%.0f%%", health)) }
            if let volts = battery.voltageVolts { Text(String(format: "电压：%.2f V", volts)) }
            if let watts = battery.powerWatts { Text(String(format: "功率：%.1f W", watts)) }
            Text("来自 macOS 电源信息；设备未提供的字段不显示。").font(.caption).foregroundStyle(.secondary)
        } else { unavailable("未检测到电池", detail: "台式 Mac 或不提供电池信息的设备会显示此状态。", symbol: "powerplug") }
    }

    @ViewBuilder private var systemControls: some View {
        let reading = metrics.snapshot
        if reading.sampledAt != nil {
            metric("CPU", value: reading.cpuHasSample ? String(format: "%.0f%%", reading.cpuTotal * 100) : "采样中", progress: reading.cpuTotal)
            DisclosureGroup("每核 CPU") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Array(reading.cpuPerCore.enumerated()), id: \.offset) { index, value in metric("核心 \(index + 1)", value: String(format: "%.0f%%", value * 100), progress: value) }
                }.padding(.top, 8)
            }
            metric("内存使用估算", value: "\(bytes(reading.memoryUsedBytes)) / \(bytes(reading.memoryTotalBytes))", progress: Double(reading.memoryUsedBytes) / Double(max(1, reading.memoryTotalBytes)))
            Text("内存压力：\(reading.memoryPressure) · 交换空间：\(bytes(reading.swapUsedBytes))").font(.caption)
            Text("固定：\(bytes(reading.memoryWiredBytes)) · 压缩：\(bytes(reading.memoryCompressedBytes)) · 文件缓存：\(bytes(reading.memoryFileCacheBytes))").font(.caption).foregroundStyle(.secondary)
            if !reading.loadAverage.isEmpty { Text("系统负载：\(reading.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / "))").font(.caption) }
            Text("热状态：\(reading.thermalState) · 运行时间：\(WidgetState.durationText(reading.uptime))").font(.caption).foregroundStyle(.secondary)
            Text("每 2 秒读取公开系统计数器。内存值为估算，压力来自内核状态。").font(.caption).foregroundStyle(.secondary)
            Button("打开活动监视器") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
            WidgetStorageBrowser()
        } else { ProgressView("正在读取系统状态…") }
    }

    private var networkControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            Picker("网络接口", selection: Binding(get: { config["networkInterface"] ?? "auto" }, set: { set("networkInterface", $0) })) {
                Text("自动选择活跃接口").tag("auto")
                Text("全部活跃接口").tag("all")
                ForEach(metrics.snapshot.network) { interface in Text(interface.name).tag(interface.name) }
            }
            if networkInterfaces.isEmpty { unavailable("没有可用的网络接口", detail: "检查 Wi-Fi、以太网或 VPN 连接。", symbol: "network") }
            ForEach(networkInterfaces) { interface in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(interface.name) · \(interface.isUp ? "已启用" : "未启用")").font(.headline)
                    Text(interface.addresses.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack { Label(rate(interface.receivedBytesPerSecond), systemImage: "arrow.down"); Spacer(); Label(rate(interface.sentBytesPerSecond), systemImage: "arrow.up") }.monospacedDigit()
                    Text("接收：\(bytes(interface.receivedBytes)) · 发送：\(bytes(interface.sentBytes))").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            Text("速率由接口字节计数差计算，不做测速或发送网络请求。累计值自接口初始化起计算；隧道接口可能与物理接口包含同一流量。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var networkInterfaces: [NetworkInterfaceMetrics] {
        let all = metrics.snapshot.network
        let selection = config["networkInterface"] ?? "auto"
        if selection == "all" { return all.filter { $0.isUp && $0.name != "lo0" } }
        if selection != "auto" { return all.filter { $0.name == selection } }
        let active = all.filter { $0.isUp && $0.name != "lo0" }
        return active.first(where: { $0.name.hasPrefix("en") }).map { [$0] } ?? Array(active.prefix(1))
    }
    private var networkSummary: String { "↓ " + rate(networkInterfaces.reduce(0) { $0 + $1.receivedBytesPerSecond }) }
    private func rate(_ value: Double) -> String { bytes(UInt64(min(Double(UInt64.max / 2), max(0, value.isFinite ? value : 0)))) + "/s" }


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
            DisclosureGroup(reminders ? "选择提醒列表" : "选择日历") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("选择全部") { set("calendarSelection", ""); runtime.loadCalendar(reminders: reminders) }
                    ForEach(runtime.calendarSources) { source in
                        Toggle("\(source.title) · \(source.account)", isOn: Binding(get: { calendarSelection?.contains(source.id) ?? true }, set: { selected in
                            var ids = calendarSelection ?? runtime.calendarSources.map(\.id)
                            ids.removeAll { $0 == source.id }
                            if selected { ids.append(source.id) }
                            set("calendarSelection", WidgetState.encodeStrings(ids))
                            runtime.loadCalendar(reminders: reminders, selection: ids)
                        }))
                    }
                }.padding(.top, 8)
            }
            HStack { Text(reminders ? "未完成提醒（最多 30 条）" : "未来 7 天（最多 30 条）").font(.caption).foregroundStyle(.secondary); Spacer(); Button("刷新") { runtime.loadCalendar(reminders: reminders, selection: calendarSelection) } }
            if rows.isEmpty && !runtime.busy { unavailable(reminders ? "没有未完成提醒" : "未来 7 天没有日程", detail: "读取已允许访问的系统账户。", symbol: kind.symbol) }
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 10) {
                    if reminders { Button { runtime.completeReminder(row.id) } label: { Image(systemName: "circle") }.buttonStyle(.plain).help("完成提醒") }
                    else { Image(systemName: "calendar").foregroundStyle(tint) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).font(.callout)
                        if let date = row.date { Text(row.allDay ? date.formatted(date: .abbreviated, time: .omitted) + " 全天" : date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                        if let date = row.date, !row.allDay {
                            HStack(spacing: 3) { Text(date > .now ? "距开始" : "已开始"); Text(date, style: .relative) }.font(.caption).foregroundStyle(.secondary)
                        }
                        if let join = row.joinURL { Link("加入会议", destination: join).font(.caption) }
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 4)
            }
        } else {
            unavailable("连接系统\(reminders ? "提醒事项" : "日历")", detail: "点击后，macOS 会请求访问权限。数据只在本机读取。", symbol: kind.symbol)
            Button("允许访问") { runtime.connectCalendar(reminders: reminders, selection: calendarSelection) }.buttonStyle(.borderedProminent)
            Button("打开隐私设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(reminders ? "Reminders" : "Calendars")")!) }
        }
        if !runtime.accessMessage.isEmpty { Text(runtime.accessMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        Button("打开\(reminders ? "提醒事项" : "日历") App") { NSWorkspace.shared.open(URL(fileURLWithPath: reminders ? "/System/Applications/Reminders.app" : "/System/Applications/Calendar.app")) }
    }

    @ViewBuilder private var weatherControls: some View {
        if let temperature = Double(config["weatherTemperature"] ?? "") {
            Text(config["weatherCity"] ?? "已选择城市").font(.headline)
            Text(String(format: "%.0f%@", temperature, weatherTemperatureUnit)).font(.system(size: 42, weight: .light))
            Text(weatherDescription(Int(config["weatherCode"] ?? "") ?? -1)).foregroundStyle(.secondary)
            if let feels = Double(config["weatherFeels"] ?? ""), let humidity = Double(config["weatherHumidity"] ?? ""), let wind = Double(config["weatherWind"] ?? "") {
                Text(String(format: "体感 %.0f%@ · 湿度 %.0f%% · 风速 %.0f %@", feels, weatherTemperatureUnit, humidity, wind, config["weatherDataUnit"] == "fahrenheit" ? "mph" : "km/h")).font(.caption).foregroundStyle(.secondary)
            }
            if let fetched = Double(config["weatherFetched"] ?? "") { Text("更新于 \(Date(timeIntervalSince1970: fetched).formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            Button("更新天气") { Task { await refreshWeather() } }.disabled(runtime.busy)
            weatherForecastControls
            Divider()
        } else {
            Text("选择城市后获取天气。").foregroundStyle(.secondary)
        }
        HStack {
            TextField("城市，例如 上海 / Shanghai", text: $cityQuery).onSubmit { Task { await runtime.searchCities(cityQuery) } }.onChange(of: cityQuery) { set("weatherCityDraft", $0) }
            Button("搜索") { Task { await runtime.searchCities(cityQuery) } }.disabled(runtime.busy || cityQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
        }
        ForEach(runtime.weatherCities) { city in
            Button {
                // Clear the previous city's data before fetching so failure never relabels old values.
                update(["weatherCity": city.name, "weatherLatitude": String(city.latitude), "weatherLongitude": String(city.longitude), "weatherTemperature": "", "weatherForecast": "", "weatherFetched": ""])
                runtime.weatherCities = []
                Task { await refreshWeather() }
            } label: { HStack { Image(systemName: "mappin"); Text(city.label).lineLimit(2); Spacer() } }.buttonStyle(.plain)
                .padding(.vertical, 4)
        }
        Button("使用当前位置") { location.request() }.disabled(location.busy)
        if location.busy { ProgressView("正在定位…").controlSize(.small) }
        if !location.message.isEmpty { Text(location.message).font(.caption).foregroundStyle(.secondary) }
        Picker("单位", selection: Binding(get: { config["weatherUnit"] ?? "celsius" }, set: { set("weatherUnit", $0); Task { await refreshWeather() } })) {
            Text("摄氏度 / km/h").tag("celsius"); Text("华氏度 / mph").tag("fahrenheit")
        }
        Picker("自动更新", selection: Binding(get: { config["weatherRefresh"] ?? "0" }, set: { set("weatherRefresh", $0) })) {
            Text("手动").tag("0"); ForEach([15, 30, 60, 180], id: \.self) { Text("每 \($0) 分钟").tag(String($0)) }
        }
        Link("天气：Open-Meteo · 地名：GeoNames", destination: URL(string: "https://open-meteo.com/")!).font(.caption)
        Text("搜索时发送城市名称，更新时发送城市或定位坐标。自动更新按所选间隔进行。天气值为模型估算，失败时保留带时间戳的缓存。").font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var weatherForecastControls: some View {
        if let forecast = cachedWeather {
            if let hourly = forecast.hourly {
                DisclosureGroup("未来 12 小时") {
                    let formatter = weatherFormatter(forecast.timezone)
                    let indices = hourly.time.indices.filter { (formatter.date(from: hourly.time[$0]) ?? .distantPast) >= Date.now.addingTimeInterval(-1800) }.prefix(12)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(indices), id: \.self) { index in
                            HStack {
                                Text(String(hourly.time[index].suffix(5)))
                                Spacer()
                                if index < hourly.temperature_2m.count, let value = hourly.temperature_2m[index] { Text(String(format: "%.0f%@", value, weatherTemperatureUnit)).monospacedDigit() }
                                if index < hourly.precipitation_probability.count, let rain = hourly.precipitation_probability[index] { Text("\(rain)% 雨").foregroundStyle(.secondary) }
                            }.font(.caption)
                        }
                    }.padding(.top, 8)
                }
            }
            if let daily = forecast.daily {
                DisclosureGroup("未来 7 天") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(daily.time.indices.prefix(7)), id: \.self) { index in
                            HStack {
                                Text(String(daily.time[index].suffix(5)))
                                Spacer()
                                if index < daily.weather_code.count, let code = daily.weather_code[index] { Text(weatherDescription(code)).foregroundStyle(.secondary) }
                                if index < daily.temperature_2m_min.count, index < daily.temperature_2m_max.count, let low = daily.temperature_2m_min[index], let high = daily.temperature_2m_max[index] { Text(String(format: "%.0f / %.0f%@", low, high, weatherTemperatureUnit)).monospacedDigit() }
                            }.font(.caption)
                        }
                    }.padding(.top, 8)
                }
            }
        }
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
            HStack {
                ForEach(["Music", "Spotify"], id: \.self) { player in
                    Toggle(player == "Music" ? "Apple Music" : "Spotify", isOn: Binding(get: { selectedMusicSources.contains(player) }, set: { enabled in
                        var sources = selectedMusicSources.filter { $0 != player }
                        if enabled { sources.append(player) }
                        set("musicSources", WidgetState.encodeStrings(sources))
                    }))
                }
            }.font(.caption)
            Toggle("自动刷新已授权的运行中播放器", isOn: boolBinding("musicAutoRefresh", default: true))
            Toggle("所选播放器关闭时隐藏", isOn: boolBinding("musicHideWhenClosed"))
            if runtime.musicTitle.isEmpty {
                unavailable("连接播放器", detail: "连接或控制时会请求 macOS 自动化权限。", symbol: "music.note")
            } else {
                HStack(alignment: .top, spacing: 12) {
                    if let art = runtime.musicArtwork { Image(nsImage: art).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8)) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(runtime.musicTitle).font(.title3).textSelection(.enabled)
                        if !runtime.musicArtist.isEmpty { Text(runtime.musicArtist).foregroundStyle(.secondary) }
                    }
                }
                Text(runtime.musicState == "playing" ? "正在播放" : runtime.musicState == "paused" ? "已暂停" : "已停止").font(.caption).foregroundStyle(.secondary)
                if runtime.musicDuration > 0 {
                    ProgressView(value: min(1, max(0, runtime.musicPosition / runtime.musicDuration))).tint(tint)
                    HStack { Text(WidgetState.durationText(runtime.musicPosition)); Spacer(); Text(WidgetState.durationText(runtime.musicDuration)) }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    Button { runtime.music(player: runtime.activeMusicPlayer, action: "previous") } label: { Image(systemName: "backward.end.fill") }.help("上一首")
                    Button { runtime.music(player: runtime.activeMusicPlayer, action: "toggle") } label: { Image(systemName: runtime.musicState == "playing" ? "pause.fill" : "play.fill") }.help("播放或暂停")
                    Button { runtime.music(player: runtime.activeMusicPlayer, action: "next") } label: { Image(systemName: "forward.end.fill") }.help("下一首")
                }.disabled(runtime.busy)
            }
            Button(runtime.musicTitle.isEmpty ? "连接" : "刷新曲目信息") { runtime.music(player: config["musicPlayer"] ?? "Music") }.disabled(runtime.busy)
            Text("初次授权由连接按钮触发。自动刷新只读取已授权且运行中的所选播放器，不启动应用或弹出新授权；封面与进度仅在播放器提供时显示。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var airDropControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            unavailable("投送文件或链接", detail: "拖入 Dock 小组件或选择文件，待发送内容保存在本机；发送后由 macOS 显示接收设备。", symbol: "airplayaudio")
            ForEach(pendingAirDrop, id: \.absoluteString) { url in
                HStack {
                    Image(systemName: url.isFileURL ? "doc" : "link")
                    Text(url.isFileURL ? url.lastPathComponent : url.absoluteString).lineLimit(2).font(.caption)
                    Spacer()
                    Button { saveAirDrop(pendingAirDrop.filter { $0 != url }) } label: { Image(systemName: "xmark.circle") }.help("移出待发送列表")
                }
            }
            HStack {
                Button("添加文件") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                panel.begin { response in
                    guard response == .OK else { return }
                    saveAirDrop(pendingAirDrop + panel.urls)
                }
                }
                Button("发送待发送内容") { shareAirDrop() }.buttonStyle(.borderedProminent).disabled(pendingAirDrop.isEmpty)
            }
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
        case .hydration:
            if config["waterGoalUnit"] == "drinks" { return "\(WidgetState.hydration(config).filter { Calendar.current.isDate(Date(timeIntervalSince1970: $0.timestamp), inSameDayAs: date) }.count) 杯" }
            return "\(WidgetState.hydrationTotal(WidgetState.hydration(config), at: date)) ml"
        case .note: return (config["note"] ?? "").isEmpty ? "记下想法" : String((config["note"] ?? "").split(separator: "\n").first ?? "便签")
        case .battery: return metrics.snapshot.battery.map { String(format: "%.0f%%", $0.chargePercent) } ?? "电源状态"
        case .system: return metrics.snapshot.cpuHasSample ? String(format: "CPU %.0f%%", metrics.snapshot.cpuTotal * 100) : "系统状态"
        case .timeProgress: return String(format: "今天 %.0f%%", WidgetState.progress(.day, at: date) * 100)
        case .weather: return Double(config["weatherTemperature"] ?? "").map { String(format: "%.0f%@", $0, weatherTemperatureUnit) } ?? "选择城市"
        case .calendar: return runtime.calendarRows.isEmpty ? clockText(date, format: "M月d日") : (runtime.calendarRows.first?.title ?? "日历")
        case .reminders: return runtime.reminderRows.isEmpty ? "提醒事项" : "\(runtime.reminderRows.count) 条待办"
        case .shortcut: return config["shortcutName"].flatMap { $0.isEmpty ? nil : $0 } ?? "快捷指令"
        case .nowPlaying: return runtime.musicTitle.isEmpty ? "连接播放器" : runtime.musicTitle
        case .airDrop: return pendingAirDrop.isEmpty ? "隔空投送" : "\(pendingAirDrop.count) 项待发送"
        case .alarm:
            guard config["alarmEnabled"] == "true" else { return "设定闹钟" }
            let time = WidgetState.boundedNumber(config, "alarmTime", default: 0, range: 0...4_102_444_800)
            if (config["alarmWeekdays"] ?? "").isEmpty && time <= date.timeIntervalSince1970 { return "已到时" }
            return Date(timeIntervalSince1970: time).formatted(date: .omitted, time: .shortened)
        case .network: return networkSummary
        case .stock, .watchlist, .stripe, .paddle, .shopify, .aiLimits, .aiActivity: return kind.title
        }
    }

    private func subtitle(at date: Date) -> String {
        switch kind {
        case .clock: return clockText(date, format: "M月d日 EEE")
        case .worldClock: return (config["timezone"] ?? TimeZone.current.identifier).components(separatedBy: "/").last?.replacingOccurrences(of: "_", with: " ") ?? "世界时钟"
        case .weather:
            if let fetched = Double(config["weatherFetched"] ?? ""), date.timeIntervalSince1970 - fetched > 3600 { return "缓存 · 点击更新" }
            return config["weatherCity"] ?? "天气"
        case .battery: return metrics.snapshot.battery?.isCharging == true && (metrics.snapshot.battery?.chargePercent ?? 100) < 100 ? "正在充电" : "电池"
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
        cityQuery = config["weatherCityDraft"] ?? config["weatherCity"] ?? ""
        durationMinutes = String(Int(defaultDuration / 60))
        waterGoal = String(Int(WidgetState.boundedNumber(config, "waterGoal", default: 2000, range: 1...10000)))
        shortcutName = config["shortcutName"] ?? ""
        waterDrink = config["waterDrink"] ?? "水"
        if config["waterGoalUnit"] == "drinks" { waterGoal = String(Int(WidgetState.boundedNumber(config, "waterDrinkGoal", default: 8, range: 1...100))) }
        let alarm = WidgetState.boundedNumber(config, "alarmDraft", default: WidgetState.boundedNumber(config, "alarmTime", default: Date.now.addingTimeInterval(3600).timeIntervalSince1970, range: 0...4_102_444_800), range: 0...4_102_444_800)
        alarmDate = Date(timeIntervalSince1970: alarm)
        alarmTitle = config["alarmTitleDraft"] ?? config["alarmTitle"] ?? "闹钟"
    }

    private func set(_ key: String, _ value: String) { update([key: value]) }
    private func update(_ values: [String: String]) {
        config.merge(values) { _, new in new }
        var changed = item
        changed.configuration = config
        onUpdate(changed)
    }

    private func refreshWeather() async {
        let latitude = config["weatherLatitude"] ?? "", longitude = config["weatherLongitude"] ?? "", unit = config["weatherUnit"] ?? "celsius"
        guard let forecast = await runtime.fetchWeather(latitude: latitude, longitude: longitude, fahrenheit: unit == "fahrenheit"), latitude == config["weatherLatitude"], longitude == config["weatherLongitude"], unit == (config["weatherUnit"] ?? "celsius") else { return }
        let result = forecast.current
        let encoded = (try? JSONEncoder().encode(forecast)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        update(["weatherTemperature": String(result.temperature_2m), "weatherFeels": String(result.apparent_temperature), "weatherHumidity": String(result.relative_humidity_2m), "weatherWind": String(result.wind_speed_10m), "weatherCode": String(result.weather_code), "weatherObserved": result.time, "weatherFetched": String(Date.now.timeIntervalSince1970), "weatherForecast": encoded, "weatherDataUnit": unit])
    }

    private func weatherAutomaticRefresh() async {
        let minutes = WidgetState.boundedNumber(config, "weatherRefresh", default: 0, range: 0...180)
        guard minutes >= 15 else { return }
        while !Task.isCancelled {
            if Date.now.timeIntervalSince1970 - WidgetState.number(config, "weatherFetched") >= minutes * 60 { await refreshWeather() }
            do { try await Task.sleep(nanoseconds: UInt64(minutes * 60) * 1_000_000_000) } catch { return }
        }
    }

    private var cachedWeather: WeatherForecast? { config["weatherForecast"]?.data(using: .utf8).flatMap { try? JSONDecoder().decode(WeatherForecast.self, from: $0) } }
    private var weatherTemperatureUnit: String { config["weatherDataUnit"] == "fahrenheit" ? "°F" : "°C" }
    private func weatherFormatter(_ timezone: String?) -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"; formatter.timeZone = timezone.flatMap(TimeZone.init(identifier:)) ?? .current; return formatter
    }

    private var calendarSelection: [String]? { (config["calendarSelection"] ?? "").isEmpty ? nil : WidgetState.strings(config, "calendarSelection") }
    private var selectedMusicSources: [String] {
        let selected = WidgetState.strings(config, "musicSources").filter { ["Music", "Spotify"].contains($0) }
        return config["musicSources"] == nil ? [config["musicPlayer"] ?? "Music"] : selected
    }
    private var shouldHideMusic: Bool {
        _ = musicRevision
        return kind == .nowPlaying && !forceVisible && !presented && config["musicHideWhenClosed"] == "true" && !selectedMusicSources.contains(where: { WidgetAutomation.running(player: $0) })
    }

    private func boolBinding(_ key: String, default fallback: Bool = false) -> Binding<Bool> {
        Binding(get: { config[key].map { $0 == "true" } ?? fallback }, set: { set(key, String($0)) })
    }

    private var noteBackground: Color? {
        guard kind == .note else { return nil }
        switch config["noteColor"] ?? "yellow" {
        case "pink": return Color(red: 1, green: 0.82, blue: 0.88)
        case "blue": return Color(red: 0.77, green: 0.87, blue: 1)
        case "green": return Color(red: 0.79, green: 0.93, blue: 0.8)
        case "white": return .white
        case "black": return Color(white: 0.1)
        case "translucent": return Color.secondary.opacity(0.1)
        default: return Color(red: 1, green: 0.93, blue: 0.65)
        }
    }
    private var noteTextColor: Color? {
        guard kind == .note else { return nil }
        if config["noteColor"] == "translucent" { return .primary }
        return config["noteColor"] == "black" ? .white : .black
    }
    private func noteColorName(_ color: String) -> String { ["yellow":"黄色", "pink":"粉色", "blue":"蓝色", "green":"绿色", "white":"白色", "black":"黑色", "translucent":"半透明"][color] ?? color }

    private func scheduleTimer(_ date: Date) async {
        do { try await LocalWidgetNotifications.shared.timer(id: item.id, date: date, title: kind == .focus ? "专注时间结束" : "倒计时结束") }
        catch { runtime.message = error.localizedDescription }
    }
    private func scheduleWaterReminder() async {
        guard config["waterReminder"] == "true" else { return }
        do {
            try await LocalWidgetNotifications.shared.hydration(id: item.id, everyMinutes: Int(WidgetState.boundedNumber(config, "waterReminderInterval", default: 60, range: 30...240)), startHour: Int(WidgetState.boundedNumber(config, "waterReminderStart", default: 8, range: 0...23)), endHour: Int(WidgetState.boundedNumber(config, "waterReminderEnd", default: 22, range: 1...24)))
        } catch { runtime.message = error.localizedDescription }
    }

    private var pendingAirDrop: [URL] { WidgetState.strings(config, "airDropPending").compactMap(URL.init(string:)).filter { ["https", "http", "file"].contains($0.scheme ?? "") } }
    private func saveAirDrop(_ urls: [URL]) {
        var unique: [URL] = []
        for url in urls where !unique.contains(url) { unique.append(url) }
        set("airDropPending", WidgetState.encodeStrings(Array(unique.prefix(100)).map(\.absoluteString)))
    }
    private func shareAirDrop() {
        let items = pendingAirDrop.filter { !$0.isFileURL || FileManager.default.fileExists(atPath: $0.path) }
        guard !items.isEmpty else { runtime.message = "待发送文件已不存在，请重新选择。"; return }
        guard let sharing = NSSharingService(named: .sendViaAirDrop), sharing.canPerform(withItems: items) else { runtime.message = "当前设备无法投送这些内容。"; return }
        sharing.perform(withItems: items)
        runtime.message = "已打开系统投送面板。草稿保留，接收状态由 macOS 显示。"
    }
    private func receiveDrop(_ providers: [NSItemProvider]) {
        NSApp.activate(ignoringOtherApps: true); presented = true
        for provider in providers {
            let type = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL.identifier : UTType.url.identifier
            provider.loadItem(forTypeIdentifier: type, options: nil) { object, _ in
                let url: URL?
                if let value = object as? URL { url = value }
                else if let data = object as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let text = object as? String { url = URL(string: text) }
                else { url = nil }
                guard let url, ["https", "http", "file"].contains(url.scheme ?? "") else { return }
                Task { @MainActor in saveAirDrop(pendingAirDrop + [url]) }
            }
        }
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
