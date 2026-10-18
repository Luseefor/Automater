import SwiftUI
import AppKit
import Combine
import os
import UserNotifications
import AutomaterKit

// MARK: - App entry

@main
struct AutomaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()
    @StateObject private var pocket = PocketController()

    var body: some Scene {
        Window("Tandem", id: "compact-panel") {
            CompactPanelView()
                .environmentObject(state)
                .environmentObject(pocket)
                .onAppear { appDelegate.state = state }
                .frame(minWidth: 480, minHeight: 520)
                .modifier(AppAppearance())
        }
        .defaultSize(width: 500, height: 540)
        .windowToolbarStyle(.unifiedCompact)
        .commands { AutomaterCommands(state: state, clipboard: pocket.clipboard) }

        Window("Clipboard", id: "clipboard-panel") {
            ClipboardHistoryView(clipboard: pocket.clipboard)
                .environmentObject(pocket)
                .modifier(AppAppearance())
                .frame(minWidth: 620, minHeight: 420)
        }.defaultSize(width: 740, height: 500)

        Window("Tandem Help", id: "help") {
            AutomaterHelpView().modifier(AppAppearance())
        }.defaultSize(width: 520, height: 490).windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(pocket)
                .modifier(AppAppearance())
        }
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        state.stopAll()
        guard state.confirmReplacingMacro() else { return .terminateCancel }
        Task { @MainActor in
            state.persistSettings()
            await state.engine.stop(silent: true)
            await state.macroEngine.stop(silent: true)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static let log = Logger(
        subsystem: "com.luseefor.automater", category: "hotkeys"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AutomaterBrand.icon(side: 256)
        HotkeyManager.shared.installDispatcher()
        HotkeyCoordinator.registerAll(log: Self.log)
        installEditingDismiss()
    }

    /// Clicking anywhere outside a text field drops the caret. SwiftUI on
    /// macOS never resigns first responder on outside clicks, so the focus
    /// ring + blinking cursor would otherwise stick around forever.
    private func installEditingDismiss() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  let content = window.contentView,
                  let hit = content.hitTest(event.locationInWindow) else { return event }
            // Only act while a field editor is active, and never when the
            // click landed inside that editor itself.
            if window.firstResponder is NSTextView, !(hit is NSTextView) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }
}

/// Central registry of global-hotkey bindings: reads settings, registers with
/// Carbon, and can be re-run after a rebind (unregisters everything first).
enum HotkeyCoordinator {
    static let bindings: [(setting: String, fallback: String, label: String, action: Notification.Name)] = [
        ("hotkey_toggle", "ctrl+alt+a", "toggle clicker", .automaterToggle),
        ("hotkey_record", "ctrl+alt+r", "record", .automatorRecordToggle),
        ("hotkey_play", "ctrl+alt+p", "play/stop macro", .automaterPlayToggle),
        ("hotkey_stop", "ctrl+alt+s", "stop all", .automaterStopAll),
        ("hotkey_grab", "ctrl+alt+g", "grab point", .automaterGrabPoint),
        ("hotkey_clipboard", "ctrl+alt+v", "clipboard history", .automaterShowClipboard),
    ]

    /// Every active binding, normalized — the recorder filters these out so
    /// hotkey presses never end up inside a recorded macro.
    static func activeCombos() -> Set<String> {
        let s = Storage.loadSettings()
        return Set(bindings.map {
            HotkeyManager.normalized(s[$0.setting] as? String ?? $0.fallback)
        })
    }

    static func binding(for setting: String) -> String {
        let s = Storage.loadSettings()
        return bindings.first(where: { $0.setting == setting })
            .map { s[$0.setting] as? String ?? $0.fallback } ?? ""
    }

    /// Persists a new binding for one hotkey and re-registers all of them.
    static func rebind(setting: String, to binding: String) {
        var s = Storage.loadSettings()
        s[setting] = binding
        Storage.saveSettings(s)
        registerAll()
    }

    static func registerAll(log: Logger? = nil) {
        HotkeyManager.shared.unregisterAll()
        let s = Storage.loadSettings()
        for b in bindings {
            let binding = s[b.setting] as? String ?? b.fallback
            let registered = HotkeyManager.shared.register(binding) {
                NotificationCenter.default.post(name: b.action, object: nil)
            }
            if !registered {
                log?.error("hotkey '\(binding, privacy: .public)' (\(b.label, privacy: .public)) failed to register — likely in use by another app")
                NotificationCenter.default.post(
                    name: .automaterStatus,
                    object: "Hotkey \(binding) (\(b.label)) failed to register"
                )
            }
        }

    }
}

extension Notification.Name {
    static let automaterToggle = Notification.Name("automaterToggle")
    static let automatorRecordToggle = Notification.Name("automatorRecordToggle")
    static let automaterStopAll = Notification.Name("automaterStopAll")
    static let automaterGrabPoint = Notification.Name("automaterGrabPoint")
    static let automaterPlayToggle = Notification.Name("automaterPlayToggle")
    static let automaterShowClipboard = Notification.Name("automaterShowClipboard")
    /// `object` carries a user-facing status message (String).
    static let automaterStatus = Notification.Name("automaterStatus")
}

// MARK: - State

/// One row of the Target tab's app table.
struct RunningApp: Identifiable {
    let app: NSRunningApplication
    let name: String
    var id: Int32 { app.processIdentifier }
}

/// A conservative preflight result. This reports whether macOS exposes a
/// supported background-delivery path; it never claims that an app accepted a
/// click, because many apps do not expose an acknowledgement for that.
enum BackgroundCompatibility {
    case noTarget
    case likely
    case foregroundRecommended

    var title: String {
        switch self {
        case .noTarget: return "No target"
        case .likely: return "Accessibility available"
        case .foregroundRecommended: return "Foreground recommended"
        }
    }

    var detail: String {
        switch self {
        case .noTarget:
            return "Choose a target app before checking compatibility."
        case .likely:
            return "The target exposes macOS accessibility windows. Smart background delivery can try an accessibility action first."
        case .foregroundRecommended:
            return "The target exposes no usable accessibility windows. Background delivery is unlikely to work; use foreground mode."
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    var onStopAll: (() -> Void)?
    var onStartAutomation: (() -> Void)?
    @Published var panelTab: PanelTab = .repeatAction
    @Published var savedMacroSnapshot: Macro?
    // Clicker
    @Published var repeatAction: ClickerConfig.Action = .mouseClick
    @Published var repeatKey = "space"
    var startActionTitle: String { repeatAction == .keyPress ? "Start Keyboard" : "Start Clicking" }
    @Published var intervalH = 0
    @Published var intervalM = 0
    @Published var intervalS = 0
    @Published var intervalMs = 100
    @Published var jitterMs = 0
    @Published var repeatCount = 0
    @Published var button: MouseButton = .left
    @Published var kind: ClickKind = .single
    @Published var mode: ClickerConfig.Mode = .fixedPoint
    @Published var fixedX = 0
    @Published var fixedY = 0
    @Published var backgroundToApp = true
    @Published var deliveryMode: ClickerConfig.DeliveryMode = .accessibility

    @Published var multipoints: [PointSpec] = []
    @Published var multipointBurst = false
    /// Row being re-picked (replace-in-place); nil when picking appends.
    /// Transient UI state, never persisted.
    @Published var repickIndex: Int?
    private var pointCaptureID = UUID()
    @Published var status = "Idle"
    @Published var isClicking = false

    // Target
    @Published var targetWindow: WindowInfo?
    @Published var runningApps: [RunningApp] = []
    @Published var windowsOfTarget: [WindowInfo] = []

    // Macros / recorder
    @Published var macros: [Macro] = []
    @Published var currentMacro = Macro(name: "New macro")
    @Published var recordedSteps: [MacroStep] = []
    @Published var hasRecording = false
    private var recordingRunID = UUID()
    @Published var isRecording = false
    @Published var playingMacro = false
    @Published var macroBackgroundPlayback = false {
        didSet { currentMacro.backgroundPlayback = macroBackgroundPlayback }
    }
    @Published var selectedAppID: Int32?
    @Published var selectedWindowID: Int?
    @Published var selectedMacroID: String?
    @Published var useRecordedForPlay = true

    let engine = ClickerEngine()
    private var clickerTask: Task<Void, Never>?
    private var clickerRunID = UUID()
    let macroEngine = MacroEngine()
    private var macroTask: Task<Void, Never>?
    private var macroRunID = UUID()
    let recorder = EventTapRecorder()
    let pointPicker = PointPicker()
    let fixedPointPicker = PointPicker()
    let macroPointPicker = PointPicker()
    private var macroCaptureID = UUID()
    @Published var isCapturingMacroPoint = false
    let fixedPointOverlay = FixedPointOverlayController()
    private var cancellables = Set<AnyCancellable>()

    @Published var isPicking = false
    @Published var isCapturingFixedPoint = false
    @Published var hasFixedPoint = false
    private var fixedPointAnchor: PointSpec?

    var backgroundCompatibility: BackgroundCompatibility {
        guard let targetWindow else { return .noTarget }
        return AXBridge.hasAXWindows(appPID: targetWindow.pid)
            ? .likely : .foregroundRecommended
    }

    func checkBackgroundCompatibility() {
        let result = backgroundCompatibility
        status = "\(result.title): \(result.detail)"
    }

    init() {
        loadFromSettings()
        refreshApps()
        refreshMacros()
        savedMacroSnapshot = currentMacro

        recorder.onStatus = { [weak self] msg in
            Task { @MainActor in self?.status = msg }
        }

        pointPicker.onPoint = { [weak self] loc in
            let replacementIndex = self?.repickIndex
            let captureID = self?.pointCaptureID
            Task { @MainActor in
                guard let self, self.pointCaptureID == captureID else { return }
                let spec = self.pointSpec(at: loc)
                if let index = replacementIndex, self.multipoints.indices.contains(index) {
                    self.multipoints[index] = spec
                    self.status = "Point \(index + 1) moved to (\(Int(loc.x)), \(Int(loc.y)))"
                    self.repickIndex = nil
                } else {
                    self.multipoints.append(spec)
                    self.status = "Picked \(self.multipoints.count): (\(Int(loc.x)), \(Int(loc.y)))"
                }
            }
        }
        pointPicker.onFinish = { [weak self] finished in
            let wasReplacing = self?.pointPicker.singleShot == true
            Task { @MainActor in
                guard let self else { return }
                NSApp.unhide(nil)
                self.isPicking = false
                self.repickIndex = nil
                self.pointPicker.singleShot = false
                if finished && !wasReplacing {
                    let n = self.multipoints.count
                    self.status = n == 0 ? "Picking ended — no points" : "\(n) point\(n == 1 ? "" : "s") picked"
                } else if !finished {
                    self.status = "Point picking needs Accessibility"
                }
            }
        }

        // Fixed point: single-shot capture + neon laser overlay tracking.
        fixedPointPicker.singleShot = true
        fixedPointPicker.onPoint = { [weak self] loc in
            Task { @MainActor in
                guard let self else { return }
                self.captureFixedPoint(at: loc)
            }
        }
        fixedPointPicker.onFinish = { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                NSApp.unhide(nil)
                self.isCapturingFixedPoint = false
                if !finished { self.status = "Fixed-point capture needs Accessibility" }
            }
        }
        Publishers.CombineLatest(
            Publishers.CombineLatest4($mode, $hasFixedPoint, $fixedX, $fixedY),
            Publishers.CombineLatest($isClicking, $backgroundToApp)
        )
            .sink { [weak self] point, delivery in
                let (mode, has, x, y) = point
                let (running, background) = delivery
                guard let self else { return }
                self.fixedPointOverlay.setVisible(
                    mode == .fixedPoint && has && !running && !background,
                    at: CGPoint(x: Double(x), y: Double(y))
                )
            }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        center.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.persistSettings() }
            .store(in: &cancellables)
        center.publisher(for: .automaterToggle)
            .sink { [weak self] _ in self?.toggleClicker() }
            .store(in: &cancellables)
        center.publisher(for: .automatorRecordToggle)
            .sink { [weak self] _ in self?.toggleRecording() }
            .store(in: &cancellables)
        center.publisher(for: .automaterStopAll)
            .sink { [weak self] _ in self?.stopAll() }
            .store(in: &cancellables)
        center.publisher(for: .automaterGrabPoint)
            .sink { [weak self] _ in self?.handleGrabHotkey() }
            .store(in: &cancellables)
        center.publisher(for: .automaterPlayToggle)
            .sink { [weak self] _ in self?.playToggle() }
            .store(in: &cancellables)
        center.publisher(for: .automaterStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                if let msg = note.object as? String { self?.status = msg }
            }
            .store(in: &cancellables)
        // Read-only prep when the user switches Spaces: re-prime the
        // current macro's exact targets while they may be visible.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.primeCurrentMacroTargets() }
            .store(in: &cancellables)
    }

    // MARK: settings round-trip

    func loadFromSettings() {
        let s = Storage.loadSettings()
        intervalH = s["click_interval_h"] as? Int ?? 0
        intervalM = s["click_interval_m"] as? Int ?? 0
        intervalS = s["click_interval_s"] as? Int ?? 0
        intervalMs = s["click_interval_ms"] as? Int ?? 100
        jitterMs = s["jitter_ms"] as? Int ?? 0
        repeatCount = s["repeat_count"] as? Int ?? 0
        repeatAction = ClickerConfig.Action(rawValue: s["repeat_action"] as? String ?? "mouseClick") ?? .mouseClick
        repeatKey = s["repeat_key"] as? String ?? "space"
        button = MouseButton(rawValue: s["mouse_button"] as? String ?? "left") ?? .left
        kind = ClickKind(rawValue: s["click_kind"] as? String ?? "single") ?? .single
        mode = ClickerConfig.Mode(rawValue: s["mode"] as? String ?? "fixedPoint") ?? .fixedPoint
        macroBackgroundPlayback = s["macro_background"] as? Bool ?? false
        backgroundToApp = s["background_to_app"] as? Bool ?? true
        if backgroundToApp && mode == .currentCursor { mode = .fixedPoint }
        deliveryMode = ClickerConfig.DeliveryMode(
            rawValue: s["delivery_mode"] as? String ?? "accessibility"
        ) ?? .accessibility
        multipointBurst = s["repeat_multipoint_burst"] as? Bool ?? false
    }

    func persistSettings() {
        var s = Storage.loadSettings()
        s["click_interval_h"] = intervalH
        s["click_interval_m"] = intervalM
        s["click_interval_s"] = intervalS
        s["click_interval_ms"] = intervalMs
        s["jitter_ms"] = jitterMs
        s["repeat_count"] = repeatCount
        s["repeat_action"] = repeatAction.rawValue
        s["repeat_key"] = repeatKey
        s["mouse_button"] = button.rawValue
        s["click_kind"] = kind.rawValue
        s["mode"] = mode.rawValue
        s["macro_background"] = macroBackgroundPlayback
        s["background_to_app"] = backgroundToApp
        s["delivery_mode"] = deliveryMode.rawValue
        s["repeat_multipoint_burst"] = multipointBurst
        Storage.saveSettings(s)
    }

    // MARK: clicker

    /// Total interval in ms — computed over the h/m/s/ms buckets that
    /// settings persist. The Clicker UI edits this through a unit picker.
    var intervalTotalMs: Int {
        get { ((intervalH * 60 + intervalM) * 60 + intervalS) * 1000 + intervalMs }
        set {
            intervalH = newValue / 3_600_000
            intervalM = newValue % 3_600_000 / 60_000
            intervalS = newValue % 60_000 / 1000
            intervalMs = newValue % 1000
        }
    }

    func buildConfig() -> ClickerConfig {
        var config = ClickerConfig()
        config.action = repeatAction
        config.keyCombo = repeatKey
        config.intervalMs = ((intervalH * 60 + intervalM) * 60 + intervalS) * 1000 + intervalMs
        config.jitterMs = jitterMs
        config.repeatCount = repeatCount
        config.button = button
        config.clickKind = kind
        config.mode = mode
        config.fixedScreenX = fixedX
        config.fixedScreenY = fixedY
        if let tw = targetWindow {
            config.appBundleId = tw.bundleId
            config.appName = tw.ownerName
            config.windowTitle = tw.title.isEmpty ? nil : tw.title
            config.targetPid = Int(tw.pid)
            config.targetWindowId = tw.windowId
        }
        if backgroundToApp, let target = targetWindow, target.windowId > 0 {
            let current = WindowScanner.windows(pid: target.pid).first { $0.windowId == target.windowId } ?? target
            config.fixedCoordSpace = .window
            config.fixedWindowId = target.windowId
            if let anchor = fixedPointAnchor, anchor.windowId == target.windowId,
               anchor.x == fixedX, anchor.y == fixedY {
                config.fixedLocalX = anchor.localX ?? 0
                config.fixedLocalY = anchor.localY ?? 0
            } else {
                config.fixedLocalX = Double(fixedX) - current.bounds.minX
                config.fixedLocalY = Double(fixedY) - current.bounds.minY
            }
        }
        config.multipoints = multipoints
        config.multipointBurst = multipointBurst
        config.backgroundToApp = backgroundToApp
        config.deliveryMode = deliveryMode
        return config
    }

    /// Below this the engine clamps to a near-busy-loop; refuse instead.
    static let minimumIntervalMs = 10

    func toggleClicker() {
        endMacroPointCapture()
        if isClicking { stopClicker(); return }
        onStartAutomation?()
        endPicking()
        endFixedCapture()
        stopRecording()
        stopMacro()
        guard AXBridge.isTrustedForAccessibility else {
            status = "Grant Accessibility first"
            AXBridge.requestAccessibilityPrompt()
            return
        }
        persistSettings()
        let config = buildConfig()
        if config.action == .mouseClick && config.mode == .multipoint && config.multipoints.isEmpty {
            status = "Add multi-points first"
            return
        }
        if config.action == .mouseClick {
            if config.mode == .fixedPoint && !hasFixedPoint {
                status = "Pick a click point first"
                return
            }
            if config.backgroundToApp && targetWindow == nil && config.mode != .multipoint {
                status = "Pick a point in the target window first"
                return
            }
            if config.backgroundToApp && config.mode == .fixedPoint, let target = targetWindow {
                guard target.windowId > 0,
                      (0..<target.bounds.width).contains(config.fixedLocalX),
                      (0..<target.bounds.height).contains(config.fixedLocalY) else {
                    status = "Pick a point inside the target window"
                    return
                }
            }
        }
        if config.action == .keyPress {
            guard KeyChord(config.keyCombo) != nil else {
                status = "Enter a key such as space or a shortcut such as cmd+shift+k"
                return
            }
            let chord = KeyChord(HotkeyManager.normalized(config.keyCombo))
            guard !HotkeyCoordinator.activeCombos().contains(where: { KeyChord($0) == chord }) else {
                status = "Choose a key that is not one of Tandem’s control shortcuts"
                return
            }
            guard !config.backgroundToApp || targetWindow != nil else {
                status = "Choose a target app or turn off background delivery"
                return
            }
        }
        guard config.intervalMs >= Self.minimumIntervalMs else {
            status = "Interval too short — minimum \(Self.minimumIntervalMs) ms"
            return
        }
        isClicking = true
        let runID = UUID()
        clickerRunID = runID
        // Let the user release the Start click / shortcut and switch apps
        // before foreground key events begin.
        status = config.action == .keyPress ? "Keyboard repeat starts in 2 seconds…" : "Starting…"
        clickerTask = Task {
            if config.action == .keyPress {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
            guard !Task.isCancelled, clickerRunID == runID else { return }
            await engine.start(config: config) { [weak self] msg in
                Task { @MainActor in
                    guard let self, self.clickerRunID == runID else { return }
                    self.status = msg
                }
            }
            while await engine.isRunning {
                do { try await Task.sleep(nanoseconds: 120_000_000) }
                catch { return }
            }
            guard clickerRunID == runID else { return }
            isClicking = false
        }
    }

    func stopClicker() {
        clickerTask?.cancel()
        clickerTask = nil
        clickerRunID = UUID()
        status = "Stopped"
        isClicking = false
        Task { await engine.stop(silent: true) }
    }

    func stopAll() {
        onStopAll?()
        endMacroPointCapture()
        endPicking()
        endFixedCapture()
        stopClicker()
        stopRecording()
        stopMacro()
    }

    private func stopMacro() {
        macroRunID = UUID()
        macroTask?.cancel()
        playingMacro = false
        macroTask = Task { await macroEngine.stop() }
    }

    func toggleFloatingControls() {
        FloatingControls.toggle(state: self)
    }

    func setBackgroundDelivery(_ enabled: Bool) {
        backgroundToApp = enabled
        if enabled && mode == .currentCursor { mode = .fixedPoint }
    }

    private func pointSpec(at location: CGPoint) -> PointSpec {
        guard backgroundToApp, let window = WindowScanner.window(at: location),
              !WindowScanner.isOwnProcess(window.pid) else {
            return PointSpec(x: Int(location.x), y: Int(location.y), pid: targetWindow.map { Int($0.pid) })
        }
        if targetWindow == nil { setTarget(window) }
        AXBridge.enqueuePrimeWindowCache(windowNumber: window.windowId, pid: window.pid,
                                         bundleId: window.bundleId, ownerName: window.ownerName,
                                         title: window.title, at: location, windowBounds: window.bounds)
        return PointSpec(x: Int(location.x), y: Int(location.y), coordSpace: .window,
                         localX: location.x - window.bounds.minX, localY: location.y - window.bounds.minY,
                         appBundleId: window.bundleId, appName: window.ownerName,
                         windowTitle: window.title.isEmpty ? nil : window.title,
                         pid: Int(window.pid), windowId: window.windowId)
    }

    private func captureFixedPoint(at location: CGPoint) {
        if backgroundToApp {
            guard let window = WindowScanner.window(at: location), !WindowScanner.isOwnProcess(window.pid) else {
                status = "Pick a point inside the window to click"
                return
            }
            setTarget(window)
        }
        fixedX = Int(location.x)
        fixedY = Int(location.y)
        hasFixedPoint = true
        fixedPointAnchor = pointSpec(at: location)
        status = backgroundToApp ? "Background point set — your mouse stays free" : "Fixed point (\(fixedX), \(fixedY))"
    }

    func editFixedPoint(x: Int? = nil, y: Int? = nil) {
        if let x { fixedX = x }
        if let y { fixedY = y }
        fixedPointAnchor = nil
        hasFixedPoint = true
    }

    func grabFixedPoint() { captureFixedPoint(at: EventPoster.cursorLocation) }

    // MARK: macro point capture

    func beginMacroPointCapture() {
        guard AXBridge.isTrustedForAccessibility else {
            status = "Grant Accessibility first"
            AXBridge.requestAccessibilityPrompt()
            return
        }
        stopAll()
        let captureID = UUID(), macroID = currentMacro.id
        macroCaptureID = captureID
        macroPointPicker.singleShot = true
        macroPointPicker.onPoint = { [weak self] point in
            Task { @MainActor in
                guard let self, self.macroCaptureID == captureID, self.currentMacro.id == macroID else { return }
                let step = Self.macroClickStep(at: point, window: WindowScanner.window(at: point))
                self.appendManualStep(step)
                self.status = "Click point added"
            }
        }
        macroPointPicker.onFinish = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.macroCaptureID == captureID else { return }
                self.isCapturingMacroPoint = false
                if self.macroPointPicker.count == 0 { self.status = "Point capture cancelled" }
                NSApp.unhide(nil)
            }
        }
        macroPointPicker.start()
        isCapturingMacroPoint = macroPointPicker.active
        if isCapturingMacroPoint {
            status = "Click a point to add it · Esc to cancel"
            hideForInputCapture()
        }
    }

    func endMacroPointCapture() {
        macroCaptureID = UUID()
        if isCapturingMacroPoint {
            macroPointPicker.stop(finished: true)
            isCapturingMacroPoint = false
            NSApp.unhide(nil)
        }
    }

    static func macroClickStep(at point: CGPoint, window: WindowInfo?) -> MacroStep {
        guard let window else { return MacroStep(type: "click", x: Int(point.x), y: Int(point.y)) }
        return MacroStep(type: "click", x: Int(point.x), y: Int(point.y), button: "left",
                         coordSpace: "window", appBundleId: window.bundleId, appName: window.ownerName,
                         windowTitle: window.title.isEmpty ? nil : window.title, windowId: window.windowId,
                         localX: point.x - window.bounds.minX, localY: point.y - window.bounds.minY)
    }

    // MARK: fixed-point capture (arm, then click the real target)

    /// The Grab button can't grab its own position — arming captures the
    /// user's NEXT click anywhere instead. (Hover + ⌃⌥G also works.)
    func toggleFixedPointCapture() {
        if isCapturingFixedPoint {
            fixedPointPicker.stop(finished: true)
            return
        }
        guard AXBridge.isTrustedForAccessibility else {
            status = "Grant Accessibility first"
            AXBridge.requestAccessibilityPrompt()
            return
        }
        fixedPointPicker.start()
        isCapturingFixedPoint = fixedPointPicker.active
        if isCapturingFixedPoint {
            status = "Click anywhere to set the fixed point — Esc to cancel"
        }
    }

    private func endFixedCapture() {
        if isCapturingFixedPoint { fixedPointPicker.stop(finished: true) }
    }

    /// Hides the laser marker (overlay clears via the mode/point sink).
    func clearFixedPoint() {
        endFixedCapture()
        hasFixedPoint = false
        fixedPointAnchor = nil
        status = "Fixed point cleared"
    }

    /// ⌃⌥G from anywhere: hover over a spot and press — no button click
    /// needed (clicking the UI would move the cursor onto the button).
    /// Contextual: feeds the Fixed Point field in that mode, otherwise
    /// appends a multi-point.
    func handleGrabHotkey() {
        if mode == .fixedPoint {
            grabFixedPoint()
        } else {
            addPointAtCursor()
        }
    }

    // MARK: point picking (click-to-capture)

    func togglePicking() {
        if isPicking {
            pointPicker.stop(finished: true)
            repickIndex = nil
            return
        }
        guard AXBridge.isTrustedForAccessibility else {
            status = "Grant Accessibility first"
            AXBridge.requestAccessibilityPrompt()
            return
        }
        pointCaptureID = UUID()
        pointPicker.singleShot = repickIndex != nil
        pointPicker.start()
        isPicking = pointPicker.active
        if isPicking {
            status = "Picking points — click to add, Esc to finish"
        }
    }

    private func endPicking() {
        pointCaptureID = UUID()
        if isPicking { pointPicker.stop(finished: true) }
        repickIndex = nil
    }

    func addPointAtCursor() {
        let loc = EventPoster.cursorLocation
        let spec = pointSpec(at: loc)
        let px = spec.x ?? 0
        let py = spec.y ?? 0
        if let index = repickIndex, multipoints.indices.contains(index) {
            multipoints[index] = spec
            status = "Point \(index + 1) moved to (\(px), \(py))"
            repickIndex = nil
            endPicking()
        } else {
            multipoints.append(spec)
            status = "Point \(multipoints.count) at (\(px), \(py))"
        }
    }

    /// Arm a one-shot replace of the point at index: the next picked (or
    /// grabbed) point moves it in place, keeping the rest of the list.
    func repickPoint(at index: Int) {
        guard multipoints.indices.contains(index) else { return }
        guard !isClicking, !isRecording, !playingMacro else { return }
        repickIndex = index
        if isPicking { pointPicker.singleShot = true }
        else { togglePicking() }
        if !isPicking { repickIndex = nil }
        status = "Click where point \(index + 1) should move"
    }

    func removeSelectedPoints(at offsets: IndexSet) {
        endPicking()
        multipoints.remove(atOffsets: offsets)
    }

    // MARK: target picker

    func clearTarget() {
        targetWindow = nil
        selectedAppID = nil
        selectedWindowID = nil
        windowsOfTarget = []
        status = "Target cleared"
    }

    func selectApp(id: Int32?) {
        guard let id, let app = NSRunningApplication(processIdentifier: id) else { return }
        selectedAppID = id
        select(app: app)
    }

    func selectWindow(id: Int?) {
        guard let id, let w = windowsOfTarget.first(where: { $0.windowId == id }) else { return }
        selectedWindowID = id
        setTarget(w)
    }

    func selectMacro(id: String?) {
        guard let id, let m = macros.first(where: { $0.id == id }) else { return }
        selectedMacroID = id
        loadMacro(m)
    }

    func refreshApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return RunningApp(app: app, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func select(app: NSRunningApplication) {
        let wins = WindowScanner.windows(pid: app.processIdentifier)
        windowsOfTarget = wins
        if let first = wins.first {
            setTarget(first)
        } else {
            // No scannable windows: keep an app-level pseudo-target
            // (windowId -1 matches no real window) so background delivery can
            // still resolve the app by name/bundle/pid via the fallback chain.
            setTarget(WindowInfo(
                windowId: -1, pid: app.processIdentifier,
                ownerName: app.localizedName ?? "", bundleId: app.bundleIdentifier,
                title: "", bounds: .zero, layer: 0
            ))
        }
    }

    func setTarget(_ w: WindowInfo) {
        if let anchor = fixedPointAnchor, anchor.windowId != w.windowId {
            fixedPointAnchor = nil
            hasFixedPoint = false
        }
        selectedAppID = w.pid
        selectedWindowID = w.windowId
        targetWindow = w
        // Same exact-window priming as recording clicks: covers clicker
        // (non-macro) background flows to other Spaces.
        AXBridge.enqueuePrimeWindowCache(windowNumber: w.windowId, pid: w.pid,
                                         bundleId: w.bundleId, ownerName: w.ownerName,
                                         title: w.title,
                                         at: CGPoint(x: w.bounds.midX, y: w.bounds.midY),
                                         windowBounds: w.bounds)
        windowsOfTarget = WindowScanner.windows(pid: w.pid)
        status = "Target: \(w.ownerName)" + (w.title.isEmpty ? "" : " — \(w.title)")
    }

    // MARK: recorder

    func toggleRecording() {
        if isRecording { stopRecording(); return }
        onStartAutomation?()
        guard AXBridge.isTrustedForAccessibility else {
            status = "Recorder needs Accessibility"
            AXBridge.requestAccessibilityPrompt()
            return
        }
        endMacroPointCapture(); endPicking(); endFixedCapture(); stopClicker(); stopMacro()
        // The app's own hotkeys (⌃⌥R stop, ⌃⌥P play, …) must never leak
        // into the recording.
        recorder.ignoredCombos = HotkeyCoordinator.activeCombos()
        let runID = UUID()
        recordingRunID = runID
        recorder.onSteps = { [weak self] steps in
            Task { @MainActor in
                guard let self, self.isRecording, self.recordingRunID == runID else { return }
                self.recordedSteps = steps
            }
        }
        recorder.start()
        isRecording = recorder.recording
        if isRecording {
            recordedSteps = []
            hasRecording = true
            useRecordedForPlay = true
            panelTab = .macros
            status = "Recording… press the record hotkey to stop"
            hideForInputCapture()
        }
    }

    func stopRecording() {
        guard recorder.recording else { return }
        recorder.stop()
        recordedSteps = recorder.steps
        isRecording = false
        NSApp.unhide(nil)
        // Read-only prep for the just-recorded targets.
        MacroEngine.primeBackgroundTargets(steps: recordedSteps, macro: currentMacro,
                                           background: macroBackgroundPlayback)
    }

    /// Read-only Space-change prep: re-prime the current macro's exact
    /// targets so visit-and-replay keeps working. No activation, no input,
    /// current macro only — never a library sweep.
    private func primeCurrentMacroTargets() {
        MacroEngine.primeBackgroundTargets(steps: displaySteps, macro: currentMacro,
                                           background: currentMacro.backgroundPlayback ?? macroBackgroundPlayback)
    }

    private func hideForInputCapture() {
        // Let the global event tap/picker start before hiding our own window,
        // so the next click or keystroke belongs to the real target app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.isRecording || self.isCapturingMacroPoint else { return }
            NSApp.hide(nil)
        }
    }

    /// ⌃⌥P — play the current macro; press again to stop mid-playback.
    func playToggle() {
        if playingMacro {
            stopMacro()
            status = "Playback stopped"
            return
        }
        let macro = playableMacro()
        guard !macro.steps.isEmpty else {
            status = "Nothing to play — record or load a macro first"
            return
        }
        play(macro: macro)
    }

    // MARK: macros

    func refreshMacros() {
        macros = Storage.listMacros()
    }

    @discardableResult
    func saveCurrentMacro() -> Bool {
        if isRecording { stopRecording() }
        currentMacro = playableMacro()
        if Storage.saveMacro(currentMacro) {
            refreshMacros()
            selectedMacroID = currentMacro.id
            savedMacroSnapshot = currentMacro
            status = "Saved “\(currentMacro.name)”"
        } else {
            status = "Failed to save “\(currentMacro.name)” — see logs"
            return false
        }
        return true
    }

    func newMacro() {
        endMacroPointCapture()
        if isRecording { stopRecording() }
        hasRecording = false
        selectedMacroID = nil
        currentMacro = Macro(name: "Macro \(macros.count + 1)", backgroundPlayback: macroBackgroundPlayback)
        recordedSteps = []
        savedMacroSnapshot = currentMacro
        panelTab = .macros
    }

    func deleteCurrentMacro() {
        guard Storage.deleteMacro(id: currentMacro.id) else {
            status = "Couldn’t delete “\(currentMacro.name)”"
            return
        }
        refreshMacros()
        newMacro()
        status = "Macro deleted"
    }

    func play(macro: Macro) {
        onStartAutomation?()
        guard AXBridge.isTrustedForAccessibility else {
            status = "Grant Accessibility first"
            return
        }
        endMacroPointCapture(); endPicking(); endFixedCapture(); stopClicker(); stopRecording()
        let previous = macroTask
        previous?.cancel()
        let runID = UUID()
        macroRunID = runID
        playingMacro = true
        // Capture the saved per-macro mode up front: a directly played saved
        // macro carries its own mode, and the toggle may move mid-run (the
        // picker is disabled while playing, but programmatic paths exist).
        let playInBackground = macro.backgroundPlayback ?? macroBackgroundPlayback
        macroTask = Task {
            await previous?.value
            guard !Task.isCancelled, macroRunID == runID else { return }
            await macroEngine.play(
                macro: macro,
                backgroundToApp: playInBackground,
                deliveryMode: deliveryMode
            ) { [weak self] msg in
                Task { @MainActor in
                    guard let self, self.macroRunID == runID else { return }
                    self.status = msg
                }
            }
            while await macroEngine.isPlaying {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            }
            guard macroRunID == runID else { return }
            playingMacro = false
            macroTask = nil
        }
    }
}
