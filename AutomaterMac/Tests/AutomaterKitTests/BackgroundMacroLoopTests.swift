import XCTest
import CoreGraphics
@testable import AutomaterKit

/// Deterministic background-macro binding coverage.
///
/// All window lookups go through the injected `windows:` closure — no live
/// WindowScanner calls — and all input goes through `performStep:` except
/// the single live-bounds test, which uses an EventPoster eventSink (no real
/// input). Covers: exact ID+app ownership, ambiguity rejection, preflight
/// before first input, ID pinning across loops/title/order/movement changes,
/// closed-target mid-loop with no sibling redirect, and keyboard rejection
/// before any click.
final class BackgroundMacroLoopTests: XCTestCase {
    // MARK: - Exact ID + app ownership

    func testResolveWindowRequiresExactIDAndMatchingApp() {
        let windows = [
            bgWindow(id: 11, pid: 1111, title: "Alpha"),
            bgWindow(id: 12, pid: 2222, owner: "Other", bundle: "other.app", title: "Beta"),
        ]
        let macro = Macro(name: "M")
        // Exact ID + matching bundle resolves.
        XCTAssertEqual(MacroEngine.resolveWindow(
            MacroStep(type: "click", appBundleId: "test.fixture", windowId: 11),
            macro, windows: windows)?.windowId, 11)
        // The same ID owned by another app must not resolve.
        XCTAssertNil(MacroEngine.resolveWindow(
            MacroStep(type: "click", appBundleId: "other.app", windowId: 11),
            macro, windows: windows))
        // App-name matching works when the bundle is absent.
        XCTAssertEqual(MacroEngine.resolveWindow(
            MacroStep(type: "click", appName: "Other", windowId: 12),
            macro, windows: windows)?.windowId, 12)
        XCTAssertNil(MacroEngine.resolveWindow(
            MacroStep(type: "click", appName: "Fixture", windowId: 12),
            macro, windows: windows))
        // Unknown ID (closed window) never resolves.
        XCTAssertNil(MacroEngine.resolveWindow(
            MacroStep(type: "click", appBundleId: "test.fixture", windowId: 999),
            macro, windows: windows))
        // Off-screen ID (e.g. target on another Space) still resolves to
        // the pinned id+app — minimized is rejected separately at run time
        // via the AX minimized attribute, which needs a live app.
        XCTAssertEqual(MacroEngine.resolveWindow(
            MacroStep(type: "click", appBundleId: "test.fixture", windowId: 11),
            macro, windows: [bgWindow(id: 11, title: "Alpha", onScreen: false)])?.windowId, 11)
    }

    // MARK: - Ambiguity rejection

    func testResolveWindowRejectsAmbiguity() {
        let windows = [
            bgWindow(id: 11, title: "Alpha"),
            bgWindow(id: 12, title: "Beta"),
        ]
        let macro = Macro(name: "M")
        // App-only with two same-app windows is ambiguous.
        XCTAssertNil(MacroEngine.resolveWindow(
            MacroStep(type: "click", appBundleId: "test.fixture"),
            macro, windows: windows))
        // Unique app+title resolves.
        XCTAssertEqual(MacroEngine.resolveWindow(
            MacroStep(type: "click", appBundleId: "test.fixture", windowTitle: "Alpha"),
            macro, windows: windows)?.windowId, 11)
        // Missing title never falls back to a sibling.
        XCTAssertNil(MacroEngine.resolveWindow(
            MacroStep(type: "click", appBundleId: "test.fixture", windowTitle: "Gamma"),
            macro, windows: windows))
        // No identity at all never picks the largest window.
        XCTAssertNil(MacroEngine.resolveWindow(
            MacroStep(type: "click", x: 10, y: 20), macro, windows: windows))
    }

    // MARK: - Preflight before first input

    func testPreflightRejectsMissingSecondTargetBeforeFirstInput() async {
        let delivered = StepLog()
        let done = expectation(description: "Preflight rejects run")
        let log = StatusLog()
        let engine = MacroEngine(
            performStep: { step in await delivered.append(step) },
            windows: { [bgWindow(id: 11, title: "Alpha")] })
        let macro = Macro(name: "Two entries", steps: [bgWindowStep(title: "Alpha"), bgWindowStep(title: "Beta")],
                          activateBeforePlay: false)
        await engine.play(macro: macro, backgroundToApp: true) {
            log.append($0)
            if $0.contains("not found or ambiguous") { done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 2)
        let deliveredIds = await delivered.windowIds
        let playing = await engine.isPlaying
        XCTAssertEqual(deliveredIds, [])
        XCTAssertFalse(playing)
    }

    // MARK: - Keyboard rejected before any click

    func testBackgroundKeyboardAndSwipeRejectedBeforeAnyClick() async {
        let okClick = MacroStep(type: "click", x: 100, y: 100)
        let cases: [[MacroStep]] = [
            [okClick, MacroStep(type: "key", key: "cmd+a")],
            [okClick, MacroStep(type: "swipe", dx: -1)],
            [okClick, MacroStep(type: "key_down", key: "a"), MacroStep(type: "key_up", key: "a")],
        ]
        for steps in cases {
            let rejected = expectation(description: "Keyboard needs foreground: \(steps[1].type)")
            let delivered = StepLog()
            let log = StatusLog()
            let engine = MacroEngine(
                performStep: { step in await delivered.append(step) },
                windows: { [bgWindow(id: 11)] })
            await engine.play(
                macro: Macro(name: "Keys", steps: steps, activateBeforePlay: false),
                backgroundToApp: true) {
                log.append($0)
                if $0.contains("need Foreground") { rejected.fulfill() }
            }
            await fulfillment(of: [rejected], timeout: 2)
            let deliveredCount = await delivered.count
            let playing = await engine.isPlaying
            XCTAssertEqual(deliveredCount, 0, "No click may precede keyboard rejection")
            XCTAssertFalse(playing)
        }
    }

    // MARK: - Pin IDs across loops / title / order / movement

    func testPinnedIDsSurviveRetitleReorderAndMovementAcrossLoops() async {
        let box = WindowBox(windows: [
            bgWindow(id: 11, title: "Alpha", origin: CGPoint(x: 100, y: 200)),
            bgWindow(id: 12, title: "Beta", origin: CGPoint(x: 700, y: 100)),
        ])
        let finished = expectation(description: "Loops finish on pinned IDs")
        let delivered = StepLog()
        let log = StatusLog()
        let engine = MacroEngine(
            performStep: { [box] step in
                await delivered.append(step)
                // After the first full loop, scramble everything the resolver
                // could use to pick a different window: order, titles, bounds.
                if await delivered.count == 2 {
                    box.set([
                        bgWindow(id: 12, title: "Beta renamed", origin: CGPoint(x: 10, y: 10)),
                        bgWindow(id: 11, title: "Alpha renamed", origin: CGPoint(x: 900, y: 800)),
                    ])
                }
            },
            windows: { box.current })
        let macro = Macro(name: "Pinned", steps: [bgWindowStep(title: "Alpha"), bgWindowStep(title: "Beta")],
                          loopCount: 2, activateBeforePlay: false)
        await engine.play(macro: macro, backgroundToApp: true) {
            log.append($0)
            if $0 == "Playback finished" { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 5)
        let deliveredIds = await delivered.windowIds
        let deliveredBundles = await delivered.bundles
        XCTAssertEqual(deliveredIds, [11, 12, 11, 12])
        XCTAssertTrue(deliveredBundles.allSatisfy { $0 == "test.fixture" })
    }

    // MARK: - Closed target mid-loop: no sibling redirect
    func testClosedTargetMidLoopStopsWithoutSiblingRedirect() async {
        let box = WindowBox(windows: [
            bgWindow(id: 11, title: "Alpha"),
            bgWindow(id: 13, title: "Sibling"),
        ])
        let stopped = expectation(description: "Closed target stops run")
        let delivered = StepLog()
        let log = StatusLog()
        let engine = MacroEngine(
            performStep: { [box] step in
                await delivered.append(step)
                // Close the recorded window mid-loop; the same-app sibling
                // must never receive its input.
                box.set([bgWindow(id: 13, title: "Sibling")])
            },
            windows: { box.current })
        let macro = Macro(name: "Closes", steps: [bgWindowStep(title: "Alpha")],
                          loopCount: 3, activateBeforePlay: false)
        await engine.play(macro: macro, backgroundToApp: true) {
            log.append($0)
            if $0.contains("not found") { stopped.fulfill() }
        }
        await fulfillment(of: [stopped], timeout: 5)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let deliveredIds = await delivered.windowIds
        let playing = await engine.isPlaying
        XCTAssertEqual(deliveredIds, [11])
        XCTAssertFalse(playing)
    }

    /// Relaunched process reusing the pinned window id: same id, same
    /// bundle/name, different pid. The run must stop before any next
    /// delivery rather than rebind input to the stranger process.
    func testReusedWindowIDWithDifferentPIDStopsBeforeAnyNextDelivery() async {
        let box = WindowBox(windows: [
            bgWindow(id: 11, pid: 1111, title: "Target"),
        ])
        let stopped = expectation(description: "PID replacement stops run")
        let delivered = StepLog()
        let log = StatusLog()
        let engine = MacroEngine(
            performStep: { [box] step in
                await delivered.append(step)
                // Simulate an app relaunch: the window server reuses id 11
                // for a new process. Identity (bundle/name/title) matches,
                // but the pid pin from preflight no longer does.
                box.set([bgWindow(id: 11, pid: 9999, title: "Target")])
            },
            windows: { box.current })
        let macro = Macro(name: "Relaunched", steps: [bgWindowStep(title: "Target")],
                          loopCount: 3, activateBeforePlay: false)
        await engine.play(macro: macro, backgroundToApp: true) {
            log.append($0)
            if $0.contains("not found") { stopped.fulfill() }
        }
        await fulfillment(of: [stopped], timeout: 5)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let deliveredIds = await delivered.windowIds
        let playing = await engine.isPlaying
        XCTAssertEqual(deliveredIds, [11])
        XCTAssertEqual(deliveredIds.count, 1, "No input may reach the replacement process")
        XCTAssertFalse(playing)
    }

    // MARK: - Window-local points follow live bounds

    func testWindowLocalClickFollowsLiveBoundsAcrossIterations() async {
        let box = WindowBox(windows: [
            bgWindow(id: 21, pid: 4242, title: "Target",
                   origin: CGPoint(x: 100, y: 200), size: CGSize(width: 400, height: 300)),
        ])
        let posted = PostedLog()
        let poster = EventPoster(eventSink: { [box] event, pid in
            posted.append(event, pid: pid)
            // Move the window after the first click's event series lands, so
            // the second loop iteration must resolve fresh coordinates.
            if posted.mouseDownCount == 1 && posted.count >= 4 {
                box.set([bgWindow(id: 21, pid: 4242, title: "Target",
                                      origin: CGPoint(x: 500, y: 600),
                                      size: CGSize(width: 400, height: 300))])
            }
        })
        let finished = expectation(description: "Both iterations post")
        let log = StatusLog()
        let engine = MacroEngine(poster: poster, windows: { box.current })
        let macro = Macro(name: "Moves",
                          steps: [MacroStep(type: "click", coordSpace: "window",
                                            appBundleId: "test.fixture", windowTitle: "Target",
                                            localX: 10, localY: 20)],
                          loopCount: 2, activateBeforePlay: false)
        await engine.play(macro: macro, backgroundToApp: true) {
            log.append($0)
            if $0 == "Playback finished" { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 20)
        let downs = posted.points(of: .leftMouseDown)
        XCTAssertEqual(downs.count, 2)
        XCTAssertEqual(downs[0].x, 110, accuracy: 0.001)
        XCTAssertEqual(downs[0].y, 220, accuracy: 0.001)
        XCTAssertEqual(downs[1].x, 510, accuracy: 0.001)
        XCTAssertEqual(downs[1].y, 620, accuracy: 0.001)
        XCTAssertTrue(posted.pids.allSatisfy { $0 == 4242 })
    }
}

private func bgWindow(
    id: Int, pid: Int32 = 1111, owner: String = "Fixture",
    bundle: String? = "test.fixture", title: String = "Target",
    origin: CGPoint = CGPoint(x: 100, y: 200),
    size: CGSize = CGSize(width: 400, height: 300),
    onScreen: Bool = true
) -> WindowInfo {
    WindowInfo(windowId: id, pid: pid_t(pid), ownerName: owner, bundleId: bundle,
               title: title, bounds: CGRect(origin: origin, size: size), layer: 0,
               isOnScreen: onScreen)
}

private func bgWindowStep(title: String, localX: Double = 10, localY: Double = 20) -> MacroStep {
    MacroStep(type: "click", coordSpace: "window", appBundleId: "test.fixture",
              windowTitle: title, localX: localX, localY: localY)
}

// MARK: - Helpers (test-only)

private final class WindowBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [WindowInfo]
    init(windows: [WindowInfo]) { value = windows }
    var current: [WindowInfo] { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ windows: [WindowInfo]) { lock.lock(); defer { lock.unlock() }; value = windows }
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ s: String) { lock.lock(); defer { lock.unlock() }; values.append(s) }
}

private actor StepLog {
    private var steps: [MacroStep] = []
    var count: Int { steps.count }
    var windowIds: [Int?] { steps.map(\.windowId) }
    var bundles: [String?] { steps.map(\.appBundleId) }
    func append(_ step: MacroStep) { steps.append(step) }
}

private final class PostedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [(type: CGEventType, point: CGPoint)] = []
    private var pidValues: [pid_t?] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return points.count }
    var mouseDownCount: Int {
        lock.lock(); defer { lock.unlock() }
        return points.filter { $0.type == .leftMouseDown }.count
    }
    var pids: [pid_t?] { lock.lock(); defer { lock.unlock() }; return pidValues }
    func append(_ event: CGEvent, pid: pid_t?) {
        lock.lock(); defer { lock.unlock() }
        points.append((event.type, event.location))
        pidValues.append(pid)
    }
    func points(of type: CGEventType) -> [CGPoint] {
        lock.lock(); defer { lock.unlock() }
        return points.filter { $0.type == type }.map(\.point)
    }
}
