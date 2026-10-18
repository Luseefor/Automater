import XCTest
import CoreGraphics
@testable import AutomaterKit

final class BackgroundClickTests: XCTestCase {
    func testMissingTargetNeverFallsBackToForegroundMouse() async {
        let stopped = expectation(description: "Missing target stops run")
        let engine = ClickerEngine(postMouse: { _, _, _ in XCTFail("No click may be sent") })
        await engine.start(config: ClickerConfig(repeatCount: 1, mode: .fixedPoint,
                                                fixedScreenX: 100, fixedScreenY: 100, backgroundToApp: true)) {
            if $0.contains("Background target not found") { stopped.fulfill() }
        }
        await fulfillment(of: [stopped], timeout: 2)
        let count = await engine.clicksPerformed
        XCTAssertEqual(count, 0)
    }

    func testClosedWindowDoesNotRedirectToAnotherWindowOfSameApp() async {
        let stopped = expectation(description: "Closed window stops run")
        let engine = ClickerEngine(postMouse: { _, _, _ in XCTFail("Closed window cannot receive clicks") })
        var config = ClickerConfig(repeatCount: 1, mode: .fixedPoint, backgroundToApp: true)
        config.targetPid = Int(getpid())
        config.targetWindowId = Int.max
        await engine.start(config: config) {
            if $0.contains("Background target not found") { stopped.fulfill() }
        }
        await fulfillment(of: [stopped], timeout: 2)
        let count = await engine.clicksPerformed
        XCTAssertEqual(count, 0)
    }

    func testWindowRelativePointDoesNotResolveAgainstArbitraryWindowAfterClosure() {
        let config = ClickerConfig(fixedCoordSpace: .window, fixedLocalX: 20, fixedLocalY: 30,
                                   fixedWindowId: Int.max, appName: "Automater")
        XCTAssertNil(ClickerEngine.resolveFixedPoint(config: config))
        let point = PointSpec(coordSpace: .window, localX: 20, localY: 30,
                              appName: "Automater", windowId: Int.max)
        XCTAssertNil(ClickerEngine.resolvePointSpec(point))
    }

    func testBackgroundCurrentCursorFreezesPointWhileMouseIsFreeToMove() async {
        let posted = expectation(description: "Three clicks at the captured point")
        posted.expectedFulfillmentCount = 3
        posted.assertForOverFulfill = true
        let stopped = expectation(description: "Run completed")
        let cursor = MovingCursor()
        let engine = ClickerEngine(postMouse: { point, target, config in
            XCTAssertEqual(point, CGPoint(x: 10, y: 20))
            XCTAssertEqual(target.pid, getpid())
            XCTAssertTrue(config.backgroundToApp)
            posted.fulfill()
        }, cursorLocation: { cursor.next() })
        var config = ClickerConfig(intervalMs: 10, repeatCount: 3, backgroundToApp: true)
        config.targetPid = Int(getpid())
        await engine.start(config: config) { if $0 == "Clicker OFF" { stopped.fulfill() } }
        await fulfillment(of: [posted, stopped], timeout: 2)
        XCTAssertEqual(cursor.reads, 1)
    }

    func testWindowLocalPointFollowsWindowMovement() {
        let first = WindowInfo(windowId: 42, pid: getpid(), ownerName: "Fixture", bundleId: nil,
                               title: "Target", bounds: CGRect(x: 100, y: 200, width: 400, height: 300), layer: 0)
        let moved = WindowInfo(windowId: 42, pid: getpid(), ownerName: "Fixture", bundleId: nil,
                               title: "Target", bounds: CGRect(x: 500, y: 600, width: 400, height: 300), layer: 0)
        XCTAssertEqual(ClickerEngine.localToScreen(localX: 20, localY: 30, in: first), CGPoint(x: 120, y: 230))
        XCTAssertEqual(ClickerEngine.localToScreen(localX: 20, localY: 30, in: moved), CGPoint(x: 520, y: 630))
    }

    func testUnselectedResolverNeverChoosesLargestWindow() {
        XCTAssertEqual(ClickerEngine.resolveBackgroundTarget(pid: nil, bundleId: nil, appName: nil,
                                                            title: nil, windowId: nil), .none)
    }
}

private final class MovingCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    func next() -> CGPoint {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return CGPoint(x: 10 * count, y: 20 * count)
    }
}

extension BackgroundClickTests {
    func testMultiplePointsRunInOrderWithFiniteCount() async {
        let expected = [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)]
        let log = PointLog()
        let finished = expectation(description: "Four points delivered")
        let engine = ClickerEngine(postMouse: { point, _, _ in log.append(point) })
        await engine.start(config: ClickerConfig(intervalMs: 5, repeatCount: 4, mode: .multipoint,
                                                multipoints: [PointSpec(x: 10, y: 20), PointSpec(x: 30, y: 40)])) {
            if $0 == "Clicker OFF" { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(log.entries, expected)
    }
    func testFiniteRunFinishesImmediatelyAfterLastClickAtLongInterval() async {
        let finished = expectation(description: "Last click completes without another interval")
        let engine = ClickerEngine(postMouse: { _, _, _ in })
        await engine.start(config: ClickerConfig(intervalMs: 60_000, repeatCount: 1, mode: .fixedPoint)) {
            if $0 == "Clicker OFF" { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 1)
        let running = await engine.isRunning
        XCTAssertFalse(running)
        await engine.stop()
    }
    func testFixedPointIgnoresLiveCursor() async {
        let finished = expectation(description: "Fixed run finishes")
        let engine = ClickerEngine(postMouse: { point, _, _ in XCTAssertEqual(point, CGPoint(x: 100, y: 200)) },
                                   cursorLocation: { XCTFail("Fixed mode must not read cursor"); return .zero })
        await engine.start(config: ClickerConfig(intervalMs: 5, repeatCount: 2, mode: .fixedPoint,
                                                fixedScreenX: 100, fixedScreenY: 200)) {
            if $0 == "Clicker OFF" { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 2)
    }
}
private final class PointLog: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [CGPoint] = []
    var entries: [CGPoint] { lock.lock(); defer { lock.unlock() }; return points }
    func append(_ point: CGPoint) { lock.lock(); defer { lock.unlock() }; points.append(point) }
}
