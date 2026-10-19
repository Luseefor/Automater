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

        // Burst multipoint runs its own preflight + timed rounds below;
        // every other path keeps the classic one-point-per-interval loop.
        if config.action == .mouseClick, config.mode == .multipoint, config.multipointBurst {
            return await runBurst(config: config, onStatus: onStatus)
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

    // MARK: - Burst multipoint (~100ms rounds)

    /// One pinned burst point: exact pid+window pinned at preflight, live
    /// screen point refreshed from the window frame before each dispatch.
    private struct BurstPoint {
        var point: CGPoint
        var target: ResolvedTarget
        var spec: PointSpec
        var config: ClickerConfig
    }

    /// Fires all points as one timed burst per round. repeatCount counts
    /// full rounds; intervalMs pauses between rounds. No hard realtime
    /// promise: the engine dispatches ASAP with a monotonic clock and says
    /// so honestly if a round overruns. Cancellation is checked between
    /// points; every dispatched click is a balanced down/up pair.
    private func runBurst(
        config: ClickerConfig,
        onStatus: @escaping @Sendable (String) -> Void
    ) async -> String? {
        guard !config.multipoints.isEmpty else {
            return "No multi-points set"
        }
        var reportedIssues: Set<String> = []
        func reportOnce(_ msg: String) {
            guard !reportedIssues.contains(msg) else { return }
            reportedIssues.insert(msg)
            onStatus(msg)
        }
        // Preflight: resolve every point before the first input. Any
        // missing target stops the run with zero actions taken.
        var pinned: [BurstPoint] = []
        for spec in config.multipoints {
            guard let resolved = Self.resolvePointSpec(spec) else {
                return "Target window not found — clicking stopped"
            }
            var target = ResolvedTarget.none
            if config.backgroundToApp {
                target = Self.resolveBackgroundTarget(
                    pid: spec.pid ?? config.targetPid,
                    bundleId: spec.appBundleId ?? config.appBundleId,
                    appName: spec.appName ?? config.appName,
                    title: spec.windowTitle ?? config.windowTitle,
                    windowId: spec.windowId ?? config.targetWindowId
                )
                if target.pid == nil {
                    return "Background target not found — clicking stopped"
                }
            }
            var pointConfig = config
            pointConfig.appBundleId = spec.appBundleId ?? config.appBundleId
            pointConfig.appName = spec.appName ?? config.appName
            pointConfig.windowTitle = spec.windowTitle ?? config.windowTitle
            pinned.append(BurstPoint(point: resolved.point, target: target, spec: spec, config: pointConfig))
        }
        if pinned.count > 20 {
            reportOnce("Burst has \(pinned.count) points — a round may exceed the ~100ms target")
        }
        // Pre-warm every needed AX window before the first timed round.
        // Real poster only: injected postMouse tests skip live AX.
        if postMouse == nil, config.backgroundToApp, config.deliveryMode == .accessibility {
            var warmed = Set<String>()
            do {
                for pin in pinned {
                    guard let pid = pin.target.pid else { continue }
                    // Visible windows use the fast native event path, which
                    // needs no AX tree or startup animation delay.
                    if EventPoster.canRouteWindowBursts, let id = pin.target.windowNumber,
                       WindowScanner.windows(pid: pid, minSize: CGSize(width: 2, height: 2))
                        .contains(where: { $0.windowId == id && $0.isOnScreen }) { continue }
                    let key = "\(pid):\(pin.target.windowNumber ?? 0)"
                    if warmed.contains(key) { continue }
                    warmed.insert(key)
                    if let stop = try await warmBurstTarget(pid: pid, windowNumber: pin.target.windowNumber,
                                                           point: pin.point, config: pin.config, report: reportOnce) {
                        return stop
                    }
                }
            } catch {
                return nil
            }
        }
        let baseInterval = Double(max(1, config.intervalMs)) / 1000.0
        var rounds = 0
        while !Task.isCancelled {
            if config.repeatCount > 0 && rounds >= config.repeatCount { break }
            do {
                try Task.checkCancellation()
                // Validate the complete round before clicking its first point.
                // A minimized or unreachable later target must not leave a
                // predictable partial burst in the earlier windows.
                if postMouse == nil, config.backgroundToApp {
                    for pin in pinned {
                        try Task.checkCancellation()
                        if let error = burstTargetError(pin) { return error }
                    }
                }
                let roundStart = DispatchTime.now().uptimeNanoseconds
                for pin in pinned {
                    try Task.checkCancellation()
                    var point = pin.point
                    if config.backgroundToApp, let wn = pin.target.windowNumber {
                        guard let window = WindowScanner.windows(pid: pin.target.pid, minSize: CGSize(width: 2, height: 2)).first(where: { $0.windowId == wn }),
                              (pin.target.pid == nil || window.pid == pin.target.pid),
                              Self.matchesApp(window, bundleId: pin.config.appBundleId,
                                              appName: pin.config.appName) else {
                            return "Background target window closed — clicking stopped"
                        }
                        if !window.isOnScreen,
                           AXBridge.isWindowMinimized(appPID: window.pid, windowBounds: window.bounds) == true {
                            return "Background target window minimized — restore it, then start again"
                        }
                        if pin.spec.coordSpace == .window {
                            point = Self.localToScreen(localX: pin.spec.localX ?? 0,
                                                       localY: pin.spec.localY ?? 0, in: window)
                        }
                    } else if pin.spec.coordSpace == .window {
                        guard let resolved = Self.resolvePointSpec(pin.spec) else {
                            return "Target window not found — clicking stopped"
                        }
                        point = resolved.point
                    }
                    if let postMouse { postMouse(point, pin.target, pin.config) }
                    else if let error = deliver(point: point, target: pin.target, config: pin.config, report: reportOnce, burst: true) { return error }
                    clicksPerformed += 1
                    // Give Stop a chance to run between balanced click pairs,
                    // even when a burst has no interval between its points.
                    await Task.yield()
                }
                rounds += 1
                let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - roundStart) / 1_000_000)
                if elapsedMs > 100 {
                    reportOnce("Burst round took \(elapsedMs)ms (target ~100ms)")
                }
            } catch is CancellationError {
                break
            } catch {
                Self.log.error("click loop error: \(error.localizedDescription, privacy: .public)")
                Diagnostics.record("clicker_error", "The click loop ended unexpectedly")
                onStatus("Clicker error: \(error.localizedDescription)")
                break
            }
            if config.repeatCount > 0 && rounds >= config.repeatCount { break }
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

    private func burstTargetError(_ pin: BurstPoint) -> String? {
        guard let pid = pin.target.pid else { return "Background target not found — clicking stopped" }
        guard let id = pin.target.windowNumber else { return nil }
        guard let window = WindowScanner.windows(pid: pid, minSize: CGSize(width: 2, height: 2))
            .first(where: { $0.windowId == id && $0.pid == pid
                && Self.matchesApp($0, bundleId: pin.config.appBundleId, appName: pin.config.appName) }) else {
            return "Background target window closed — clicking stopped"
        }
        let point = pin.spec.coordSpace == .window
            ? Self.localToScreen(localX: pin.spec.localX ?? 0, localY: pin.spec.localY ?? 0, in: window)
            : pin.point
        guard window.bounds.contains(point) else { return "Point is outside its target window — re-pick it" }
        if window.isOnScreen {
            if pin.config.deliveryMode == .events && !EventPoster.canRouteWindowBursts {
                return "Fast background clicks are unavailable here — choose Accessibility or Foreground"
            }
            return nil
        }
        if AXBridge.isWindowMinimized(appPID: pid, windowBounds: window.bounds) == true {
            return "Background target window minimized — restore it, then start again"
        }
        if AXBridge.hasQueryableWindow(appPID: pid, x: point.x, y: point.y, windowBounds: window.bounds) { return nil }
        guard pin.config.clickKind == .single, pin.config.button == .left,
              pin.config.deliveryMode == .accessibility,
              AXBridge.hasCachedPressable(windowNumber: id, pid: pid, x: point.x, y: point.y,
                                         expectedFrame: window.bounds, bundleId: pin.config.appBundleId,
                                         ownerName: pin.config.appName) else {
            return "Background target cannot accept this burst on another Space — open its window here, then start again"
        }
        return nil
    }

    /// One target's readiness probe, shared by every burst round's pre-warm.
    /// Nil when ready (or cached); a stop message when the target is gone.
    private func warmBurstTarget(
        pid: pid_t, windowNumber: Int?, point: CGPoint,
        config: ClickerConfig, report: (String) -> Void
    ) async throws -> String? {
        if !AXBridge.hasAXWindows(appPID: pid) {
            report("Target exposes no accessibility — if clicks don't land, turn off background delivery")
        }
        AXBridge.enableAccessibility(appPID: pid)
        if config.button == .left, let wn = windowNumber,
           let window = WindowScanner.windows(pid: pid, minSize: CGSize(width: 2, height: 2)).first(where: { $0.windowId == wn }),
           AXBridge.hasCachedPressable(windowNumber: wn, pid: pid, x: point.x, y: point.y,
                                       expectedFrame: window.bounds, bundleId: config.appBundleId,
                                       ownerName: config.appName) {
            return nil
        }
        for _ in 0..<20 {
            let bounds: CGRect?
            if let id = windowNumber {
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
        try Task.checkCancellation()
        return nil
    }

    /// Delivers one click. AX misses (fully-covered windows in AX-hostile
    /// apps) automatically fall back to pid-routed synthetic events.
    /// Nil on delivery (or AXPress-backed single-press fallback); a message
    /// when the run must stop. Native double/triple click counts are never
    /// faked as repeated AXPresses off-Space.
    private func deliver(
        point: CGPoint, target: ResolvedTarget, config: ClickerConfig,
        report: (String) -> Void, burst: Bool = false
    ) -> String? {
        if config.backgroundToApp {
            guard let pid = target.pid else { return nil }
            // AXPress may synchronously animate a native button for ~150ms.
            // On this Space, a burst uses balanced window-routed events so
            // that per-control animations do not serialize the whole burst.
            if burst, EventPoster.canRouteWindowBursts, let id = target.windowNumber,
               let window = WindowScanner.windows(pid: pid, minSize: CGSize(width: 2, height: 2))
                .first(where: { $0.windowId == id && $0.isOnScreen }) {
                poster.burstBackgroundClick(x: point.x, y: point.y, pid: pid,
                                            windowNumber: window.windowId,
                                            button: config.button, kind: config.clickKind,
                                            windowBounds: window.bounds)
                return nil
            }
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
                if burst {
                    poster.burstBackgroundClick(
                        x: point.x, y: point.y,
                        pid: pid,
                        childPIDs: Array(children.dropFirst()),
                        windowNumber: target.windowNumber,
                        button: config.button,
                        kind: config.clickKind
                    )
                } else {
                    poster.backgroundClick(
                        x: point.x, y: point.y,
                        pid: pid,
                        childPIDs: Array(children.dropFirst()),
                        windowNumber: target.windowNumber,
                        button: config.button,
                        kind: config.clickKind
                    )
                }
                Self.log.info("AX unreachable at (\(Int(point.x)),\(Int(point.y))) pid \(pid) — routed synthetic-event fallback")
                report("Using window-routed events for this control")
            case .events:
                let children = AXBridge.hitTestPIDs(appPID: pid, x: point.x, y: point.y)
                if burst {
                    poster.burstBackgroundClick(
                        x: point.x, y: point.y,
                        pid: pid,
                        childPIDs: Array(children.dropFirst()),
                        windowNumber: target.windowNumber,
                        button: config.button,
                        kind: config.clickKind
                    )
                } else {
                    poster.backgroundClick(
                        x: point.x, y: point.y,
                        pid: pid,
                        childPIDs: Array(children.dropFirst()),
                        windowNumber: target.windowNumber,
                        button: config.button,
                        kind: config.clickKind
                    )
                }
            }
        } else if burst {
            poster.burstForegroundClick(
                x: point.x, y: point.y,
                button: config.button,
                kind: config.clickKind
            )
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
