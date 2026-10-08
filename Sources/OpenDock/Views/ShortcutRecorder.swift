import SwiftUI
import AppKit
import Carbon

struct ShortcutRecorder: View {
    @EnvironmentObject var store: AppStore
    let profileID: UUID
    @State private var recording = false
    private var shortcut: DockShortcut? {
        guard let index = store.profiles.firstIndex(where: { $0.id == profileID }) else { return nil }
        return store.profiles[index].shortcut ?? GlobalHotkeyService.defaultShortcut(index: index)
    }
    var body: some View {
        HStack(spacing: 8) {
            if recording {
                ShortcutKeyCapture { result in
                    recording = false
                    if let result {
                        guard GlobalHotkeyService.valid(result) else { store.errorMessage = "快捷键需要至少两个修饰键（⌘、⌥、⌃、⇧）。"; return }
                        let conflict = store.profiles.enumerated().first { entry in
                            entry.element.id != profileID && (entry.element.shortcut ?? GlobalHotkeyService.defaultShortcut(index: entry.offset)).map { $0.modifiers != 0 && $0.keyCode == result.keyCode && $0.modifiers == result.modifiers } == true
                        }
                        guard conflict == nil else { store.errorMessage = "此快捷键已用于「\(conflict!.element.name)」。"; return }
                        store.updateProfile(profileID) { $0.shortcut = result }
                    }
                }.frame(width: 170, height: 28)
            } else {
                Button(shortcut?.label ?? "录制快捷键") { recording = true }.buttonStyle(.bordered)
            }
            if shortcut?.modifiers != 0 { Button { store.updateProfile(profileID) { $0.shortcut = DockShortcut(keyCode: 0, modifiers: 0, label: "未设置") } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("清除快捷键") }
        }
    }
}
private struct ShortcutKeyCapture: NSViewRepresentable {
    let completion: (DockShortcut?) -> Void
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView(); view.completion = completion
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: KeyView, context: Context) { view.completion = completion }
    final class KeyView: NSView {
        var completion: ((DockShortcut?) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func draw(_ dirtyRect: NSRect) { ("按下快捷键…  Esc 取消" as NSString).draw(at: NSPoint(x: 4,y: 6), withAttributes: [.font:NSFont.systemFont(ofSize: 11),.foregroundColor:NSColor.secondaryLabelColor]) }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { completion?(nil); return }
            if event.keyCode == 51 || event.keyCode == 117 { completion?(DockShortcut(keyCode: 0, modifiers: 0, label: "未设置")); return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods: UInt32 = 0; var label = ""
            for (flag, mask, symbol) in [(NSEvent.ModifierFlags.control,controlKey,"⌃"),(.option,optionKey,"⌥"),(.shift,shiftKey,"⇧"),(.command,cmdKey,"⌘")] where flags.contains(flag) { mods |= UInt32(mask); label += symbol }
            let names: [UInt16:String] = [36:"↩",48:"⇥",49:"Space",123:"←",124:"→",125:"↓",126:"↑"]
            label += names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            completion?(DockShortcut(keyCode: UInt32(event.keyCode), modifiers: mods, label: label))
        }
    }
}
