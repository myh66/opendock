import AppKit
import ApplicationServices
import UniformTypeIdentifiers
import ImageIO

struct ApplicationWindow: Identifiable {
    let id: String
    let title: String
    let isMinimized: Bool
    let element: AXUIElement
    let processIdentifier: pid_t
    let frame: CGRect?
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
        if let symbol = item.configuration["iconSymbol"], !symbol.isEmpty,
           let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: item.title) {
            return icon.withSymbolConfiguration(.init(paletteColors: [iconColor(item.configuration["color"] ?? item.configuration["folderColor"] ?? item.configuration["groupColor"] ?? "8B7BF4")])) ?? icon
        }
        if item.kind == .link, let encoded = item.configuration["faviconPNG"], let data = Data(base64Encoded: encoded), data.count <= 500_000,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
           let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
           width > 0, width <= 2048, height > 0, height <= 2048, let image = NSImage(data: data) { return image }
        if item.kind == .link, let letter = item.configuration["letter"] {
            return labeledIcon(color: item.configuration["color"] ?? "8B7BF4", text: letter, folder: false)
        }
        if item.kind == .folder, item.configuration["folderColor"] != nil || item.configuration["folderLetter"] != nil || item.configuration["color"] != nil {
            return labeledIcon(color: item.configuration["folderColor"] ?? item.configuration["color"] ?? "699DCF", text: item.configuration["folderLetter"] ?? item.configuration["letter"] ?? "", folder: true)
        }
        if item.kind == .appGroup {
            return labeledIcon(color: item.configuration["groupColor"] ?? item.configuration["color"] ?? "8B7BF4", text: item.configuration["groupName"] ?? item.configuration["letter"] ?? item.title, folder: false)
        }
        if item.kind == .app, Bundle(path: resolvedPath(item.target))?.bundleIdentifier == "com.apple.iCal" {
            return calendarIcon(date: Date())
        }
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
        return windows.map { window in
            var title: CFTypeRef?
            var minimized: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            _ = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            let windowTitle = title as? String ?? ""
            let launch = application.launchDate?.timeIntervalSince1970 ?? 0
            return ApplicationWindow(id: "\(application.processIdentifier):\(launch):\(CFHash(window))",
                                     title: windowTitle.isEmpty ? (application.localizedName ?? "窗口") : windowTitle,
                                     isMinimized: minimized as? Bool ?? false, element: window,
                                     processIdentifier: application.processIdentifier, frame: windowFrame(window))
        }
    }

    /// Only reads the Dock's exposed badge/status label. Notification text and
    /// notification-center databases are never inspected.
    static func dockBadges() -> [String: String] {
        guard accessibilityEnabled, let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var result: [String: String] = [:]
        let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 5 else { return }
            var names: CFArray?
            if AXUIElementCopyAttributeNames(element, &names) == .success,
               let statusAttribute = (names as? [String])?.first(where: { $0.hasSuffix("StatusLabel") }) {
                var status: CFTypeRef?
                var title: CFTypeRef?
                var location: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, statusAttribute as CFString, &status)
                _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
                _ = AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &location)
                if let label = status as? String, let badge = badgeToken(from: label) {
                    if let url = location as? URL, url.isFileURL { result[url.standardizedFileURL.path] = badge }
                    else if let app = applications.first(where: { $0.localizedName == title as? String }), let path = app.bundleURL?.standardizedFileURL.path { result[path] = badge }
                }
            }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
               let children = value as? [AXUIElement] { for child in children.prefix(120) { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return result
    }

    static func badgeToken(from label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = trimmed.range(of: "[0-9]+(?:\\+)?", options: .regularExpression) { return String(trimmed[range]) }
        return "•"
    }

    static func calendarIcon(date: Date, calendar: Calendar = .current) -> NSImage {
        let day = String(calendar.component(.day, from: date))
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.dateFormat = "MMM"
        let month = formatter.string(from: date).uppercased()
        return NSImage(size: NSSize(width: 128, height: 128), flipped: false) { _ in
            let body = NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 112, height: 112), xRadius: 23, yRadius: 23)
            NSColor.white.setFill(); body.fill()
            NSColor.systemRed.setFill(); NSBezierPath(roundedRect: NSRect(x: 8, y: 85, width: 112, height: 35), xRadius: 17, yRadius: 17).fill()
            NSColor.systemRed.setFill(); NSRect(x: 8, y: 85, width: 112, height: 17).fill()
            drawCentered(month, in: NSRect(x: 11, y: 92, width: 106, height: 20), font: .systemFont(ofSize: 17, weight: .semibold), color: .white)
            drawCentered(day, in: NSRect(x: 9, y: 13, width: 110, height: 70), font: .systemFont(ofSize: 62, weight: .light), color: .black)
            return true
        }
    }

    static func labeledIcon(color: String, text: String, folder: Bool) -> NSImage {
        let tint = iconColor(color)
        let label = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(folder ? 1 : 2))
        return NSImage(size: NSSize(width: 128, height: 128), flipped: false) { _ in
            tint.setFill()
            if folder {
                NSBezierPath(roundedRect: NSRect(x: 9, y: 82, width: 48, height: 27), xRadius: 9, yRadius: 9).fill()
                NSBezierPath(roundedRect: NSRect(x: 8, y: 22, width: 112, height: 75), xRadius: 13, yRadius: 13).fill()
            } else { NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 112, height: 112), xRadius: 24, yRadius: 24).fill() }
            if !label.isEmpty { drawCentered(label, in: NSRect(x: 14, y: folder ? 28 : 25, width: 100, height: 68), font: .systemFont(ofSize: 43, weight: .semibold), color: .white) }
            else if let symbol = NSImage(systemSymbolName: folder ? "folder.fill" : "square.grid.2x2.fill", accessibilityDescription: nil) {
                symbol.draw(in: NSRect(x: 38, y: 40, width: 52, height: 48))
            }
            return true
        }
    }

    private static func drawCentered(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private static func iconColor(_ value: String) -> NSColor {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return .systemBlue }
        return NSColor(srgbRed: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
    }

    private static func windowFrame(_ window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef, CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionRef, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
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
