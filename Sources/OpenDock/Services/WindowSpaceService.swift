import AppKit
import ApplicationServices

/// Conservatively shrinks the focused, overlapping window using public AX APIs.
/// Frames are restored only if the app/user has not changed our last applied frame.
@MainActor
final class WindowSpaceService {
    private struct Change { let element:AXUIElement; let original:CGRect; var applied:CGRect }
    private var changes:[String:Change] = [:]
    func reserve(dockFrame:NSRect?,screen:NSScreen?,position:DockPosition) {
        guard let dockFrame, let screen, AppService.accessibilityEnabled else { restore(); return }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              front.activationPolicy == .regular else { return }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        var object:CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&object) == .success, let object, CFGetTypeID(object) == AXUIElementGetTypeID() else { return }
        let window = unsafeBitCast(object,to:AXUIElement.self)
        var fullscreen:CFTypeRef?
        _ = AXUIElementCopyAttributeValue(window,"AXFullScreen" as CFString,&fullscreen)
        guard fullscreen as? Bool != true, let current = Self.frame(window) else { return }
        let key = "\(front.processIdentifier):\(CFHash(window))"
        if let owned = changes[key], !Self.near(current,owned.applied) { changes[key] = nil }
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        var available = screen.visibleFrame
        switch position {
        case .left: let edge = dockFrame.maxX + 8; available.size.width -= max(0,edge - available.minX); available.origin.x = max(available.minX,edge)
        case .right: available.size.width = max(240,min(available.maxX,dockFrame.minX - 8) - available.minX)
        case .bottom: let edge = dockFrame.maxY + 8; available.size.height -= max(0,edge - available.minY); available.origin.y = max(available.minY,edge)
        }
        let allowed = CGRect(x:available.minX,y:top - available.maxY,width:available.width,height:available.height)
        let dockAX = CGRect(x:dockFrame.minX,y:top - dockFrame.maxY,width:dockFrame.width,height:dockFrame.height)
        guard changes[key] != nil || current.intersects(dockAX) else { return }
        let next = Self.constrained(current,to:allowed)
        guard !Self.near(current,next), next.width >= 240, next.height >= 160 else { return }
        var point = next.origin, size = next.size
        guard let p = AXValueCreate(.cgPoint,&point), let s = AXValueCreate(.cgSize,&size) else { return }
        var settable:DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window,kAXSizeAttribute as CFString,&settable) == .success,settable.boolValue else { return }
        let original = changes[key]?.original ?? current
        let sizeResult = AXUIElementSetAttributeValue(window,kAXSizeAttribute as CFString,s)
        let positionResult = AXUIElementSetAttributeValue(window,kAXPositionAttribute as CFString,p)
        if sizeResult == .success || positionResult == .success {
            let actual = Self.frame(window) ?? current
            changes[key] = Change(element:window,original:original,applied:actual)
        }
    }
    func restore() {
        guard AppService.accessibilityEnabled else { return }
        defer { changes.removeAll() }
        for change in changes.values {
            guard let current = Self.frame(change.element), Self.near(current,change.applied) else { continue }
            var point = change.original.origin, size = change.original.size
            if let p = AXValueCreate(.cgPoint,&point), let s = AXValueCreate(.cgSize,&size) { _ = AXUIElementSetAttributeValue(change.element,kAXPositionAttribute as CFString,p); _ = AXUIElementSetAttributeValue(change.element,kAXSizeAttribute as CFString,s) }
        }
    }
    nonisolated static func constrained(_ frame:CGRect,to allowed:CGRect)->CGRect {
        guard frame.intersects(allowed), allowed.width >= 240,allowed.height >= 160 else { return frame }
        var result = frame
        result.size.width = min(result.width,allowed.width); result.size.height = min(result.height,allowed.height)
        result.origin.x = min(max(result.minX,allowed.minX),allowed.maxX - result.width)
        result.origin.y = min(max(result.minY,allowed.minY),allowed.maxY - result.height)
        return result
    }
    private static func near(_ a:CGRect,_ b:CGRect)->Bool { abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3 }
    private static func frame(_ window:AXUIElement)->CGRect? {
        var p:CFTypeRef?,s:CFTypeRef?
        guard AXUIElementCopyAttributeValue(window,kAXPositionAttribute as CFString,&p) == .success, AXUIElementCopyAttributeValue(window,kAXSizeAttribute as CFString,&s) == .success,let p,let s,CFGetTypeID(p) == AXValueGetTypeID(),CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero,size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p,to:AXValue.self),.cgPoint,&point),AXValueGetValue(unsafeBitCast(s,to:AXValue.self),.cgSize,&size) else { return nil }
        return CGRect(origin:point,size:size)
    }
}

@MainActor
enum DesktopVisibility {
    static func nativeDockVisible() -> Bool {
        guard AppService.accessibilityEnabled,let dock = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first else { return false }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        func visit(_ element:AXUIElement,_ depth:Int)->Bool {
            guard depth < 4 else { return false }
            var role:CFTypeRef?,p:CFTypeRef?,s:CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element,kAXRoleAttribute as CFString,&role)
            if role as? String == kAXListRole,AXUIElementCopyAttributeValue(element,kAXPositionAttribute as CFString,&p) == .success,AXUIElementCopyAttributeValue(element,kAXSizeAttribute as CFString,&s) == .success,let p,let s,CFGetTypeID(p) == AXValueGetTypeID(),CFGetTypeID(s) == AXValueGetTypeID() {
                var point = CGPoint.zero,size = CGSize.zero
                if AXValueGetValue(unsafeBitCast(p,to:AXValue.self),.cgPoint,&point),AXValueGetValue(unsafeBitCast(s,to:AXValue.self),.cgSize,&size) {
                    let top = NSScreen.screens.first?.frame.maxY ?? 0
                    let frame = NSRect(x:point.x,y:top - point.y - size.height,width:size.width,height:size.height)
                    if size.width > 20 && size.height > 20 && NSScreen.screens.contains(where: { $0.frame.intersection(frame).width > 20 && $0.frame.intersection(frame).height > 20 }) { return true }
                }
            }
            var children:CFTypeRef?; _ = AXUIElementCopyAttributeValue(element,kAXChildrenAttribute as CFString,&children)
            return (children as? [AXUIElement] ?? []).prefix(120).contains { visit($0,depth + 1) }
        }
        return visit(root,0)
    }
    static func missionControlVisible() -> Bool {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
        return windows.contains { ($0[kCGWindowOwnerName as String] as? String) == "Dock" && ["Mission Control","MissionControl","Expose"].contains($0[kCGWindowName as String] as? String ?? "") }
    }
}
