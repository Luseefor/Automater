import XCTest
import CoreGraphics
@testable import AutomaterKit

final class KeyboardRepeatTests: XCTestCase {
    func testControlShortcutsMatchRegardlessOfModifierOrderOrAlias() {
        XCTAssertEqual(HotkeyManager.normalized("alt+control+a"), "ctrl+alt+a")
        XCTAssertEqual(HotkeyManager.normalized("right_alt+ctrl+control+a"), "ctrl+alt+a")
        XCTAssertEqual(KeyChord(HotkeyManager.normalized("shift+cmd+return")),
                       KeyChord(HotkeyManager.normalized("command+shift+enter")))
    }

    func testChordAcceptsKeysAndRejectsAmbiguousInput() {
        XCTAssertEqual(KeyChord("space")?.key, 49)
        XCTAssertEqual(KeyChord(" Cmd + Shift + K ")?.modifiers, [55, 56])
        XCTAssertEqual(KeyChord("cmd+command+k")?.modifiers, [55])
        for invalid in ["", "cmd", "a+b", "cmd++k", "+a", "a+", "a+cmd", "no_such_key"] {
            XCTAssertNil(KeyChord(invalid), invalid)
            XCTAssertNil(EventPoster.keyboardEvents(for: invalid), invalid)
        }
    }

    func testShortcutEventsReleaseEveryKeyAndModifier() throws {
        let events = try XCTUnwrap(EventPoster.keyboardEvents(for: "cmd+shift+k"))
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [55, 56, 40, 40, 56, 55])
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        XCTAssertTrue(events[2].flags.contains([.maskCommand, .maskShift]))
        XCTAssertEqual(events[4].flags, .maskCommand)
        XCTAssertTrue(events[5].flags.isEmpty)
    }

    func testKeyboardRepeatDoesNotRequireMousePointsAndHonorsCount() async {
        let sent = expectation(description: "Three keys sent")
        sent.expectedFulfillmentCount = 3
        sent.assertForOverFulfill = true
        let stopped = expectation(description: "Finite repeat finished")
        let engine = ClickerEngine(postKey: { key, pid in
            XCTAssertEqual(key, "space")
            XCTAssertNil(pid)
            sent.fulfill()
            return true
        })
        let config = ClickerConfig(intervalMs: 10, repeatCount: 3, mode: .multipoint,
                                   action: .keyPress, keyCombo: "space")
        await engine.start(config: config) { status in
            if status == "Keyboard repeat OFF" { stopped.fulfill() }
        }
        await fulfillment(of: [sent, stopped], timeout: 2)
        let count = await engine.clicksPerformed
        let running = await engine.isRunning
        XCTAssertEqual(count, 3)
        XCTAssertFalse(running)
    }

    func testMissingBackgroundTargetNeverSendsForegroundKeys() async {
        let stopped = expectation(description: "Missing target reported")
        let engine = ClickerEngine(postKey: { _, _ in
            XCTFail("No key should be posted without the requested target")
            return true
        })
        let config = ClickerConfig(repeatCount: 1, appBundleId: "invalid.automater.test.target",
                                   backgroundToApp: true, action: .keyPress)
        await engine.start(config: config) { status in
            if status.contains("target not found") { stopped.fulfill() }
        }
        await fulfillment(of: [stopped], timeout: 2)
        let count = await engine.clicksPerformed
        let running = await engine.isRunning
        XCTAssertEqual(count, 0)
        XCTAssertFalse(running)
    }

    func testStopInterruptsContinuousKeyboardRepeat() async {
        let sent = expectation(description: "First key sent")
        let engine = ClickerEngine(postKey: { _, _ in sent.fulfill(); return true })
        await engine.start(config: ClickerConfig(intervalMs: 1_000, action: .keyPress))
        await fulfillment(of: [sent], timeout: 2)
        await engine.stop()
        let count = await engine.clicksPerformed
        let running = await engine.isRunning
        XCTAssertEqual(count, 1)
        XCTAssertFalse(running)
    }

    func testBackgroundKeyboardUsesSelectedProcessWithoutMousePoints() async {
        let sent = expectation(description: "Key routed to selected process")
        let stopped = expectation(description: "Finished")
        let engine = ClickerEngine(postKey: { key, pid in
            XCTAssertEqual(key, "enter")
            XCTAssertEqual(pid, getpid())
            sent.fulfill()
            return true
        })
        var config = ClickerConfig(intervalMs: 10, repeatCount: 1, mode: .multipoint,
                                   backgroundToApp: true, action: .keyPress, keyCombo: "enter")
        config.targetPid = Int(getpid())
        await engine.start(config: config) { status in
            if status == "Keyboard repeat OFF" { stopped.fulfill() }
        }
        await fulfillment(of: [sent, stopped], timeout: 2)
    }

    func testUnselectedBackgroundTargetDoesNotChooseAnArbitraryWindow() async {
        let stopped = expectation(description: "Target required")
        let engine = ClickerEngine(postKey: { _, _ in XCTFail("No target selected"); return true })
        await engine.start(config: ClickerConfig(backgroundToApp: true, action: .keyPress)) { status in
            if status.contains("Choose a background target") { stopped.fulfill() }
        }
        await fulfillment(of: [stopped], timeout: 2)
        let running = await engine.isRunning
        XCTAssertFalse(running)
    }

    func testRestartIsNotStoppedByPreviousRunTeardown() async {
        let first = expectation(description: "First run started")
        let second = expectation(description: "Second run completed")
        let engine = ClickerEngine(postKey: { key, _ in
            if key == "space" { first.fulfill() }
            return true
        })
        await engine.start(config: ClickerConfig(intervalMs: 1_000, action: .keyPress))
        await fulfillment(of: [first], timeout: 2)
        await engine.start(config: ClickerConfig(intervalMs: 10, repeatCount: 3,
                                                action: .keyPress, keyCombo: "enter")) { status in
            if status == "Keyboard repeat OFF" { second.fulfill() }
        }
        await fulfillment(of: [second], timeout: 2)
        let count = await engine.clicksPerformed
        XCTAssertEqual(count, 3)
    }
}
