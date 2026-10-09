import AppKit
import SwiftUI
import Combine

final class DockPanel:NSPanel {
    override var canBecomeKey:Bool { true }
    override var canBecomeMain:Bool { false }
}

/// A trackpad movement chooses at most one layout. Inertia is scrolling, not
/// another layout-selection gesture; unphased devices reset after an idle gap.
struct DockLayoutScrollGesture {
    private var accumulated:CGFloat = 0
    private var triggered = false
    private var lastUnphasedTime:TimeInterval?
    mutating func reset() { accumulated = 0; triggered = false; lastUnphasedTime = nil }
    mutating func direction(delta:CGFloat,threshold:CGFloat,momentum:Bool,unphased:Bool,timestamp:TimeInterval)->Int? {
        guard !momentum, delta.isFinite, threshold.isFinite, threshold > 0 else { return nil }
        if unphased {
            if let last = lastUnphasedTime, timestamp - last > 0.2 { reset() }
            lastUnphasedTime = timestamp
        }
        guard !triggered else { return nil }
        accumulated += delta
        guard abs(accumulated) >= threshold else { return nil }
        triggered = true
        return accumulated > 0 ? -1:1
    }
}

@MainActor
final class DockPanelController {
    private let store:AppStore
    private var panel:DockPanel?
    private var handle:DockPanel?
    private var cancellables = Set<AnyCancellable>()
    private var timer:Timer?
    private var inputMonitor:Any?
    private var openManager:()->Void
    private var pointerAwaySince:Date?
    private var edgeEnteredAt:Date?
    private var revealedUntil = Date.distantPast
    private var layoutGesture = DockLayoutScrollGesture()
    private var pointerInteraction = false
    private var visibilityTimerInterval:TimeInterval?
    private var displayedProfileID:UUID?
    private var displayedItemIDs = Set<UUID>()
    private var windowSpace = WindowSpaceService()
    private var lastReservation = Date.distantPast
    init(store:AppStore,openManager:@escaping()->Void) {
        self.store = store; self.openManager = openManager
        store.$archive.map { archive in "\(archive.settings)-\(archive.activeCustomID?.uuidString ?? "")-\(archive.profiles.first { $0.id == archive.activeCustomID }?.items.map { "\($0.id)-\($0.kind)-\($0.configuration["width"] ?? "")" }.joined() ?? "")" }.removeDuplicates().receive(on:RunLoop.main).sink { [weak self] _ in self?.update() }.store(in:&cancellables)
        NotificationCenter.default.publisher(for:NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in self?.update() }.store(in:&cancellables)
        for name in [NSWorkspace.didLaunchApplicationNotification,NSWorkspace.didTerminateApplicationNotification] { NSWorkspace.shared.notificationCenter.publisher(for:name).sink { [weak self] _ in self?.update() }.store(in:&cancellables) }
        WindowMonitor.shared.$minimized.map(\.count).removeDuplicates().sink { [weak self] _ in self?.update() }.store(in:&cancellables)
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching:[.scrollWheel,.swipe,.keyDown,.leftMouseDown,.leftMouseUp]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .leftMouseUp {
                self.pointerInteraction = false
                // Defer until SwiftUI's drop/resize completion has processed mouse-up.
                DispatchQueue.main.async { DockInteractionState.shared.dragging = false; DockInteractionState.shared.resizing = false }
            }
            guard event.window == panel || (panel.childWindows ?? []).contains(where:{$0 == event.window}) else { return event }
            if event.type == .leftMouseDown { self.pointerInteraction = true; self.pointerAwaySince = nil; return event }
            if event.type == .keyDown,WidgetPopoverCoordinator.shared.activeID != nil,
               event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "w") { WidgetPopoverCoordinator.shared.activeID = nil; return nil }
            guard event.type == .scrollWheel || event.type == .swipe else { return event }
            // Popover scroll views must receive their own events; only Dock layout
            // switching is suspended while a popover or resize is in progress.
            guard WidgetPopoverCoordinator.shared.activeID == nil,!DockInteractionState.shared.resizing,!DockInteractionState.shared.dragging else { return event }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) { self.layoutGesture.reset() }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { self.layoutGesture.reset(); return event }
            let vertical = self.store.settings.position != .bottom
            let cross = vertical ? event.scrollingDeltaX : event.scrollingDeltaY
            let along = vertical ? event.scrollingDeltaY : event.scrollingDeltaX
            if event.modifierFlags.contains(.command),abs(event.scrollingDeltaY) > 3 {
                if event.hasPreciseScrollingDeltas {
                    if let direction = self.layoutGesture.direction(delta:event.scrollingDeltaY,threshold:3,momentum:!event.momentumPhase.isEmpty,unphased:event.phase.isEmpty,timestamp:event.timestamp) { self.cycle(direction) }
                } else if event.momentumPhase.isEmpty { self.cycle(event.scrollingDeltaY > 0 ? -1:1) }
                return nil
            }
            if event.type == .swipe { let delta = vertical ? event.deltaX : event.deltaY; if abs(delta) > 0 { self.cycle(delta > 0 ? -1:1); return nil }; return event }
            if event.hasPreciseScrollingDeltas,abs(cross) > abs(along) * 1.2 {
                if let direction = self.layoutGesture.direction(delta:cross,threshold:36,momentum:!event.momentumPhase.isEmpty,unphased:event.phase.isEmpty,timestamp:event.timestamp) { self.cycle(direction) }
                return nil
            }
            if !DockInteractionState.shared.contentOverflows,abs(along) >= abs(cross) { return nil }
            return event
        }
        update()
    }
    deinit { timer?.invalidate(); if let inputMonitor { NSEvent.removeMonitor(inputMonitor) } }
    func prepareForTermination() { timer?.invalidate(); WidgetPopoverCoordinator.shared.activeID = nil; panel?.orderOut(nil); handle?.orderOut(nil); windowSpace.restore() }
    private func cycle(_ direction:Int) { store.cycleCustom(direction:direction) }
    private func update() {
        guard store.settings.mode != .nativeOnly,store.settings.showCustomDock,let profile = store.activeCustom else { WidgetPopoverCoordinator.shared.activeID = nil; panel?.orderOut(nil); handle?.orderOut(nil); timer?.invalidate(); timer = nil; visibilityTimerInterval = nil; pointerInteraction = false; edgeEnteredAt = nil; pointerAwaySince = nil; DockInteractionState.shared.endIfMouseReleased(); windowSpace.restore(); return }
        let currentIDs = Set(profile.items.map(\.id))
        let addedItems = displayedProfileID == profile.id && !currentIDs.subtracting(displayedItemIDs).isEmpty
        displayedProfileID = profile.id; displayedItemIDs = currentIDs
        var newlyCreated = false
        if panel == nil {
            let created = DockPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            created.isFloatingPanel = true; created.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
            created.backgroundColor = .clear; created.isOpaque = false; created.hasShadow = true; created.hidesOnDeactivate = false; created.isReleasedWhenClosed = false; created.title = "OpenDock Custom Dock"
            created.contentView = NSHostingView(rootView:CustomDockView(openManager:openManager).environmentObject(store)); panel = created; newlyCreated = true
        }
        guard let panel,!NSScreen.screens.isEmpty else { return }
        let screen = NSScreen.screens[max(0,min(store.settings.displayIndex,NSScreen.screens.count - 1))]
        let visible = store.settings.mode == .replacement ? screen.frame.insetBy(dx:0,dy:8) : screen.visibleFrame
        let icon = CGFloat(store.settings.iconSize) + 14
        let runningCount = store.settings.showRunningApps ? AppService.runningApps().filter { running in !profile.items.contains { $0.kind == .app && $0.target == running.target } }.count : 0
        let minimizedCount = store.settings.showMinimizedWindows ? WindowMonitor.shared.minimized.count : 0
        let extra = CGFloat(runningCount + minimizedCount + (store.settings.showTrash ? 1:0)) * (icon + 8)
        let frame:NSRect
        if store.settings.position == .bottom {
            let length = profile.items.reduce(CGFloat(0)) { total,item in total + (item.kind == .widget ? 148:item.kind == .spacer ? 16:icon + 8) } + extra + 24
            let width = min(max(length,190),visible.width - 36)
            let hasNames = profile.items.contains { $0.configuration["showName"] == "true" }
            frame = NSRect(x:visible.midX - width/2,y:visible.minY + 9,width:width,height:max(icon + 58 + (hasNames ? 14:0),108))
        } else {
            let length = profile.items.reduce(CGFloat(0)) { total,item in total + (item.kind == .widget ? 76:item.kind == .spacer ? 18:icon + 8) } + extra + 45
            let height = min(max(length,160),visible.height - 50)
            frame = NSRect(x:store.settings.position == .left ? visible.minX + 9:visible.maxX - 175,y:visible.midY - height/2,width:166,height:height)
        }
        panel.level = store.settings.desktopWidget ? NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.desktopIconWindow)) + 1):.floating
        if panel.frame != frame { WidgetPopoverCoordinator.shared.activeID = nil }
        panel.setFrame(frame,display:true)
        configureHandle(screen)
        let interval:TimeInterval = store.settings.autoHide ? 0.25:1
        if timer == nil || visibilityTimerInterval != interval {
            timer?.invalidate(); visibilityTimerInterval = interval
            timer = Timer.scheduledTimer(withTimeInterval:interval,repeats:true) { [weak self] _ in Task { @MainActor in self?.checkVisibility() } }; timer?.tolerance = store.settings.autoHide ? 0.08:0.25
        }
        // Resizing or editing the current layout must not repeatedly hide its panel.
        if store.settings.autoHide { if newlyCreated { panel.orderOut(nil) } } else { panel.orderFrontRegardless() }
        if addedItems { revealedUntil = Date().addingTimeInterval(2); panel.orderFrontRegardless(); handle?.orderOut(nil); pointerAwaySince = nil }
        checkVisibility()
    }
    private func configureHandle(_ screen:NSScreen) {
        guard store.settings.autoHide,store.settings.showHiddenHandle else { handle?.orderOut(nil); return }
        if handle == nil {
            let created = DockPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            created.backgroundColor = .clear; created.isOpaque = false; created.hasShadow = false; created.level = .floating; created.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]; created.isReleasedWhenClosed = false
            created.contentView = NSHostingView(rootView:Button { [weak self] in self?.reveal() } label: { Capsule().fill(.secondary.opacity(0.45)).padding(2) }.buttonStyle(.plain)); handle = created
        }
        let f = screen.frame
        switch store.settings.position {
        case .left:handle?.setFrame(NSRect(x:f.minX,y:f.midY - 22,width:7,height:44),display:true)
        case .right:handle?.setFrame(NSRect(x:f.maxX - 7,y:f.midY - 22,width:7,height:44),display:true)
        case .bottom:handle?.setFrame(NSRect(x:f.midX - 22,y:f.minY,width:44,height:7),display:true)
        }
    }
    private func reveal() { revealedUntil = Date().addingTimeInterval(1.4); panel?.orderFrontRegardless(); handle?.orderOut(nil); pointerAwaySince = nil }
    private func checkVisibility() {
        DockInteractionState.shared.endIfMouseReleased()
        guard let panel,store.settings.showCustomDock,store.settings.mode != .nativeOnly,!NSScreen.screens.isEmpty else { return }
        let screen = NSScreen.screens[max(0,min(store.settings.displayIndex,NSScreen.screens.count - 1))]
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        if !mouseDown { pointerInteraction = false }
        let hasPopover = WidgetPopoverCoordinator.shared.activeID != nil || !(panel.childWindows ?? []).filter(\.isVisible).isEmpty
        let interacting = hasPopover || (mouseDown && (pointerInteraction || DockInteractionState.shared.dragging || DockInteractionState.shared.resizing))
        if DesktopVisibility.missionControlVisible() || (!interacting && store.settings.mode == .both && store.settings.hideWhenNativeDockShows && DesktopVisibility.nativeDockVisible()) { WidgetPopoverCoordinator.shared.activeID = nil; panel.orderOut(nil); handle?.orderOut(nil); edgeEnteredAt = nil; windowSpace.restore(); return }
        if store.settings.autoHide {
            let pointer = NSEvent.mouseLocation,f = screen.frame
            let atEdge:Bool
            switch store.settings.position { case .left:atEdge = pointer.x <= f.minX + 5 && f.contains(pointer);case .right:atEdge = pointer.x >= f.maxX - 5 && f.contains(pointer);case .bottom:atEdge = pointer.y <= f.minY + 5 && f.contains(pointer) }
            if atEdge {
                if edgeEnteredAt == nil { edgeEnteredAt = Date() }
                if Date().timeIntervalSince(edgeEnteredAt!) >= 0.2 { reveal() }
            }
            else {
                edgeEnteredAt = nil
                if panel.frame.insetBy(dx:-18,dy:-18).contains(pointer) || hasPopover || (mouseDown && (pointerInteraction || DockInteractionState.shared.dragging || DockInteractionState.shared.resizing)) { pointerAwaySince = nil }
                else if Date() > revealedUntil {
                    if pointerAwaySince == nil { pointerAwaySince = Date() }
                    if Date().timeIntervalSince(pointerAwaySince!) > 0.65 { panel.orderOut(nil); if store.settings.showHiddenHandle { handle?.orderFrontRegardless() } }
                }
            }
        } else { panel.orderFrontRegardless(); handle?.orderOut(nil) }
        if Date().timeIntervalSince(lastReservation) > 1 {
            lastReservation = Date()
            windowSpace.reserve(dockFrame:!ProcessInfo.processInfo.arguments.contains("--smoke-test") && !ProcessInfo.processInfo.arguments.contains("--ui-test") && store.settings.reserveWindowSpace && !store.settings.autoHide && !store.settings.desktopWidget && panel.isVisible ? panel.frame:nil,screen:screen,position:store.settings.position)
        }
    }
}
