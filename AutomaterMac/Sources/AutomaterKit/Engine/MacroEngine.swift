import CoreGraphics
import Foundation
import AppKit

/// Plays Macro steps — foreground or background, with loops and speed.
public actor MacroEngine {
    public private(set) var isPlaying = false
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private var heldKeys: [UInt16: UUID] = [:]
    private let poster: EventPoster
    private let scanWindows: @Sendable () -> [WindowInfo]
    private var warmedTargets: Set<String> = []
    /// Per-run window-id → app-pid binding captured at preflight. A window
    /// id later owned by a different process (relaunch / id reuse) is
    /// treated as closed. Cleared on every play/stop.
    private var pinnedPIDs: [Int: pid_t] = [:]
    private struct MousePress {
        let owner: UUID
        var point: CGPoint
        let target: ResolvedTarget
        let button: MouseButton
    }
    private var heldMouse: [MouseButton: MousePress] = [:]

    private var performStep: (@Sendable (MacroStep) async throws -> Void)?

    public init() {
        poster = EventPoster()
        scanWindows = { WindowScanner.allWindows(minSize: CGSize(width: 2, height: 2)) }
    }
    init(poster: EventPoster, windows: @escaping @Sendable () -> [WindowInfo] = { WindowScanner.allWindows(minSize: CGSize(width: 2, height: 2)) }) {
        self.poster = poster
        scanWindows = windows
    }
    init(performStep: @escaping @Sendable (MacroStep) async throws -> Void,
         windows: @escaping @Sendable () -> [WindowInfo] = { WindowScanner.allWindows(minSize: CGSize(width: 2, height: 2)) }) {
        poster = EventPoster()
        self.performStep = performStep
        scanWindows = windows
    }

    public func play(
        macro: Macro,
        backgroundToApp: Bool = false,
        deliveryMode: ClickerConfig.DeliveryMode = .accessibility,
        onStatus: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        stop(silent: true)
        guard !macro.steps.isEmpty, macro.speed.isFinite, macro.speed > 0, macro.loopCount >= 0 else {
            onStatus("Choose a nonempty recording with a valid playback speed")
            return
        }
        let runID = UUID()
        self.runID = runID
        isPlaying = true
        onStatus("Playing: \(macro.name)")

        if backgroundToApp && macro.steps.contains(where: { ["type", "key", "key_down", "key_up", "swipe"].contains($0.type) }) {
            isPlaying = false
            onStatus("Keyboard and swipe macros need Foreground playback")
            return
        }
        warmedTargets.removeAll()
        pinnedPIDs.removeAll()

        var macro = macro
        if backgroundToApp {
            // Pin every step before sending the first input. Repeated loops
            // must not pick a different sibling window as focus/title/order changes.
            let windows = scanWindows()
            for index in macro.steps.indices where macro.steps[index].type != "delay" {
                guard let window = Self.resolveWindow(macro.steps[index], macro, windows: windows) else {
                    isPlaying = false
                    let where_ = Self.stepContext(macro.steps[index], macro, number: index + 1, count: macro.steps.count)
                    onStatus("Background macro target not found or ambiguous — playback stopped \(where_)")
                    return
                }
                macro.steps[index].windowId = window.windowId
                macro.steps[index].appBundleId = window.bundleId
                macro.steps[index].appName = window.ownerName
                pinnedPIDs[window.windowId] = window.pid
            }
        }
        let playback = macro
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var iteration = 0
                while !Task.isCancelled {
                    iteration += 1
                    if playback.loopCount > 0 && iteration > playback.loopCount { break }
                    for (offset, step) in playback.steps.enumerated() {
                        try Task.checkCancellation()
                        let delay = min(86_400, Double(max(0, step.delayMs)) / 1000.0 / max(0.05, playback.speed))
                        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                        try Task.checkCancellation()
                        try await self.run(step: step, macro: playback, bg: backgroundToApp, mode: deliveryMode,
                                           stepNumber: offset + 1, stepCount: playback.steps.count)
                    }
                    await Task.yield()
                }
                await self.finish(runID: runID, status: "Playback finished", onStatus: onStatus)
            } catch is CancellationError {
                // Explicit stop already resets state and releases held input.
            } catch {
                await self.finish(runID: runID, status: error.localizedDescription, onStatus: onStatus)
            }
        }
    }

    public func stop(silent: Bool = false) {
        task?.cancel()
        task = nil
        runID = UUID()
        releaseHeldKeys()
        releaseHeldMouse()
        pinnedPIDs.removeAll()
        if isPlaying { isPlaying = false }
    }

    private func finish(runID: UUID, status: String, onStatus: @Sendable (String) -> Void) {
        guard self.runID == runID else { return }
        isPlaying = false
        task = nil
        releaseHeldKeys()
        releaseHeldMouse()
        pinnedPIDs.removeAll()
        onStatus(status)
    }

    // MARK: - Step execution

    /// Step context for error messages: keeps the original head wording
    /// (tests match on it) and appends position + recorded target.
    private static func stepContext(_ step: MacroStep, _ macro: Macro, number: Int, count: Int) -> String {
        let title = step.windowTitle ?? macro.targetWindowTitle
        let app = step.appName ?? macro.targetAppName
        let target: String
        switch (title, app) {
        case let (t?, a?): target = "“\(t)” · \(a)"
        case let (t?, nil): target = "“\(t)”"
        case let (nil, a?): target = a
        default: target = "unknown target"
        }
        return "(step \(number) of \(count), target \(target))"
    }

    private func run(
        step: MacroStep, macro: Macro,
        bg: Bool, mode: ClickerConfig.DeliveryMode,
        stepNumber: Int, stepCount: Int
    ) async throws {
        let where_ = Self.stepContext(step, macro, number: stepNumber, count: stepCount)
        let target = bg && step.type != "delay" ? bgTarget(step, macro) : .none
        if bg && step.type != "delay" && target.pid == nil {
            throw PlaybackError("Background macro target not found — playback stopped \(where_)")
        }
        if (step.coordSpace == "window" && resolvePoint(step, macro: macro) == nil)
            || (step.windowId != nil && step.type != "delay" && targetWindow(step, macro) == nil) {
            throw PlaybackError("Recorded window not found — playback stopped \(where_)")
        }
        // CG marks both minimized-to-Dock and other-Space windows
        // isOnScreen == false. Only the minimized case is unreachable, and
        // only when AX can actually confirm it (nil = unknown → attempt).
        if bg && step.type != "delay", let window = targetWindow(step, macro), !window.isOnScreen,
           AXBridge.isWindowMinimized(appPID: window.pid, windowBounds: window.bounds) == true {
            throw PlaybackError("Background target is minimized — restore it onto a Space, then replay \(where_)")
        }
        // The performStep seam sits here deliberately: injected tests use
        // fake pids to verify target/identity/PID pinning and step order —
        // they run BEFORE the real-hardware AX availability gate below
        // (live AX calls, cache scope), which parent native tests cover.
        if let performStep { try await performStep(step); return }
        // Off-Space with no live AX window and no exact cached ref: delivery
        // is impossible (raw events are dropped there). Say so honestly
        // instead of logging phantom clicks — open the window here once
        // (recording or target pick primes the cache), then replay.
        // The cache serves AXPress-backed clicks only; hold/drag/move/scroll
        // use raw routed events, so they need a live window regardless.
        // Accessibility delivery only: .events mode never consults the cache.
        if bg && step.type != "delay", let window = targetWindow(step, macro), !window.isOnScreen,
           let point = resolvePoint(step, macro: macro),
           !AXBridge.hasQueryableWindow(appPID: window.pid, x: point.x, y: point.y,
                                        windowBounds: window.bounds),
           !(mode == .accessibility && step.type == "click"
             && AXBridge.hasCachedPressable(windowNumber: window.windowId, pid: window.pid,
                                        x: point.x, y: point.y, expectedFrame: window.bounds,
                                        bundleId: step.appBundleId ?? macro.targetAppBundleId,
                                        ownerName: step.appName ?? macro.targetAppName)) {
            throw PlaybackError("Background target is on another Space and cannot be reached — open its window on this Space once, then replay \(where_)")
        }
        if !bg && macro.activateBeforePlay && step.type != "delay" {
            try await activateTarget(macro, step: step)
        }
        if bg, step.type == "click", let pid = target.pid {
            let cacheKey = "\(pid):\(target.windowNumber ?? 0)"
            if warmedTargets.insert(cacheKey).inserted {
                AXBridge.enableAccessibility(appPID: pid)
                // An exact cached ref already verified live below skips the
                // tree probe: off-Space trees never build, the ref still works.
                let cachedReady: Bool = {
                    guard step.button == nil || step.button == MouseButton.left.rawValue,
                          let wn = target.windowNumber,
                          let probePoint = resolvePoint(step, macro: macro),
                          let probeBounds = targetWindow(step, macro)?.bounds else { return false }
                    return AXBridge.hasCachedPressable(windowNumber: wn, pid: pid,
                                                       x: probePoint.x, y: probePoint.y,
                                                       expectedFrame: probeBounds,
                                                       bundleId: step.appBundleId ?? macro.targetAppBundleId,
                                                       ownerName: step.appName ?? macro.targetAppName)
                }()
                if mode != .accessibility || !cachedReady {
                    for _ in 0..<20 {
                        try Task.checkCancellation()
                        guard bgTarget(step, macro).pid != nil, let point = resolvePoint(step, macro: macro) else {
                            throw PlaybackError("Background macro target not found — playback stopped \(where_)")
                        }
                        let bounds = targetWindow(step, macro)?.bounds
                        let ready = mode == .accessibility
                            ? AXBridge.hasPressableElementAt(appPID: pid, x: point.x, y: point.y, windowBounds: bounds)
                            : AXBridge.hasElementAt(appPID: pid, x: point.x, y: point.y)
                        if ready { break }
                        try await Task.sleep(nanoseconds: 150_000_000)
                    }
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            guard bgTarget(step, macro).pid != nil else {
                throw PlaybackError("Background macro target not found — playback stopped \(where_)")
            }
        }
        try Task.checkCancellation()
        switch step.type {
        case "delay":
            break // handled by caller

        case "click":
            guard let p = resolvePoint(step, macro: macro) else { return }
            try click(p, step: step, macro: macro, bg: bg, mode: mode, target: target,
                      stepNumber: stepNumber, stepCount: stepCount)

        case "hold":
            await hold(step, macro: macro, bg: bg, target: target)

        case "drag":
            await drag(step, macro: macro, bg: bg, target: target)

        case "move":
            guard let p = resolvePoint(step, macro: macro) else { return }
            poster.moveCursor(x: p.x, y: p.y, pid: target.pid,
                              windowNumber: target.windowNumber)

        case "scroll":
            await scrollStep(step, macro: macro, bg: bg, target: target)

        case "swipe":
            try await swipe(step, macro: macro)

        case "key", "key_down", "key_up":
            try await key(step, bg: bg, macro: macro, mode: mode)

        case "type":
            await typeText(step.text ?? "", pid: bg ? bgTarget(step, macro).pid : nil)

        default:
            throw PlaybackError("Unsupported macro step: \(step.type)")
        }
    }

    // MARK: resolution helpers

    /// Resolve only the recorded identity. An ID owned by another app, an
    /// ambiguous app-only match or a missing title must not redirect input.
    /// The match is deliberately NOT limited to on-screen windows: a target
    /// on another Space stays in the CG list with isOnScreen == false (the
    /// same flag value as a minimized window), so Space switches must keep
    /// resolving to the pinned id. Minimized targets are rejected
    /// separately at run time via the AX minimized attribute — background
    /// input cannot reach the Dock.
    static func resolveWindow(_ step: MacroStep, _ macro: Macro, windows: [WindowInfo]) -> WindowInfo? {
        let bundle = step.appBundleId ?? macro.targetAppBundleId
        let app = step.appName ?? macro.targetAppName
        let title = step.windowTitle ?? macro.targetWindowTitle
        func matchesApp(_ window: WindowInfo) -> Bool {
            if let bundle { return window.bundleId == bundle }
            if let app { return window.ownerName.caseInsensitiveCompare(app) == .orderedSame }
            return true
        }
        if let id = step.windowId, id > 0 {
            return windows.first { $0.windowId == id && matchesApp($0) }
        }
        guard bundle != nil || app != nil || title != nil else { return nil }
        var candidates = windows.filter { matchesApp($0) }
        if let title, !title.isEmpty {
            candidates = candidates.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Read-only prep for background playback: prime the exact-AX cache
    /// for the given steps' currently-resolvable windows at their recorded
    /// window-local points. No activation, no input, no retargeting — pure
    /// prime. Callers pass the current macro only (load / stop-record /
    /// Space-change); never a library sweep. One prime per unique window.
    public static func primeBackgroundTargets(steps: [MacroStep], macro: Macro,
                                              background: Bool,
                                              windows: [WindowInfo]? = nil) {
        guard background else { return }
        let list = windows ?? WindowScanner.allWindows(minSize: CGSize(width: 2, height: 2))
        var seen = Set<Int>()
        for step in steps where step.type != "delay" {
            guard let window = resolveWindow(step, macro, windows: list) else { continue }
            guard seen.insert(window.windowId).inserted else { continue }
            let point: CGPoint
            if step.coordSpace == "window", let lx = step.localX, let ly = step.localY {
                point = CGPoint(x: window.bounds.minX + lx, y: window.bounds.minY + ly)
            } else if let x = step.x, let y = step.y,
                      window.bounds.contains(CGPoint(x: x, y: y)) {
                point = CGPoint(x: x, y: y)
            } else {
                point = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
            }
            AXBridge.enqueuePrimeWindowCache(windowNumber: window.windowId, pid: window.pid,
                                             bundleId: window.bundleId, ownerName: window.ownerName,
                                             title: window.title, at: point,
                                             windowBounds: window.bounds)
        }
    }

    private func targetWindow(_ step: MacroStep, _ macro: Macro) -> WindowInfo? {
        guard let window = Self.resolveWindow(step, macro, windows: scanWindows()) else { return nil }
        // Per-run pid pin: the bound id must still belong to the app process
        // captured at preflight. A replaced process (relaunch reusing the id)
        // reads as closed — never deliver to a stranger. Titles are NOT
        // compared: legitimate retitles (browsers, documents) keep the window.
        // Pins exist only on background runs (cleared on play/stop), so
        // foreground resolution is unaffected.
        if let id = step.windowId, id > 0, let pid = pinnedPIDs[id], window.pid != pid {
            return nil
        }
        return window
    }

    private func resolvePoint(_ step: MacroStep, macro: Macro) -> CGPoint? {
        if step.coordSpace == "window" {
            guard let w = targetWindow(step, macro) else { return nil }
            return CGPoint(x: w.bounds.minX + (step.localX ?? 0),
                           y: w.bounds.minY + (step.localY ?? 0))
        }
        if let x = step.x, let y = step.y { return CGPoint(x: x, y: y) }
        let loc = EventPoster.cursorLocation
        return CGPoint(x: loc.x, y: loc.y)
    }

    private func bgTarget(_ step: MacroStep, _ macro: Macro) -> ResolvedTarget {
        guard let window = targetWindow(step, macro) else { return .none }
        return ResolvedTarget(pid: window.pid, windowNumber: window.windowId)
    }

    private func activateTarget(_ macro: Macro, step: MacroStep? = nil) async throws {
        let bundle = step?.appBundleId ?? macro.targetAppBundleId ?? macro.steps.first(where: { $0.appBundleId != nil })?.appBundleId
        let name = step?.appName ?? macro.targetAppName ?? macro.steps.first(where: { $0.appName != nil })?.appName
        guard bundle != nil || name != nil else { return }
        let window = WindowScanner.findWindow(
            bundleId: bundle,
            appName: name,
            windowTitle: step?.windowTitle ?? macro.targetWindowTitle,
            windowId: step?.windowId
        )
        if let window,
           let app = NSRunningApplication(processIdentifier: window.pid) {
            let switching = await MainActor.run {
                let switching = NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid
                if !switching {
                    AXBridge.focusWindow(window)
                    return false
                }
                if NSApp.isActive && window.pid != getpid() {
                    NSApp.yieldActivation(to: app)
                    app.activate(from: .current, options: [])
                } else { app.activate(options: []) }
                AXBridge.focusWindow(window)
                return switching
            }
            if switching {
                for _ in 0..<20 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid { break }
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else {
                    throw PlaybackError("Could not focus the recorded app — playback stopped")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } else if let bundleId = bundle,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            _ = await MainActor.run { app.activate(options: []) }
            try await Task.sleep(nanoseconds: 150_000_000)
        } else {
            throw PlaybackError("Recorded app not found — playback stopped")
        }
    }

    // MARK: delivery

    private func click(
        _ p: CGPoint, step: MacroStep, macro: Macro,
        bg: Bool, mode: ClickerConfig.DeliveryMode, target: ResolvedTarget,
        stepNumber: Int, stepCount: Int
    ) throws {
        let kind = ClickKind(rawValue: step.clickKind) ?? .single
        let presses = step.clicks > 1 ? step.clicks : kind.presses
        let button = MouseButton(rawValue: step.button ?? "left") ?? .left

        let sequence = presses == 3 ? ClickKind.triple : presses == 2 ? .double : .single
        let repetitions = presses > 3 ? presses : 1
        if bg {
            guard let pid = target.pid else { return }
            AXBridge.enableAccessibility(appPID: pid)
            // AXPress expresses one action, NOT native double/triple click
            // semantics (loop-repeat is unrelated to click counts). The raw
            // routed sequence is dropped off-Space, so a cache-only target
            // supports single presses only — anything more stops clearly
            // instead of silently converting to N separate presses. The
            // native double/triple path below is preserved wherever the live
            // tree (or this Space) still carries it.
            if mode == .accessibility, presses > 1,
               let wn = target.windowNumber,
               let w = targetWindow(step, macro), !w.isOnScreen,
               !AXBridge.hasQueryableWindow(appPID: pid, x: p.x, y: p.y, windowBounds: w.bounds) {
                let where_ = Self.stepContext(step, macro, number: stepNumber, count: stepCount)
                if AXBridge.hasCachedPressable(windowNumber: wn, pid: pid, x: p.x, y: p.y,
                                               expectedFrame: w.bounds,
                                               bundleId: step.appBundleId ?? macro.targetAppBundleId,
                                               ownerName: step.appName ?? macro.targetAppName) {
                    throw PlaybackError("Background double/triple click on another Space is not supported — replay it on this Space \(where_)")
                }
            }
            // Verified AX support is LEFT single clicks only (axClick
            // returns false for right/middle): those would fall through to
            // raw events, which are dropped off-Space — a phantom success.
            if mode == .accessibility, button != .left,
               let w = targetWindow(step, macro), !w.isOnScreen,
               !AXBridge.hasQueryableWindow(appPID: pid, x: p.x, y: p.y, windowBounds: w.bounds) {
                let where_ = Self.stepContext(step, macro, number: stepNumber, count: stepCount)
                throw PlaybackError("Background right/middle click on another Space is not supported — replay it on this Space \(where_)")
            }
            if mode == .accessibility, presses == 1,
               poster.axClick(x: p.x, y: p.y, pid: pid, button: button, kind: .single,
                              windowNumber: target.windowNumber,
                              bundleId: step.appBundleId ?? macro.targetAppBundleId,
                              ownerName: step.appName ?? macro.targetAppName) { return }
            for _ in 0..<repetitions {
                poster.backgroundClick(x: p.x, y: p.y, pid: pid, windowNumber: target.windowNumber,
                                       button: button, kind: sequence)
            }
        } else {
            for _ in 0..<repetitions {
                poster.foregroundClick(x: p.x, y: p.y, button: button, kind: sequence)
            }
        }
    }

    /// Scroll: a step with hold_ms replays as continuous scrolling for that
    /// duration (recorder coalesces bursts); without, a single tick.
    /// Backgrounded scrolls route into the target process so covered
    /// windows scroll too (global HID scrolls respect z-order).
    private func scrollStep(_ step: MacroStep, macro: Macro, bg: Bool, target: ResolvedTarget) async {
        // Optionally move to the step position first.
        if step.x != nil || step.coordSpace == "window" {
            if let p = resolvePoint(step, macro: macro) {
                poster.moveCursor(x: p.x, y: p.y, pid: target.pid, windowNumber: target.windowNumber)
            }
        }
        let dx = step.dx ?? 0
        let dy = step.dy ?? 0
        guard dx != 0 || dy != 0 else { return }

        func post() {
            poster.scroll(dx: dx, dy: dy,
                          pid: target.pid, windowNumber: target.windowNumber)
        }

        let duration = Double(max(0, step.holdMs)) / 1000.0 / max(0.05, macro.speed)
        guard duration > 0.05 else {
            post()
            return
        }
        let tick: Double = 0.06
        var elapsed: Double = 0
        while elapsed < duration {
            post()
            do { try await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000)) }
            catch { break }
            elapsed += tick
        }
    }

    /// Recorded three-finger swipes replay as their keyboard equivalents
    /// (System Settings' default mappings): left/right switch Spaces,
    /// up = Mission Control, down = App Exposé.
    private func swipe(_ step: MacroStep, macro: Macro) async throws {
        let combo: String
        if (step.dx ?? 0) < 0 { combo = "ctrl+left" }
        else if (step.dx ?? 0) > 0 { combo = "ctrl+right" }
        else if (step.dy ?? 0) < 0 { combo = "ctrl+up" }
        else if (step.dy ?? 0) > 0 { combo = "ctrl+down" }
        else { return }
        try await key(MacroStep(type: "key", key: combo), bg: false, macro: macro,
            mode: .accessibility)
    }

    private static func downEvent(for button: MouseButton) -> CGEventType {
        switch button {
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        case .left: return .leftMouseDown
        }
    }

    private static func upEvent(for button: MouseButton) -> CGEventType {
        switch button {
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        case .left: return .leftMouseUp
        }
    }

    private func hold(_ step: MacroStep, macro: Macro, bg: Bool, target: ResolvedTarget) async {
        guard let p = resolvePoint(step, macro: macro) else { return }
        let button = MouseButton(rawValue: step.button ?? "left") ?? .left

        func deliver(_ type: CGEventType) {
            poster.postMouseEvent(type, x: p.x, y: p.y, button: button,
                                  pid: target.pid,
                                  windowNumber: target.windowNumber)
        }

        let owner = runID
        heldMouse[button] = MousePress(owner: owner, point: p, target: target, button: button)
        deliver(Self.downEvent(for: button))
        // Hold duration scales with playback speed like every other delay.
        let secs = min(86_400, Double(max(0, step.holdMs)) / 1000.0 / max(0.05, macro.speed))
        do { try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000)) } catch {}
        if heldMouse[button]?.owner == owner {
            heldMouse.removeValue(forKey: button)
            deliver(Self.upEvent(for: button))
        }
    }

    /// AXPress cannot express press-and-move, so background drags always use
    /// pid-routed synthetic events when background delivery is selected.
    private func drag(_ step: MacroStep, macro: Macro, bg: Bool, target: ResolvedTarget) async {
        guard let start = resolvePoint(step, macro: macro) else { return }
        let end: CGPoint?
        if step.coordSpace == "window" {
            end = targetWindow(step, macro).map {
                CGPoint(x: $0.bounds.minX + (step.endLocalX ?? 0),
                        y: $0.bounds.minY + (step.endLocalY ?? 0))
            }
        } else if let ex = step.endX, let ey = step.endY {
            end = CGPoint(x: ex, y: ey)
        } else {
            end = nil
        }
        guard let end else { return }
        let button = MouseButton(rawValue: step.button ?? "left") ?? .left

        func deliver(_ type: CGEventType, _ x: Double, _ y: Double, clickState: Int) {
            poster.postMouseEvent(type, x: x, y: y, button: button,
                                  pid: target.pid, clickState: clickState,
                                  windowNumber: target.windowNumber)
        }

        if target.pid == nil {
            poster.warpCursor(x: start.x, y: start.y)
            poster.moveCursor(x: start.x, y: start.y)
        }
        let owner = runID
        heldMouse[button] = MousePress(owner: owner, point: start, target: target, button: button)
        deliver(Self.downEvent(for: button), start.x, start.y, clickState: 1)

        // Interpolation density scales inversely with speed at a fixed 10ms
        // cadence with a minimum number of interpolation steps.
        // While the button is held, apps expect *Dragged events — plain
        // mouseMoved reads as a hover and drags never engage.
        let dragMoveType: CGEventType = button == .right ? .rightMouseDragged
            : button == .middle ? .otherMouseDragged : .leftMouseDragged
        let stepCount = Self.interpolationSteps(speed: macro.speed)
        do {
            for i in 1...stepCount {
                try Task.checkCancellation()
                let t = Double(i) / Double(stepCount)
                let x = start.x + (end.x - start.x) * t
                let y = start.y + (end.y - start.y) * t
                heldMouse[button]?.point = CGPoint(x: x, y: y)
                deliver(dragMoveType, x, y, clickState: 1)
                let tick = step.holdMs > 0
                    ? min(86_400, Double(step.holdMs) / 1000 / max(0.05, macro.speed)) / Double(stepCount)
                    : 0.01
                try await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
            }
        } catch {
            // Cancelled mid-drag — the release below still runs so the
            // button never sticks down.
        }
        if let press = heldMouse[button], press.owner == owner {
            heldMouse.removeValue(forKey: button)
            deliver(Self.upEvent(for: button), press.point.x, press.point.y, clickState: 1)
        }
    }

    static func interpolationSteps(speed: Double) -> Int {
        max(5, Int((20.0 / max(0.05, speed)).rounded(.down)))
    }

    private func key(_ step: MacroStep, bg: Bool, macro: Macro, mode: ClickerConfig.DeliveryMode) async throws {
        let combo = step.key ?? ""
        let codes: [UInt16]
        if let chord = KeyChord(combo) {
            codes = chord.modifiers + [chord.key]
        } else {
            let parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty, parts.allSatisfy({ KeyCodeMap.isModifier(name: $0) }) else {
                throw PlaybackError("Invalid macro shortcut: \(combo)")
            }
            codes = parts.compactMap { KeyCodeMap.keycode(for: $0) }
        }
        let seconds = min(86_400, Double(max(0, step.holdMs)) / 1000.0 / max(0.05, macro.speed))
        await pressKeys(codes: codes, downOnly: step.type == "key_down", upOnly: step.type == "key_up", holdSeconds: seconds)
    }

    private func pressKeys(codes: [UInt16], downOnly: Bool, upOnly: Bool, holdSeconds: Double) async {
        let playbackID = runID
        let source = CGEventSource(stateID: .hidSystemState)
        var flags = heldKeys.keys.reduce(CGEventFlags()) { $0.union(Self.flag(forVirtual: $1)) }
        func post(_ code: UInt16, _ down: Bool) {
            if down {
                heldKeys[code] = playbackID
                flags.formUnion(Self.flag(forVirtual: code))
            } else {
                guard heldKeys[code] == playbackID else { return }
                heldKeys.removeValue(forKey: code)
                flags.subtract(Self.flag(forVirtual: code))
            }
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            event.flags = flags
            poster.post(event)
        }
        if !upOnly { for code in codes { post(code, true) } }
        if !upOnly && (!downOnly || holdSeconds > 0) {
            let duration = max(0.02, holdSeconds)
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        }
        if !downOnly { for code in codes.reversed() { post(code, false) } }
    }

    private func releaseHeldKeys() {
        let source = CGEventSource(stateID: .hidSystemState)
        var flags = heldKeys.keys.reduce(CGEventFlags()) { $0.union(Self.flag(forVirtual: $1)) }
        // Release ordinary keys before their modifiers.
        let codes = heldKeys.keys.sorted {
            let left = Self.flag(forVirtual: $0).isEmpty ? 0 : 1
            let right = Self.flag(forVirtual: $1).isEmpty ? 0 : 1
            return left == right ? $0 < $1 : left < right
        }
        for code in codes {
            flags.subtract(Self.flag(forVirtual: code))
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { continue }
            event.flags = flags
            poster.post(event)
        }
        heldKeys.removeAll()
    }

    private func releaseHeldMouse() {
        for press in heldMouse.values {
            poster.postMouseEvent(Self.upEvent(for: press.button), x: press.point.x, y: press.point.y,
                                  button: press.button, pid: press.target.pid, windowNumber: press.target.windowNumber)
        }
        heldMouse.removeAll()
    }

    private static func flag(forVirtual code: UInt16) -> CGEventFlags {
        switch code {
        case 55, 54: return .maskCommand
        case 59, 62: return .maskControl
        case 58, 61: return .maskAlternate
        case 56, 60: return .maskShift
        default: return []
        }
    }

    /// Unicode typing via event string payload (covers any character).
    private func typeText(_ text: String, pid: pid_t? = nil) async {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in text {
            if Task.isCancelled { return }
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
            let utf = Array(ch.utf16)
            down.keyboardSetUnicodeString(stringLength: utf.count, unicodeString: utf)
            up.keyboardSetUnicodeString(stringLength: utf.count, unicodeString: utf)
            down.flags = []; up.flags = []
            poster.post(down, pid: pid)
            poster.post(up, pid: pid)
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
        }
    }
}

private struct PlaybackError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
