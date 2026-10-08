import XCTest
@testable import OpenDock

final class ArchiveTests: XCTestCase {
    private func sample() -> DockArchive {
        let profile = DockProfile(name: "Work", items: [DockItem(kind: .widget, title: "Note", widget: .note, configuration: ["text": "hello\nworld"]), DockItem(kind: .link, title: "Example", target: "https://example.com")])
        return DockArchive(profiles: [profile], activeCustomID: profile.id)
    }
    func testArchiveRoundTripPreservesConfigurationAndActiveProfile() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(DockArchive.self, from: data).validated(), original)
    }
    func testImportAddsCopiesWithoutChangingActiveProfileOrSettings() throws {
        let original = sample()
        let result = try original.mergingProfiles(from: original)
        XCTAssertEqual(result.profiles.count, 2)
        XCTAssertEqual(result.profiles[0], original.profiles[0])
        XCTAssertNotEqual(result.profiles[0].id, result.profiles[1].id)
        XCTAssertNotEqual(result.profiles[0].items[0].id, result.profiles[1].items[0].id)
        XCTAssertEqual(result.profiles[1].items[0].configuration["text"], "hello\nworld")
        XCTAssertEqual(result.activeCustomID, original.activeCustomID)
    }
    func testRejectsMalformedArchives() throws {
        var archive = sample(); archive.version = 999
        XCTAssertThrowsError(try archive.validated())
        archive = sample(); archive.profiles.append(archive.profiles[0])
        XCTAssertThrowsError(try archive.validated())
        archive = sample(); archive.activeCustomID = UUID()
        XCTAssertThrowsError(try archive.validated())
        archive = sample(); archive.settings.iconSize = .infinity
        XCTAssertThrowsError(try archive.validated())
        archive = sample(); archive.profiles[0].kind = .native
        XCTAssertThrowsError(try archive.validated())
    }
    @MainActor func testStorePersistsEditingAndRestoresOnReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layouts.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(sample()).write(to: url)
        let store = AppStore(storageURL: url)
        let id = store.profiles[0].id
        store.updateProfile(id) { $0.name = "Renamed" }
        let reloaded = AppStore(storageURL: url)
        XCTAssertEqual(reloaded.profiles[0].name, "Renamed")
    }
    @MainActor func testCorruptStorageIsBackedUpBeforeDefaultsAreWritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layouts.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("corrupt source".utf8); try original.write(to: url)
        let store = AppStore(storageURL: url)
        XCTAssertNotNil(store.errorMessage)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("layouts-unreadable-") })
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }
}
