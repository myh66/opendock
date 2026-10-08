import AppKit
import ScreenCaptureKit

/// Temporary wallpaper windows survive Dock's restart, without capturing app content.
@MainActor
final class DockTransitionService {
    static let shared = DockTransitionService()
    private var windows: [UUID: [NSWindow]] = [:]
    func begin() async -> UUID? {
        guard #available(macOS 14, *), CGPreflightScreenCaptureAccess(), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        let id = UUID()
        var held: [NSWindow] = []
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        for screen in NSScreen.screens {
            guard let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { continue }
            var image: NSImage?
            if let display = content?.displays.first(where: { $0.displayID == screenID }), let content {
                let wallpaper = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.dock" && $0.windowLayer < 0 }
                if !wallpaper.isEmpty {
                    let filter = SCContentFilter(display: display, including: wallpaper)
                    let config = SCStreamConfiguration(); config.width = display.width; config.height = display.height; config.showsCursor = false
                    if let captured = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image = NSImage(cgImage: captured, size: screen.frame.size) }
                }
            }
            if image == nil, let url = NSWorkspace.shared.desktopImageURL(for: screen) { image = NSImage(contentsOf: url) }
            guard let image else { continue }
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
            let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size)); view.image = image; view.imageScaling = .scaleAxesIndependently
            window.contentView = view; window.orderFrontRegardless(); held.append(window)
        }
        guard !held.isEmpty else { return nil }
        windows[id] = held
        return id
    }
    func end(_ id: UUID?) {
        guard let id, let held = windows.removeValue(forKey: id) else { return }
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.18; held.forEach { $0.animator().alphaValue = 0 } } completionHandler: { held.forEach { $0.close() } }
    }
}
