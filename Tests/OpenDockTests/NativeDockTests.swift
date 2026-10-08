import XCTest
@testable import OpenDock

final class NativeDockTests: XCTestCase {
    /// These tests exercise pure serialization only. They never modify system
    /// preferences, restart Dock, register shortcuts, or request TCC permission.
    func testApplicationAndSpacersRoundTrip() throws {
        let items = [DockItem(kind: .app, title: "Calculator", target: "/System/Applications/Calculator.app"),
                     DockItem(kind: .spacer, configuration: ["size": "small"]), DockItem(kind: .spacer)]
        let tiles = try NativeDockService.tiles(for: items)
        let restored = try NativeDockService.items(from: tiles)
        XCTAssertEqual(restored.map(\.kind), items.map(\.kind))
        XCTAssertEqual(restored[0].target, items[0].target)
        XCTAssertEqual(restored[0].title, "Calculator")
        XCTAssertEqual(restored[1].configuration["size"], "small")
        XCTAssertEqual(restored[2].configuration["size"], "regular")
    }

    func testCapturedNativeMetadataIsPreserved() throws {
        let tile: [String: Any] = ["GUID": 12345, "tile-type": "file-tile", "tile-data": [
            "file-data": ["_CFURLString": "file:///Applications/An%20App.app/", "_CFURLStringType": 15],
            "file-label": "An App", "bundle-identifier": "org.example.app", "file-mod-date": 42,
            "book": Data([1, 2, 3])
        ]]
        let items = try NativeDockService.items(from: [tile])
        XCTAssertEqual(items[0].target, "/Applications/An App.app")
        let recovered = try XCTUnwrap(NativeDockService.tiles(for: items).first)
        XCTAssertTrue(NSDictionary(dictionary: recovered).isEqual(to: tile))
    }

    func testChangingCapturedTargetRebuildsTile() throws {
        let tile: [String: Any] = ["GUID": 12345, "tile-type": "file-tile", "tile-data": [
            "file-data": ["_CFURLString": "file:///Applications/Old.app/", "_CFURLStringType": 15], "file-label": "Old"
        ]]
        var item = try XCTUnwrap(NativeDockService.items(from: [tile]).first)
        item.target = "/Applications/New.app"
        let tiles = try NativeDockService.tiles(for: [item])
        XCTAssertEqual(try NativeDockService.items(from: tiles).first?.target, item.target)
        XCTAssertNil(tiles[0]["GUID"])
    }

    func testUnsupportedNativeItemsCannotSilentlyDisappear() {
        XCTAssertThrowsError(try NativeDockService.tiles(for: [DockItem(kind: .folder, target: "/tmp")]))
        XCTAssertThrowsError(try NativeDockService.items(from: [["tile-type": "unsupported-tile"]]))
        XCTAssertThrowsError(try NativeDockService.tiles(for: [DockItem(kind: .app, target: "https://example.com/App.app")]))
        XCTAssertThrowsError(try NativeDockService.tiles(for: [DockItem(kind: .app, target: "/tmp/file.txt")]))
    }

    func testMalformedCapturedMetadataFallsBackToSafeTile() throws {
        let item = DockItem(kind: .app, title: "App", target: "/Applications/App.app", configuration: ["nativeTile": "not a plist"])
        let tiles = try NativeDockService.tiles(for: [item])
        XCTAssertEqual(try NativeDockService.items(from: tiles).first?.target, item.target)
    }

    func testPureGeneratedLayoutIsAValidPropertyList() throws {
        let items = [DockItem(kind: .app, target: "/Applications/A & B.app"), DockItem(kind: .spacer)]
        let tiles = try NativeDockService.tiles(for: items)
        let preferences: [String: Any] = ["persistent-apps": tiles, "persistent-others": [["tile-type": "directory-tile"]], "autohide": true]
        let data = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        let restored = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(restored["autohide"] as? Bool, true)
        XCTAssertEqual((restored["persistent-others"] as? [[String: String]])?.first?["tile-type"], "directory-tile")
        let restoredTiles = try XCTUnwrap(restored["persistent-apps"] as? [[String: Any]])
        XCTAssertEqual(try NativeDockService.items(from: restoredTiles).first?.target, items.first?.target)
    }
}
