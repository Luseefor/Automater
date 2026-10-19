import SwiftUI
import AppKit
import Combine
import AutomaterKit

// MARK: - Compact panel

enum PanelTab: String, CaseIterable, Identifiable {
    case repeatAction = "Repeat", macros = "Macros"
    var id: Self { self }
}

struct CompactPanelView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pocket: PocketController
    @Environment(\.openWindow) private var openWindow
    #if compiler(>=6.0)
    @Environment(\.openSettings) private var openSettings
    #endif
    private var selection: PanelTab { state.panelTab }
    @FocusState private var focusedTab: PanelTab?
    @AppStorage("general.keepOnTop") private var isPinned = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                panelTab(.repeatAction)
                panelTab(.macros)
                Spacer()
                Button { MenuBarController.shared.openClipboard() } label: {
                    HeaderIcon(name: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .help("Clipboard history · ⌃⌥V")
                .accessibilityLabel("Clipboard history")
                Button { isPinned.toggle() } label: {
                    HeaderIcon(name: isPinned ? "pin.fill" : "pin", selected: isPinned)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin window" : "Keep window on top")
                .accessibilityLabel(isPinned ? "Unpin window" : "Keep window on top")
                SettingsLink { HeaderIcon(name: "gearshape.fill") }
                    .buttonStyle(.plain)
                    .help("Settings")
                    .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            Group {
                switch selection {
                case .repeatAction: ClickerView()
                case .macros: MacrosView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            runBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .background(WindowPinningView(isPinned: isPinned))
        .textFieldStyle(.roundedBorder)
        .controlSize(.regular)
        .buttonBorderShape(.roundedRectangle(radius: 6))
        .modifier(HideDefaultWindowTitle())
        .toolbar {
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                ToolbarItem(placement: .principal) { AppBrandLabel() }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { AppBrandLabel() }
            }
            #else
            ToolbarItem(placement: .principal) { AppBrandLabel() }
            #endif
        }
        .onAppear {
            pocket.connect(state)
            MenuBarController.shared.configure(
                state: state, pocket: pocket,
                showPanel: { openWindow(id: "compact-panel") },
                showClipboard: { openWindow(id: "clipboard-panel") },
                showSettings: { presentSettings() }
            )
        }
    }

    private func presentSettings() {
        #if compiler(>=6.0)
        openSettings()
        #else
        // Older SDKs expose SettingsLink but no programmatic openSettings
        // action. Invoke the app's native Settings menu item instead.
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: {
                  $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
              }) else { return }
        appMenu.performActionForItem(at: index)
        #endif
    }

    private func panelTab(_ tab: PanelTab) -> some View {
        Button { state.panelTab = tab } label: {
            Text(tab.rawValue)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                .frame(minWidth: 70, minHeight: 28)
                .padding(.horizontal, 2)
                .background(selection == tab ? Color.primary.opacity(0.085) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedTab, equals: tab)
        .focusEffectDisabled()
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(focusedTab == tab ? 0.22 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }

    private var anyActive: Bool { state.isClicking || state.isRecording || state.playingMacro }
    private var selectedActionRunning: Bool {
        selection == .repeatAction ? state.isClicking : state.playingMacro
    }

    private var runBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(anyActive ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(state.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(state.status)
                .accessibilityIdentifier("run-status")
            Text(shortcutLabel(HotkeyCoordinator.binding(
                for: selection == .repeatAction ? "hotkey_toggle" : "hotkey_play"
            )))
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Global start / stop shortcut")
            Button {
                if selection == .repeatAction { state.toggleClicker() }
                else { state.playToggle() }
            } label: {
                Label(selectedActionRunning ? "Stop" : (selection == .repeatAction ? "Start" : "Play"),
                      systemImage: selectedActionRunning ? "stop.fill" : "play.fill")
                    .frame(minWidth: 72)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(selectedActionRunning ? .red : .accentColor)
            .disabled(state.isPicking || state.isCapturingFixedPoint || state.isCapturingMacroPoint
                      || (selection == .macros && !state.playingMacro && state.playableMacro().steps.isEmpty))
            .help(selection == .repeatAction && state.repeatAction == .keyPress
                  ? "Start after a 2-second countdown" : "Start or stop playback")
            Button { state.stopAll() } label: {
                HeaderIcon(name: "stop.fill")
            }
            .buttonStyle(.plain)
            .help("Stop all")
            .accessibilityLabel("Stop all")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct HideDefaultWindowTitle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.0)
        if #available(macOS 15, *) { content.toolbar(removing: .title) }
        else { content }
        #else
        content
        #endif
    }
}

private func shortcutLabel(_ binding: String) -> String {
    binding.split(separator: "+").map { raw in
        switch raw.lowercased() {
        case "ctrl", "control": return "⌃"
        case "alt", "option", "opt": return "⌥"
        case "shift": return "⇧"
        case "cmd", "command": return "⌘"
        default: return raw.uppercased()
        }
    }.joined()
}

private struct WindowPinningView: NSViewRepresentable {
    var isPinned: Bool
    func makeNSView(context: Context) -> PinningView { PinningView() }
    func updateNSView(_ view: PinningView, context: Context) {
        if view.isPinned != isPinned { view.isPinned = isPinned }
    }

    final class PinningView: NSView {
        var isPinned = false { didSet { applyLevel() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyLevel() }
        private func applyLevel() {
            guard let window else { return }
            let desiredLevel: NSWindow.Level = isPinned ? .floating : .normal
            if window.level != desiredLevel { window.level = desiredLevel }
        }
    }
}

struct PanelRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
            HStack(spacing: 8, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 28)
    }
}

/// Give compact fields an actual expanding NSPopUpButton, rather than an
/// intrinsically sized SwiftUI menu floating in the middle of a row.
struct PanelChoice<Value: Equatable>: NSViewRepresentable {
    let label: String
    @Binding var selection: Value
    let options: [(String, Value)]

    func makeCoordinator() -> PopupAction { PopupAction() }
    func makeNSView(context: Context) -> NSPopUpButton { makePopup() }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        let appearance: NSAppearance.Name = context.environment.colorScheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != appearance { view.appearance = NSAppearance(named: appearance) }
        let titles = options.map { $0.0 }
        if view.itemTitles != titles {
            view.removeAllItems()
            for title in titles { view.addItem(withTitle: title) }
        }
        if let index = options.firstIndex(where: { $0.1 == selection }) { view.selectItem(at: index) }
        view.isEnabled = context.environment.isEnabled
        view.setAccessibilityLabel(label)
        context.coordinator.action = { popup in
            guard options.indices.contains(popup.indexOfSelectedItem) else { return }
            selection = options[popup.indexOfSelectedItem].1
        }
        view.target = context.coordinator
        view.action = #selector(PopupAction.choose(_:))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: 28)
    }
}

struct PanelMenu: NSViewRepresentable {
    struct Item {
        var title: String
        var icon: NSImage? = nil
        var enabled = true
        var action: (() -> Void)?
        static var separator: Item { Item(title: "", action: nil) }
    }
    let title: String
    var icon: NSImage? = nil
    let label: String
    let items: [Item]

    func makeCoordinator() -> PopupAction { PopupAction() }
    func makeNSView(context: Context) -> NSPopUpButton { makePopup(pullsDown: true) }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        let appearance: NSAppearance.Name = context.environment.colorScheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != appearance { view.appearance = NSAppearance(named: appearance) }
        let titles = [title] + items.map { $0.action == nil && $0.title.isEmpty ? "" : $0.title }
        if view.itemTitles != titles {
            view.removeAllItems()
            view.addItem(withTitle: title)
            view.item(at: 0)?.image = smallIcon(icon)
            view.item(at: 0)?.tag = -1
            for (index, item) in items.enumerated() {
                if item.action == nil && item.title.isEmpty {
                    view.menu?.addItem(.separator())
                } else {
                    let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                    menuItem.image = smallIcon(item.icon)
                    menuItem.isEnabled = item.enabled
                    menuItem.tag = index
                    view.menu?.addItem(menuItem)
                }
            }
        } else {
            view.item(at: 0)?.image = smallIcon(icon)
            for (index, item) in items.enumerated() {
                view.item(at: index + 1)?.isEnabled = item.enabled
                view.item(at: index + 1)?.image = smallIcon(item.icon)
            }
        }
        view.menu?.autoenablesItems = false
        view.selectItem(at: 0)
        view.isEnabled = context.environment.isEnabled
        view.setAccessibilityLabel(label)
        context.coordinator.action = { popup in
            guard let index = popup.selectedItem?.tag, items.indices.contains(index) else { return }
            items[index].action?()
            popup.selectItem(at: 0)
        }
        view.target = context.coordinator
        view.action = #selector(PopupAction.choose(_:))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: 28)
    }
    private func smallIcon(_ source: NSImage?) -> NSImage? {
        guard let icon = source?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

final class PopupAction: NSObject {
    var action: ((NSPopUpButton) -> Void)?
    @objc func choose(_ sender: NSPopUpButton) { action?(sender) }
}

private func makePopup(pullsDown: Bool = false) -> NSPopUpButton {
    let popup = NSPopUpButton(frame: .zero, pullsDown: pullsDown)
    popup.controlSize = .regular
    popup.bezelStyle = .rounded
    popup.font = .systemFont(ofSize: NSFont.systemFontSize)
    popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
    popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return popup
}

// MARK: - Repeat

struct ClickerView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("repeat.intervalUnit") private var intervalUnit: IntervalUnit = .ms
    @State private var advanced = false
    @State private var showingTargets = false
    @State private var lastRepeatCount = 1

    enum IntervalUnit: String, CaseIterable, Identifiable {
        case ms, seconds, minutes
        var id: Self { self }
        var label: String {
            switch self {
            case .ms: return "ms"
            case .seconds: return "sec"
            case .minutes: return "min"
            }
        }
        var msPerUnit: Int {
            switch self {
            case .ms: return 1
            case .seconds: return 1_000
            case .minutes: return 60_000
            }
        }
    }

    private var isKeyboard: Bool { state.repeatAction == .keyPress }
    private var isBurst: Bool { !isKeyboard && state.mode == .multipoint && state.multipointBurst }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 2) {
                    actionButton("Mouse", action: .mouseClick)
                    actionButton("Keyboard", action: .keyPress)
                }
                .padding(3)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Action")
                .disabled(state.isClicking)
                VStack(alignment: .leading, spacing: 12) {
                    if isKeyboard {
                        PanelRow("Key") { KeyPressEditor(binding: $state.repeatKey) }
                    } else {
                        mouseControls
                    }
                    PanelRow(isBurst ? "Between rounds" : "Interval") {
                        TextField("Interval", value: intervalValueBinding,
                                  format: .number.grouping(.never).precision(.fractionLength(0...6)))
                            .frame(minWidth: 60, maxWidth: .infinity)
                            .accessibilityLabel("Repeat interval")
                        Stepper("Interval", value: intervalValueBinding,
                                in: (1 / Double(intervalUnit.msPerUnit))...(86_400_000 / Double(intervalUnit.msPerUnit)))
                            .labelsHidden().fixedSize()
                        PanelChoice(label: "Interval unit", selection: $intervalUnit,
                                    options: IntervalUnit.allCases.map { ($0.label, $0) })
                            .frame(width: 88)
                    }
                    PanelRow(isBurst ? "Rounds" : "Repeat") {
                        PanelChoice(label: "Repeat", selection: finiteRepeatBinding,
                                    options: [("Until stopped", false), ("Count", true)])
                        if state.repeatCount > 0 {
                            TextField("Count", value: repeatBinding, format: .number.grouping(.never))
                                .frame(width: 68).accessibilityLabel("Repeat count")
                            Stepper("Repeat count", value: repeatBinding, in: 1...1_000_000)
                                .labelsHidden().fixedSize()
                        }
                    }
                }
                .disabled(state.isClicking)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    PanelRow("Background") {
                        Toggle("Background", isOn: Binding(get: { state.backgroundToApp }, set: { state.setBackgroundDelivery($0) }))
                            .toggleStyle(.switch).labelsHidden()
                            .help("Click in the target window while using your mouse elsewhere")
                        if !isKeyboard { Text("Keep cursor free").font(.caption).foregroundStyle(.secondary) }
                    }
                    PanelRow("Target") { targetMenu }
                    if state.backgroundToApp && state.windowsOfTarget.count > 1 {
                        PanelRow("Window") {
                            PanelChoice(label: "Target window", selection: Binding(get: { state.selectedWindowID }, set: { state.selectWindow(id: $0) }),
                                        options: state.windowsOfTarget.enumerated().map { index, window in
                                            (window.title.isEmpty ? "Window \(index + 1)" : window.title, Optional(window.windowId))
                                        })
                        }
                    }
                }
                .disabled(state.isClicking)
                Divider()
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    advancedControls.padding(.top, 14)
                }
                .disabled(state.isClicking)
            }
            .padding(20)
        }
        .onAppear {
            state.refreshApps()
            let domain = Bundle.main.bundleIdentifier ?? "com.luseefor.automater"
            if UserDefaults.standard.persistentDomain(forName: domain)?["repeat.intervalUnit"] == nil {
                let ms = state.intervalTotalMs
                intervalUnit = ms >= 60_000 && ms.isMultiple(of: 60_000) ? .minutes : ms >= 1_000 ? .seconds : .ms
            }
        }
        .onChange(of: state.repeatAction) { _, action in
            if action == .mouseClick { state.setBackgroundDelivery(state.backgroundToApp) }
        }
        .sheet(isPresented: $showingTargets) {
            VStack(spacing: 0) {
                HStack {
                    Text("Target").font(.headline)
                    Spacer()
                    Button("Done") { showingTargets = false }.keyboardShortcut(.defaultAction)
                }.padding()
                Divider()
                TargetPickerView()
            }
            .frame(width: 600, height: 600)
        }
    }

    private func actionButton(_ title: String, action: ClickerConfig.Action) -> some View {
        Button { state.repeatAction = action } label: {
            Label(title, systemImage: action == .mouseClick ? "cursorarrow" : "keyboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(state.repeatAction == action ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(state.repeatAction == action ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(state.repeatAction == action ? .isSelected : [])
    }

    private var mouseControls: some View {
        Group {
            PanelRow("Click") {
                PanelChoice(label: "Mouse button", selection: $state.button,
                            options: MouseButton.allCases.map { ($0.rawValue.capitalized, $0) })
                PanelChoice(label: "Click type", selection: $state.kind,
                            options: ClickKind.allCases.map { ($0.rawValue.capitalized, $0) })
            }
            PanelRow("Position") {
                PanelChoice(label: "Position", selection: $state.mode,
                            options: state.backgroundToApp
                                ? [("Fixed point", .fixedPoint), ("Multiple points", .multipoint)]
                                : [("Current cursor", .currentCursor), ("Fixed point", .fixedPoint), ("Multiple points", .multipoint)])
            }
            if state.mode == .fixedPoint {
                PanelRow("Point") {
                    TextField("X", value: Binding(get: { state.fixedX }, set: { state.editFixedPoint(x: $0) }), format: .number.grouping(.never))
                        .accessibilityLabel("Fixed point X")
                    TextField("Y", value: Binding(get: { state.fixedY }, set: { state.editFixedPoint(y: $0) }), format: .number.grouping(.never))
                        .accessibilityLabel("Fixed point Y")
                    Button(state.isCapturingFixedPoint ? "Cancel" : "Pick…") { state.toggleFixedPointCapture() }
                        .help("Pick a point, or hover and press ⌃⌥G")
                        .disabled(state.isRecording)
                    Button { state.clearFixedPoint() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).disabled(!state.hasFixedPoint)
                        .accessibilityLabel("Clear fixed point")
                }
            } else if state.mode == .multipoint {
                multipoints
            }
        }
    }

    private var multipoints: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(state.multipoints.count) points").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(state.isPicking ? "Finish" : "Pick Points…") { state.togglePicking() }
                    .disabled(state.isRecording)
                    .help("Click target points, then press Escape or Finish")
                Button("Clear") { state.multipoints.removeAll() }
                    .disabled(state.multipoints.isEmpty || state.isPicking)
            }
            PanelRow("Timing") {
                PanelChoice(label: "Multi-point timing", selection: $state.multipointBurst,
                            options: [("Sequential", false), ("Burst ~100ms", true)])
            }
            if state.repickIndex != nil {
                Text("Click where the point should move — Finish cancels")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !state.multipoints.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(state.multipoints.enumerated()), id: \.offset) { index, point in
                            HStack {
                                Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 20)
                                Text("\(point.x ?? 0), \(point.y ?? 0)").monospacedDigit()
                                    .accessibilityIdentifier("mouse-point-\(index)-coordinates")
                                Spacer()
                                Button { state.repickPoint(at: index) } label: {
                                    Image(systemName: state.repickIndex == index ? "mappin.circle.fill" : "mappin.circle")
                                }.buttonStyle(.borderless)
                                    .disabled(state.isRecording)
                                    .help("Re-pick point \(index + 1) in place")
                                    .accessibilityLabel("Re-pick point \(index + 1)")
                                Button { state.multipoints.remove(at: index) } label: {
                                    Image(systemName: "minus.circle")
                                }.buttonStyle(.borderless)
                                    .accessibilityLabel("Remove point \(index + 1)")
                                    .disabled(state.isPicking)
                            }
                        }
                    }
                }.frame(height: min(100, CGFloat(state.multipoints.count) * 26))
            }
        }
    }

    private var targetMenu: some View {
        PanelMenu(title: state.targetWindow?.ownerName ?? "Choose App…",
                  icon: state.targetWindow.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.icon },
                  label: "Target app", items: targetMenuItems)
    }

    private var targetMenuItems: [PanelMenu.Item] {
        var items: [PanelMenu.Item] = [
            .init(title: "No target", action: { state.clearTarget() }), .separator
        ]
        items += state.runningApps.map { app in
            .init(title: app.name, icon: app.app.icon, action: { state.selectApp(id: app.id) })
        }
        items += [.separator,
                  .init(title: "Choose Window…", action: { showingTargets = true }),
                  .init(title: "Refresh Apps", action: { state.refreshApps() })]
        return items
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow("Jitter") {
                TextField("Jitter", value: jitterBinding, format: .number.grouping(.never))
                    .frame(width: 86).accessibilityLabel("Interval jitter in milliseconds")
                Stepper("Jitter", value: jitterBinding, in: 0...5_000).labelsHidden().fixedSize()
                Text("± ms").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if state.backgroundToApp, !isKeyboard {
                PanelRow("Delivery") {
                    PanelChoice(label: "Delivery method", selection: $state.deliveryMode,
                                options: [("Smart background", .accessibility), ("Synthetic events", .events)])
                }
                HStack {
                    Text(state.backgroundCompatibility.title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check") { state.checkBackgroundCompatibility() }
                        .disabled(state.targetWindow == nil)
                }
            }
            if let target = state.targetWindow {
                Text(target.title.isEmpty ? target.ownerName : target.title)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("Floating Controls…") { state.toggleFloatingControls() }
                .controlSize(.small)
        }
    }

    private var intervalValueBinding: Binding<Double> {
        Binding(get: { Double(state.intervalTotalMs) / Double(intervalUnit.msPerUnit) }, set: { value in
            guard value.isFinite else { return }
            state.intervalTotalMs = Int((min(max(value, 0), 86_400_000 / Double(intervalUnit.msPerUnit))
                                        * Double(intervalUnit.msPerUnit)).rounded())
        })
    }
    private var finiteRepeatBinding: Binding<Bool> {
        Binding(get: { state.repeatCount > 0 }, set: { finite in
            if finite { state.repeatCount = max(1, lastRepeatCount) }
            else { lastRepeatCount = max(1, state.repeatCount); state.repeatCount = 0 }
        })
    }
    private var repeatBinding: Binding<Int> {
        Binding(get: { state.repeatCount }, set: { state.repeatCount = min(max($0, 1), 1_000_000) })
    }
    private var jitterBinding: Binding<Int> {
        Binding(get: { state.jitterMs }, set: { state.jitterMs = min(max($0, 0), 5_000) })
    }
}

struct KeyPressEditor: View {
    @Binding var binding: String
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(recording ? "Press a key…" : (binding.isEmpty ? "—" : keyTitle(binding)))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(recording ? Color.secondary : Color.primary)
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 26)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
                .accessibilityLabel("Captured key")
                .accessibilityValue(binding.isEmpty ? "None" : keyTitle(binding))
                .accessibilityIdentifier("captured-key")
            Spacer(minLength: 0)
            Button(recording ? "Cancel" : "Capture") {
                if recording { stopRecording() } else { startRecording() }
            }
            .help("Capture a key or combination")
        }
        .onDisappear { stopRecording() }
    }

    private func keyTitle(_ value: String) -> String {
        guard let chord = KeyChord(value) else { return value }
        let titles: [UInt16: String] = [
            49: "Space", 36: "Return ↩", 48: "Tab ⇥", 53: "Escape ⎋",
            51: "Backspace ⌫", 117: "Forward Delete ⌦", 126: "↑", 125: "↓",
            123: "←", 124: "→", 115: "Home", 119: "End",
            116: "Page Up", 121: "Page Down", 57: "Caps Lock",
        ]
        let modifiers = chord.modifiers.map { code -> String in
            switch code {
            case 59, 62: return "⌃"
            case 58, 61: return "⌥"
            case 56, 60: return "⇧"
            case 55, 54: return "⌘"
            default: return ""
            }
        }.joined()
        let key = titles[chord.key] ?? KeyCodeMap.name(for: chord.key)?.uppercased() ?? value
        return modifiers + key
    }

    private func startRecording() {
        guard monitor == nil else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let key = KeyCodeMap.name(for: event.keyCode), !KeyCodeMap.isModifier(name: key) else { return nil }
            var parts: [String] = []
            if event.modifierFlags.contains(.control) { parts.append("ctrl") }
            if event.modifierFlags.contains(.option) { parts.append("alt") }
            if event.modifierFlags.contains(.shift) { parts.append("shift") }
            if event.modifierFlags.contains(.command) { parts.append("cmd") }
            binding = (parts + [key]).joined(separator: "+")
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

// MARK: - Target tab

/// Target picker: two adaptive lists (apps → windows). Lists with custom
/// rows handle narrow panes gracefully — no columns to crush.
struct TargetPickerView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        GeometryReader { geo in
            // Below ~700pt of detail width the two panes stop fitting
            // side-by-side — stack them instead of clipping.
            let compact = geo.size.width < 700
            VStack(alignment: .leading, spacing: 12) {
                currentTargetBanner
                if compact {
                    appPane
                        .padding(.horizontal, 12)
                        .frame(height: 240)
                    Divider()
                    windowPane
                        .padding(.horizontal, 12)
                } else {
                    HSplitView {
                        appPane
                            .padding(12)
                            .frame(minWidth: 280, idealWidth: 330)
                            .layoutPriority(1)
                        windowPane
                            .padding(12)
                            .frame(minWidth: 300, idealWidth: 420)
                    }
                }
                Text("Click an app, then one of its windows. The ◎ mark shows the active target — background clicks are delivered there without touching your pointer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
    }

    private var appSelection: Binding<Int32?> {
        Binding(
            get: { state.selectedAppID },
            set: { state.selectApp(id: $0) }
        )
    }

    private var windowSelection: Binding<Int?> {
        Binding(
            get: { state.selectedWindowID },
            set: { state.selectWindow(id: $0) }
        )
    }

    private var appPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Running Apps").font(.headline)
                Spacer()
                Text("\(state.runningApps.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List(selection: appSelection) {
                ForEach(state.runningApps) { app in
                    AppListRow(
                        app: app,
                        isTarget: state.targetWindow?.pid == app.id
                    )
                    .tag(app.id)
                }
            }
            .listStyle(.inset)
            .overlay {
                if state.runningApps.isEmpty {
                    Text("No apps — click Refresh")
                        .foregroundStyle(.secondary)
                }
            }
            Button("Refresh") { state.refreshApps() }
                .controlSize(.small)
        }
    }

    private var windowPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows of Target").font(.headline)
            if state.windowsOfTarget.isEmpty {
                GroupBox {
                    VStack(spacing: 6) {
                        Image(systemName: state.selectedAppID == nil ? "scope" : "rectangle.dashed")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text(state.selectedAppID == nil
                             ? "Select an app on the left"
                             : "No scannable windows — app-level targeting will be used")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
                Spacer()
            } else {
                List(selection: windowSelection) {
                    ForEach(state.windowsOfTarget) { w in
                        WindowListRow(
                            window: w,
                            isTarget: state.targetWindow?.windowId == w.windowId
                        )
                        .tag(w.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var currentTargetBanner: some View {
        HStack(spacing: 10) {
            if let t = state.targetWindow {
                if let app = NSRunningApplication(processIdentifier: t.pid),
                   let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.ownerName + (t.title.isEmpty ? "" : " — \(t.title)"))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("pid \(t.pid) · wid \(t.windowId)" + (t.isOnScreen ? "" : " · minimized/off-Space"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Label(state.backgroundCompatibility.title,
                          systemImage: compatibilityIcon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(compatibilityColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Image(systemName: "scope")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No target selected").font(.headline)
                    Text("Pick an app below to begin")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.targetWindow != nil {
                Button("Clear", role: .destructive) {
                    state.clearTarget()
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.top, 10)
    }

    private var compatibilityIcon: String {
        switch state.backgroundCompatibility {
        case .likely: return "checkmark.circle.fill"
        case .foregroundRecommended: return "hand.raised.fill"
        case .noTarget: return "questionmark.circle"
        }
    }

    private var compatibilityColor: Color {
        switch state.backgroundCompatibility {
        case .likely: return .green
        case .foregroundRecommended: return .red
        case .noTarget: return .secondary
        }
    }
}

private struct AppListRow: View {
    let app: RunningApp
    let isTarget: Bool

    var body: some View {
        HStack(spacing: 9) {
            if let icon = app.app.icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Text(app.app.bundleIdentifier ?? "pid \(app.app.processIdentifier)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if isTarget {
                Image(systemName: "target")
                    .foregroundStyle(Color.accentColor)
                    .help("Current target app")
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}

private struct WindowListRow: View {
    let window: WindowInfo
    let isTarget: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isTarget ? "target" : "circle.dashed")
                .foregroundStyle(isTarget ? Color.accentColor : Color.secondary.opacity(0.35))
                .help(isTarget ? "Active target" : "Click to target this window")
            VStack(alignment: .leading, spacing: 1) {
                Text(window.title.isEmpty ? "(untitled)" : window.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text("\(Int(window.bounds.width))×\(Int(window.bounds.height))")
                    Text("·")
                    Text(window.isOnScreen ? "On Screen" : "Minimized / Off-Space")
                        .foregroundStyle(window.isOnScreen ? Color.secondary : Color.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}

// MARK: - Macros tab

struct MacrosView: View {
    @EnvironmentObject var state: AppState
    @State private var confirmDelete = false
    @State private var showingShortcut = false
    @State private var shortcut = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    PanelMenu(title: state.currentMacro.name, label: "Saved macros", items: macroMenuItems)
                        .disabled(state.playingMacro || state.isRecording)
                    Button { state.requestNewMacro() } label: { Image(systemName: "plus") }
                        .help("New macro").accessibilityLabel("New macro")
                        .disabled(state.playingMacro || state.isRecording)
                    Button("Save") { state.saveCurrentMacro() }.disabled(state.playingMacro)
                }
                VStack(spacing: 16) {
                    PanelRow("Name") { TextField("Macro name", text: $state.currentMacro.name).accessibilityIdentifier("macro-name").disabled(state.playingMacro) }
                    PanelRow("Loops") {
                        TextField("Loops", value: loopBinding, format: .number.grouping(.never))
                            .frame(width: 70).accessibilityLabel("Macro loop count")
                        Stepper("Loops", value: loopBinding, in: 0...10_000).labelsHidden().fixedSize()
                        Text(state.currentMacro.loopCount == 0 ? "Until stopped" : "times")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Steps").font(.headline)
                        Text("\(state.displaySteps.count)").font(.callout).foregroundStyle(.secondary)
                            .accessibilityIdentifier("macro-step-count")
                        Spacer()
                        Button { state.toggleRecording() } label: {
                            Label(state.isRecording ? "Stop Recording" : "Record",
                                  systemImage: state.isRecording ? "stop.circle.fill" : "record.circle")
                        }
                        .tint(state.isRecording ? .red : .accentColor)
                    }
                    PanelRow("Playback") {
                        PanelChoice(label: "Macro playback mode", selection: $state.macroBackgroundPlayback,
                                    options: [("Foreground", false), ("Background", true)])
                            .disabled(state.playingMacro || state.isRecording)
                    }
                    HStack {
                        PanelMenu(title: "Add Step", label: "Add step", items: [
                            .init(title: "Pick Click Point…", action: { state.beginMacroPointCapture() }),
                            .init(title: "Keyboard Shortcut…", action: { shortcut = ""; showingShortcut = true })
                        ])
                        .frame(width: 120)
                        .disabled(state.playingMacro || state.isRecording)
                        Spacer()
                        if state.hasRecording {
                            Button("Clear Recording") { state.clearRecordedSteps() }
                                .disabled(state.recordedSteps.isEmpty || state.isRecording || state.playingMacro)
                        }
                    }
                    if state.hasRecording {
                        Toggle("Use recording", isOn: $state.useRecordedForPlay)
                            .font(.callout).disabled(state.playingMacro || state.isRecording)
                    }
                    stepsList
                }
            }.padding(24)
        }
        .onAppear { state.refreshMacros() }
        .confirmationDialog("Delete “\(state.currentMacro.name)” ?", isPresented: $confirmDelete) {
            Button("Delete Macro", role: .destructive) { state.deleteCurrentMacro() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingShortcut) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Add Shortcut").font(.headline)
                KeyPressEditor(binding: $shortcut)
                HStack {
                    Spacer()
                    Button("Cancel") { showingShortcut = false }.keyboardShortcut(.cancelAction)
                    Button("Add") {
                        state.appendManualStep(MacroStep(type: "key", key: shortcut))
                        showingShortcut = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(KeyChord(shortcut) == nil)
                }
            }
            .padding(24).frame(width: 430)
            .textFieldStyle(.roundedBorder)
        }
    }

    private var macroMenuItems: [PanelMenu.Item] {
        var items: [PanelMenu.Item] = state.macros.map { macro in
            .init(title: macro.name, action: {
                guard state.confirmReplacingMacro() else { return }
                state.selectMacro(id: macro.id)
            })
        }
        items += [.separator, .init(title: "New Macro", action: { state.requestNewMacro() }),
                  .init(title: "Delete Macro…",
                        enabled: state.macros.contains(where: { $0.id == state.currentMacro.id }),
                        action: { confirmDelete = true })]
        return items
    }

    private var loopBinding: Binding<Int> {
        Binding(get: { state.currentMacro.loopCount },
                set: { state.currentMacro.loopCount = min(max($0, 0), 10_000) })
    }

    private var stepsList: some View {
        Group {
            if state.displaySteps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "record.circle").font(.system(size: 22, weight: .light))
                    Text("Record or add your first step").font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.displaySteps.enumerated()), id: \.offset) { index, step in
                        let label = MacroStepLabel(step)
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary).frame(width: 20)
                            Image(systemName: label.icon)
                                .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(label.title).font(.callout).lineLimit(1)
                                if !label.detail.isEmpty {
                                    Text(label.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(label.title + " · " + label.detail)
                            Button { state.deleteStep(at: index) } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 14)).frame(width: 26, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove step \(index + 1)")
                            .accessibilityLabel("Delete step \(index + 1)")
                            .accessibilityIdentifier("delete-step-\(index + 1)")
                            .disabled(state.playingMacro || state.isRecording)
                        }
                        .padding(.vertical, 8)
                        if index < state.displaySteps.count - 1 { Divider().padding(.leading, 48) }
                    }
                }
            }
        }
    }

}

extension AppState {
    var displaySteps: [MacroStep] {
        useRecordedForPlay && hasRecording ? recordedSteps : currentMacro.steps
    }

    func loadMacro(_ m: Macro) {
        endMacroPointCapture()
        if isRecording { stopRecording() }
        hasRecording = false
        var m = m
        macroBackgroundPlayback = m.backgroundPlayback ?? macroBackgroundPlayback
        m.backgroundPlayback = macroBackgroundPlayback
        currentMacro = m
        savedMacroSnapshot = m
        recordedSteps = []
        status = "Loaded “\(m.name)”"
        // Read-only prep so visit-and-replay works without re-recording.
        MacroEngine.primeBackgroundTargets(steps: m.steps, macro: m,
                                           background: m.backgroundPlayback ?? macroBackgroundPlayback)
    }

    /// Empty is a valid recording. Keep it selected rather than falling back
    /// to the previously loaded macro, which could replay unwanted actions.
    func clearRecordedSteps() {
        recorder.clear()
        recordedSteps = []
        hasRecording = true
        useRecordedForPlay = true
        status = "Recording cleared"
    }

    func appendManualStep(_ step: MacroStep) {
        if useRecordedForPlay && hasRecording {
            recordedSteps.append(step)
        } else {
            currentMacro.steps.append(step)
        }
    }

    /// Removes one step from whichever source the list is showing
    /// (live recording or the saved macro) — other steps stay intact.
    func deleteStep(at index: Int) {
        if useRecordedForPlay && hasRecording {
            guard recordedSteps.indices.contains(index) else { return }
            recordedSteps.remove(at: index)
        } else {
            guard currentMacro.steps.indices.contains(index) else { return }
            currentMacro.steps.remove(at: index)
        }
    }

    func playableMacro() -> Macro {
        var m = currentMacro
        m.backgroundPlayback = macroBackgroundPlayback
        if useRecordedForPlay && hasRecording {
            m.steps = recordedSteps
        }
        // The target picker configures clicker playback as well as macros.
        // Copy its current identity into the transient macro so recorded text
        // and keys can focus the intended app before replay.
        if let target = targetWindow {
            m.targetAppBundleId = target.bundleId
            m.targetAppName = target.ownerName
            m.targetWindowTitle = target.title.isEmpty ? nil : target.title
            m.steps = m.steps.map { step in
                var step = step
                if step.windowId == nil && step.appBundleId == nil && step.appName == nil {
                    step.windowId = target.windowId > 0 ? target.windowId : nil
                    step.appBundleId = target.bundleId
                    step.appName = target.ownerName
                }
                return step
            }
        }
        return m
    }
}

// MARK: - Settings window (native ⌘, scene)

private enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance = "Appearance", shortcuts = "Shortcuts", clipboard = "Clipboard", permissions = "Permissions", storage = "Storage"
    var id: Self { self }
    var icon: String {
        switch self {
        case .appearance: return "paintpalette"
        case .shortcuts: return "keyboard"
        case .clipboard: return "clipboard"
        case .permissions: return "hand.raised"
        case .storage: return "folder"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pocket: PocketController
    @AppStorage("appearance.theme") private var theme: AppTheme = .light
    @AppStorage("appearance.accent") private var accent: AppAccent = .blue
    @AppStorage("general.showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("general.keepOnTop") private var keepOnTop = false
    @State private var tab: SettingsTab = .appearance
    @FocusState private var focusedTab: SettingsTab?
    @State private var axTrusted = AXBridge.isTrustedForAccessibility
    @State private var confirmPermissionReset = false
    private let trustPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { item in
                    Button { tab = item } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.icon).font(.system(size: 18, weight: .regular))
                            Text(item.rawValue).font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(tab == item ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(tab == item ? Color.accentColor.opacity(0.09) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedTab, equals: item)
                    .focusEffectDisabled()
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(focusedTab == item ? 0.22 : 0), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel(item.rawValue)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .appearance: appearancePane
                    case .shortcuts: shortcutsPane
                    case .clipboard: ClipboardSettingsPane(clipboard: pocket.clipboard)
                    case .permissions: permissionsPane
                    case .storage: storagePane
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .frame(width: 560, height: 460)
        .background(Color(nsColor: .textBackgroundColor))
        .buttonBorderShape(.roundedRectangle(radius: 6))
        .onReceive(trustPoll) { _ in
            if tab == .permissions {
                axTrusted = AXBridge.isTrustedForAccessibility
            }
        }
        .confirmationDialog("Reset Tandem’s Accessibility permission?", isPresented: $confirmPermissionReset) {
            Button("Reset Permission", role: .destructive) { Self.resetTCCEntries(); axTrusted = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’ll need to allow Tandem again in System Settings.")
        }
    }

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Theme").font(.headline)
                HStack(spacing: 14) {
                    ForEach(AppTheme.allCases) { choice in
                        Button { theme = choice } label: {
                            VStack(spacing: 9) {
                                ThemePreview(theme: choice)
                                    .frame(height: 84)
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(theme == choice ? Color.accentColor : Color.primary.opacity(0.12),
                                                      lineWidth: theme == choice ? 2 : 1))
                                HStack(spacing: 5) {
                                    Text(choice.title).font(.callout)
                                    if theme == choice {
                                        Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(choice.title) theme")
                        .accessibilityAddTraits(theme == choice ? .isSelected : [])
                    }
                }
            }
            Divider()
            HStack(spacing: 18) {
                Text("Accent").font(.headline)
                Spacer()
                ForEach(AppAccent.allCases) { choice in
                    Button { accent = choice } label: {
                        Circle().fill(choice.color).frame(width: 22, height: 22)
                            .overlay {
                                if accent == choice {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                }
                            }
                            .padding(4)
                            .overlay(Circle().strokeBorder(accent == choice ? choice.color : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .help(choice.title)
                    .accessibilityLabel("\(choice.title) accent")
                    .accessibilityAddTraits(accent == choice ? .isSelected : [])
                }
            }
            Divider()
            VStack(spacing: 14) {
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                Toggle("Keep panel on top", isOn: $keepOnTop)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var shortcutsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Global Shortcuts").font(.headline)
            ForEach(HotkeyCoordinator.bindings, id: \.setting) { binding in
                HotkeyRow(setting: binding.setting, label: shortcutTitle(binding.setting),
                          binding: HotkeyCoordinator.binding(for: binding.setting))
            }
            Divider()
            Text("Click a shortcut to change it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var permissionsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Accessibility").font(.headline)
                Spacer()
                Label(axTrusted ? "Granted" : "Required", systemImage: axTrusted ? "checkmark.shield.fill" : "exclamationmark.shield")
                    .foregroundStyle(axTrusted ? Color.green : .orange)
            }
            if !axTrusted {
                Text("Allow Tandem in System Settings → Privacy & Security → Accessibility.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Open System Settings") { AXBridge.openAccessibilitySettings() }
                Button("Restart & Apply") { Self.restartApp() }
            }
            Divider()
            DisclosureGroup("Recovery") {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Reveal App in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                    Button("Reset Permission…", role: .destructive) { confirmPermissionReset = true }
                }.padding(.top, 12)
            }
        }
    }

    private var storagePane: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Local Storage").font(.headline)
            Text(Storage.appDir.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Open Folder") { NSWorkspace.shared.activateFileViewerSelecting([Storage.appDir]) }
                Button("Open Diagnostics") { NSWorkspace.shared.activateFileViewerSelecting([Storage.diagnosticsURL]) }
            }
            Divider()
            HStack(spacing: 10) {
                Image(nsImage: AutomaterBrand.icon(side: 64)).resizable().frame(width: 32, height: 32)
                Text("Tandem \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func shortcutTitle(_ setting: String) -> String {
        switch setting {
        case "hotkey_toggle": return "Start / stop"
        case "hotkey_record": return "Record"
        case "hotkey_play": return "Play macro"
        case "hotkey_stop": return "Stop all"
        case "hotkey_grab": return "Grab point"
        case "hotkey_clipboard": return "Clipboard history"
        default: return setting
        }
    }

    static func resetTCCEntries() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.luseefor.automater"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try? task.run()
        task.waitUntilExit()
    }

    static func restartApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NSApp.terminate(nil) }
    }
}

private struct ThemePreview: View {
    let theme: AppTheme
    var body: some View {
        HStack(spacing: 0) {
            miniature(dark: theme == .dark)
            if theme == .system { miniature(dark: true) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private func miniature(dark: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(dark ? Color.white.opacity(0.25) : .black.opacity(0.18)).frame(width: 4, height: 4) }
                Spacer(minLength: 0)
            }.padding(8).background(dark ? Color(white: 0.22) : Color(white: 0.91))
            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(dark ? Color.white.opacity(0.22) : .black.opacity(0.13)).frame(width: 34, height: 4)
                RoundedRectangle(cornerRadius: 3).fill(dark ? Color.white.opacity(0.10) : .black.opacity(0.05)).frame(height: 10)
                HStack {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor).frame(width: 24, height: 9)
                }
            }.padding(9).frame(maxHeight: .infinity).background(dark ? Color(white: 0.13) : .white)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Hotkey keycaps + rebinding

/// One keycap badge ("⌃", "⌥", "A").
struct KeyCap: View {
    let symbol: String
    var isModifier: Bool = false

    var body: some View {
        Text(symbol)
            .font(.system(isModifier ? .footnote : .callout, design: .rounded).weight(.medium))
            .frame(minWidth: isModifier ? 22 : 24, minHeight: 24)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.22), radius: 0.6, y: 1.2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.7)
                    )
            )
    }
}

/// "ctrl+alt+a" → ordered keycap symbols.
@ViewBuilder
func hotkeyCaps(_ binding: String) -> some View {
    let parts = binding.split(separator: "+")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    let symbols: [(String, Bool)] = parts.map { part in
        switch part {
        case "ctrl", "control", "right_ctrl": return ("⌃", true)
        case "alt", "opt", "option", "right_alt": return ("⌥", true)
        case "shift", "right_shift": return ("⇧", true)
        case "cmd", "command", "right_cmd": return ("⌘", true)
        default:
            let pretty = part.count == 1 ? part.uppercased() : part.replacingOccurrences(of: "_", with: " ")
            return (pretty, false)
        }
    }
    HStack(spacing: 3) {
        ForEach(Array(symbols.enumerated()), id: \.offset) { _, cap in
            KeyCap(symbol: cap.0, isModifier: cap.1)
        }
    }
}

struct HotkeyRow: View {
    let setting: String
    let label: String
    let binding: String

    @State private var recordedBinding: String?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 150, alignment: .leading)
            if recording {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Press new shortcut — Esc to cancel")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    startRecording()
                } label: {
                    hotkeyCaps(recordedBinding ?? binding)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to rebind")
            }
            Spacer()
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keycode = event.keyCode
            if keycode == 53 { // Escape cancels
                stopRecording()
                return nil
            }
            guard KeyCodeMap.name(for: keycode) != nil,
                  !KeyCodeMap.isModifier(name: KeyCodeMap.name(for: keycode) ?? "") else {
                return nil // swallow lone modifiers while recording
            }
            var mods: [String] = []
            if event.modifierFlags.contains(.control) { mods.append("ctrl") }
            if event.modifierFlags.contains(.option) { mods.append("alt") }
            if event.modifierFlags.contains(.shift) { mods.append("shift") }
            if event.modifierFlags.contains(.command) { mods.append("cmd") }
            let keyName = KeyCodeMap.name(for: keycode) ?? ""
            let combo = (mods + [keyName]).joined(separator: "+")
            recordedBinding = combo
            stopRecording()
            HotkeyCoordinator.rebind(setting: setting, to: combo)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
