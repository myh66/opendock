import AppKit
import XCTest
@testable import OpenDock

final class WindowServicesTests: XCTestCase {
    @MainActor func testPreviewCachePersistsPrunesAndDeletesWhenDisabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenDockPreviewTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = WindowPreviewCache(directory: directory)
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in NSColor.blue.setFill(); rect.fill(); return true }
        XCTAssertFalse(cache.store(image, for: "disabled-window"))
        cache.setEnabled(true)
        XCTAssertTrue(cache.store(image, for: "application/window-A"))
        XCTAssertTrue(cache.store(image, for: "application/window-B"))
        let reloaded = WindowPreviewCache(directory: directory)
        reloaded.setEnabled(true)
        XCTAssertNotNil(reloaded.image(for: "application/window-A"))
        reloaded.prune(keeping: ["application/window-B"])
        XCTAssertNil(reloaded.image(for: "application/window-A"))
        XCTAssertNotNil(reloaded.image(for: "application/window-B"))
        reloaded.setEnabled(false)
        XCTAssertTrue(reloaded.entries.isEmpty)
        XCTAssertNil(reloaded.image(for: "application/window-B"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testPreviewFilenameCannotEscapeCacheDirectory() {
        let filename = WindowPreviewCache.filename(for: "../../private/window:Title")
        XCTAssertTrue(WindowPreviewCache.validFilename(filename))
        XCTAssertEqual(filename.count, 68)
        XCTAssertFalse(WindowPreviewCache.validFilename("../outside.png"))
        XCTAssertNotEqual(filename, WindowPreviewCache.filename(for: "other-window"))
    }

    @MainActor func testBadgeExtractionReturnsCountsOrPresenceWithoutCopyingText() async {
        XCTAssertEqual(AppService.badgeToken(from: "12 new notifications"), "12")
        XCTAssertEqual(AppService.badgeToken(from: "99+"), "99+")
        XCTAssertEqual(AppService.badgeToken(from: "Updated"), "•")
        XCTAssertNil(AppService.badgeToken(from: "  "))
    }

    @MainActor func testThumbnailCacheKeyChangesWhenFileOrSizeChanges() async {
        let url = URL(fileURLWithPath: "/fixture/image.png")
        let key = FilePreviewService.cacheKey(url: url, size: CGSize(width: 100, height: 80), modificationDate: Date(timeIntervalSince1970: 100), fileSize: 50)
        XCTAssertNotEqual(key, FilePreviewService.cacheKey(url: url, size: CGSize(width: 200, height: 80), modificationDate: Date(timeIntervalSince1970: 100), fileSize: 50))
        XCTAssertNotEqual(key, FilePreviewService.cacheKey(url: url, size: CGSize(width: 100, height: 80), modificationDate: Date(timeIntervalSince1970: 101), fileSize: 50))
        XCTAssertNotEqual(key, FilePreviewService.cacheKey(url: url, size: CGSize(width: 100, height: 80), modificationDate: Date(timeIntervalSince1970: 100), fileSize: 51))
    }

    @MainActor func testGeneratedFolderAndCalendarIconsHaveRealImageData() async throws {
        let folder = AppService.labeledIcon(color: "5EAF97", text: "工", folder: true)
        let calendar = AppService.calendarIcon(date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(folder.size, NSSize(width: 128, height: 128))
        XCTAssertNotNil(folder.tiffRepresentation)
        XCTAssertNotNil(calendar.tiffRepresentation)
    }

    // Tests deliberately do not enable WindowMonitor or call capture/QuickLook
    // generation, so no desktop capture, disk scan, or permission prompt occurs.
}
