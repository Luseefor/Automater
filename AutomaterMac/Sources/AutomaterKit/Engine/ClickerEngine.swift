import CoreGraphics
import Foundation
import os

/// Outcome of resolving a background delivery destination.
public struct ResolvedTarget: Sendable, Equatable {
    public var pid: pid_t?
    public var windowNumber: Int?

    static let none = ResolvedTarget(pid: nil, windowNumber: nil)
}

/// Background clicker worker: current-cursor, fixed-point, and multi-point
/// modes with true pointer-free background delivery.
public actor ClickerEngine {

    private static let log = Logger(
        subsystem: "com.luseefor.automater", category: "engine"
    )

    public private(set) var isRunning = false
    public private(set) var clicksPerformed = 0

    private var task: Task<Void, Never>?
    private var runID = UUID()
    private let poster = EventPoster()
    private var postMouse: (@Sendable (CGPoint, ResolvedTarget, ClickerConfig) -> Void)?
    private var cursorLocation: @Sendable () -> CGPoint = { EventPoster.cursorLocation }
    private let postKey: @Sendable (String, pid_t?) -> Bool
    public init() {
        postKey = { EventPoster().keyCombo($0, pid: $1) }
    }

    init(postKey: @escaping @Sendable (String, pid_t?) -> Bool) {
        self.postKey = postKey
    }

    init(postMouse: @escaping @Sendable (CGPoint, ResolvedTarget, ClickerConfig) -> Void,
         cursorLocation: @escaping @Sendable () -> CGPoint = { EventPoster.cursorLocation }) {
        self.postMouse = postMouse
        self.cursorLocation = cursorLocation
        postKey = { EventPoster().keyCombo($0, pid: $1) }
    }

    public nonisolated var isBusy: Bool {
        get async { await isRunning }
    }

    public func start(
        config: ClickerConfig,
        onStatus: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        stop(silent: true)
        if config.action == .keyPress, KeyChord(config.keyCombo) == nil {
            onStatus("Choose a valid key or shortcut")
            return
        }
        clicksPerformed = 0
        isRunning = true
        let runID = UUID()
        self.runID = runID
        let name = config.action == .keyPress ? "Keyboard repeat" : "Clicker"
        onStatus(name + " ON" + (config.backgroundToApp ? " (background app)" : ""))

        task = Task { [weak self] in
            guard let self else { return }
            let error = await self.runLoop(config: config, onStatus: onStatus)
            await self.finish(runID: runID, status: error ?? name + " OFF", onStatus: onStatus)
        }
    }

    public func stop(silent: Bool = false) {
        task?.cancel()
        task = nil
        runID = UUID()
        if isRunning {
            isRunning = false
            if !silent { /* status emitted by loop teardown */ }
        }
    }

    private func finish(runID: UUID, status: String,
                        onStatus: @Sendable (String) -> Void) {
        guard self.runID == runID else { return }
        isRunning = false
        task = nil
        onStatus(status)
    }

    // MARK: - Loop

    private func runLoop(
        config: ClickerConfig,
        onStatus: @escaping @Sendable (String) -> Void
    ) async -> String? {
        let baseInterval = Double(max(1, config.intervalMs)) / 1000.0
        var done = 0
        var pointIndex = 0
        var didWarmUp = false
        // A background run never follows the user's live pointer.
        let initialPoint = config.action == .mouseClick && config.mode == .currentCursor
            && config.backgroundToApp ? cursorLocation() : nil
        // Report each distinct delivery issue once per session (no spam).
        var reportedIssues: Set<String> = []
        func reportOnce(_ msg: String) {
            guard !reportedIssues.contains(msg) else { return }
            reportedIssues.insert(msg)
            onStatus(msg)
        }

        while !Task.isCancelled {
            if config.repeatCount > 0 && done >= config.repeatCount { break }

            do {
                try Task.checkCancellation()

                if config.action == .keyPress {
                    if config.backgroundToApp && config.targetPid == nil && config.appBundleId == nil
                        && config.appName == nil && config.targetWindowId == nil {
                        return "Choose a background target before starting keyboard repeat"
                    }
                    let target = config.backgroundToApp ? Self.resolveBackgroundTarget(
                        pid: config.targetPid, bundleId: config.appBundleId,
                        appName: config.appName, title: config.windowTitle,
                        windowId: config.targetWindowId
                    ) : .none
                    if config.backgroundToApp && target.pid == nil {
                        return "Background target not found — keyboard repeat stopped"
                    }
                    guard postKey(config.keyCombo, target.pid) else {
                        return "Unable to send keyboard shortcut"
                    }
                } else {
                    var resolvedPoint: CGPoint?
                    var bgTarget = ResolvedTarget.none
                    var selectedSpec: PointSpec?

                    switch config.mode {
                    case .currentCursor:
                        let loc = initialPoint ?? cursorLocation()
                        resolvedPoint = CGPoint(x: loc.x, y: loc.y)
                        if config.backgroundToApp {
                            bgTarget = Self.resolveBackgroundTarget(
                                pid: config.targetPid,
                                bundleId: config.appBundleId,
                                appName: config.appName,
                                title: config.windowTitle,
                                windowId: config.targetWindowId
                            )
                        }

                    case .fixedPoint:
                        if let p = Self.resolveFixedPoint(config: config) {
                            resolvedPoint = p.point
                            if config.backgroundToApp {
                                bgTarget = Self.resolveBackgroundTarget(
                                    pid: config.targetPid,
                                    bundleId: config.appBundleId,
                                    appName: config.appName,
                                    title: config.windowTitle,
                                    windowId: config.targetWindowId ?? config.fixedWindowId
                                )
                            }
                        } else {
                            return "Target window not found — clicking stopped"
                        }

                    case .multipoint:
                        guard !config.multipoints.isEmpty else {
                            return "No multi-points set"
                        }
                        let spec = config.multipoints[pointIndex % config.multipoints.count]
                        pointIndex += 1
                        selectedSpec = spec
                        if let p = Self.resolvePointSpec(spec) {
                            resolvedPoint = p.point
                            if config.backgroundToApp {
                                bgTarget = Self.resolveBackgroundTarget(
                                    pid: spec.pid ?? config.targetPid,
                                    bundleId: spec.appBundleId ?? config.appBundleId,
                                    appName: spec.appName ?? config.appName,
                                    title: spec.windowTitle ?? config.windowTitle,
                                    windowId: spec.windowId ?? config.targetWindowId
                                )
                            }
                        } else {
                            return "Target window not found — clicking stopped"
                        }
                    }

                    if config.backgroundToApp && bgTarget.pid == nil {
                        return "Background target not found — clicking stopped"
                    }
                    guard var point = resolvedPoint else {
                        return "Click point not found — clicking stopped"
                    }

                    // Chromium-family apps build their AX tree lazily on first
                    // query; poke until an element resolves (max ~3s) so neither
                    // AX presses nor event routing get swallowed. The flags are
                    // safe for native apps too (verified: Calculator keeps its
                    // tree) — the poke must always run or lazy trees never build.
                    if postMouse == nil, config.backgroundToApp, let pid = bgTarget.pid, !didWarmUp {
                        didWarmUp = true
                        if !AXBridge.hasAXWindows(appPID: pid) {
                            reportOnce("Target exposes no accessibility — if clicks don't land, turn off background delivery")
                        }
                        AXBridge.enableAccessibility(appPID: pid)
                        // Exact cached ref (primed by recording/target pick)
                        // skips the tree probe: off-Space trees never build.
                        var skipProbe = false
                        if config.button == .left,
                           let wn = bgTarget.windowNumber, let p = resolvedPoint,
                           let w = WindowScanner.windows(pid: pid, minSize: CGSize(width: 2, height: 2)).first(where: { $0.windowId == wn }),
                           AXBridge.hasCachedPressable(windowNumber: wn, pid: pid, x: p.x, y: p.y,
                                                       expectedFrame: w.bounds, bundleId: config.appBundleId,
                                                       ownerName: config.appName) {
                            skipProbe = true
                        }
                        if !skipProbe {
                            for _ in 0..<20 {
                                let bounds: CGRect?
                                if let id = bgTarget.windowNumber {
                                    guard let window = WindowScanner.windows(pid: pid, minSize: CGSize(width: 2, height: 2)).first(where: { $0.windowId == id }) else {
                                        return "Background target window closed — clicking stopped"
                                    }
                                    if !window.isOnScreen,
                                       AXBridge.isWindowMinimized(appPID: pid, windowBounds: window.bounds) == true {
                                        return "Background target window minimized — restore it, then start again"
                                    }
                                    bounds = window.bounds
                                } else { bounds = nil }
                                let ready = config.deliveryMode == .accessibility
                                    ? AXBridge.hasPressableElementAt(appPID: pid, x: point.x, y: point.y, windowBounds: bounds)
                                    : AXBridge.hasElementAt(appPID: pid, x: point.x, y: point.y)
                                if ready { break }
                                try await Task.sleep(nanoseconds: 150_000_000)
                                try Task.checkCancellation()
                            }
                            try await Task.sleep(nanoseconds: 300_000_000)
                        }
                        try Task.checkCancellation()
                    }

                    if config.backgroundToApp, let id = bgTarget.windowNumber {
                        guard let window = WindowScanner.windows(pid: bgTarget.pid, minSize: CGSize(width: 2, height: 2)).first(where: { $0.windowId == id }) else {
                            return "Background target window closed — clicking stopped"
                        }
                        if !window.isOnScreen,
                           AXBridge.isWindowMinimized(appPID: window.pid, windowBounds: window.bounds) == true {
                            return "Background target window minimized — restore it, then start again"
                        }
                        // Warm-up can suspend this task. Reapply local offsets
                        // to the live frame immediately before sending input.
                        if config.mode == .fixedPoint && config.fixedCoordSpace == .window {
                            point = Self.localToScreen(localX: config.fixedLocalX, localY: config.fixedLocalY, in: window)
                        } else if let spec = selectedSpec, spec.coordSpace == .window {
                            point = Self.localToScreen(localX: spec.localX ?? 0, localY: spec.localY ?? 0, in: window)
                        }
                    }
                    if let postMouse { postMouse(point, bgTarget, config) }
                    else if let error = deliver(point: point, target: bgTarget, config: config, report: reportOnce) { return error }
                }
                clicksPerformed += 1
                done += 1
            } catch is CancellationError {
                break
            } catch {
                Self.log.error("click loop error: \(error.localizedDescription, privacy: .public)")
                Diagnostics.record("clicker_error", "The click loop ended unexpectedly")
                onStatus("Clicker error: \(error.localizedDescription)")
                break
            }

            if config.repeatCount > 0 && done >= config.repeatCount { break }

            // Interval with jitter, cancellable. Task.sleep only throws on
            // cancellation here.
            var wait = baseInterval
            if config.jitterMs > 0 {
                wait += Double(Int.random(in: -config.jitterMs...config.jitterMs)) / 1000.0
                wait = max(0.001, wait)
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch {
                break
            }
        }
        return nil
    }

    /// Delivers one click. AX misses (fully-covered windows in AX-hostile
    /// apps) automatically fall back to pid-routed synthetic events.
    /// Nil on delivery (or AXPress-backed single-press fallback); a message
    /// when the run must stop. Native double/triple click counts are never
    /// faked as repeated AXPresses off-Space.
    private func deliver(
        point: CGPoint, target: ResolvedTarget, config: ClickerConfig,
        report: (String) -> Void
    ) -> String? {
        if config.backgroundToApp {
            guard let pid = target.pid else { return nil }
            if config.clickKind.presses > 1, let wn = target.windowNumber,
               let w = WindowScanner.windows(pid: pid, minSize: CGSize(width: 2, height: 2)).first(where: { $0.windowId == wn }),
               !w.isOnScreen,
               !AXBridge.hasQueryableWindow(appPID: pid, x: point.x, y: point.y, windowBounds: w.bounds) {
                return "Background double/triple click on another Space is not supported — run it on this Space"
            }
            // Verified AX support is LEFT clicks only (axClick refuses
            // right/middle): those would fall through to dropped raw events.
            if config.button != .left,
               let w = WindowScanner.windows(pid: pid, minSize: CGSize(width: 2, height: 2)).first(where: { $0.windowId == target.windowNumber }),
               !w.isOnScreen,
               !AXBridge.hasQueryableWindow(appPID: pid, x: point.x, y: point.y, windowBounds: w.bounds) {
                return "Background right/middle click on another Space is not supported — run it on this Space"
            }
            // Same honest gate as MacroEngine: off-Space with no live AX
            // window is unreachable (raw routed events are dropped there).
            // The cache exception is accessibility-only — .events delivery
            // never consults it. postMouse-injected tests bypass deliver
            // entirely, so fake-pid semantics tests are unaffected.
            if let wn = target.windowNumber,
               let w = WindowScanner.windows(pid: pid, minSize: CGSize(width: 2, height: 2)).first(where: { $0.windowId == wn }),
               !w.isOnScreen,
               !AXBridge.hasQueryableWindow(appPID: pid, x: point.x, y: point.y, windowBounds: w.bounds),
               !(config.deliveryMode == .accessibility && config.button == .left
                 && AXBridge.hasCachedPressable(windowNumber: wn, pid: pid, x: point.x, y: point.y,
                                                expectedFrame: w.bounds, bundleId: config.appBundleId,
                                                ownerName: config.appName)) {
                return "Background target is on another Space and cannot be reached — open its window on this Space once, then start again"
            }
            switch config.deliveryMode {
            case .accessibility:
                let landed = poster.axClick(x: point.x, y: point.y, pid: pid,
                                            button: config.button, kind: config.clickKind,
                                            windowNumber: target.windowNumber,
                                            bundleId: config.appBundleId, ownerName: config.appName)
                if landed { return nil }
                // An AX miss can be specific to this control or a temporary
                // layout change. Try AX again next time instead of disabling
                // it permanently for every window of the app.
                // Tier 2: route synthetic events into the process — reaches
                // covered windows that expose no pressable AX elements.
                let children = AXBridge.hitTestPIDs(appPID: pid, x: point.x, y: point.y)
                poster.backgroundClick(
                    x: point.x, y: point.y,
                    pid: pid,
                    childPIDs: Array(children.dropFirst()),
                    windowNumber: target.windowNumber,
                    button: config.button,
                    kind: config.clickKind
                )
                Self.log.info("AX unreachable at (\(Int(point.x)),\(Int(point.y))) pid \(pid) — routed synthetic-event fallback")
                report("Using window-routed events for this control")
            case .events:
                let children = AXBridge.hitTestPIDs(appPID: pid, x: point.x, y: point.y)
                poster.backgroundClick(
                    x: point.x, y: point.y,
                    pid: pid,
                    childPIDs: Array(children.dropFirst()),
                    windowNumber: target.windowNumber,
                    button: config.button,
                    kind: config.clickKind
                )
            }
        } else {
            poster.foregroundClick(
                x: point.x, y: point.y,
                button: config.button,
                kind: config.clickKind
            )
        }
        return nil
    }

    // MARK: - Point resolution (static: no isolation needed)

    /// Returns (screenPoint, windowUsedForLocalResolution).
    static func resolveFixedPoint(config: ClickerConfig) -> (point: CGPoint, window: WindowInfo?)? {
        if config.fixedCoordSpace == .window {
            let window = pointWindow(bundleId: config.appBundleId, appName: config.appName,
                                     title: config.windowTitle, windowId: config.fixedWindowId)
            guard let window else { return nil }
            let p = localToScreen(
                localX: config.fixedLocalX, localY: config.fixedLocalY, in: window
            )
            return (p, window)
        }
        return (CGPoint(x: config.fixedScreenX, y: config.fixedScreenY), nil)
    }

    static func resolvePointSpec(_ spec: PointSpec) -> (point: CGPoint, window: WindowInfo?)? {
        if spec.coordSpace == .window {
            let window = pointWindow(bundleId: spec.appBundleId, appName: spec.appName,
                                     title: spec.windowTitle, windowId: spec.windowId)
            guard let window else { return nil }
            let lx = spec.localX ?? 0
            let ly = spec.localY ?? 0
            return (localToScreen(localX: lx, localY: ly, in: window), window)
        }
        if let x = spec.x, let y = spec.y {
            return (CGPoint(x: x, y: y), nil)
        }
        return nil
    }

    static func localToScreen(localX: Double, localY: Double, in window: WindowInfo) -> CGPoint {
        CGPoint(x: window.bounds.minX + localX, y: window.bounds.minY + localY)
    }

    private static func pointWindow(bundleId: String?, appName: String?, title: String?, windowId: Int?) -> WindowInfo? {
        if let id = windowId, id > 0 {
            // No isOnScreen filter: other-Space windows keep valid bounds and
            // must keep resolving; minimized ones are rejected at run time.
            // The id must still belong to the recorded app — never resolve a
            // recycled id owned by another process.
            return WindowScanner.allWindows(minSize: CGSize(width: 2, height: 2))
                .first { $0.windowId == id && matchesApp($0, bundleId: bundleId, appName: appName) }
        }
        guard bundleId != nil || appName != nil || title != nil else { return nil }
        return WindowScanner.findWindow(bundleId: bundleId, appName: appName, windowTitle: title)
    }

    /// Same app-identity rule as MacroEngine.resolveWindow: a bundle-id (or,
    /// failing that, an app-name) match is required; with neither given, any
    /// owner is accepted (legacy pid-only targets).
    private static func matchesApp(_ window: WindowInfo, bundleId: String?, appName: String?) -> Bool {
        if let bundleId { return window.bundleId == bundleId }
        if let appName { return window.ownerName.caseInsensitiveCompare(appName) == .orderedSame }
        return true
    }

    /// An explicitly chosen window must still exist. Never redirect a closed
    /// window's run to another window or the user's foreground app.
    public static func resolveBackgroundTarget(
        pid: Int?, bundleId: String?, appName: String?, title: String?, windowId: Int?
    ) -> ResolvedTarget {
        if let id = windowId, id > 0 {
            // No isOnScreen filter: an id on another Space must keep
            // resolving (same flag value as minimized, distinguished at run
            // time via AX). A vanished id — or one now owned by another app
            // — is treated as closed. Never redirect.
            guard let window = WindowScanner.allWindows(minSize: CGSize(width: 2, height: 2))
                .first(where: { $0.windowId == id && matchesApp($0, bundleId: bundleId, appName: appName) }),
                  pid == nil || Int(window.pid) == pid else { return .none }
            return ResolvedTarget(pid: window.pid, windowNumber: window.windowId)
        }
        if let pid {
            guard pid > 0, kill(pid_t(pid), 0) == 0 else { return .none }
            return ResolvedTarget(pid: pid_t(pid), windowNumber: WindowScanner.windows(pid: pid_t(pid), minSize: CGSize(width: 2, height: 2)).first?.windowId)
        }
        guard bundleId != nil || appName != nil || title != nil else { return .none }
        if let window = WindowScanner.findWindow(bundleId: bundleId, appName: appName, windowTitle: title) {
            return ResolvedTarget(pid: window.pid, windowNumber: window.windowId)
        }
        return .none
    }
}
