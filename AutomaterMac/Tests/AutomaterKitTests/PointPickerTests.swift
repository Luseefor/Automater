import XCTest
import CoreGraphics
@testable import AutomaterKit

final class PointPickerTests: XCTestCase {
    private func event(_ type: CGEventType) -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: CGPoint(x: 1_000_000, y: 1_000_000), mouseButton: .left)!
    }

    @MainActor
    func testSinglePointSwallowsPressAndReleaseBeforeFinishing() async {
        let picker = PointPicker()
        picker.singleShot = true
        var points = 0
        var finished = false
        let done = expectation(description: "Finished after returning swallowed release")
        picker.onPoint = { _ in points += 1 }
        picker.onFinish = { success in finished = success; done.fulfill() }
        XCTAssertNil(picker.handle(type: .leftMouseDown, event: event(.leftMouseDown)))
        XCTAssertEqual(points, 1)
        XCTAssertFalse(finished)
        XCTAssertNil(picker.handle(type: .leftMouseUp, event: event(.leftMouseUp)))
        XCTAssertFalse(finished)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertTrue(finished)
    }

    func testMultipointSwallowsBothHalvesOfEachPickedClick() {
        let picker = PointPicker()
        for (down, up) in [(CGEventType.leftMouseDown, CGEventType.leftMouseUp), (.rightMouseDown, .rightMouseUp)] {
            XCTAssertNil(picker.handle(type: down, event: event(down)))
            XCTAssertNil(picker.handle(type: up, event: event(up)))
        }
        XCTAssertEqual(picker.count, 2)
    }

    func testReleaseWithoutCapturedPressPassesThrough() {
        let picker = PointPicker()
        let release = event(.leftMouseUp)
        XCTAssertFalse(picker.handle(type: .leftMouseUp, event: release) == nil)
        withExtendedLifetime(release) {}
        XCTAssertEqual(picker.count, 0)
    }
}
