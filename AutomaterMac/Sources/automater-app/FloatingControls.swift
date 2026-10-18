import AppKit
import SwiftUI

@MainActor
enum FloatingControls {
    private static var panel: NSPanel?

    static func toggle(state: AppState) {
        if let panel, panel.isVisible { panel.orderOut(nil); return }
        let view = FloatingControlsView().environmentObject(state).modifier(AppAppearance())
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 280),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "Tandem Controls"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Keep the standard title bar visible: it is the reliable drag area
        // for moving this always-on-top window.  A slight window alpha still
        // gives the panel a soft glass feel without losing that affordance.
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.titlebarAppearsTransparent = false
        panel.alphaValue = 0.96
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}

private struct FloatingControlsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(state.isClicking ? "Running" : "Ready to run",
                  systemImage: state.repeatAction == .keyPress ? "keyboard" : "cursorarrow.click.2")
                .font(.headline)
                .foregroundStyle(state.isClicking ? .green : .primary)
            Divider()
            row("Interval", "\(state.intervalTotalMs) ms")
            row("Action", state.repeatAction == .keyPress ? state.repeatKey
                : "\(state.button.rawValue.capitalized) · \(state.kind.rawValue)")
            row("Target", state.backgroundToApp ? (state.targetWindow?.ownerName ?? "None selected") : "Foreground")
            row("Repeat", state.repeatCount == 0 ? "Until stopped" : "\(state.repeatCount) times")
            Divider()
            Label(state.backgroundToApp ? (state.repeatAction == .keyPress ? "Background keyboard events"
                : state.backgroundCompatibility.title) : "Foreground delivery",
                  systemImage: state.backgroundToApp ? "app.badge" : "display")
                .foregroundStyle(.secondary)
            Text("Stays above other windows and Spaces.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(state.isClicking ? "Stop" : "Start") { state.toggleClicker() }
                    .buttonStyle(.borderedProminent)
                    .tint(state.isClicking ? .red : .accentColor)
                Button("Stop All") { state.stopAll() }
                Spacer()
            }
        }
        .padding(18)
        .frame(width: 330, height: 280, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}
