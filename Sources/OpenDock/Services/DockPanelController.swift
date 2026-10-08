import AppKit
import SwiftUI
import Combine

final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DockPanelController {
    private let store: AppStore
    private var panel: DockPanel?
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var scrollMonitor: Any?
    private var openManager: () -> Void
    private var pointerAwaySince: Date?
    private var revealedUntil = Date.distantPast
    private var lastCycle = Date.distantPast

    init(store: AppStore, openManager: @escaping () -> Void) {
        self.store = store; self.openManager = openManager
        store.$archive.map { archive in
            "\(archive.settings)-\(archive.activeCustomID?.uuidString ?? "")-\(archive.profiles.first { $0.id == archive.activeCustomID }?.items.map { "\($0.id)-\($0.kind)" }.joined() ?? "")"
        }.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.update() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in self?.update() }.store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification).sink { [weak self] _ in self?.update() }.store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification).sink { [weak self] _ in self?.update() }.store(in: &cancellables)
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let panel = self.panel, event.window == panel, event.modifierFlags.contains(.command), abs(event.scrollingDeltaY) > 3, Date().timeIntervalSince(self.lastCycle) > 0.5 else { return event }
            self.lastCycle = Date(); self.store.cycleCustom(direction: event.scrollingDeltaY > 0 ? -1 : 1)
            return nil
        }
        update()
    }
    deinit { timer?.invalidate(); if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) } }

    private func update() {
        guard store.settings.showCustomDock, let profile = store.activeCustom else { panel?.orderOut(nil); stopTimer(); return }
        if panel == nil {
            let newPanel = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            newPanel.isFloatingPanel = true; newPanel.level = .floating
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            newPanel.backgroundColor = .clear; newPanel.isOpaque = false; newPanel.hasShadow = true
            newPanel.hidesOnDeactivate = false; newPanel.isReleasedWhenClosed = false
            newPanel.title = "OpenDock Custom Dock"
            newPanel.contentView = NSHostingView(rootView: CustomDockView(openManager: openManager).environmentObject(store))
            panel = newPanel
        }
        guard let panel, !NSScreen.screens.isEmpty else { return }
        let screen = NSScreen.screens[min(store.settings.displayIndex, NSScreen.screens.count - 1)]
        let visible = screen.visibleFrame
        let icon = CGFloat(store.settings.iconSize) + 14
        let runningCount = store.settings.showRunningApps ? min(AppService.runningApps().filter { running in !profile.items.contains { $0.kind == .app && $0.target == running.target } }.count, 12) : 0
        let extra = CGFloat(runningCount + (store.settings.showTrash ? 1 : 0)) * (icon + 8)
        var frame: NSRect
        if store.settings.position == .bottom {
            let length = profile.items.reduce(CGFloat(0)) { total, item in total + (item.kind == .widget ? 146 : item.kind == .spacer ? 16 : icon + 8) } + extra + 24
            let width = min(max(length, 190), visible.width - 36)
            frame = NSRect(x: visible.midX - width / 2, y: visible.minY + 9, width: width, height: max(icon + 50, 108))
        } else {
            let length = profile.items.reduce(CGFloat(0)) { total, item in total + (item.kind == .widget ? 76 : item.kind == .spacer ? 18 : icon + 8) } + extra + 45
            let height = min(max(length, 160), visible.height - 50)
            frame = NSRect(x: store.settings.position == .left ? visible.minX + 9 : visible.maxX - 175, y: visible.midY - height / 2, width: 166, height: height)
        }
        panel.setFrame(frame, display: true)
        if store.settings.autoHide {
            if timer == nil { panel.orderOut(nil); timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkPointer() } }; timer?.tolerance = 0.06 }
        } else { stopTimer(); panel.orderFrontRegardless() }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil; pointerAwaySince = nil }
    private func checkPointer() {
        guard let panel, store.settings.showCustomDock, !NSScreen.screens.isEmpty else { return }
        let screen = NSScreen.screens[min(store.settings.displayIndex, NSScreen.screens.count - 1)]
        let pointer = NSEvent.mouseLocation
        let frame = screen.frame
        let atEdge: Bool
        switch store.settings.position {
        case .left: atEdge = pointer.x <= frame.minX + 5 && frame.contains(pointer)
        case .right: atEdge = pointer.x >= frame.maxX - 5 && frame.contains(pointer)
        case .bottom: atEdge = pointer.y <= frame.minY + 5 && frame.contains(pointer)
        }
        let inDock = panel.frame.insetBy(dx: -18, dy: -18).contains(pointer)
        let hasPopover = !(panel.childWindows ?? []).filter { $0.isVisible }.isEmpty
        if atEdge {
            revealedUntil = Date().addingTimeInterval(1.4)
            panel.orderFrontRegardless(); pointerAwaySince = nil
        } else if inDock || hasPopover { pointerAwaySince = nil }
        else if Date() > revealedUntil {
            if pointerAwaySince == nil { pointerAwaySince = Date() }
            if Date().timeIntervalSince(pointerAwaySince!) > 0.65 { panel.orderOut(nil) }
        }
    }
}
