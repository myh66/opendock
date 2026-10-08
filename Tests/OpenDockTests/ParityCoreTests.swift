import XCTest
import Carbon
@testable import OpenDock

final class ParityCoreTests:XCTestCase {
    func testUpdaterVerifiesExactReleaseTag() {
        XCTAssertTrue(UpdateService.packageVersionMatches(version:"0.2.0",tag:"v0.2.0-beta.2",release:"v0.2.0-beta.2",current:"v0.2.0-beta.1"))
        XCTAssertFalse(UpdateService.packageVersionMatches(version:"0.2.0",tag:"v0.2.0-beta.1",release:"v0.2.0",current:"v0.1.0"))
        XCTAssertFalse(UpdateService.packageVersionMatches(version:"0.3.0",tag:"v0.2.0",release:"v0.2.0",current:"v0.1.0"))
    }
    func testLegacySettingsDecodeWithoutLosingValues() throws {
        let json = """
        {"position":"left","material":"clear","iconSize":62,"autoHide":true,"showRunningApps":false,"magnification":false,"showTrash":false,"showCustomDock":false,"displayIndex":2,"launchAtLogin":false,"clickToMinimize":true}
        """
        let settings = try JSONDecoder().decode(DockSettings.self,from:Data(json.utf8))
        XCTAssertEqual(settings.iconSize,62); XCTAssertEqual(settings.position,.left); XCTAssertTrue(settings.clickToMinimize)
        XCTAssertEqual(settings.mode,.both); XCTAssertFalse(settings.showMinimizedWindows); XCTAssertTrue(settings.hasCompletedTour)
        XCTAssertEqual(try JSONDecoder().decode(DockSettings.self,from:JSONEncoder().encode(settings)),settings)
    }
    func testReplacementSnapshotRejectsCorruptionBeforeWritingPreferences() throws {
        let valid: [String: Any] = ["version": 1, "values": ["autohide": true, "autohide-delay": 1.5], "missing": ["autohide-time-modifier"]]
        let decoded = try NativeDockModeService.validateSnapshot(valid)
        XCTAssertEqual(decoded.1,["autohide-time-modifier"])
        XCTAssertThrowsError(try NativeDockModeService.validateSnapshot(["version":1,"values":[:],"missing":[]]))
        XCTAssertThrowsError(try NativeDockModeService.validateSnapshot(["version":1,"values":["autohide":true],"missing":["autohide","autohide-delay","autohide-time-modifier"]]))
        XCTAssertThrowsError(try NativeDockModeService.validateSnapshot(["version":1,"values":["autohide":"true"],"missing":["autohide-delay","autohide-time-modifier"]]))
    }
    func testShortcutRequiresTwoModifiersAndAllowsClearSentinel() {
        XCTAssertFalse(GlobalHotkeyService.valid(DockShortcut(keyCode:12,modifiers:UInt32(cmdKey),label:"⌘Q")))
        XCTAssertTrue(GlobalHotkeyService.valid(DockShortcut(keyCode:12,modifiers:UInt32(cmdKey | optionKey),label:"⌥⌘Q")))
        XCTAssertTrue(GlobalHotkeyService.valid(DockShortcut(keyCode:0,modifiers:0,label:"未设置")))
        XCTAssertNil(GlobalHotkeyService.defaultShortcut(index:9))
    }
    @MainActor func testGroupMoveKeepsRelativeOrderAndDuplicateDisarmsIdentityNotifications() throws {
        let items = ["A","B","C","D","E"].map { DockItem(kind:.link,title:$0,target:"https://example.com") }
        let profile = DockProfile(name:"Group",items:items)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenDockParity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("layouts.json")
        try JSONEncoder().encode(DockArchive(profiles:[profile],activeCustomID:profile.id)).write(to:url)
        let store = AppStore(storageURL:url)
        store.moveItems([items[1].id,items[3].id],to:items[0].id,in:profile.id)
        XCTAssertEqual(store.profiles[0].items.map(\.title),["B","D","A","C","E"])
        store.moveItems([items[1].id,items[3].id],to:nil,in:profile.id)
        XCTAssertEqual(store.profiles[0].items.map(\.title),["A","C","E","B","D"])
        let alarm = DockItem(kind:.widget,widget:.alarm,configuration:["alarmEnabled":"true","waterReminder":"true","timerNotification":"true","text":"preserve"])
        let copy = AppStore.independentCopy(alarm)
        XCTAssertNotEqual(copy.id,alarm.id); XCTAssertEqual(copy.configuration["alarmEnabled"],"false"); XCTAssertEqual(copy.configuration["waterReminder"],"false"); XCTAssertEqual(copy.configuration["timerNotification"],"false"); XCTAssertEqual(copy.configuration["text"],"preserve")
    }
    func testWindowReservationConservesInsideAndAvoidsForeignDisplay() {
        let allowed = CGRect(x:0,y:0,width:1000,height:800)
        XCTAssertEqual(WindowSpaceService.constrained(CGRect(x:10,y:10,width:400,height:500),to:allowed),CGRect(x:10,y:10,width:400,height:500))
        XCTAssertEqual(WindowSpaceService.constrained(CGRect(x:900,y:0,width:300,height:900),to:allowed),CGRect(x:700,y:0,width:300,height:800))
        let foreign = CGRect(x:1600,y:0,width:400,height:800)
        XCTAssertEqual(WindowSpaceService.constrained(foreign,to:allowed),foreign)
    }
    func testUpdateVersionComparisonRejectsEqualOlderAndMalformed() {
        XCTAssertTrue(UpdateService.isNewer("v0.3.0-beta.1",than:"0.2.0"))
        XCTAssertFalse(UpdateService.isNewer("v0.2.0-beta.2",than:"0.2.0"))
        XCTAssertFalse(UpdateService.isNewer("v0.1.9",than:"0.2.0"))
        XCTAssertFalse(UpdateService.isNewer("",than:"0.2.0"))
        XCTAssertTrue(UpdateService.isNewer("v0.2.0-beta.2",than:"v0.2.0-beta.1"))
        XCTAssertTrue(UpdateService.isNewer("v0.2.0",than:"v0.2.0-beta.2"))
    }
    func testNativeMutationQueuePreservesFIFOAndContinuesAfterFailure() async throws {
        actor Log { var values:[Int] = []; func add(_ n:Int) { values.append(n) }; func read()->[Int] {values} }
        let log = Log()
        let first = Task { try await NativeDockService.performDockMutation { await log.add(1); try await Task.sleep(nanoseconds:80_000_000); await log.add(2) } }
        try await Task.sleep(nanoseconds:10_000_000)
        let second = Task { try await NativeDockService.performDockMutation { await log.add(3); throw ArchiveError.invalidSettings } }
        try await Task.sleep(nanoseconds:10_000_000)
        let third = Task { try await NativeDockService.performDockMutation { await log.add(4) } }
        try await first.value; do { try await second.value; XCTFail("Expected failure") } catch {}; try await third.value
        let values = await log.read(); XCTAssertEqual(values,[1,2,3,4])
    }
}
