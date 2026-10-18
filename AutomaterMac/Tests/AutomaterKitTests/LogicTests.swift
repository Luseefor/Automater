import XCTest
import Carbon.HIToolbox
@testable import AutomaterKit

final class LogicTests: XCTestCase {

    // MARK: recorder relative delays

    func testStepDelayClampsGaps() {
        XCTAssertEqual(EventTapRecorder.stepDelay(gapMs: nil), 0)
        XCTAssertEqual(EventTapRecorder.stepDelay(gapMs: -50), 0)
        XCTAssertEqual(EventTapRecorder.stepDelay(gapMs: 0), 0)
        XCTAssertEqual(EventTapRecorder.stepDelay(gapMs: 250), 250)
        XCTAssertEqual(
            EventTapRecorder.stepDelay(gapMs: EventTapRecorder.maxStepDelayMs + 42),
            EventTapRecorder.maxStepDelayMs
        )
    }

    // MARK: drag interpolation scales with playback speed

    func testInterpolationStepsUseStableCadence() {
        XCTAssertEqual(MacroEngine.interpolationSteps(speed: 1.0), 20)
        XCTAssertEqual(MacroEngine.interpolationSteps(speed: 2.0), 10)
        XCTAssertEqual(MacroEngine.interpolationSteps(speed: 4.0), 5) // floor
        // Speeds below the 0.05 floor clamp to it → max density.
        XCTAssertEqual(MacroEngine.interpolationSteps(speed: 0.05), 400)
        XCTAssertEqual(MacroEngine.interpolationSteps(speed: 0.001), 400)
        // Zero / negative speed still yields a sane count.
        XCTAssertEqual(MacroEngine.interpolationSteps(speed: 0), 400)
        XCTAssertEqual(MacroEngine.interpolationSteps(speed: -3), 400)
    }

    // MARK: scroll steps keep their deltas through the JSON schema

    func testScrollStepCarriesDeltasThroughSchema() throws {
        let json = """
        {"type":"scroll","x":10,"y":20,"dx":-3,"dy":9,"delay_ms":120}
        """.data(using: .utf8)!

        let step = try JSONDecoder().decode(MacroStep.self, from: json)
        XCTAssertEqual(step.dx, -3)
        XCTAssertEqual(step.dy, 9)
        XCTAssertEqual(step.delayMs, 120)

        let out = try JSONEncoder().encode(step)
        let reparsed = try JSONDecoder().decode(MacroStep.self, from: out)
        XCTAssertEqual(reparsed, step)
    }

    func testSwipeStepKeepsItsDirection() {
        let swipe = MacroStep(type: "swipe", dx: -1, dy: 0)
        XCTAssertEqual(swipe.dx, -1)
        XCTAssertEqual(swipe.dy, 0)
    }

    // MARK: hotkey binding parsing

    func testHotkeyParseModifiersAndKey() {
        let parsed = HotkeyManager.parse("ctrl+alt+a")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.1, UInt32(kVK_ANSI_A))
        XCTAssertNotEqual(parsed!.0 & UInt32(controlKey), 0)
        XCTAssertNotEqual(parsed!.0 & UInt32(optionKey), 0)
        XCTAssertEqual(parsed!.0 & UInt32(cmdKey), 0)
    }

    func testHotkeyParseCommandAliasAndWhitespace() {
        let parsed = HotkeyManager.parse(" Cmd + Shift + K ")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.1, UInt32(kVK_ANSI_K))
        XCTAssertNotEqual(parsed!.0 & UInt32(cmdKey), 0)
        XCTAssertNotEqual(parsed!.0 & UInt32(shiftKey), 0)
    }

    func testHotkeyParseRejectsBindingsWithoutKey() {
        XCTAssertNil(HotkeyManager.parse("ctrl+alt"))
        XCTAssertNil(HotkeyManager.parse(""))
        XCTAssertNil(HotkeyManager.parse("notakey+combo"))
    }
}

extension LogicTests {
    func testHotkeyParseRejectsMalformedBindingsRatherThanRegisteringAnotherKey() {
        for binding in ["a+b", "unknown+ctrl+a", "ctrl+a+", "+a", "ctrl++a"] {
            XCTAssertNil(HotkeyManager.parse(binding), binding)
        }
        XCTAssertNotNil(HotkeyManager.parse("right_ctrl+right_alt+a"))
    }
}
