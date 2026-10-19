import XCTest
import AppKit
import AutomaterKit
@testable import automater_app

final class MacroEditingTests: XCTestCase {
    @MainActor func testDeletingLastRecordedStepCannotRestoreSavedSteps() async {
        _ = NSApplication.shared
        let state = AppState()
        state.currentMacro = Macro(name: "Saved", steps: [MacroStep(type: "key", key: "tab")])
        state.hasRecording = true
        state.recordedSteps = [MacroStep(type: "click", x: 10, y: 20)]
        state.deleteStep(at: 0)
        XCTAssertTrue(state.displaySteps.isEmpty)
        XCTAssertTrue(state.playableMacro().steps.isEmpty)
        state.appendManualStep(MacroStep(type: "key", key: "return"))
        XCTAssertEqual(state.displaySteps.map(\.key), ["return"])
    }
    @MainActor func testManualStepsEditTheLoadedMacroWithoutCreatingARecording() async {
        _ = NSApplication.shared
        let state = AppState()
        state.loadMacro(Macro(name: "Loaded", steps: [MacroStep(type: "key", key: "tab")]))
        state.appendManualStep(MacroStep(type: "key", key: "return"))
        XCTAssertFalse(state.hasRecording)
        XCTAssertEqual(state.currentMacro.steps.map(\.key), ["tab", "return"])
        state.deleteStep(at: 1)
        XCTAssertEqual(state.displaySteps.map(\.key), ["tab"])
    }
    @MainActor func testSavingManualMacroPreservesItsSelectedTarget() async {
        _ = NSApplication.shared
        let state = AppState()
        let id = "qa-save-" + UUID().uuidString
        defer { Storage.deleteMacro(id: id) }
        state.currentMacro = Macro(id: id, name: "QA save regression", steps: [MacroStep(type: "key", key: "tab")])
        state.targetWindow = WindowInfo(windowId: 42, pid: 123, ownerName: "Fixture", bundleId: "test.fixture",
                                        title: "Target", bounds: .zero, layer: 0)
        state.saveCurrentMacro()
        let saved = Storage.listMacros().first { $0.id == id }
        XCTAssertEqual(saved?.targetAppBundleId, "test.fixture")
        XCTAssertEqual(saved?.steps.first?.windowId, 42)
    }
    @MainActor func testLoadingAndNewMacroDiscardPreviousRecordingSource() async {
        _ = NSApplication.shared
        let state = AppState()
        state.hasRecording = true
        state.recordedSteps = [MacroStep(type: "click", x: 10, y: 20)]
        state.loadMacro(Macro(name: "Loaded", steps: [MacroStep(type: "key", key: "tab")]))
        XCTAssertFalse(state.hasRecording)
        XCTAssertEqual(state.displaySteps.map(\.key), ["tab"])
        state.newMacro()
        XCTAssertFalse(state.hasRecording)
        XCTAssertTrue(state.displaySteps.isEmpty)
    }
}

extension MacroEditingTests {
    @MainActor func testRemovingFirstMiddleAndLastOfLongMacroPreservesRemainingStepsAfterSave() async throws {
        _ = NSApplication.shared
        let state = AppState()
        let id = "qa-edits-" + UUID().uuidString
        defer { Storage.deleteMacro(id: id) }
        let original = (0..<12).map { MacroStep(type: "type", text: "Entry \($0)", delayMs: $0 * 10) }
        state.loadMacro(Macro(id: id, name: "QA long edit", steps: original, loopCount: 3))
        state.deleteStep(at: 0) // first
        state.deleteStep(at: 4) // original entry 5
        state.deleteStep(at: state.displaySteps.count - 1) // last
        let expected = original.enumerated().filter { ![0, 5, 11].contains($0.offset) }.map(\.element)
        XCTAssertEqual(state.displaySteps, expected)
        XCTAssertEqual(state.playableMacro().steps, expected)
        XCTAssertTrue(state.saveCurrentMacro())
        let saved = try XCTUnwrap(Storage.listMacros().first { $0.id == id })
        XCTAssertEqual(saved.steps, expected)
        XCTAssertEqual(saved.loopCount, 3)
        state.loadMacro(saved)
        XCTAssertFalse(state.macroHasChanges)
        XCTAssertEqual(state.displaySteps, expected)
        while !state.displaySteps.isEmpty { state.deleteStep(at: 0) }
        XCTAssertTrue(state.saveCurrentMacro())
        XCTAssertTrue(try XCTUnwrap(Storage.listMacros().first { $0.id == id }).steps.isEmpty)
        state.appendManualStep(MacroStep(type: "key", key: "tab"))
        XCTAssertEqual(state.displaySteps.map(\.key), ["tab"])
    }

    @MainActor func testClearRecordingCannotRevealPreviouslyLoadedActions() async throws {
        _ = NSApplication.shared
        let state = AppState()
        let id = "qa-clear-" + UUID().uuidString
        defer { Storage.deleteMacro(id: id) }
        state.loadMacro(Macro(id: id, name: "QA clear", steps: [MacroStep(type: "key", key: "cmd+w")]))
        state.hasRecording = true
        state.useRecordedForPlay = false
        state.recordedSteps = [MacroStep(type: "key", key: "space")]
        state.clearRecordedSteps()
        XCTAssertTrue(state.hasRecording)
        XCTAssertTrue(state.useRecordedForPlay)
        XCTAssertTrue(state.displaySteps.isEmpty)
        XCTAssertTrue(state.playableMacro().steps.isEmpty)
        XCTAssertTrue(state.macroHasChanges)
        XCTAssertTrue(state.saveCurrentMacro())
        XCTAssertTrue(try XCTUnwrap(Storage.listMacros().first { $0.id == id }).steps.isEmpty)
        state.appendManualStep(MacroStep(type: "key", key: "return"))
        XCTAssertEqual(state.playableMacro().steps.map(\.key), ["return"])
    }

    @MainActor func testRecordedListDeletionKeepsDuplicateStepsAndOrder() async {
        _ = NSApplication.shared
        let state = AppState()
        let first = MacroStep(type: "key", key: "tab")
        let last = MacroStep(type: "key", key: "return")
        state.hasRecording = true
        state.recordedSteps = [first, first, MacroStep(type: "delay", delayMs: 100), first, last]
        state.deleteStep(at: 1)
        state.deleteStep(at: 1)
        XCTAssertEqual(state.displaySteps, [first, first, last])
        state.deleteStep(at: -1)
        state.deleteStep(at: 1000)
        XCTAssertEqual(state.playableMacro().steps, [first, first, last])
    }

    @MainActor func testDeletingOneSavedMacroKeepsOtherEntriesAndStartsCleanDraft() async throws {
        _ = NSApplication.shared
        let state = AppState()
        let macros = (0..<3).map { Macro(id: "qa-library-" + UUID().uuidString, name: "QA entry \($0)", steps: [MacroStep(type: "delay", delayMs: $0)]) }
        defer { for macro in macros { Storage.deleteMacro(id: macro.id) } }
        for macro in macros { XCTAssertTrue(Storage.saveMacro(macro)) }
        state.refreshMacros()
        state.selectMacro(id: macros[1].id)
        state.deleteCurrentMacro()
        XCTAssertFalse(state.macros.contains { $0.id == macros[1].id })
        XCTAssertTrue(state.displaySteps.isEmpty)
        for macro in [macros[0], macros[2]] {
            state.selectMacro(id: macro.id)
            XCTAssertEqual(state.playableMacro().steps, macro.steps)
            XCTAssertEqual(state.currentMacro.id, macro.id)
        }
    }
}

extension MacroEditingTests {
    @MainActor func testManualClickCaptureKeepsWindowIdentityAndLocalCoordinates() async {
        let window = WindowInfo(windowId: 123, pid: 456, ownerName: "Fixture", bundleId: "test.fixture", title: "Target",
                                bounds: CGRect(x: 200, y: 300, width: 500, height: 400), layer: 0)
        let step = AppState.macroClickStep(at: CGPoint(x: 235, y: 370), window: window)
        XCTAssertEqual(step.coordSpace, "window")
        XCTAssertEqual(step.localX, 35)
        XCTAssertEqual(step.localY, 70)
        XCTAssertEqual(step.windowId, 123)
        XCTAssertEqual(step.appBundleId, "test.fixture")
        XCTAssertEqual(step.windowTitle, "Target")
        let screen = AppState.macroClickStep(at: CGPoint(x: 20, y: 30), window: nil)
        XCTAssertEqual(screen.coordSpace, "screen")
        XCTAssertEqual(screen.x, 20)
        XCTAssertNil(screen.windowId)
    }
}
