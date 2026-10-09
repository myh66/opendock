import AppKit
import CoreLocation
import Foundation
import UserNotifications
import SwiftUI
import Combine

@MainActor final class WidgetPopoverCoordinator: ObservableObject {
    static let shared = WidgetPopoverCoordinator()
    @Published var activeID: UUID?
    private var keyboardMonitor: Any?
    private init() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self,self.activeID != nil else { return event }
            if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "w") { self.activeID = nil; return nil }
            return event
        }
    }
}

struct WidgetPopoverIconButton: View {
    let symbol: String
    let label: String
    var prominent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 16, height: 16) }
            .buttonStyle(DockGlassButtonStyle(prominent: prominent))
            .help(label).accessibilityLabel(label)
    }
}

struct WidgetPopoverHeader<Actions: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var subtitle: String?
    let onClose: () -> Void
    let actions: Actions
    init(title: String, symbol: String, tint: Color, subtitle: String? = nil,
         onClose: @escaping () -> Void, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.symbol = symbol; self.tint = tint; self.subtitle = subtitle
        self.onClose = onClose; self.actions = actions()
    }
    var body: some View {
        DockGlassGroup(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 34, height: 34).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) { actions; WidgetPopoverIconButton(symbol: "xmark", label: "关闭", action: onClose).keyboardShortcut(.cancelAction) }
            }.padding(11).dockGlass(cornerRadius: 18)
        }
    }
}

/// Only an overflowing, visible credit animates; VoiceOver always receives the full text.
struct WidgetMarqueeText: View {
    let text: String
    var font: Font = .caption
    var lineHeight: CGFloat = 16
    var staticLines = 1
    var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    private var overflow: CGFloat { max(0, textWidth - viewportWidth) }
    private var animationKey: String { "\(text)|\(textWidth)|\(viewportWidth)|\(enabled)|\(reduceMotion)" }
    var body: some View {
        Group {
            if reduceMotion {
                Text(text).font(font).lineLimit(staticLines).fixedSize(horizontal: false, vertical: true)
            } else {
                GeometryReader { geometry in
                    Text(text).font(font).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .background(GeometryReader { reader in Color.clear.preference(key: WidgetMarqueeWidth.self, value: reader.size.width) })
                        .offset(x: offset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .clipped()
                        .onAppear { viewportWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { viewportWidth = $0 }
                }.frame(height: lineHeight)
            }
        }
        .onPreferenceChange(WidgetMarqueeWidth.self) { width in if abs(width - textWidth) > 0.5 { textWidth = width } }
        .task(id: animationKey) { await animateCredit() }
        .help(text).accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
    @MainActor private func animateCredit() async {
        withAnimation(nil) { offset = 0 }
        guard enabled, !reduceMotion, textWidth.isFinite, viewportWidth.isFinite, overflow.isFinite, overflow > 1, viewportWidth > 0 else { return }
        let duration = min(30, max(2, Double(overflow / 24)))
        do {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation(.linear(duration: duration)) { offset = -overflow }
                try await Task.sleep(nanoseconds: UInt64((duration + 2.5) * 1_000_000_000))
                withAnimation(.linear(duration: duration)) { offset = 0 }
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            }
        } catch { /* Disappearance or a changed track cancels the view's animation task. */ }
    }
}
private struct WidgetMarqueeWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

@MainActor enum WidgetMetricsLeases {
    private static var owners = Set<UUID>()
    static func acquire(_ id: UUID) { if owners.insert(id).inserted { SystemMetrics.shared.start() } }
    static func release(_ id: UUID) { owners.remove(id); if owners.isEmpty { SystemMetrics.shared.stop() } }
}

@MainActor final class WidgetMetricState: ObservableObject {
    @Published var snapshot = SystemMetricsSnapshot()
    private var owner: UUID?
    private var subscription: AnyCancellable?
    func start(owner id: UUID) {
        guard owner == nil else { return }
        owner = id
        WidgetMetricsLeases.acquire(id)
        subscription = SystemMetrics.shared.$snapshot.sink { [weak self] in self?.snapshot = $0 }
    }
    func stop() {
        subscription = nil
        if let owner { WidgetMetricsLeases.release(owner) }
        owner = nil
    }
}

extension StorageEntry {
    var widgetChildren: [StorageEntry]? { children.isEmpty ? nil : children }
}

struct WidgetStorageBrowser: View {
    @ObservedObject private var scanner = StorageScanner.shared
    var body: some View {
        DisclosureGroup("存储扫描") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ForEach(StorageScanScope.allCases) { scope in Button(scope.title) { scanner.start(scope: scope) }.disabled(scanner.scanning) }
                }.font(.caption)
                Button("选择其他文件夹…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.begin { result in if result == .OK, let url = panel.url { scanner.scan(url: url) } }
                }.disabled(scanner.scanning)
                Text(scanner.progress).font(.caption).foregroundStyle(.secondary)
                if scanner.scanning { ProgressView().controlSize(.small); Button("取消扫描") { scanner.cancel() } }
                if let result = scanner.result {
                    Text("\(bytes(result.bytes)) · \(result.fileCount) 个文件\(result.isPartial ? " · 部分结果" : "")").font(.caption)
                    OutlineGroup(result.root.children, children: \.widgetChildren) { entry in
                        HStack {
                            Text(entry.name).lineLimit(1)
                            Spacer()
                            Text(bytes(entry.bytes)).foregroundStyle(.secondary)
                            Button { scanner.reveal(entry) } label: { Image(systemName: "folder") }.buttonStyle(.plain).help("在访达中显示")
                        }.font(.caption)
                    }
                }
                if let error = scanner.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
                Text("选择范围后才扫描；不会删除文件。关闭小组件后扫描仍可继续。").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }
    }
    private func bytes(_ count: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file) }
}

/// A paused timer yields only its initial value. Running countdowns stop at the deadline.
struct WidgetTimeline: TimelineSchedule {
    var kind: WidgetKind
    var configuration: [String: String]
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        let deadline = WidgetState.number(configuration, "deadline")
        let timer = kind == .focus || kind == .countdown
        let running = kind == .clock || kind == .worldClock || (kind == .stopwatch && WidgetState.number(configuration, "started") > 0) || (timer && deadline > startDate.timeIntervalSince1970)
        let slow = [.timeProgress, .hydration, .calendar].contains(kind)
        let interval: TimeInterval = running ? 1 : 60
        return AnySequence {
            var next: Date? = startDate
            return AnyIterator<Date> {
                guard let current = next else { return nil }
                if running || slow {
                    let candidate = current.addingTimeInterval(interval)
                    if timer {
                        next = current.timeIntervalSince1970 >= deadline ? nil : min(candidate, Date(timeIntervalSince1970: deadline))
                    } else { next = candidate }
                } else { next = nil }
                return current
            }
        }
    }
}

enum WidgetEnhancementError: LocalizedError {
    case notificationsUnavailable, notificationsDenied, invalidDate
    var errorDescription: String? {
        switch self {
        case .notificationsUnavailable: return "请从 OpenDock.app 打开应用后启用通知。"
        case .notificationsDenied: return "通知未获允许，请在系统设置 → 通知 → OpenDock 中开启。"
        case .invalidDate: return "请选择未来的时间。"
        }
    }
}

/// OS-managed requests fire after the popover closes or OpenDock quits.
final class LocalWidgetNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalWidgetNotifications()
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }

    func enable() async throws { try await authorize(requestPermission: true) }

    private func authorize(requestPermission: Bool) async throws {
        guard let center else { throw WidgetEnhancementError.notificationsUnavailable }
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional { return }
        if settings.authorizationStatus == .notDetermined && requestPermission,
           try await center.requestAuthorization(options: [.alert, .sound]) { return }
        throw WidgetEnhancementError.notificationsDenied
    }

    func cancel(id: UUID, channel: String) {
        let identifiers = (0..<64).map { "opendock.\(id).\(channel).\($0)" }
        center?.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func cancelAll(id: UUID) {
        for channel in ["timer", "alarm", "water"] { cancel(id: id, channel: channel) }
    }

    func timer(id: UUID, date: Date, title: String) async throws {
        try await authorize(requestPermission: false)
        guard date > .now else { cancel(id: id, channel: "timer"); return }
        cancel(id: id, channel: "timer")
        let content = UNMutableNotificationContent()
        content.title = title; content.body = "设定的时间已到。"; content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        try await center?.add(UNNotificationRequest(identifier: "opendock.\(id).timer.0", content: content, trigger: trigger))
    }

    func alarm(id: UUID, date: Date, weekdays: Set<Int>, title: String) async throws {
        try await authorize(requestPermission: false)
        if weekdays.isEmpty && date <= .now { throw WidgetEnhancementError.invalidDate }
        let specs = WidgetState.alarmComponents(date: date, weekdays: weekdays)
        cancel(id: id, channel: "alarm")
        for (index, spec) in specs.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = title.isEmpty ? "闹钟" : title
            content.body = "现在是 \(date.formatted(date: .omitted, time: .shortened))。"
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: spec, repeats: !weekdays.isEmpty)
            try await center?.add(UNNotificationRequest(identifier: "opendock.\(id).alarm.\(index)", content: content, trigger: trigger))
        }
    }

    func hydration(id: UUID, everyMinutes: Int, startHour: Int, endHour: Int) async throws {
        try await authorize(requestPermission: false)
        let specs = WidgetState.hydrationReminderComponents(everyMinutes: everyMinutes, startHour: startHour, endHour: endHour)
        cancel(id: id, channel: "water")
        for (index, spec) in specs.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "喝杯水，休息一下"
            content.body = "饮水提醒 · 记得在 OpenDock 记录。"
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: spec, repeats: true)
            try await center?.add(UNNotificationRequest(identifier: "opendock.\(id).water.\(index)", content: content, trigger: trigger))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@MainActor final class WidgetLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var message = ""
    @Published var busy = false
    private let manager = CLLocationManager()
    private var requested = false
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func request() {
        requested = true; busy = true; message = ""
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: busy = false; message = "定位未获允许，请在系统设置 → 隐私与安全性 → 定位服务中允许 OpenDock。"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.requested else { return }
            switch self.manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: self.manager.requestLocation()
            case .denied, .restricted: self.busy = false; self.message = "未授予定位权限。"
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in
            self.coordinate = coordinate
            self.busy = false; self.requested = false
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.busy = false; self.requested = false; self.message = error.localizedDescription }
    }
}

enum MeetingLink {
    static func parse(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeeting(url) { return url }
        let text = [url?.absoluteString, location, notes].compactMap { $0 }.joined(separator: "\n")
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        if let found = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first(where: isMeeting) { return found }
        let regex = try? NSRegularExpression(pattern: "(?:zoommtg|msteams)://[^\\s<>\\\"]+", options: [.caseInsensitive])
        return regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).flatMap { URL(string: String(text[$0])) }
        }.first(where: isMeeting)
    }

    static func isMeeting(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if ["zoommtg", "msteams"].contains(scheme) { return true }
        guard ["https", "http"].contains(scheme), let host = url.host?.lowercased() else { return false }
        return host == "meet.google.com" || host == "teams.microsoft.com" || host == "teams.live.com" || host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoom.com" || host.hasSuffix(".zoom.com")
    }
}
