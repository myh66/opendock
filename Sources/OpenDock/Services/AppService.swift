import AppKit
import ApplicationServices
import UniformTypeIdentifiers

struct ApplicationWindow: Identifiable {
    let id: String
    let title: String
    let isMinimized: Bool
    fileprivate let element: AXUIElement
    fileprivate let processIdentifier: pid_t
}

/// Uses NSWorkspace and the public Accessibility API. Reading window lists never
/// requests authorization; the permission prompt is limited to the explicit
/// requestAccessibilityPermission action.
@MainActor
enum AppService {
    private static var runningIDs: [pid_t: UUID] = [:]
    static var accessibilityEnabled: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        if accessibilityEnabled { openAccessibilitySettings(); return true }
        return AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    static func icon(for item: DockItem) -> NSImage {
        if [.app, .folder, .file].contains(item.kind), !item.target.isEmpty {
            return NSWorkspace.shared.icon(forFile: resolvedPath(item.target))
        }
        let symbol: String
        switch item.kind {
        case .link: symbol = "link"
        case .appGroup: symbol = "square.stack.3d.up.fill"
        case .spacer: symbol = "ellipsis"
        case .widget: symbol = item.widget?.symbol ?? "square.grid.2x2"
        case .app: symbol = "app.fill"
        case .folder: symbol = "folder.fill"
        case .file: symbol = "doc.fill"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: item.title) ?? NSImage()
    }

    @discardableResult
    static func open(_ item: DockItem) -> Bool {
        switch item.kind {
        case .app:
            let path = resolvedPath(item.target)
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return false }
            if let application = runningApplication(for: item) {
                application.unhide()
                for window in applicationWindows(for: item) where window.isMinimized {
                    _ = AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                return application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
            return NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .folder, .file:
            let path = resolvedPath(item.target)
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return false }
            return NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .link:
            guard let url = URL(string: item.target), let scheme = url.scheme?.lowercased(), ["https", "http", "mailto", "shortcuts"].contains(scheme) else { return false }
            return NSWorkspace.shared.open(url)
        case .appGroup:
            let paths = groupPaths(for: item)
            guard !paths.isEmpty else { return false }
            var result = true
            for path in paths { result = open(DockItem(kind: .app, target: path)) && result }
            return result
        case .widget, .spacer: return false
        }
    }

    /// Returns false when a requested window action cannot be performed, allowing
    /// the UI to show a permission action without prompting in the background.
    @discardableResult
    static func click(_ item: DockItem, minimizeIfActive: Bool) -> Bool {
        if item.kind == .app, minimizeIfActive, runningApplication(for: item)?.isActive == true {
            return minimizeWindows(for: item)
        }
        return open(item)
    }

    static func runningApps() -> [DockItem] {
        let applications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let currentPIDs = Set(applications.map(\.processIdentifier))
        runningIDs = runningIDs.filter { currentPIDs.contains($0.key) }
        return applications.compactMap { application in
                guard let url = application.bundleURL else { return nil }
                let id = runningIDs[application.processIdentifier] ?? UUID()
                runningIDs[application.processIdentifier] = id
                return DockItem(id: id, kind: .app, title: application.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                target: url.path, configuration: ["running": "true", "pid": String(application.processIdentifier)])
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func runningApplication(for item: DockItem) -> NSRunningApplication? {
        let path = URL(fileURLWithPath: resolvedPath(item.target)).standardizedFileURL.path
        if let exact = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == path && !$0.isTerminated }) { return exact }
        guard let identifier = Bundle(path: path)?.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first { !$0.isTerminated }
    }

    static func chooseItems(kind: ItemKind) -> [DockItem] {
        guard [.app, .appGroup, .folder, .file].contains(kind) else { return [] }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = kind == .folder
        panel.canChooseFiles = kind != .folder
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "添加"
        if kind == .app || kind == .appGroup {
            panel.title = kind == .appGroup ? "选择应用组中的应用" : "选择应用"
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        } else { panel.title = kind == .folder ? "选择文件夹" : "选择文件" }
        guard panel.runModal() == .OK else { return [] }
        if kind == .appGroup {
            let paths = panel.urls.filter { $0.pathExtension.lowercased() == "app" }.map(\.path)
            guard !paths.isEmpty, let data = try? JSONEncoder().encode(paths), let target = String(data: data, encoding: .utf8) else { return [] }
            return [DockItem(kind: .appGroup, title: "应用组", target: target)]
        }
        return panel.urls.map { url in
            DockItem(kind: kind, title: kind == .app ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent, target: url.path)
        }
    }

    static func reveal(_ item: DockItem) {
        guard [.app, .folder, .file].contains(item.kind) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: resolvedPath(item.target))])
    }

    @discardableResult
    static func quit(_ item: DockItem) -> Bool { runningApplication(for: item)?.terminate() ?? false }

    static func applicationWindows(for item: DockItem) -> [ApplicationWindow] {
        guard accessibilityEnabled, let application = runningApplication(for: item) else { return [] }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &result) == .success,
              let windows = result as? [AXUIElement] else { return [] }
        return windows.enumerated().map { index, window in
            var title: CFTypeRef?
            var minimized: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            _ = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            let windowTitle = title as? String ?? ""
            return ApplicationWindow(id: "\(application.processIdentifier):\(CFHash(window)):\(index)",
                                     title: windowTitle.isEmpty ? (application.localizedName ?? "窗口") : windowTitle,
                                     isMinimized: minimized as? Bool ?? false, element: window,
                                     processIdentifier: application.processIdentifier)
        }
    }

    @discardableResult
    static func activateWindow(_ window: ApplicationWindow) -> Bool {
        guard accessibilityEnabled, let app = NSRunningApplication(processIdentifier: window.processIdentifier) else { return false }
        _ = AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        app.unhide()
        guard app.activate(options: [.activateIgnoringOtherApps]) else { return false }
        return AXUIElementPerformAction(window.element, kAXRaiseAction as CFString) == .success
    }

    @discardableResult
    static func closeWindow(_ window: ApplicationWindow) -> Bool {
        guard accessibilityEnabled else { return false }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window.element, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button, CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString) == .success
    }

    @discardableResult
    static func minimizeWindows(for item: DockItem) -> Bool {
        guard accessibilityEnabled, let application = runningApplication(for: item), application.isActive else { return false }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        // AXFocusedWindow points at the active window. Enumerating all windows
        // would also minimize windows on other Spaces, which is undesirable.
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }

    private static func resolvedPath(_ path: String) -> String {
        if let url = URL(string: path), url.isFileURL { return url.standardizedFileURL.path }
        return (path as NSString).expandingTildeInPath
    }

    private static func groupPaths(for item: DockItem) -> [String] {
        for candidate in [item.configuration["apps"], item.target] {
            guard let candidate, let data = candidate.data(using: .utf8) else { continue }
            if let paths = try? JSONDecoder().decode([String].self, from: data) { return paths }
            if let applications = try? JSONDecoder().decode([DockItem].self, from: data) { return applications.filter { $0.kind == .app }.map(\.target) }
        }
        return item.target.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
