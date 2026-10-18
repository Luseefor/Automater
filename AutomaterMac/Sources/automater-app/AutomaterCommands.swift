import SwiftUI
import AppKit
import AutomaterKit

struct AutomaterCommands: Commands {
    @ObservedObject var state: AppState
    @ObservedObject var clipboard: ClipboardMonitor
    @Environment(\.openWindow) private var openWindow
    @AppStorage("general.keepOnTop") private var isPinned = false
    @AppStorage("general.showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("appearance.theme") private var theme: AppTheme = .light
    @AppStorage("appearance.accent") private var accent: AppAccent = .blue

    private var capturing: Bool { state.isRecording || state.isPicking || state.isCapturingFixedPoint || state.isCapturingMacroPoint }
    private var editingLocked: Bool { capturing || state.playingMacro }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Tandem") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "Tandem",
                    .applicationIcon: AutomaterBrand.icon(side: 128),
                    .credits: NSAttributedString(string: "Copyright © 2026 Rijan Ghimire. MIT License.\n\n" + ((Bundle.main.url(forResource: "LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""))
                ])
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Macro") { state.requestNewMacro(); showPanel() }
                .keyboardShortcut("n").disabled(editingLocked)
            Button("Import Macro…") { showPanel(); state.importMacroFile() }
                .keyboardShortcut("o").disabled(editingLocked)
            Menu("Open Saved Macro") {
                if state.macros.isEmpty { Text("No Saved Macros") }
                ForEach(state.macros) { macro in
                    Button(macro.name) {
                        guard state.confirmReplacingMacro() else { return }
                        state.selectMacro(id: macro.id)
                        state.panelTab = .macros
                        showPanel()
                    }
                }
            }.disabled(editingLocked || state.macros.isEmpty)
            Divider()
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Macro") { state.saveMacroFromMenu() }
                .keyboardShortcut("s").disabled(editingLocked)
            Button("Duplicate Macro") { state.duplicateMacro(); showPanel() }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(editingLocked)
            Button("Export Macro…") { state.exportMacroFile() }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(editingLocked)
            Divider()
            Button("Show Macro Library in Finder") {
                Storage.ensureDirs()
                NSWorkspace.shared.open(Storage.macrosDir)
            }
        }
        // Keep AppKit's Cut/Copy/Paste/Select All responder chain intact.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Clipboard History") { showClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Find in Clipboard…") {
                showClipboard()
                // Deliver after a newly opened scene has installed its observer.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    NotificationCenter.default.post(name: .automaterFindClipboard, object: nil)
                }
            }.keyboardShortcut("f")
        }
        CommandGroup(after: .toolbar) {
            Button("Show Tandem") { showPanel() }.keyboardShortcut("0")
            Button("Repeat") { state.panelTab = .repeatAction; showPanel() }.keyboardShortcut("1")
            Button("Macros") { state.panelTab = .macros; showPanel() }.keyboardShortcut("2")
            Divider()
            Toggle("Keep Panel on Top", isOn: $isPinned)
            Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)
            Menu("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
                Divider()
                Picker("Accent", selection: $accent) {
                    ForEach(AppAccent.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
            }
        }
        CommandMenu("Controls") {
            Button(state.isClicking ? "Stop Repeating" : state.startActionTitle) { state.toggleClicker() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!state.isClicking && capturing)
            Button(state.isRecording ? "Stop Recording" : "Start Recording") { state.toggleRecording() }
                .keyboardShortcut("r").disabled(state.isPicking || state.isCapturingFixedPoint)
            Button(state.playingMacro ? "Stop Macro" : "Play Macro") { state.playToggle() }
                .keyboardShortcut("p")
                .disabled(!state.playingMacro && (capturing || state.displaySteps.isEmpty))
            Divider()
            Button("Stop Everything") { state.stopAll() }.keyboardShortcut(".")
        }
        CommandMenu("Clipboard") {
            Button("Show History") { showClipboard() }.keyboardShortcut("3")
            Toggle("Pause History", isOn: $clipboard.isPaused)
        }
        CommandGroup(replacing: .help) {
            Button("Tandem Help") { openWindow(id: "help"); NSApp.activate(ignoringOtherApps: true) }
            Button("Accessibility Settings…") { AXBridge.openAccessibilitySettings() }
            Divider()
            Button("Show Application Support in Finder") {
                Storage.ensureDirs()
                NSWorkspace.shared.open(Storage.appDir)
            }
        }
    }

    private func showPanel() {
        openWindow(id: "compact-panel")
        NSApp.activate(ignoringOtherApps: true)
    }
    private func showClipboard() {
        openWindow(id: "clipboard-panel")
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let automaterFindClipboard = Notification.Name("automaterFindClipboard")
}

struct AutomaterHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppBrandLabel()
            Text("Repeat, record, and keep things handy.").font(.title3.weight(.semibold))
            help("Repeat", "Choose Mouse or Keyboard, set an interval, then Start. Capture a key directly with Capture.")
            help("Background clicks", "Choose a target window and a fixed point or multiple points. You can use another app while it runs. Some apps require foreground input; keyboard macros use Foreground playback.")
            help("Macros", "Record your actions or add steps, set loops, and Save. Import and export JSON from File. A loop count of 0 repeats until stopped.")
            help("Clipboard", "Text, images, and files you copy appear in History. Pin items to keep them. Paste returns to the previous app after a short countdown.")
            Divider()
            Text("Global shortcuts").font(.headline)
            ForEach(HotkeyCoordinator.bindings, id: \.setting) { binding in
                HStack {
                    Text(binding.label.capitalized)
                    Spacer()
                    Text(HotkeyCoordinator.binding(for: binding.setting).replacingOccurrences(of: "ctrl", with: "⌃").replacingOccurrences(of: "alt", with: "⌥").replacingOccurrences(of: "shift", with: "⇧").replacingOccurrences(of: "cmd", with: "⌘").replacingOccurrences(of: "+", with: "").uppercased())
                        .foregroundStyle(.secondary).monospaced()
                }.font(.callout)
            }
            Text("Change global shortcuts in Settings → Shortcuts. ⌘. stops everything while Tandem is active.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 520)
    }
    private func help(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
