import XCTest
import AppKit
import AutomaterKit
@testable import automater_app

final class StatusMenuTests: XCTestCase {
    @MainActor private func item(_ action: MenuBarController.Action, in menu: NSMenu) -> NSMenuItem {
        menu.item(withTag: action.rawValue)!
    }
    @MainActor func testIdleMenuHasHeaderIconsAndNoEnabledEmptyPlaybackOrStop() async {
        _ = NSApplication.shared
        let state = AppState(), controller = MenuBarController(), menu = NSMenu()
        controller.updateMenu(menu, state: state)
        XCTAssertNotNil(menu.item(withTag: 100)?.view)
        XCTAssertFalse(item(.play, in: menu).isEnabled)
        XCTAssertFalse(item(.stop, in: menu).isEnabled)
        XCTAssertTrue(item(.panel, in: menu).isEnabled)
        XCTAssertEqual(item(.panel, in: menu).title, "Open Tandem")
        XCTAssertTrue(item(.clipboard, in: menu).isEnabled)
        for row in menu.items where row.action != nil { XCTAssertNotNil(row.image) }
        XCTAssertEqual(item(.settings, in: menu).keyEquivalent, ",")
        XCTAssertEqual(item(.quit, in: menu).keyEquivalentModifierMask, .command)
    }
    @MainActor func testRunningMenuUpdatesExistingRowsAndAllowsStop() async {
        _ = NSApplication.shared
        let state = AppState(), controller = MenuBarController(), menu = NSMenu()
        controller.updateMenu(menu, state: state)
        let repeatRow = item(.repeatAction, in: menu), header = menu.item(withTag: 100)!
        state.isClicking = true
        controller.updateMenu(menu, state: state)
        XCTAssertTrue(repeatRow === item(.repeatAction, in: menu))
        XCTAssertTrue(header === menu.item(withTag: 100))
        XCTAssertEqual(repeatRow.title, "Stop Repeating")
        XCTAssertTrue(repeatRow.isEnabled)
        XCTAssertTrue(item(.stop, in: menu).isEnabled)
        state.isClicking = false
        state.repeatAction = .keyPress
        controller.updateMenu(menu, state: state)
        XCTAssertEqual(repeatRow.title, "Repeat Key")
        XCTAssertFalse(item(.stop, in: menu).isEnabled)
    }
    @MainActor func testRecordingAndPointCapturePreventConflictingStarts() async {
        _ = NSApplication.shared
        let state = AppState(), controller = MenuBarController(), menu = NSMenu()
        state.currentMacro.steps = [MacroStep(type: "delay", delayMs: 100)]
        state.isRecording = true
        controller.updateMenu(menu, state: state)
        XCTAssertEqual(item(.record, in: menu).title, "Stop Recording")
        XCTAssertTrue(item(.record, in: menu).isEnabled)
        XCTAssertFalse(item(.repeatAction, in: menu).isEnabled)
        XCTAssertFalse(item(.play, in: menu).isEnabled)
        state.isRecording = false
        state.isCapturingMacroPoint = true
        controller.updateMenu(menu, state: state)
        XCTAssertFalse(item(.record, in: menu).isEnabled)
        XCTAssertFalse(item(.play, in: menu).isEnabled)
        XCTAssertTrue(item(.stop, in: menu).isEnabled)
    }
    @MainActor func testPlaybackToggleReflectsVisibleSourceAndRunningState() async {
        _ = NSApplication.shared
        let state = AppState(), controller = MenuBarController(), menu = NSMenu()
        state.currentMacro.steps = [MacroStep(type: "delay", delayMs: 100)]
        controller.updateMenu(menu, state: state)
        XCTAssertTrue(item(.play, in: menu).isEnabled)
        state.hasRecording = true
        state.recordedSteps = []
        controller.updateMenu(menu, state: state)
        XCTAssertFalse(item(.play, in: menu).isEnabled)
        state.playingMacro = true
        controller.updateMenu(menu, state: state)
        XCTAssertEqual(item(.play, in: menu).title, "Stop Playback")
        XCTAssertTrue(item(.play, in: menu).isEnabled)
        XCTAssertTrue(item(.stop, in: menu).isEnabled)
    }
    func testShortcutMappingPreservesCustomModifiersAndSpecialKeys() {
        let custom = MenuShortcut("right_ctrl+right_alt+shift+p")
        XCTAssertEqual(custom?.key, "p")
        XCTAssertEqual(custom?.modifiers, [.control, .option, .shift])
        XCTAssertEqual(MenuShortcut("ctrl+alt+space")?.key, " ")
        XCTAssertEqual(MenuShortcut("cmd+f5")?.key, String(UnicodeScalar(NSF1FunctionKey + 4)!))
        XCTAssertNil(MenuShortcut("cmd+a+b"))
    }
}
