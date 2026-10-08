import AppIntents
import Foundation

struct DockProfileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dock 布局"
    static var defaultQuery = DockProfileQuery()
    var id: String
    var name: String
    var kind: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(kind)") }
    init(_ profile: DockProfile) { id = profile.id.uuidString; name = profile.name; kind = profile.kind.title }
}

struct DockProfileQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [DockProfileEntity] {
        await MainActor.run { AppStore.shared.profiles.filter { identifiers.contains($0.id.uuidString) }.map(DockProfileEntity.init) }
    }
    func suggestedEntities() async throws -> [DockProfileEntity] { await MainActor.run { AppStore.shared.profiles.map(DockProfileEntity.init) } }
    func entities(matching string: String) async throws -> [DockProfileEntity] {
        await MainActor.run { AppStore.shared.profiles.filter { $0.name.localizedCaseInsensitiveContains(string) }.map(DockProfileEntity.init) }
    }
}

struct SwitchDockFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "切换 Dock"
    static var description = IntentDescription("专注模式开启时应用保存的 Dock 布局。关闭专注模式时保留当前布局。")
    @Parameter(title: "Dock 布局") var profile: DockProfileEntity?
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "切换 Dock", subtitle: "\(profile?.name ?? "选择布局")") }
    func perform() async throws -> some IntentResult {
        guard let profile else { return .result() }
        let stored = await MainActor.run { AppStore.shared.profiles.first { $0.id.uuidString == profile.id } }
        guard let stored else { throw SetFocusFilterIntentError.notFound }
        try await AppStore.shared.activateAndWait(stored)
        return .result()
    }
}

struct SwitchDockIntent: AppIntent {
    static var title: LocalizedStringResource = "切换 OpenDock 布局"
    static var description = IntentDescription("从快捷指令切换保存的 Dock 布局。")
    static var openAppWhenRun = false
    @Parameter(title: "Dock 布局") var profile: DockProfileEntity
    static var parameterSummary: some ParameterSummary { Summary("切换到 \(\.$profile)") }
    func perform() async throws -> some IntentResult {
        let stored = await MainActor.run { AppStore.shared.profiles.first { $0.id.uuidString == profile.id } }
        guard let stored else { throw SetFocusFilterIntentError.notFound }
        try await AppStore.shared.activateAndWait(stored)
        return .result()
    }
}

struct OpenDockShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SwitchDockIntent(), phrases: ["切换 \(.applicationName) 布局"], shortTitle: "切换 Dock", systemImageName: "dock.rectangle")
    }
}
