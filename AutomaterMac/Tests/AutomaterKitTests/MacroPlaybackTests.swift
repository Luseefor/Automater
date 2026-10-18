import XCTest
import CoreGraphics
@testable import AutomaterKit

final class MacroPlaybackTests: XCTestCase {
    private func play(_ steps: [MacroStep], loopCount: Int = 1, speed: Double = 1) async -> [PostedInput] {
        let finished = expectation(description: "Playback completes")
        let log = InputLog()
        let engine = MacroEngine(poster: EventPoster(eventSink: { log.append($0, pid: $1) }))
        await engine.play(macro: Macro(name: "Test", steps: steps, loopCount: loopCount, speed: speed, activateBeforePlay: false)) {
            if $0 == "Playback finished" { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 3)
        await engine.stop()
        return log.events
    }
    func testDoubleAndTripleClicksCarryClickState() async {
        for (kind, expected) in [("double", [1, 1, 2, 2]), ("triple", [1, 1, 2, 2, 3, 3])] {
            let events = await play([MacroStep(type: "click", x: 10, y: 20, clickKind: kind)])
            XCTAssertEqual(events.filter { [.leftMouseDown, .leftMouseUp].contains($0.type) }.map(\.clickState), expected)
        }
    }
    func testShortcutReleasesModifiersWithClearedFlags() async {
        let events = await play([MacroStep(type: "key", key: "ctrl+alt+shift+cmd+a")])
        XCTAssertEqual(events.map(\.key), [59, 58, 56, 55, 0, 0, 55, 56, 58, 59])
        XCTAssertEqual(events.last?.flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]), [])
        XCTAssertTrue(events[4].flags.contains([.maskControl, .maskAlternate, .maskShift, .maskCommand]))
    }
    func testRightModifierAndModifierOnlyStepsAreBalanced() async {
        let events = await play([MacroStep(type: "key", key: "right_cmd+a"), MacroStep(type: "key", key: "ctrl+alt")])
        XCTAssertEqual(events.map(\.key), [54, 0, 0, 54, 59, 58, 58, 59])
        XCTAssertEqual(events.last?.flags.intersection([.maskControl, .maskAlternate, .maskCommand]), [])
    }
    func testMalformedShortcutStopsWithoutPostingAnyInput() async {
        let rejected = expectation(description: "Invalid shortcut rejected")
        let engine = MacroEngine(poster: EventPoster(eventSink: { _, _ in XCTFail("Malformed shortcut sent input") }))
        await engine.play(macro: Macro(name: "Invalid", steps: [MacroStep(type: "key", key: "a+b")], activateBeforePlay: false)) {
            if $0.contains("Invalid macro shortcut") { rejected.fulfill() }
        }
        await fulfillment(of: [rejected], timeout: 1)
    }
    func testUnicodePayloadAndFiniteLoops() async {
        let events = await play([MacroStep(type: "type", text: "Aé🙂")], loopCount: 2)
        XCTAssertEqual(events.filter { $0.type == .keyDown }.map(\.text).joined(), "Aé🙂Aé🙂")
        XCTAssertEqual(events.filter { $0.type == .keyDown }.count, events.filter { $0.type == .keyUp }.count)
    }
    func testStopReleasesHeldKeyExactlyOnce() async throws {
        let log = InputLog()
        let engine = MacroEngine(poster: EventPoster(eventSink: { log.append($0, pid: $1) }))
        await engine.play(macro: Macro(name: "Hold", steps: [MacroStep(type: "key", key: "cmd+a", holdMs: 10_000)], activateBeforePlay: false))
        try await awaitEvent(log, type: .keyDown)
        await engine.stop()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(log.events.filter { $0.key == 0 }.count, 2)
        XCTAssertEqual(log.events.filter { $0.key == 55 }.count, 2)
        XCTAssertEqual(log.events.last?.flags.intersection(.maskCommand), [])
    }
    func testRapidRestartCannotReleaseNewRunsHeldKey() async throws {
        let log = InputLog()
        let engine = MacroEngine(poster: EventPoster(eventSink: { log.append($0, pid: $1) }))
        await engine.play(macro: Macro(name: "Old", steps: [MacroStep(type: "key", key: "a", holdMs: 10_000)], activateBeforePlay: false))
        try await awaitEvent(log, type: .keyDown)
        await engine.play(macro: Macro(name: "New", steps: [MacroStep(type: "key_down", key: "a"), MacroStep(type: "delay", delayMs: 1_000)], activateBeforePlay: false))
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(log.events.filter { $0.type == .keyDown }.count, 2)
        XCTAssertEqual(log.events.filter { $0.type == .keyUp }.count, 1)
        await engine.stop()
        XCTAssertEqual(log.events.filter { $0.type == .keyUp }.count, 2)
    }
    func testStopReleasesMouseHoldImmediatelyAndOnlyOnce() async throws {
        let log = InputLog()
        let engine = MacroEngine(poster: EventPoster(eventSink: { log.append($0, pid: $1) }))
        await engine.play(macro: Macro(name: "Mouse hold", steps: [MacroStep(type: "hold", x: 10, y: 20, holdMs: 10_000)], activateBeforePlay: false))
        try await awaitEvent(log, type: .leftMouseDown)
        await engine.stop()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(log.events.map(\.type), [.leftMouseDown, .leftMouseUp])
    }
    func testCancelledDragReleasesAtCurrentPositionWithoutJumpingToEnd() async throws {
        let log = InputLog()
        let engine = MacroEngine(poster: EventPoster(eventSink: { log.append($0, pid: $1) }))
        await engine.play(macro: Macro(name: "Drag", steps: [MacroStep(type: "drag", x: 10, y: 20, endX: 400, endY: 500, holdMs: 2_000)], activateBeforePlay: false))
        try await awaitEvent(log, type: .leftMouseDragged)
        await engine.stop()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(log.events.filter { $0.type == .leftMouseUp }.count, 1)
        XCTAssertNotEqual(log.events.last?.point, CGPoint(x: 400, y: 500))
    }
    func testContinuousLoopStopsWithoutFurtherEvents() async throws {
        let log = InputLog()
        let engine = MacroEngine(poster: EventPoster(eventSink: { log.append($0, pid: $1) }))
        await engine.play(macro: Macro(name: "Continuous", steps: [MacroStep(type: "key", key: "tab", delayMs: 10)], loopCount: 0, activateBeforePlay: false))
        try await awaitEvent(log, type: .keyDown)
        await engine.stop()
        let count = log.events.count
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(log.events.count, count)
    }
    private func awaitEvent(_ log: InputLog, type: CGEventType) async throws {
        for _ in 0..<100 {
            if log.events.contains(where: { $0.type == type }) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Playback did not post expected event")
    }
}
private struct PostedInput {
    let type: CGEventType
    let flags: CGEventFlags
    let key: Int64
    let clickState: Int
    let text: String
    let point: CGPoint
}
private final class InputLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PostedInput] = []
    var events: [PostedInput] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ event: CGEvent, pid: pid_t?) {
        var count = 0
        var chars = [UniChar](repeating: 0, count: 32)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &count, unicodeString: &chars)
        let value = PostedInput(type: event.type, flags: event.flags, key: event.getIntegerValueField(.keyboardEventKeycode),
                                clickState: Int(event.getIntegerValueField(.clickState)),
                                text: String(utf16CodeUnits: chars, count: min(count, chars.count)), point: event.location)
        lock.lock(); values.append(value); lock.unlock()
    }
}
