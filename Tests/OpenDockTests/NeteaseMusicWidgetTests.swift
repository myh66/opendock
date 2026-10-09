import XCTest
@testable import OpenDock

final class NeteaseMusicWidgetTests: XCTestCase {
    func testPublicRoutesCanonicalizeWithoutPrivateTracking() throws {
        for kind in NeteaseMusicLinkKind.allCases {
            let plain = try NeteaseMusicPublicLink("https://music.163.com/\(kind.rawValue)?id=000123")
            let hash = try NeteaseMusicPublicLink("https://music.163.com/#/\(kind.rawValue)?id=123")
            XCTAssertEqual(plain, hash); XCTAssertEqual(hash.kind, kind); XCTAssertEqual(hash.resourceID, "123")
            XCTAssertEqual(try NeteaseMusicPublicLink(plain.url.absoluteString), plain)
        }
    }
    func testRejectsCredentialsOtherHostsControlsAndAmbiguousIDs() {
        let urls = ["https://music.163.com.evil.test/playlist?id=1", "https://evil.test/#/playlist?id=1",
                    "https://user:secret@music.163.com/playlist?id=1", "http://music.163.com/playlist?id=1",
                    "orpheus://playlist/1", "https://music.163.com:8443/playlist?id=1", "https://music.163.com/api/playlist?id=1",
                    "https://music.163.com/playlist?id=0", "https://music.163.com/playlist?id=-1", "https://music.163.com/playlist?id=1&id=2",
                    "https://music.163.com/playlist?id=1&userid=123", "https://music.163.com/playlist?id=1#other",
                    "https://music.163.com/?token=secret#/playlist?id=1", "https://music.163.com/#/song?id=1%26x%3D2",
                    "https://music.163.com/#/song?id=123456789012345678901", "https://music.163.com/#/song?id=１"]
        for url in urls { XCTAssertThrowsError(try NeteaseMusicPublicLink(url), url) }
    }
    func testBookmarkDuplicateUpdatesNameAndPreservesIdentity() throws {
        let first = try NeteaseMusicBookmarks.adding(title: " Synthetic playlist ", link: "https://music.163.com/playlist?id=123", to: [])
        let second = try NeteaseMusicBookmarks.adding(title: "Renamed synthetic playlist", link: "https://music.163.com/#/playlist?id=000123", to: first)
        XCTAssertEqual(second.count, 1); XCTAssertEqual(first.first?.id, second.first?.id)
        XCTAssertEqual(second.first?.title, "Renamed synthetic playlist")
        XCTAssertEqual(NeteaseMusicBookmarks.decode(NeteaseMusicBookmarks.encode(second)), second)
    }
    func testImportedBookmarksFilterInvalidLinksIDsAndTitles() throws {
        let valid = NeteaseMusicBookmark(title: "Synthetic", link: "https://music.163.com/song?id=1")
        let entries = [valid, valid,
                       NeteaseMusicBookmark(title: "External", link: "https://evil.test/song?id=1"),
                       NeteaseMusicBookmark(title: "", link: "https://music.163.com/song?id=2"),
                       NeteaseMusicBookmark(title: "Duplicate route", link: "https://music.163.com/#/song?id=1")]
        let data = try JSONEncoder().encode(entries)
        let decoded = NeteaseMusicBookmarks.decode(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(decoded.count, 1); XCTAssertEqual(decoded.first?.id, valid.id)
        XCTAssertTrue(NeteaseMusicBookmarks.decode("invalid JSON").isEmpty)
        XCTAssertTrue(NeteaseMusicBookmarks.decode(String(repeating: "x", count: NeteaseMusicBookmarks.maximumBytes + 1)).isEmpty)
    }
    func testCapacityAndTitleLimitsPreserveExistingBookmarks() throws {
        var entries: [NeteaseMusicBookmark] = []
        for id in 1...50 { entries = try NeteaseMusicBookmarks.adding(title: "Synthetic \(id)", link: "https://music.163.com/song?id=\(id)", to: entries) }
        XCTAssertEqual(entries.count, 50)
        XCTAssertThrowsError(try NeteaseMusicBookmarks.adding(title: "Extra", link: "https://music.163.com/song?id=51", to: entries))
        XCTAssertEqual(try NeteaseMusicBookmarks.adding(title: "Rename", link: "https://music.163.com/song?id=50", to: entries).count, 50)
        XCTAssertThrowsError(try NeteaseMusicBookmarks.adding(title: String(repeating: "x", count: 121), link: "https://music.163.com/song?id=51", to: []))
        XCTAssertThrowsError(try NeteaseMusicBookmarks.adding(title: "bad\nname", link: "https://music.163.com/song?id=51", to: []))
    }
    func testCapabilitiesNeverClaimUnverifiedPlaybackControl() {
        let capabilities = NeteaseMusicCapabilities()
        XCTAssertTrue(capabilities.supportsPublicLinks)
        XCTAssertFalse(capabilities.supportsNowPlaying); XCTAssertFalse(capabilities.supportsPlaybackControl)
    }
}
