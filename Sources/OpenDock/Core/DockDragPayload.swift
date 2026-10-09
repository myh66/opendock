import AppKit
import Combine
import UniformTypeIdentifiers

/// Internal drag data carries identities, so a drop resolves the current saved
/// items instead of accepting a stale serialized group or widget configuration.
struct DockDragPayload: Codable, Equatable {
    static let typeIdentifier = "io.github.myh66.opendock.items"
    static let acceptedTypes = [typeIdentifier, UTType.text.identifier]
    let sourceProfileID: UUID
    let orderedItemIDs: [UUID]
    var runningItem: DockItem? = nil

    var itemProvider: NSItemProvider {
        let provider = NSItemProvider(object: (orderedItemIDs.first?.uuidString ?? "") as NSString)
        if let data = try? JSONEncoder().encode(self) {
            provider.registerDataRepresentation(forTypeIdentifier: Self.typeIdentifier, visibility: .ownProcess) { completion in
                completion(data, nil); return nil
            }
        }
        return provider
    }

    func resolvedItems(in profiles: [DockProfile]) -> [DockItem]? {
        guard !orderedItemIDs.isEmpty, orderedItemIDs.count <= 500,
              Set(orderedItemIDs).count == orderedItemIDs.count,
              let profile = profiles.first(where: { $0.id == sourceProfileID }) else { return nil }
        if let runningItem {
            guard profile.kind == .custom, orderedItemIDs == [runningItem.id],
                  runningItem.kind == .app, runningItem.target.hasPrefix("/"),
                  URL(fileURLWithPath: runningItem.target).pathExtension.lowercased() == "app" else { return nil }
            return [runningItem]
        }
        let requested = Set(orderedItemIDs)
        let items = profile.items.filter { requested.contains($0.id) }
        guard items.count == orderedItemIDs.count else { return nil }
        // Keep the saved order even if a malformed payload changes its ID order.
        return items
    }

    @MainActor
    static func load(from providers: [NSItemProvider], profiles: [DockProfile], completion: @escaping @MainActor (DockDragPayload?) -> Void) {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(typeIdentifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                let payload = data.flatMap { $0.count <= 1_000_000 ? try? JSONDecoder().decode(Self.self, from: $0) : nil }
                Task { @MainActor in completion(payload) }
            }
        } else if let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) {
            provider.loadObject(ofClass: NSString.self) { value, _ in
                let id = (value as? String).flatMap { UUID(uuidString: $0) }
                let profile = id.flatMap { id in profiles.first { $0.items.contains { $0.id == id } } }
                let payload = id.flatMap { id in profile.map { Self(sourceProfileID: $0.id, orderedItemIDs: [id]) } }
                Task { @MainActor in completion(payload) }
            }
        } else { completion(nil) }
    }
}

@MainActor
final class DockInteractionState: ObservableObject {
    static let shared = DockInteractionState()
    @Published var resizing = false { didSet { updateTracking() } }
    @Published var dragging = false { didSet { updateTracking() } }
    @Published var contentOverflows = false
    private var trackingTimer:Timer?

    private func updateTracking() {
        if dragging || resizing {
            guard trackingTimer == nil else { return }
            // A drag can finish outside every OpenDock window. This short-lived
            // public mouse-button poll also works when the custom Dock is hidden.
            trackingTimer = Timer.scheduledTimer(withTimeInterval:0.2,repeats:true) { [weak self] _ in
                Task { @MainActor in self?.endIfMouseReleased() }
            }
        } else { trackingTimer?.invalidate(); trackingTimer = nil }
    }

    func endIfMouseReleased() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        if dragging { dragging = false }
        if resizing { resizing = false }
    }
}
