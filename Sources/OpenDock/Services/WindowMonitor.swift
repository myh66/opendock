import AppKit
import ApplicationServices
import Combine
import CoreGraphics

@MainActor
struct MiniWindow: Identifiable {
    let id: String
    let title: String
    let appItem: DockItem
    let image: NSImage?
    private let window: ApplicationWindow

    init(window: ApplicationWindow, appItem: DockItem, image: NSImage?) {
        id = window.id; title = window.title; self.appItem = appItem; self.image = image; self.window = window
    }

    @discardableResult
    func restore() -> Bool {
        let restored = AppService.activateWindow(window)
        if restored { WindowMonitor.shared.refresh() }
        return restored
    }
}

@MainActor
final class WindowMonitor: ObservableObject {
    static let shared = WindowMonitor()
    @Published private(set) var minimized: [MiniWindow] = []
    @Published private(set) var badges: [String: String] = [:]
    @Published private(set) var enabled = false
    @Published private(set) var badgesEnabled = false
    private var timer: Timer?
    private var captureTask: Task<Void, Never>?
    private var captureGeneration = UUID()
    private let cache: WindowPreviewCache

    init(cache: WindowPreviewCache? = nil) { self.cache = cache ?? .shared }

    var screenCaptureGranted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    func requestScreenCapturePermission() -> Bool {
        if screenCaptureGranted {
            openScreenCaptureSettings(); return true
        }
        return CGRequestScreenCaptureAccess()
    }

    func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        cache.setEnabled(value)
        if !value { minimized = []; captureGeneration = UUID(); captureTask?.cancel(); captureTask = nil }
        updateTimer(); refresh()
    }

    func setBadgesEnabled(_ value: Bool) {
        badgesEnabled = value
        if !value { badges = [:] }
        updateTimer(); refresh()
    }

    func refresh() {
        guard enabled || badgesEnabled else { return }
        guard AppService.accessibilityEnabled else {
            minimized = []; badges = [:]; captureTask?.cancel(); captureTask = nil
            return
        }
        if badgesEnabled { badges = AppService.dockBadges() }
        guard enabled else { return }
        var allKeys = Set<String>()
        var snapshots: [WindowCaptureRequest] = []
        var mini: [MiniWindow] = []
        for app in AppService.runningApps() {
            for window in AppService.applicationWindows(for: app) {
                allKeys.insert(window.id)
                if window.isMinimized { mini.append(MiniWindow(window: window, appItem: app, image: screenCaptureGranted ? cache.image(for: window.id) : nil)) }
                else { snapshots.append(WindowCaptureRequest(key: window.id, processIdentifier: window.processIdentifier, title: window.title, frame: window.frame)) }
            }
        }
        cache.prune(keeping: allKeys)
        minimized = mini.sorted { $0.appItem.title == $1.appItem.title ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.appItem.title.localizedStandardCompare($1.appItem.title) == .orderedAscending }
        if screenCaptureGranted, captureTask == nil, !snapshots.isEmpty {
            let token = UUID(); captureGeneration = token
            captureTask = Task { [weak self] in
                guard let self else { return }
                await cache.capture(snapshots)
                if self.captureGeneration == token { self.captureTask = nil }
            }
        }
    }

    private func updateTimer() {
        if enabled || badgesEnabled {
            if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }; timer?.tolerance = 0.4 }
        } else { timer?.invalidate(); timer = nil }
    }

    deinit { timer?.invalidate(); captureTask?.cancel() }
}
