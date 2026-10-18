import XCTest
@testable import AutomaterKit

final class MacroLifecycleTests: XCTestCase {
    func testEmptyInfiniteRecordingDoesNotStartBusyLoop() async {
        let engine = MacroEngine()
        await engine.play(macro: Macro(name: "Empty", loopCount: 0, activateBeforePlay: false))
        let playing = await engine.isPlaying
        XCTAssertFalse(playing)
    }
    func testOldRecordingTeardownDoesNotStopNewRecording() async throws {
        let engine = MacroEngine()
        let long = Macro(name: "First", steps: [MacroStep(type: "delay", delayMs: 5_000)], activateBeforePlay: false)
        await engine.play(macro: long)
        let second = Macro(name: "Second", steps: [MacroStep(type: "delay", delayMs: 1_000)], activateBeforePlay: false)
        await engine.play(macro: second)
        try await Task.sleep(nanoseconds: 30_000_000)
        let playing = await engine.isPlaying
        XCTAssertTrue(playing)
        await engine.stop()
    }
    func testStopInterruptsLongWaitPromptly() async throws {
        let engine = MacroEngine()
        await engine.play(macro: Macro(name: "Wait", steps: [MacroStep(type: "delay", delayMs: 60_000)], activateBeforePlay: false))
        try await Task.sleep(nanoseconds: 10_000_000)
        let start = Date()
        await engine.stop()
        let playing = await engine.isPlaying
        XCTAssertFalse(playing)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}

extension MacroLifecycleTests {
    func testFinitePlaybackPreservesOrderAndLoopCount() async {
        let finished = expectation(description: "Playback finishes")
        let log = StepLog()
        let engine = MacroEngine(performStep: { step in await log.append(step.type) })
        await engine.play(macro: Macro(name: "Loops", steps: [MacroStep(type: "first"), MacroStep(type: "second")],
                                       loopCount: 3, activateBeforePlay: false)) {
            if $0 == "Playback finished" { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 2)
        let entries = await log.entries
        XCTAssertEqual(entries, ["first", "second", "first", "second", "first", "second"])
    }
    func testRecordedDelayHappensBeforeItsStep() async {
        let finished = expectation(description: "Delayed step runs")
        let start = Date()
        let engine = MacroEngine(performStep: { _ in
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.09)
            finished.fulfill()
        })
        await engine.play(macro: Macro(name: "Delay", steps: [MacroStep(type: "click", delayMs: 120)], activateBeforePlay: false))
        await fulfillment(of: [finished], timeout: 2)
    }
    func testStoppingDuringDelaySendsNoStep() async throws {
        let engine = MacroEngine(performStep: { _ in XCTFail("Cancelled step must not run") })
        await engine.play(macro: Macro(name: "Wait", steps: [MacroStep(type: "click", delayMs: 500)], activateBeforePlay: false))
        try await Task.sleep(nanoseconds: 20_000_000)
        await engine.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    func testBackgroundMissingTargetSendsNoStep() async {
        let stopped = expectation(description: "Missing target rejected")
        let engine = MacroEngine(performStep: { _ in XCTFail("No foreground fallback") })
        await engine.play(macro: Macro(name: "Missing", steps: [MacroStep(type: "click", x: 100, y: 100)], activateBeforePlay: false),
                          backgroundToApp: true) {
            if $0.contains("Background macro target not found") { stopped.fulfill() }
        }
        await fulfillment(of: [stopped], timeout: 2)
        let playing = await engine.isPlaying
        XCTAssertFalse(playing)
    }
    func testClosedRecordedWindowStopsForegroundPlaybackToo() async {
        let stopped = expectation(description: "Closed window rejected")
        let step = MacroStep(type: "click", coordSpace: "window", windowId: Int.max, localX: 10, localY: 20)
        let engine = MacroEngine(performStep: { _ in XCTFail("Must not click stale coordinates") })
        await engine.play(macro: Macro(name: "Closed", steps: [step], activateBeforePlay: false)) {
            if $0.contains("Recorded window not found") { stopped.fulfill() }
        }
        await fulfillment(of: [stopped], timeout: 2)
    }
    func testBackgroundKeyboardMacroIsExplicitlyRejected() async {
        let rejected = expectation(description: "Needs foreground")
        let engine = MacroEngine(performStep: { _ in XCTFail("Keyboard must not leak to active app") })
        await engine.play(macro: Macro(name: "Keys", steps: [MacroStep(type: "key", key: "cmd+a")], activateBeforePlay: false),
                          backgroundToApp: true) {
            if $0.contains("need Foreground") { rejected.fulfill() }
        }
        await fulfillment(of: [rejected], timeout: 2)
        let playing = await engine.isPlaying
        XCTAssertFalse(playing)
    }
}
private actor StepLog {
    var entries: [String] = []
    func append(_ value: String) { entries.append(value) }
}

extension MacroLifecycleTests {
    func testEditedMultiEntryMacroReplaysOnlyRemainingStepsInOrder() async {
        let finished = expectation(description: "Edited macro finishes")
        let log = StepLog()
        let engine = MacroEngine(performStep: { step in await log.append(step.type) })
        var steps = (0..<12).map { MacroStep(type: "entry-\($0)") }
        steps.remove(at: 0)
        steps.remove(at: 4)
        steps.removeLast()
        let expected = steps.map(\.type)
        await engine.play(macro: Macro(name: "Edited", steps: steps, loopCount: 2, activateBeforePlay: false)) {
            if $0 == "Playback finished" { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 2)
        let actual = await log.entries
        XCTAssertEqual(actual, expected + expected)
    }
}
