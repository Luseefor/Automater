import Foundation
import AppKit
import AutomaterKit

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

}
