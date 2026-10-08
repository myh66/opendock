import XCTest
@testable import OpenDock

/// Every test loads a complete fixture from a temporary directory, preventing
/// AppStore's default-layout discovery or persistence from touching user data.
final class StoreTests: XCTestCase {
    private func fixture() -> DockArchive {
        let items = ["A", "B", "C", "D"].map { DockItem(kind: .link, title: $0, target: "https://example.com/\($0)") }
        let first = DockProfile(name: "First", items: items)
        let second = DockProfile(name: "创作 布局", items: [DockItem(kind: .widget, title: "Note", widget: .note, configuration: ["text": "Keep this note"])])
        // Even if a URL guard regresses, this nonexistent app fails NativeDock
        // validation before any system preference can be written.
        let native = DockProfile(name: "Native", kind: .native, items: [DockItem(kind: .app, target: "/__OpenDockIntegrationTests__/Missing.app")])
        return DockArchive(profiles: [first, second, native], activeCustomID: first.id, activeNativeID: native.id)
    }

    @MainActor private func makeStore(_ archive: DockArchive) throws -> (AppStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenDockStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("layouts.json")
        try JSONEncoder().encode(archive.validated()).write(to: url, options: .atomic)
        return (AppStore(storageURL: url), directory)
    }

    @MainActor private func persistedArchive(_ store: AppStore) throws -> DockArchive {
        try JSONDecoder().decode(DockArchive.self, from: Data(contentsOf: store.storageURL)).validated()
    }

    @MainActor func testDraggingForwardReachesHoveredSlotAndPersistsOrder() async throws {
        let archive = fixture(), profile = archive.profiles[0]
        let (store, directory) = try makeStore(archive)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.moveItem(profile.items[0].id, before: profile.items[1].id, in: profile.id)
        XCTAssertEqual(store.profiles[0].items.map(\.title), ["B", "A", "C", "D"])
        store.moveItem(profile.items[0].id, before: profile.items[3].id, in: profile.id)
        XCTAssertEqual(store.profiles[0].items.map(\.title), ["B", "C", "D", "A"])
        XCTAssertEqual(try persistedArchive(store), store.archive)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testDraggingBackwardAndOntoItselfPreservesItems() async throws {
        let archive = fixture(), profile = archive.profiles[0]
        let (store, directory) = try makeStore(archive)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.moveItem(profile.items[3].id, before: profile.items[1].id, in: profile.id)
        XCTAssertEqual(store.profiles[0].items.map(\.title), ["A", "D", "B", "C"])
        let before = store.archive
        store.moveItem(profile.items[3].id, before: profile.items[3].id, in: profile.id)
        XCTAssertEqual(store.archive, before)
        XCTAssertEqual(Set(store.profiles[0].items.map(\.id)), Set(profile.items.map(\.id)))
        XCTAssertEqual(try persistedArchive(store), store.archive)
    }

    @MainActor func testDuplicatingProfileCreatesIndependentIDsAndPreservesContent() async throws {
        let archive = fixture(), source = archive.profiles[1]
        let (store, directory) = try makeStore(archive)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.duplicate(source)
        let copy = try XCTUnwrap(store.profiles.last)
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertNotEqual(copy.items[0].id, source.items[0].id)
        XCTAssertEqual(copy.items[0].configuration["text"], "Keep this note")
        XCTAssertEqual(store.profiles[1], source)
        XCTAssertEqual(store.selectedID, copy.id)
        XCTAssertEqual(store.archive.activeCustomID, archive.activeCustomID)
        XCTAssertEqual(try persistedArchive(store), store.archive)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testDeletingActiveCustomProfilePersistsValidReplacementWithoutFalseError() async throws {
        let archive = fixture()
        let (store, directory) = try makeStore(archive)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.deleteProfile(archive.profiles[0].id)
        XCTAssertEqual(store.archive.activeCustomID, archive.profiles[1].id)
        XCTAssertEqual(store.selectedID, archive.profiles[1].id)
        XCTAssertFalse(store.profiles.contains { $0.id == archive.profiles[0].id })
        XCTAssertEqual(try persistedArchive(store), store.archive)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testDeletingActiveNativeProfileClearsReferenceWithoutWritingSystemDock() async throws {
        let archive = fixture()
        let (store, directory) = try makeStore(archive)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.deleteProfile(archive.profiles[2].id)
        XCTAssertNil(store.archive.activeNativeID)
        XCTAssertFalse(store.applyingNative)
        XCTAssertEqual(store.archive.activeCustomID, archive.activeCustomID)
        XCTAssertEqual(try persistedArchive(store), store.archive)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testCustomURLActivatesByIdentifierAndEncodedName() async throws {
        let archive = fixture()
        let (store, directory) = try makeStore(archive)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.settings.showCustomDock = false
        let second = archive.profiles[1]
        store.handleURL(try XCTUnwrap(URL(string: "opendock://profile/\(second.id.uuidString.lowercased())")))
        XCTAssertEqual(store.archive.activeCustomID, second.id)
        XCTAssertTrue(store.settings.showCustomDock)
        store.handleURL(try XCTUnwrap(URL(string: "opendock://profile/First")))
        XCTAssertEqual(store.archive.activeCustomID, archive.profiles[0].id)
        let encoded = try XCTUnwrap(second.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
        store.handleURL(try XCTUnwrap(URL(string: "opendock://profile/\(encoded)")))
        XCTAssertEqual(store.archive.activeCustomID, second.id)
        XCTAssertFalse(store.applyingNative)
        XCTAssertEqual(try persistedArchive(store), store.archive)
    }

    @MainActor func testNativeURLIsRejectedBeforeAnyNativeOperation() async throws {
        let archive = fixture()
        let (store, directory) = try makeStore(archive)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = store.archive
        store.handleURL(try XCTUnwrap(URL(string: "opendock://profile/\(archive.profiles[2].id.uuidString)")))
        XCTAssertEqual(store.archive, before)
        XCTAssertFalse(store.applyingNative)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try persistedArchive(store), before)
    }

    @MainActor func testNativeProfileCannotBeDeletedDuringAnApplication() async throws {
        let archive = fixture()
        let (store, directory) = try makeStore(archive)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Simulate the UI's in-progress state; do not call a native operation.
        store.applyingNative = true
        store.deleteProfile(archive.profiles[2].id)
        XCTAssertEqual(store.archive, archive)
        XCTAssertTrue(store.applyingNative)
        XCTAssertEqual(try persistedArchive(store), archive)
    }

    @MainActor func testNativeProfileAdditionFiltersUnsupportedItemKinds() async throws {
        let archive = fixture()
        let (store, directory) = try makeStore(archive)
        defer { try? FileManager.default.removeItem(at: directory) }
        let native = archive.profiles[2]
        store.addItems([DockItem(kind: .widget, widget: .clock), DockItem(kind: .folder, target: "/tmp"), DockItem(kind: .spacer)], to: native.id)
        XCTAssertEqual(store.profiles[2].items.map(\.kind), [.app, .spacer])
        XCTAssertFalse(store.applyingNative)
        XCTAssertEqual(try persistedArchive(store), store.archive)
        XCTAssertNil(store.errorMessage)
    }
}
