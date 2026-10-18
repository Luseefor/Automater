import AppKit
import AutomaterKit
import UniformTypeIdentifiers

/// File interchange is independent of the live recorder and never starts playback.
enum MacroFiles {
    static func read(_ url: URL) throws -> Macro {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else { throw FileError.invalid("The macro file is too large (20 MB maximum).") }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Macro {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["steps"] is [Any] else {
            throw FileError.invalid("Choose an Tandem macro JSON file containing a steps list.")
        }
        var macro = try JSONDecoder().decode(Macro.self, from: data)
        try validate(macro)
        // A foreign ID must never select a path in our library or overwrite a saved macro.
        macro.id = Macro(name: "").id
        // Window numbers are session-local. Resolve the saved app/window identity instead.
        for index in macro.steps.indices { macro.steps[index].windowId = nil }
        if macro.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { macro.name = "Imported macro" }
        return macro
    }

    static func write(_ macro: Macro, to url: URL) throws {
        try validate(macro)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(macro).write(to: url, options: .atomic)
    }

    static func validate(_ macro: Macro) throws {
        guard macro.loopCount >= 0, macro.speed.isFinite, (0.01...1000).contains(macro.speed),
              macro.steps.count <= 100_000 else {
            throw FileError.invalid("The macro has an invalid loop count, speed, or step count.")
        }
        let types: Set<String> = ["delay", "click", "hold", "drag", "move", "scroll", "swipe", "key", "key_down", "key_up", "type"]
        for (index, step) in macro.steps.enumerated() {
            guard types.contains(step.type), (0...86_400_000).contains(step.delayMs),
                  (0...86_400_000).contains(step.holdMs), (0...86_400_000).contains(step.timeoutMs),
                  (1...1000).contains(step.clicks),
                  [step.localX, step.localY, step.endLocalX, step.endLocalY].allSatisfy({ $0?.isFinite ?? true }) else {
                throw FileError.invalid("Step \(index + 1) contains an unsupported action or invalid value.")
            }
        }
    }

    static func suggestedFilename(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Macro" : cleaned).prefix(100)) + ".json"
    }

    enum FileError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
    }
}

@MainActor
extension AppState {
    /// Compare the visible editing source, without injecting the repeat panel's target.
    var macroHasChanges: Bool {
        var draft = currentMacro
        draft.steps = displaySteps
        return isRecording || draft != savedMacroSnapshot
    }

    @discardableResult
    func confirmReplacingMacro() -> Bool {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard macroHasChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(currentMacro.name)”?"
        alert.informativeText = "Your unsaved macro changes will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveCurrentMacro()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func requestNewMacro() {
        guard confirmReplacingMacro() else { return }
        newMacro()
    }

    func importMacroFile() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let panel = NSOpenPanel()
        panel.title = "Import Macro"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let macro = try MacroFiles.read(url)
            guard confirmReplacingMacro() else { return }
            // Import creates its own library entry, leaving the source file untouched.
            guard Storage.saveMacro(macro) else { throw MacroFiles.FileError.invalid("The imported macro could not be saved to your library.") }
            loadMacro(macro)
            selectedMacroID = macro.id
            refreshMacros()
            panelTab = .macros
            status = "Imported “\(macro.name)”"
        } catch { showFileError("Couldn’t import macro", error: error) }
    }

    func exportMacroFile() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let panel = NSSavePanel()
        panel.title = "Export Macro"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = MacroFiles.suggestedFilename(currentMacro.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MacroFiles.write(playableMacro(), to: url)
            status = "Exported “\(currentMacro.name)”"
        } catch { showFileError("Couldn’t export macro", error: error) }
    }

    func duplicateMacro() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        var copy = playableMacro()
        copy.id = Macro(name: "").id
        copy.name += " Copy"
        guard Storage.saveMacro(copy) else {
            showFileError("Couldn’t duplicate macro", error: MacroFiles.FileError.invalid("The macro library could not be written."))
            return
        }
        // The copy includes the visible draft, including unsaved edits.
        loadMacro(copy)
        selectedMacroID = copy.id
        refreshMacros()
        panelTab = .macros
        status = "Duplicated “\(copy.name)”"
    }

    func saveMacroFromMenu() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if !saveCurrentMacro() {
            showFileError("Couldn’t save macro", error: MacroFiles.FileError.invalid("Check that the macro library folder is writable."))
        }
    }

    private func showFileError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
