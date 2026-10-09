import SwiftUI
import AppKit
import Carbon

extension Notification.Name {
    static let opendockShortcutRecordingChanged = Notification.Name("OpenDockShortcutRecordingChanged")
}

struct ShortcutRecorder: View {
    @EnvironmentObject var store: AppStore
    let profileID: UUID
    @State private var recording = false
    @State private var modifiers = ""
    @State private var validationMessage: String?

    private var shortcut: DockShortcut? {
        guard let index = store.profiles.firstIndex(where: { $0.id == profileID }) else { return nil }
        return store.profiles[index].shortcut ?? GlobalHotkeyService.defaultShortcut(index: index)
    }
    private var hasShortcut: Bool { shortcut.map { $0.modifiers != 0 } ?? false }

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            DockGlassGroup(spacing: 7) {
                HStack(spacing: 7) {
                    if recording {
                        ZStack {
                            HStack(spacing: 7) {
                                Circle().fill(DockTheme.accent).frame(width: 5, height: 5)
                                Text(modifiers.isEmpty ? "按下组合键…" : modifiers + " …")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                            }.padding(.horizontal, 12)
                            ShortcutKeyCapture(completion: receive, modifiersChanged: { value in modifiers = value })
                        }.frame(width: 178, height: 35)
                            .dockGlass(cornerRadius: 11, tint: DockTheme.accent.opacity(0.13))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(DockTheme.accent.opacity(0.5)))
                            .accessibilityLabel("正在录制快捷键").accessibilityHint("至少两个修饰键；Escape 取消，Delete 清除。")
                        Button { cancel() } label: { Image(systemName: "xmark").frame(width: 12, height: 12) }
                            .buttonStyle(QuietButtonStyle()).help("取消录制").accessibilityLabel("取消录制")
                    } else {
                        Button {
                            validationMessage = nil; modifiers = ""; recording = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "keyboard").foregroundStyle(.secondary)
                                Text(hasShortcut ? shortcut?.label ?? "设置快捷键" : "设置快捷键")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                            }.frame(minWidth: 125)
                        }.buttonStyle(QuietButtonStyle()).help("点击录制布局快捷键")
                            .accessibilityLabel("录制布局快捷键").accessibilityValue(hasShortcut ? shortcut?.label ?? "未设置" : "未设置")
                        if hasShortcut {
                            Button { clear() } label: { Image(systemName: "xmark").frame(width: 12, height: 12) }
                                .buttonStyle(QuietButtonStyle()).help("清除快捷键").accessibilityLabel("清除快捷键")
                        }
                    }
                }
            }
            if let validationMessage {
                Text(validationMessage).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 230, alignment: .leading)
                    .accessibilityLabel(validationMessage)
            } else if recording {
                Text("Esc 取消 · Delete 清除").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.frame(width: 230, alignment: .trailing)
        .onChange(of: recording) { value in announce(value) }
        .onReceive(NotificationCenter.default.publisher(for: .opendockShortcutRecordingChanged)) { notification in
            guard notification.userInfo?["recording"] as? Bool == true,
                  let other = notification.userInfo?["profileID"] as? UUID, other != profileID, recording else { return }
            cancel()
        }
        .onDisappear { if recording { recording = false; announce(false) } }
    }

    private func receive(_ result: DockShortcut?) {
        guard let result else { cancel(); return }
        guard GlobalHotkeyService.valid(result) else {
            validationMessage = "请同时按下至少两个修饰键：⌘、⌥、⌃、⇧。"
            return
        }
        if result.modifiers != 0, let conflict = store.profiles.enumerated().first(where: { entry in
            guard entry.element.id != profileID, let other = entry.element.shortcut ?? GlobalHotkeyService.defaultShortcut(index: entry.offset) else { return false }
            return other.modifiers != 0 && other.keyCode == result.keyCode && other.modifiers == result.modifiers
        }) {
            validationMessage = "已用于「\(conflict.element.name)」，请换一个组合键。"
            return
        }
        store.updateProfile(profileID) { $0.shortcut = result }
        validationMessage = nil; recording = false
    }
    private func clear() {
        store.updateProfile(profileID) { $0.shortcut = DockShortcut(keyCode: 0, modifiers: 0, label: "未设置") }
        validationMessage = nil; recording = false
    }
    private func cancel() { validationMessage = nil; modifiers = ""; recording = false }
    private func announce(_ value: Bool) {
        NotificationCenter.default.post(name: .opendockShortcutRecordingChanged, object: nil, userInfo: ["recording": value, "profileID": profileID])
    }
}

private struct ShortcutKeyCapture: NSViewRepresentable {
    let completion: (DockShortcut?) -> Void
    let modifiersChanged: (String) -> Void
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView(); view.completion = completion; view.modifiersChanged = modifiersChanged
        return view
    }
    func updateNSView(_ view: KeyView, context: Context) { view.completion = completion; view.modifiersChanged = modifiersChanged }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.completion = nil; view.modifiersChanged = nil }

    final class KeyView: NSView {
        var completion: ((DockShortcut?) -> Void)?
        var modifiersChanged: ((String) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let targetWindow = window else { return }
            DispatchQueue.main.async { [weak self, weak targetWindow] in
                guard let self, let targetWindow, self.window === targetWindow, self.completion != nil else { return }
                targetWindow.makeFirstResponder(self)
            }
        }
        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window?.firstResponder !== self else { return }
                    self.completion?(nil)
                }
            }
            return result
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }
        override func flagsChanged(with event: NSEvent) { modifiersChanged?(Self.modifierDescription(event.modifierFlags).label) }
        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat else { return }
            if event.keyCode == 53 { completion?(nil); return }
            if event.keyCode == 51 || event.keyCode == 117 { completion?(DockShortcut(keyCode: 0, modifiers: 0, label: "未设置")); return }
            let modifier = Self.modifierDescription(event.modifierFlags)
            let names: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 76: "⌤", 123: "←", 124: "→", 125: "↓", 126: "↑",
                122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
            let key = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            completion?(DockShortcut(keyCode: UInt32(event.keyCode), modifiers: modifier.value, label: modifier.label + key))
        }
        private static func modifierDescription(_ flags: NSEvent.ModifierFlags) -> (value: UInt32, label: String) {
            let flags = flags.intersection(.deviceIndependentFlagsMask)
            var value: UInt32 = 0; var label = ""
            for (flag, mask, symbol) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] where flags.contains(flag) {
                value |= UInt32(mask); label += symbol
            }
            return (value, label)
        }
    }
}
