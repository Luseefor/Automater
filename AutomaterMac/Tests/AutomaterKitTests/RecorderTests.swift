import XCTest
import CoreGraphics
import Carbon.HIToolbox
@testable import AutomaterKit

final class RecorderTests: XCTestCase {
    private let window = WindowInfo(windowId: 42, pid: 123, ownerName: "Fixture", bundleId: "test.fixture",
                                    title: "Target", bounds: CGRect(x: 100, y: 200, width: 500, height: 400), layer: 0)
    private func recorder() -> EventTapRecorder {
        EventTapRecorder(windowAtPoint: { [window] _ in window }, focusedWindow: { [window] in window })
    }
    private func mouse(_ recorder: EventTapRecorder, _ type: CGEventType, _ point: CGPoint, clickCount: Int = 1) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
        event.setIntegerValueField(.clickState, value: Int64(clickCount))
        recorder.handle(type: type, event: event)
    }
    private func key(_ recorder: EventTapRecorder, _ code: Int, down: Bool, text: String? = nil, flags: CGEventFlags = []) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        event.flags = flags
        if let text {
            let chars = Array(text.utf16)
            chars.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: $0.baseAddress!) }
        }
        recorder.handle(type: down ? .keyDown : .keyUp, event: event)
    }
    func testClickRecordsWindowIdentityAndLocalCoordinates() throws {
        let r = recorder()
        mouse(r, .leftMouseDown, CGPoint(x: 130, y: 250))
        mouse(r, .leftMouseUp, CGPoint(x: 130, y: 250))
        let step = try XCTUnwrap(r.steps.first)
        XCTAssertEqual(step.type, "click")
        XCTAssertEqual(step.windowId, 42)
        XCTAssertEqual(step.appBundleId, "test.fixture")
        XCTAssertEqual(step.coordSpace, "window")
        XCTAssertEqual(step.localX, 30)
        XCTAssertEqual(step.localY, 50)
        XCTAssertEqual(step.delayMs, 0)
    }
    func testDoubleAndTripleClickRecordingKeepsNativeClickCount() {
        let r = recorder()
        for count in 1...3 {
            mouse(r, .leftMouseDown, CGPoint(x: 130, y: 250), clickCount: count)
            mouse(r, .leftMouseUp, CGPoint(x: 130, y: 250), clickCount: count)
            XCTAssertEqual(r.steps.count, 1)
            XCTAssertEqual(r.steps.first?.clickKind, count == 3 ? "triple" : count == 2 ? "double" : "single")
        }
    }
    func testDragKeepsBothEndpointsInSameWindow() throws {
        let r = recorder()
        mouse(r, .leftMouseDown, CGPoint(x: 130, y: 250))
        mouse(r, .leftMouseUp, CGPoint(x: 190, y: 290))
        let step = try XCTUnwrap(r.steps.first)
        XCTAssertEqual(step.type, "drag")
        XCTAssertEqual(step.endLocalX, 90)
        XCTAssertEqual(step.endLocalY, 90)
    }
    func testScrollIsWindowLocalAndCoalesced() throws {
        let r = recorder()
        for _ in 0..<3 {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0)!
            event.location = CGPoint(x: 130, y: 250)
            r.handle(type: .scrollWheel, event: event)
        }
        XCTAssertEqual(r.steps.count, 1)
        XCTAssertEqual(r.steps.first?.coordSpace, "window")
        XCTAssertEqual(r.steps.first?.localY, 50)
        XCTAssertEqual(r.steps.first?.dy, 2)
    }
    func testClearResetsModifiersAndPendingPress() {
        let r = recorder()
        key(r, kVK_Command, down: true)
        mouse(r, .leftMouseDown, CGPoint(x: 130, y: 250))
        r.clear()
        mouse(r, .leftMouseUp, CGPoint(x: 130, y: 250))
        key(r, kVK_ANSI_A, down: true, text: "a")
        key(r, kVK_ANSI_A, down: false)
        XCTAssertEqual(r.steps.map(\.type), ["type"])
        XCTAssertEqual(r.steps.first?.text, "a")
    }
    func testIgnoredShortcutDoesNotLeaveBareModifierStep() {
        let r = recorder()
        r.ignoredCombos = ["ctrl+alt+r"]
        key(r, kVK_Control, down: true)
        key(r, kVK_Option, down: true)
        key(r, kVK_ANSI_R, down: true, flags: [.maskControl, .maskAlternate])
        key(r, kVK_ANSI_R, down: false)
        key(r, kVK_Option, down: false)
        key(r, kVK_Control, down: false)
        XCTAssertTrue(r.steps.isEmpty)
    }
    func testShiftedTextDoesNotRecordAnExtraModifierTap() {
        let r = recorder()
        key(r, kVK_Shift, down: true)
        key(r, kVK_ANSI_A, down: true, text: "A", flags: [.maskShift])
        key(r, kVK_ANSI_A, down: false)
        key(r, kVK_Shift, down: false)
        XCTAssertEqual(r.steps.map(\.type), ["type"])
        XCTAssertEqual(r.steps.first?.text, "A")
    }
    func testRightModifierProducesCanonicalChord() {
        let r = recorder()
        key(r, kVK_RightCommand, down: true)
        key(r, kVK_ANSI_A, down: true, flags: [.maskCommand])
        key(r, kVK_ANSI_A, down: false)
        key(r, kVK_RightCommand, down: false)
        XCTAssertEqual(r.steps.map(\.key), ["cmd+a"])
    }
    func testTextInDifferentWindowsDoesNotMerge() {
        var current = window
        let r = EventTapRecorder(windowAtPoint: { _ in nil }, focusedWindow: { current })
        key(r, kVK_ANSI_A, down: true, text: "a")
        key(r, kVK_ANSI_A, down: false)
        current = WindowInfo(windowId: 43, pid: 124, ownerName: "Other", bundleId: "test.other", title: "Other",
                             bounds: window.bounds, layer: 0)
        key(r, kVK_ANSI_B, down: true, text: "b")
        key(r, kVK_ANSI_B, down: false)
        XCTAssertEqual(r.steps.map(\.text), ["a", "b"])
        XCTAssertEqual(r.steps.map(\.windowId), [42, 43])
    }
    func testNavigationAndFunctionKeyUnicodeIsNotRecordedAsText() {
        let r = recorder()
        for (code, text) in [(kVK_LeftArrow, "\u{F702}"), (kVK_UpArrow, "\u{F700}"), (kVK_F5, "\u{F708}")] {
            key(r, code, down: true, text: text)
            key(r, code, down: false)
        }
        XCTAssertEqual(r.steps.map(\.type), ["key", "key", "key"])
        XCTAssertEqual(r.steps.map(\.key), ["left", "up", "f5"])
    }
    func testShortcutAlreadyHeldWhenCaptureStartsKeepsModifiers() {
        let r = recorder()
        key(r, kVK_ANSI_A, down: true, text: "a", flags: [.maskCommand])
        key(r, kVK_ANSI_A, down: false, flags: [.maskCommand])
        XCTAssertEqual(r.steps.map(\.type), ["key"])
        XCTAssertEqual(r.steps.first?.key, "cmd+a")
    }
    func testIgnoredHotkeyWithAlreadyHeldModifiersLeavesNoInput() {
        let r = recorder()
        r.ignoredCombos = ["ctrl+alt+r"]
        key(r, kVK_ANSI_R, down: true, text: "r", flags: [.maskControl, .maskAlternate])
        key(r, kVK_ANSI_R, down: false, flags: [.maskControl, .maskAlternate])
        XCTAssertTrue(r.steps.isEmpty)
    }
    func testScrollBurstDoesNotMergeAcrossWindows() {
        var current = window
        let r = EventTapRecorder(windowAtPoint: { _ in current }, focusedWindow: { current })
        for id in [42, 43] {
            current = WindowInfo(windowId: id, pid: 123, ownerName: "Fixture", bundleId: "test.fixture", title: "Target", bounds: window.bounds, layer: 0)
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0)!
            event.location = CGPoint(x: 130, y: 250)
            r.handle(type: .scrollWheel, event: event)
        }
        XCTAssertEqual(r.steps.map(\.windowId), [42, 43])
    }
    func testShiftedCharactersUseWhatTheTargetActuallyReceives() {
        let r = recorder()
        key(r, kVK_ANSI_Z, down: true, flags: [.maskShift])
        key(r, kVK_ANSI_Z, down: false, flags: [.maskShift])
        key(r, kVK_ANSI_1, down: true, flags: [.maskShift])
        key(r, kVK_ANSI_1, down: false, flags: [.maskShift])
        XCTAssertEqual(r.steps.map(\.type), ["type"])
        XCTAssertEqual(r.steps.first?.text, "Z!")
    }
    func testStopCompletesHeldKeyWithItsDuration() {
        var time: TimeInterval = 100
        let r = EventTapRecorder(windowAtPoint: { _ in nil }, focusedWindow: { nil }, now: { time })
        key(r, kVK_LeftArrow, down: true)
        time += 0.8
        r.stop()
        XCTAssertEqual(r.steps.map(\.type), ["key"])
        XCTAssertEqual(r.steps.first?.key, "left")
        XCTAssertEqual(Double(r.steps.first?.holdMs ?? 0), 800, accuracy: 1)
    }
    func testStopResetsKeyboardStateWithoutDiscardingSteps() {
        let r = recorder()
        key(r, kVK_Command, down: true)
        r.stop()
        key(r, kVK_ANSI_B, down: true, text: "b")
        key(r, kVK_ANSI_B, down: false)
        XCTAssertEqual(r.steps.first?.text, "b")
    }
}
