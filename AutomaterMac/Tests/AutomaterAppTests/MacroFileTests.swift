import XCTest
import AppKit
import AutomaterKit
@testable import automater_app

final class MacroFileTests: XCTestCase {
    func testImportUsesFreshIdentityAndClearsSessionWindowNumbers() throws {
        let source = Macro(id: "../../settings", name: "Portable", steps: [
            MacroStep(type: "click", coordSpace: "window", appBundleId: "test.fixture", windowTitle: "Target", windowId: 123, localX: 30, localY: 40)
        ])
        let data = try JSONEncoder().encode(source)
        let first = try MacroFiles.decode(data)
        let second = try MacroFiles.decode(data)
        XCTAssertNotEqual(first.id, source.id)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(first.id.contains("/"))
        XCTAssertNil(first.steps[0].windowId)
        XCTAssertEqual(first.steps[0].appBundleId, "test.fixture")
        XCTAssertEqual(first.steps[0].localX, 30)
    }

    func testExportAndImportRoundTripPreservesActionsAndPlaybackDefaults() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let source = Macro(name: "Round trip", steps: [MacroStep(type: "key", key: "cmd+a"), MacroStep(type: "type", text: "Hello 🌎", delayMs: 123)], loopCount: 3, speed: 2)
        try MacroFiles.write(source, to: file)
        let imported = try MacroFiles.read(file)
        XCTAssertEqual(imported.steps, source.steps)
        XCTAssertEqual(imported.loopCount, 3)
        XCTAssertEqual(imported.speed, 2)
        XCTAssertEqual(imported.name, source.name)
    }

    func testImportRejectsUnrelatedJSONAndMalformedActions() throws {
        for json in ["{}", "[]", "{\"steps\":null}", "{\"steps\":[{\"type\":\"shell\"}]}", "{\"steps\":[],\"speed\":0}", "{\"steps\":[],\"loop_count\":-1}", "{\"steps\":[{\"type\":\"delay\",\"delay_ms\":-1}]}"] {
            XCTAssertThrowsError(try MacroFiles.decode(Data(json.utf8)), json)
        }
    }

    func testExportFailureDoesNotWriteAnInvalidMacro() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        XCTAssertThrowsError(try MacroFiles.write(Macro(name: "Invalid", speed: 0), to: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLegacyFileDefaultsAndSafeExportFilename() throws {
        let macro = try MacroFiles.decode(Data("{\"steps\":[{\"type\":\"key\",\"key\":\"tab\"}]}".utf8))
        XCTAssertEqual(macro.loopCount, 1)
        XCTAssertEqual(macro.speed, 1)
        XCTAssertEqual(MacroFiles.suggestedFilename(" A/B:C\\D\n"), "A-B-C-D-.json")
        XCTAssertEqual(MacroFiles.suggestedFilename("  "), "Macro.json")
    }

    @MainActor func testDraftChangesFollowVisibleRecordingAndSavedSnapshot() async {
        _ = NSApplication.shared
        let state = AppState()
        XCTAssertFalse(state.macroHasChanges)
        state.currentMacro.name = "Changed"
        XCTAssertTrue(state.macroHasChanges)
        state.newMacro()
        XCTAssertEqual(state.panelTab, .macros)
        XCTAssertFalse(state.macroHasChanges)
        let macro = Macro(name: "Loaded", steps: [MacroStep(type: "key", key: "tab")])
        state.loadMacro(macro)
        XCTAssertFalse(state.macroHasChanges)
        state.hasRecording = true
        state.recordedSteps = []
        XCTAssertTrue(state.macroHasChanges)
        state.useRecordedForPlay = false
        XCTAssertFalse(state.macroHasChanges)
    }
}
