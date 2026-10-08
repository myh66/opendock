import XCTest
@testable import OpenDock

final class StorageScannerTests: XCTestCase {
    func testDirectoryTotalsIncludeDeepFilesAndDoNotFollowSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenDockStorageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = directory.appendingPathComponent("scope")
        let deep = scope.appendingPathComponent("A/B/C/D")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: deep.appendingPathComponent("deep.bin"))
        try Data(repeating: 2, count: 50).write(to: scope.appendingPathComponent("small.bin"))
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 9000).write(to: outside.appendingPathComponent("private.bin"))
        try FileManager.default.createSymbolicLink(at: scope.appendingPathComponent("link"), withDestinationURL: outside)
        let result = StorageScanner.scanDirectory(at: scope)
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertEqual(result.logicalBytes, 1050)
        XCTAssertGreaterThanOrEqual(result.bytes, result.logicalBytes)
        XCTAssertEqual(result.root.children.first(where: { $0.name == "A" })?.logicalBytes, 1000)
        XCTAssertEqual(result.root.children.first(where: { $0.name == "small.bin" })?.isDirectory, false)
        XCTAssertEqual(result.root.children.first(where: { $0.name == "A" })?.isDirectory, true)
        XCTAssertFalse(result.root.children.contains { $0.name == "link" })
        XCTAssertFalse(result.isPartial)
    }

    func testHardLinksAreNotDoubleCounted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenDockStorageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("original.bin")
        try Data(repeating: 1, count: 500).write(to: original)
        try FileManager.default.linkItem(at: original, to: directory.appendingPathComponent("hardlink.bin"))
        let result = StorageScanner.scanDirectory(at: directory)
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertEqual(result.logicalBytes, 500)
    }

    func testInvalidScanRangeIsExplicitlyPartial() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        let result = StorageScanner.scanDirectory(at: url)
        XCTAssertEqual(result.bytes, 0)
        XCTAssertTrue(result.isPartial)
        XCTAssertFalse(result.errorMessages.isEmpty)
    }
}
