import AppKit
import Combine
import AutomaterKit

/// Clipboard actions shared by the compact panel and its history window.
@MainActor
final class PocketController: ObservableObject {
    let clipboard = ClipboardMonitor()
    @Published private(set) var isRunning = false
    @Published private(set) var runStatus = ""
    @Published private(set) var toast: String?
    @Published private(set) var lastExternalApp: NSRunningApplication?
    private weak var state: AppState?
    private var pasteTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var pasteID = UUID()
    private var cancellables = Set<AnyCancellable>()

    init() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID {
            lastExternalApp = app
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ownPID, app.activationPolicy == .regular else { return }
                self?.lastExternalApp = app
            }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.stop() }.store(in: &cancellables)
    }

    func connect(_ state: AppState) {
        guard self.state == nil else { return }
        self.state = state
        state.onStopAll = { [weak self] in self?.stop() }
        state.onStartAutomation = { [weak self] in self?.stop() }
    }

    func pasteClipboard(_ entry: ClipboardEntry) {
        guard !isRunning else { return }
        guard AXBridge.isTrustedForAccessibility else {
            clipboard.error = "Allow Tandem in Settings → Permissions to paste into another app. You can also use Copy."
            return
        }
        guard let target = lastExternalApp, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            clipboard.error = "Switch to the app you want to paste into, then reopen clipboard history."
            return
        }
        state?.stopAll()
        do { try clipboard.copy(entry) }
        catch { clipboard.error = error.localizedDescription; return }
        let id = UUID()
        pasteID = id
        isRunning = true
        pasteTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.pasteID == id { self.isRunning = false; self.pasteTask = nil }
            }
            do {
                for seconds in stride(from: 2, through: 1, by: -1) {
                    self.runStatus = "Paste to \(target.localizedName ?? "app") in \(seconds)…"
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try Task.checkCancellation()
                guard !target.isTerminated, target.activate(options: []) else {
                    throw ClipboardError("Couldn’t activate the previous app. Use Copy and paste it manually.")
                }
                try await Task.sleep(nanoseconds: 250_000_000)
                try Task.checkCancellation()
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                    throw ClipboardError("The previous app is no longer active. Use Copy and paste it manually.")
                }
                guard EventPoster().keyCombo("cmd+v", pid: nil) else {
                    throw ClipboardError("Couldn’t send the paste shortcut. Use Copy and paste it manually.")
                }
                self.flash("Pasted")
            } catch is CancellationError {
                // Stop All and a new repeat/recording cancel pending paste.
            } catch {
                self.clipboard.error = error.localizedDescription
            }
        }
    }

    func stop() {
        pasteID = UUID()
        pasteTask?.cancel()
        pasteTask = nil
        isRunning = false
        runStatus = ""
    }

    func flash(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_500_000_000) } catch { return }
            self?.toast = nil
        }
    }
}
