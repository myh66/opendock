import XCTest
@testable import OpenDock

final class DockDragPayloadTests:XCTestCase {
    func testDropResolvesCurrentGroupConfigurationAndSavedSelectionOrder() throws {
        let first = DockItem(kind:.app,title:"First",target:"/Applications/First.app")
        let group = DockItem(kind:.appGroup,title:"Current group",configuration:["apps":"old group configuration"])
        let last = DockItem(kind:.widget,title:"Clock",widget:.clock)
        var profile = DockProfile(name:"Fixture",items:[first,group,last])
        let payload = DockDragPayload(sourceProfileID:profile.id,orderedItemIDs:[last.id,group.id])
        let decoded = try JSONDecoder().decode(DockDragPayload.self,from:JSONEncoder().encode(payload))
        let currentApps = try JSONEncoder().encode([first])
        profile.items[1].configuration["apps"] = String(decoding:currentApps,as:UTF8.self)
        let resolved = try XCTUnwrap(decoded.resolvedItems(in:[profile]))
        XCTAssertEqual(resolved.map(\.id),[group.id,last.id])
        XCTAssertEqual(resolved.first?.configuration["apps"],String(decoding:currentApps,as:UTF8.self))
    }

    func testDeletedOrForeignIdentitiesCannotBecomeDrops() {
        let item = DockItem(kind:.app,target:"/Applications/Fixture.app")
        let profile = DockProfile(name:"Fixture",items:[item])
        XCTAssertNil(DockDragPayload(sourceProfileID:UUID(),orderedItemIDs:[item.id]).resolvedItems(in:[profile]))
        XCTAssertNil(DockDragPayload(sourceProfileID:profile.id,orderedItemIDs:[UUID()]).resolvedItems(in:[profile]))
        XCTAssertNil(DockDragPayload(sourceProfileID:profile.id,orderedItemIDs:[item.id,item.id]).resolvedItems(in:[profile]))
        XCTAssertNil(DockDragPayload(sourceProfileID:profile.id,orderedItemIDs:[]).resolvedItems(in:[profile]))
        var deleted = profile; deleted.items = []
        XCTAssertNil(DockDragPayload(sourceProfileID:profile.id,orderedItemIDs:[item.id]).resolvedItems(in:[deleted]))
    }

    func testRunningAppDropCannotSmuggleOtherKindsOrRelativePaths() {
        let profile = DockProfile(name:"Fixture")
        for item in [DockItem(kind:.widget,widget:.clock),DockItem(kind:.app,target:"Fixture.app"),DockItem(kind:.app,target:"/tmp/document.txt")] {
            XCTAssertNil(DockDragPayload(sourceProfileID:profile.id,orderedItemIDs:[item.id],runningItem:item).resolvedItems(in:[profile]))
        }
        let app = DockItem(kind:.app,target:"/Applications/Fixture.app")
        XCTAssertEqual(DockDragPayload(sourceProfileID:profile.id,orderedItemIDs:[app.id],runningItem:app).resolvedItems(in:[profile]),[app])
        XCTAssertNil(DockDragPayload(sourceProfileID:profile.id,orderedItemIDs:[UUID()],runningItem:app).resolvedItems(in:[profile]))
    }

    func testRunningAppPayloadCannotWriteThroughANativeProfile() {
        let native = DockProfile(name:"Native fixture",kind:.native)
        let app = DockItem(kind:.app,target:"/Applications/Fixture.app")
        XCTAssertNil(DockDragPayload(sourceProfileID:native.id,orderedItemIDs:[app.id],runningItem:app).resolvedItems(in:[native]))
    }
}
