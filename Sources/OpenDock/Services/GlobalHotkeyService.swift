import Carbon
import Foundation

/// Cmd + Option + 1…9 uses Carbon's public registered-hotkey API, which does not
/// require Input Monitoring or Accessibility permission.
final class GlobalHotkeyService {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var action: ((Int) -> Void)?
    private let signature: OSType = 0x4F444F4B // ODOK
    private(set) var unavailableIndices: [Int] = []

    func register(count: Int, action: @escaping (Int) -> Void) {
        unregister()
        self.action = action
        guard count > 0 else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else { return result }
            let service = Unmanaged<GlobalHotkeyService>.fromOpaque(context).takeUnretainedValue()
            guard identifier.signature == service.signature, identifier.id > 0 else { return OSStatus(eventNotHandledErr) }
            service.action?(Int(identifier.id) - 1)
            return noErr
        }, 1, &event, context, &handler)
        guard status == noErr else {
            unavailableIndices = Array(0..<min(count, 9))
            return
        }
        let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for index in 0..<min(count, codes.count) {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            let result = RegisterEventHotKey(UInt32(codes[index]), UInt32(cmdKey | optionKey), identifier, GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { references.append(reference) } else { unavailableIndices.append(index) }
        }
    }

    func unregister() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        action = nil
        unavailableIndices.removeAll()
    }

    deinit { unregister() }
}
