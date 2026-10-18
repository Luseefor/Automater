import XCTest
import AppKit
import AutomaterKit
@testable import automater_app

/// Per-macro background-mode save/load coverage (test-only, no Storage writes
/// to the real macro library — JSON codec plus temp-dir MacroFiles only).
final class BackgroundModePersistenceTests: XCTestCase {
    func testBackgroundPlaybackJSONRoundTrip() throws {
        for mode: Bool? in [true, false] {
            let macro = Macro(name: "Mode", steps: [MacroStep(type: "key", key: "tab")],
                              backgroundPlayback: mode)
            let data = try JSONEncoder().encode(macro)
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(raw?["background_playback"] as? Bool, mode)
            XCTAssertEqual(try JSONDecoder().decode(Macro.self, from: data).backgroundPlayback, mode)
        }
    }

    func testLegacyMacroFileDecodesNilMode() throws {
        let legacy = Data("{\"name\":\"Old\",\"steps\":[{\"type\":\"key\",\"key\":\"tab\"}]}".utf8)
        XCTAssertNil(try JSONDecoder().decode(Macro.self, from: legacy).backgroundPlayback)
        XCTAssertNil(try MacroFiles.decode(legacy).backgroundPlayback)
    }

    func testExportImportRoundTripPreservesPerMacroMode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for mode in [true, false] {
            let file = dir.appendingPathComponent("mode-\(mode).json")
            let source = Macro(name: "Mode \(mode)",
                               steps: [MacroStep(type: "click", x: 10, y: 20)],
                               backgroundPlayback: mode)
            try MacroFiles.write(source, to: file)
            XCTAssertEqual(try MacroFiles.read(file).backgroundPlayback, mode)
        }
    }

    @MainActor func testLoadMacroNormalizesLegacyDraftWithoutDirtyFlag() {
        _ = NSApplication.shared
        // Legacy file (nil mode) inherits the current toggle and stays clean.
        let state = AppState()
        state.macroBackgroundPlayback = true
        let legacy = Macro(name: "Legacy", steps: [MacroStep(type: "key", key: "tab")])
        XCTAssertNil(legacy.backgroundPlayback)
        state.loadMacro(legacy)
        XCTAssertEqual(state.currentMacro.backgroundPlayback, true)
        XCTAssertTrue(state.savedMacroSnapshot?.backgroundPlayback == true)
        XCTAssertFalse(state.macroHasChanges)

        let foreground = AppState()
        foreground.macroBackgroundPlayback = false // hermetic: never inherit ambient user settings
        XCTAssertFalse(foreground.macroBackgroundPlayback)
        foreground.loadMacro(legacy)
        XCTAssertEqual(foreground.currentMacro.backgroundPlayback, false)
        XCTAssertFalse(foreground.macroHasChanges)
    }

    @MainActor func testExplicitModeOverridesToggleOnLoad() {
        _ = NSApplication.shared
        let state = AppState()
        state.macroBackgroundPlayback = false // hermetic: never inherit ambient user settings
        XCTAssertFalse(state.macroBackgroundPlayback)
        state.loadMacro(Macro(name: "BG", steps: [MacroStep(type: "click", x: 1, y: 2)],
                              backgroundPlayback: true))
        XCTAssertTrue(state.macroBackgroundPlayback)
        XCTAssertEqual(state.playableMacro().backgroundPlayback, true)
        XCTAssertFalse(state.macroHasChanges)
    }

    @MainActor func testNewMacroCarriesCurrentMode() {
        _ = NSApplication.shared
        let state = AppState()
        state.macroBackgroundPlayback = true
        state.newMacro()
        XCTAssertEqual(state.currentMacro.backgroundPlayback, true)
        XCTAssertFalse(state.macroHasChanges)
        state.macroBackgroundPlayback = false
        state.newMacro()
        XCTAssertEqual(state.currentMacro.backgroundPlayback, false)
        XCTAssertFalse(state.macroHasChanges)
    }

    @MainActor func testPlayableMacroStampsModeAndToggleMarksDraftDirty() {
        _ = NSApplication.shared
        let state = AppState()
        state.macroBackgroundPlayback = false // hermetic: never inherit ambient user settings
        state.loadMacro(Macro(name: "Legacy", steps: [MacroStep(type: "key", key: "tab")]))
        XCTAssertFalse(state.macroHasChanges)
        state.macroBackgroundPlayback = true // didSet stamps the draft only
        XCTAssertEqual(state.playableMacro().backgroundPlayback, true)
        XCTAssertTrue(state.savedMacroSnapshot?.backgroundPlayback == false)
        XCTAssertTrue(state.macroHasChanges)
    }

    @MainActor func testSavedSnapshotRoundTripKeepsModeClean() throws {
        _ = NSApplication.shared
        let state = AppState()
        state.macroBackgroundPlayback = true
        state.loadMacro(Macro(name: "BG", steps: [MacroStep(type: "click", x: 1, y: 2)],
                              backgroundPlayback: true))
        // Simulate a save/load cycle through the JSON codec only.
        let saved = try JSONDecoder().decode(
            Macro.self, from: JSONEncoder().encode(state.playableMacro()))
        state.loadMacro(saved)
        XCTAssertEqual(state.currentMacro.backgroundPlayback, true)
        XCTAssertFalse(state.macroHasChanges)
    }

    /// Parent-requested adjudication: A(saved BG true) -> B(saved FG false) ->
    /// reload A must restore true with a clean snapshot. The mode follows the
    /// loaded macro every time; nothing leaks across entries via the toggle.
    @MainActor func testSavedModeSwitchingDoesNotLeakAcrossMacros() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func saved(_ macro: Macro, as name: String) throws -> Macro {
            let file = dir.appendingPathComponent(name)
            try MacroFiles.write(macro, to: file)
            return try MacroFiles.read(file)
        }
        let savedA = try saved(Macro(name: "A", steps: [MacroStep(type: "click", x: 1, y: 2)],
                                     backgroundPlayback: true), as: "a.json")
        let savedB = try saved(Macro(name: "B", steps: [MacroStep(type: "key", key: "tab")],
                                     backgroundPlayback: false), as: "b.json")
        let state = AppState()
        state.loadMacro(savedA)
        XCTAssertTrue(state.macroBackgroundPlayback)
        XCTAssertFalse(state.macroHasChanges)
        state.loadMacro(savedB)
        XCTAssertFalse(state.macroBackgroundPlayback)
        XCTAssertFalse(state.macroHasChanges)
        state.loadMacro(savedA)
        XCTAssertTrue(state.macroBackgroundPlayback)
        XCTAssertEqual(state.currentMacro.backgroundPlayback, true)
        XCTAssertEqual(state.playableMacro().backgroundPlayback, true)
        XCTAssertFalse(state.macroHasChanges)
    }

    /// Recorded steps carrying identity are never rebound; fully unbound
    /// manual steps intentionally inherit the selected target at play time.
    @MainActor func testPlayableMacroKeepsRecordedIdentityAndInjectsTargetOnlyIntoUnboundSteps() {
        _ = NSApplication.shared
        let state = AppState()
        state.targetWindow = WindowInfo(windowId: 42, pid: 123, ownerName: "Picked",
                                        bundleId: "picked.app", title: "Picked",
                                        bounds: .zero, layer: 0)
        state.currentMacro = Macro(name: "M", steps: [
            MacroStep(type: "click", coordSpace: "window", appBundleId: "rec.app",
                      windowTitle: "Rec", windowId: 7, localX: 1, localY: 2),
            MacroStep(type: "key", key: "tab"),
        ])
        let playable = state.playableMacro()
        XCTAssertEqual(playable.steps[0].windowId, 7)
        XCTAssertEqual(playable.steps[0].appBundleId, "rec.app")
        XCTAssertEqual(playable.steps[0].windowTitle, "Rec")
        XCTAssertEqual(playable.steps[1].windowId, 42)
        XCTAssertEqual(playable.steps[1].appBundleId, "picked.app")
        XCTAssertEqual(playable.steps[1].appName, "Picked")
    }
}
