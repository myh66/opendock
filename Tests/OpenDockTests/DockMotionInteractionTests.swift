import XCTest
@testable import OpenDock

final class DockMotionInteractionTests: XCTestCase {
    func testOnePhysicalGestureCyclesOnlyOnceAndNextGestureHasNoCooldown() {
        var gesture = DockLayoutScrollGesture()
        XCTAssertNil(gesture.direction(delta:10,threshold:36,momentum:false,unphased:false,timestamp:1))
        XCTAssertEqual(gesture.direction(delta:26,threshold:36,momentum:false,unphased:false,timestamp:1.01), -1)
        XCTAssertNil(gesture.direction(delta:100,threshold:36,momentum:false,unphased:false,timestamp:1.02))
        XCTAssertNil(gesture.direction(delta:-150,threshold:36,momentum:false,unphased:false,timestamp:1.03))
        gesture.reset()
        XCTAssertEqual(gesture.direction(delta:-36,threshold:36,momentum:false,unphased:false,timestamp:1.04), 1)
    }

    func testMomentumNeverAccumulatesOrSelectsAnotherLayout() {
        var gesture = DockLayoutScrollGesture()
        XCTAssertNil(gesture.direction(delta:34,threshold:36,momentum:false,unphased:false,timestamp:1))
        XCTAssertNil(gesture.direction(delta:400,threshold:36,momentum:true,unphased:false,timestamp:1.01))
        XCTAssertNil(gesture.direction(delta:1,threshold:36,momentum:false,unphased:false,timestamp:1.02))
        XCTAssertEqual(gesture.direction(delta:1,threshold:36,momentum:false,unphased:false,timestamp:1.03), -1)
        gesture.reset()
        XCTAssertNil(gesture.direction(delta:-400,threshold:36,momentum:true,unphased:false,timestamp:1.04))
    }

    func testUnphasedDeviceKeepsOneGestureUntilIdleGap() {
        var gesture = DockLayoutScrollGesture()
        XCTAssertEqual(gesture.direction(delta:40,threshold:36,momentum:false,unphased:true,timestamp:1), -1)
        XCTAssertNil(gesture.direction(delta:40,threshold:36,momentum:false,unphased:true,timestamp:1.05))
        XCTAssertNil(gesture.direction(delta:40,threshold:36,momentum:false,unphased:true,timestamp:1.1))
        XCTAssertEqual(gesture.direction(delta:-40,threshold:36,momentum:false,unphased:true,timestamp:1.31), 1)
    }

    func testDirectionCanReverseBeforeThresholdWithoutFalseSelection() {
        var gesture = DockLayoutScrollGesture()
        XCTAssertNil(gesture.direction(delta:20,threshold:36,momentum:false,unphased:false,timestamp:1))
        XCTAssertNil(gesture.direction(delta:-30,threshold:36,momentum:false,unphased:false,timestamp:1.01))
        XCTAssertEqual(gesture.direction(delta:-26,threshold:36,momentum:false,unphased:false,timestamp:1.02), 1)
        gesture.reset()
        XCTAssertNil(gesture.direction(delta:.nan,threshold:36,momentum:false,unphased:false,timestamp:1.03))
        XCTAssertNil(gesture.direction(delta:40,threshold:.infinity,momentum:false,unphased:false,timestamp:1.04))
        XCTAssertEqual(gesture.direction(delta:36,threshold:36,momentum:false,unphased:false,timestamp:1.05), -1)
    }

    func testResizeTracksOriginalGrabSizeAndCancellationDiscardsIt() {
        var resize = DockResizeGestureState()
        XCTAssertEqual(resize.size(currentSize:44,translation:CGSize(width:0,height:-30),vertical:false), 54)
        XCTAssertEqual(resize.size(currentSize:54,translation:CGSize(width:0,height:-60),vertical:false), 64)
        resize.end()
        XCTAssertNil(resize.startSize)
        XCTAssertEqual(resize.size(currentSize:32,translation:CGSize(width:0,height:-6),vertical:false), 34)
    }

    func testSideDockResizeUsesHorizontalAxisAndClampsToSupportedSizes() {
        var resize = DockResizeGestureState()
        XCTAssertEqual(resize.size(currentSize:44,translation:CGSize(width:-30,height:900),vertical:true), 54)
        XCTAssertEqual(resize.size(currentSize:54,translation:CGSize(width:300,height:0),vertical:true), 24)
        resize.end()
        XCTAssertEqual(resize.size(currentSize:70,translation:CGSize(width:-300,height:0),vertical:true), 80)
    }

    func testInvalidResizeInputNeverProducesInvalidSettings() {
        var resize = DockResizeGestureState()
        XCTAssertEqual(resize.size(currentSize:.nan,translation:CGSize(width:0,height:CGFloat.infinity),vertical:false), 44)
        XCTAssertEqual(resize.size(currentSize:44,translation:CGSize(width:0,height:-3),vertical:false), 45)
        resize.end()
        XCTAssertEqual(resize.size(currentSize:500,translation:.zero,vertical:false), 80)
    }
}
