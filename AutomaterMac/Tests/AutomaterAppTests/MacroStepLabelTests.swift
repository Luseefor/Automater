import XCTest
import AutomaterKit
@testable import automater_app

final class MacroStepLabelTests: XCTestCase {
    func testWindowLocalClicksNeverShowFictionalZeroCoordinates() {
        let label = MacroStepLabel(MacroStep(type: "click", coordSpace: "window", appName: "Fixture", localX: 135, localY: 240))
        XCTAssertEqual(label.title, "Left click")
        XCTAssertTrue(label.detail.contains("135, 240"))
        XCTAssertTrue(label.detail.contains("Window"))
        XCTAssertTrue(label.detail.contains("Fixture"))
    }
    func testShortcutAndDelayLabelsAreReadable() {
        XCTAssertEqual(MacroStepLabel(MacroStep(type: "key", key: "cmd+shift+a")).title, "⌘⇧A")
        XCTAssertEqual(MacroStepLabel(MacroStep(type: "key", key: "space")).title, "Space")
        XCTAssertEqual(MacroStepLabel(MacroStep(type: "delay", delayMs: 1500)).title, "Wait 1.5 s")
        XCTAssertEqual(MacroStepLabel(MacroStep(type: "type", text: "One\nTwo")).detail, "One ↵ Two")
    }
}
