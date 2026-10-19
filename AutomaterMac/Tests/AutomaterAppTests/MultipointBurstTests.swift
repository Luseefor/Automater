import XCTest
import CoreGraphics
import AppKit
import AutomaterKit
@testable import AutomaterKit
@testable import automater_app

/// Multipoint burst (~100ms rounds) coverage. Foreground screen-coordinate
/// points through the injected postMouse seam only — no windows, no AX,
/// no real input. Timing asserts stay CI-tolerant: completion against a
/// huge interval proves no per-point pause without hard millisecond pins
/// (the ~100ms schedule itself is measured in the live app by parent).
final class MultipointBurstTests: XCTestCase {
    private func points(_ values: (Int, Int)...) -> [PointSpec] {
        values.map { PointSpec(x: $0.0, y: $0.1) }
    }

    private func burstConfig(_ pts: [PointSpec], intervalMs: Int = 60_000,
                             repeatCount: Int = 1, burst: Bool = true) -> ClickerConfig {
        ClickerConfig(intervalMs: intervalMs, repeatCount: repeatCount, mode: .multipoint,
                      multipoints: pts, multipointBurst: burst)
    }

    func testBurstOneRoundEmitsAllPointsInOrderWithoutPerPointInterval() async {
        let finished = expectation(description: "Burst round finishes")
        let log = BurstLog()
        let engine = ClickerEngine(postMouse: { point, _, _ in log.append(point) })
        let expected = [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40), CGPoint(x: 50, y: 60)]
        await engine.start(config: burstConfig(points((10, 20), (30, 40), (50, 60)))) {
            if $0 == "Clicker OFF" { finished.fulfill() }
        }
        // intervalMs is 60s: finishing at all proves no per-point interval wait.
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(log.points, expected)
        let performed = await engine.clicksPerformed
        XCTAssertEqual(performed, 3)
        XCTAssertLessThan(log.span, 5.0)
    }

    func testBurstTwoRoundsRepeatFullOrder() async {
        let finished = expectation(description: "Two rounds finish")
        let log = BurstLog()
        let engine = ClickerEngine(postMouse: { point, _, _ in log.append(point) })
        await engine.start(config: burstConfig(points((1, 2), (3, 4)), intervalMs: 20, repeatCount: 2)) {
            if $0 == "Clicker OFF" { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(log.points, [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4),
                                   CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)])
        let performed = await engine.clicksPerformed
        XCTAssertEqual(performed, 4)
    }

    func testBurstEmptyAndInvalidTargetYieldZeroActions() async {
        let validThenInvalid: [PointSpec] = [
            PointSpec(x: 10, y: 20),
            PointSpec(coordSpace: .window, localX: 5, localY: 5, windowId: Int.max),
        ]
        for (name, config, status): (String, ClickerConfig, String) in [
            ("empty", burstConfig([], repeatCount: 1), "No multi-points set"),
            ("invalid", burstConfig([PointSpec(coordSpace: .window, localX: 5, localY: 5,
                                              windowId: Int.max)], repeatCount: 1), "Target window not found"),
            ("mixed", burstConfig(validThenInvalid, repeatCount: 1), "Target window not found"),
        ] {
            let stopped = expectation(description: "Burst preflight rejects \(name)")
            let log = BurstLog()
            let engine = ClickerEngine(postMouse: { point, _, _ in
                log.append(point)
                XCTFail("Preflight must stop before any input")
            })
            await engine.start(config: config) {
                if $0.contains(status) { stopped.fulfill() }
            }
            await fulfillment(of: [stopped], timeout: 5)
            XCTAssertEqual(log.points.count, 0, "\(name): zero actions taken")
            let performed = await engine.clicksPerformed
            XCTAssertEqual(performed, 0)
            let running = await engine.isRunning
            XCTAssertFalse(running)
        }
    }

    func testStopMidBurstHaltsLargeBatchWithExactCounterThenRestartsCleanly() async throws {
        let firstPosted = expectation(description: "First burst point posted")
        let holder = EngineHolder()
        let log = BurstLog()
        let engine = ClickerEngine(postMouse: { [holder] point, _, _ in
            log.append(point)
            if log.count == 1 {
                firstPosted.fulfill()
                Task { await holder.stopAttached() }
            }
        })
        await holder.attach(engine)
        let total = 1000
        let specs = (0..<total).map { PointSpec(x: $0, y: $0) }
        await engine.start(config: burstConfig(specs, intervalMs: 10, repeatCount: 0)) { _ in }
        await fulfillment(of: [firstPosted], timeout: 5)
        // The queued stop lands via the per-point Task.yield; assert the
        // batch halted early, then fully settled with an exact counter.
        try await Task.sleep(nanoseconds: 300_000_000)
        let stoppedCount = log.count
        XCTAssertLessThan(stoppedCount, total)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.count, stoppedCount)
        let performed = await engine.clicksPerformed
        XCTAssertEqual(performed, stoppedCount)
        let running = await engine.isRunning
        XCTAssertFalse(running)

        let finished = expectation(description: "Restarted run finishes")
        await engine.start(config: burstConfig(points((9, 9)), intervalMs: 10, repeatCount: 1)) {
            if $0 == "Clicker OFF" { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(log.count, stoppedCount + 1)
        XCTAssertEqual(log.points.last, CGPoint(x: 9, y: 9))
        let restarted = await engine.clicksPerformed
        XCTAssertEqual(restarted, 1)
    }

    func testNormalSequentialModeUnchanged() async {
        XCTAssertFalse(ClickerConfig().multipointBurst)
        let finished = expectation(description: "Sequential run finishes")
        let log = BurstLog()
        let engine = ClickerEngine(postMouse: { point, _, _ in log.append(point) })
        await engine.start(config: burstConfig(points((1, 2), (3, 4), (5, 6)),
                                               intervalMs: 5, repeatCount: 4, burst: false)) {
            if $0 == "Clicker OFF" { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 5)
        // Sequential repeat counts actions, not rounds.
        XCTAssertEqual(log.points, [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4),
                                   CGPoint(x: 5, y: 6), CGPoint(x: 1, y: 2)])
        let performed = await engine.clicksPerformed
        XCTAssertEqual(performed, 4)
    }

    @MainActor func testBuildConfigCarriesBurstSettingAndReplacedPoints() {        _ = NSApplication.shared
        let state = AppState()
        state.multipointBurst = false // hermetic: never inherit ambient settings
        state.multipoints = [PointSpec(x: 1, y: 2)]
        var config = state.buildConfig()
        XCTAssertFalse(config.multipointBurst)
        XCTAssertEqual(config.multipoints, [PointSpec(x: 1, y: 2)])
        state.multipointBurst = true
        state.multipoints = [PointSpec(x: 3, y: 4), PointSpec(x: 5, y: 6)]
        config = state.buildConfig()
        XCTAssertTrue(config.multipointBurst)
        XCTAssertEqual(config.multipoints, [PointSpec(x: 3, y: 4), PointSpec(x: 5, y: 6)])
    }

    @MainActor func testStopAllResetsArmedRepickWithoutStartingPicker() {
        _ = NSApplication.shared
        let state = AppState()
        state.multipoints = [PointSpec(x: 1, y: 2), PointSpec(x: 3, y: 4)]
        XCTAssertFalse(state.isPicking)
        // Arm the one-shot directly: repickPoint(at:) would start the picker.
        state.repickIndex = 1
        state.stopAll()
        XCTAssertNil(state.repickIndex)
        XCTAssertEqual(state.multipoints, [PointSpec(x: 1, y: 2), PointSpec(x: 3, y: 4)])
        XCTAssertFalse(state.isPicking)
    }

    @MainActor func testRepickCanArmAfterSeveralPointsHaveBeenPicked() async {
        let picker = PointPicker()
        var captured = 0
        picker.onPoint = { _ in captured += 1 }
        func event(_ type: CGEventType) -> CGEvent {
            CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: CGPoint(x: 1_000_000, y: 1_000_000), mouseButton: .left)!
        }
        for _ in 0..<3 {
            _ = picker.handle(type: .leftMouseDown, event: event(.leftMouseDown))
            _ = picker.handle(type: .leftMouseUp, event: event(.leftMouseUp))
        }
        picker.singleShot = true
        XCTAssertEqual(picker.count, 0)
        let finished = expectation(description: "Replacement click completes")
        picker.onFinish = { _ in finished.fulfill() }
        _ = picker.handle(type: .leftMouseDown, event: event(.leftMouseDown))
        XCTAssertEqual(captured, 4)
        _ = picker.handle(type: .leftMouseUp, event: event(.leftMouseUp))
        await fulfillment(of: [finished], timeout: 2)
    }

    func testBurstEventsCarryNativeWindowAndLocalCoordinates() {
        let log = BurstEventLog()
        let poster = EventPoster(eventSink: { log.append($0, pid: $1) })
        poster.burstBackgroundClick(x: 120, y: 230, pid: 4242, windowNumber: 7,
                                    windowBounds: CGRect(x: 100, y: 200, width: 400, height: 300))
        XCTAssertEqual(log.nativeWindows, [7, 7])
        XCTAssertEqual(log.cgPoints, [CGPoint(x: 120, y: 230), CGPoint(x: 120, y: 230)])
        XCTAssertEqual(log.types, [.leftMouseDown, .leftMouseUp])
    }

    func testBurstClickPostsBalancedDownUpWithClickState() {
        for (kind, expected): (ClickKind, [Int]) in [
            (.single, [1, 1]), (.double, [1, 1, 2, 2]), (.triple, [1, 1, 2, 2, 3, 3]),
        ] {
            let log = BurstEventLog()
            let poster = EventPoster(eventSink: { log.append($0, pid: $1) })
            poster.burstBackgroundClick(x: 10, y: 20, pid: 4242, windowNumber: 7,
                                        button: .left, kind: kind)
            let downs = log.types.filter { $0 == .leftMouseDown }.count
            let ups = log.types.filter { $0 == .leftMouseUp }.count
            XCTAssertEqual(downs, kind.presses, "\(kind)")
            XCTAssertEqual(ups, kind.presses, "\(kind)")
            XCTAssertEqual(log.clickStates, expected, "\(kind)")
            XCTAssertTrue(log.pids.allSatisfy { $0 == 4242 })
        }
    }
}

private final class BurstLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(point: CGPoint, at: Date)] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var points: [CGPoint] { lock.lock(); defer { lock.unlock() }; return values.map(\.point) }
    var span: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let first = values.first?.at, let last = values.last?.at else { return 0 }
        return last.timeIntervalSince(first)
    }
    func append(_ point: CGPoint) {
        lock.lock(); defer { lock.unlock() }
        values.append((point, Date()))
    }
}

private actor EngineHolder {
    private var engine: ClickerEngine?
    func attach(_ engine: ClickerEngine) { self.engine = engine }
    func stopAttached() async { await engine?.stop() }
}

private final class BurstEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(type: CGEventType, clickState: Int, pid: pid_t?)] = []
    private var nativeValues: [(window: Int, point: CGPoint)] = []
    private var cgValues: [CGPoint] = []
    var cgPoints: [CGPoint] { lock.lock(); defer { lock.unlock() }; return cgValues }
    var nativeWindows: [Int] { lock.lock(); defer { lock.unlock() }; return nativeValues.map(\.window) }
    var nativePoints: [CGPoint] { lock.lock(); defer { lock.unlock() }; return nativeValues.map(\.point) }
    var types: [CGEventType] { lock.lock(); defer { lock.unlock() }; return values.map(\.type) }
    var clickStates: [Int] { lock.lock(); defer { lock.unlock() }; return values.map(\.clickState) }
    var pids: [pid_t?] { lock.lock(); defer { lock.unlock() }; return values.map(\.pid) }
    func append(_ event: CGEvent, pid: pid_t?) {
        lock.lock(); defer { lock.unlock() }
        values.append((event.type, Int(event.getIntegerValueField(.clickState)), pid))
        cgValues.append(event.location)
        if let native = NSEvent(cgEvent: event) { nativeValues.append((native.windowNumber, native.locationInWindow)) }
    }
}
