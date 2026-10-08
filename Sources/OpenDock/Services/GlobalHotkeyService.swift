import Carbon
import Foundation

/// Public registered-hotkey API; no Input Monitoring permission required.
final class GlobalHotkeyService {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var action: ((Int) -> Void)?
    private let signature: OSType = 0x4F444F4B
    private(set) var unavailableIndices: [Int] = []
    static func defaultShortcut(index: Int) -> DockShortcut? {
        let codes = [kVK_ANSI_1,kVK_ANSI_2,kVK_ANSI_3,kVK_ANSI_4,kVK_ANSI_5,kVK_ANSI_6,kVK_ANSI_7,kVK_ANSI_8,kVK_ANSI_9]
        guard codes.indices.contains(index) else { return nil }
        return DockShortcut(keyCode: UInt32(codes[index]), modifiers: UInt32(cmdKey | optionKey), label: "⌥⌘\(index + 1)")
    }
    static func valid(_ shortcut: DockShortcut) -> Bool {
        if shortcut.modifiers == 0 { return shortcut.keyCode == 0 }
        let masks = [UInt32(cmdKey),UInt32(optionKey),UInt32(controlKey),UInt32(shiftKey)]
        return shortcut.keyCode <= 127 && masks.filter { shortcut.modifiers & $0 != 0 }.count >= 2 && shortcut.modifiers & ~masks.reduce(0, |) == 0
    }
    func register(profiles: [DockProfile], action: @escaping (Int) -> Void) {
        unregister(); self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else { return result }
            let service = Unmanaged<GlobalHotkeyService>.fromOpaque(context).takeUnretainedValue()
            guard identifier.signature == service.signature, identifier.id > 0 else { return OSStatus(eventNotHandledErr) }
            service.action?(Int(identifier.id) - 1); return noErr
        }, 1, &event, context, &handler)
        guard result == noErr else { unavailableIndices = Array(profiles.indices); return }
        var used = Set<String>()
        for (index, profile) in profiles.enumerated() {
            guard let shortcut = profile.shortcut ?? Self.defaultShortcut(index: index), shortcut.modifiers != 0 else { continue }
            let signature = "\(shortcut.keyCode):\(shortcut.modifiers)"
            guard Self.valid(shortcut), used.insert(signature).inserted else { unavailableIndices.append(index); continue }
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: self.signature, id: UInt32(index + 1))
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { references.append(reference) } else { unavailableIndices.append(index) }
        }
    }
    func unregister() {
        references.forEach { UnregisterEventHotKey($0) }; references.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil; action = nil; unavailableIndices.removeAll()
    }
    deinit { unregister() }
}
