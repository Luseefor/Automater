import ApplicationServices
import AppKit
import Foundation

/// Accessibility trust checks and point→pid hit-testing.
public enum AXBridge {

    public static var isTrustedForAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Opens System Settings → Privacy & Security → Accessibility directly.
    /// More reliable than the legacy API prompt, which ad-hoc-signed apps
    /// often never see.
    @discardableResult
    public static func openAccessibilitySettings() -> Bool {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Returns current trust state and lands the user on the Accessibility
    /// pane so they can grant immediately.
    @discardableResult
    public static func requestAccessibilityPrompt() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted { openAccessibilitySettings() }
        return trusted
    }

    /// PIDs that should receive an event at this point: the app pid plus the
    /// renderer/child pid when the AX hit lands in web content (WebKit,
    /// Chromium).
    public static func hitTestPIDs(appPID: pid_t, x: CGFloat, y: CGFloat) -> [pid_t] {
        var pids: [pid_t] = [appPID]
        let appElement = AXUIElementCreateApplication(appPID)
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(appElement, Float(x), Float(y), &element)
        guard err == .success, let element else { return pids }

        var ownerPid: pid_t = 0
        if AXUIElementGetPid(element, &ownerPid) == .success,
           ownerPid != 0, ownerPid != appPID {
            pids.append(ownerPid)
        }
        return pids
    }

    /// Forces Chromium/Electron-family apps to build their full web
    /// accessibility tree. Safe to call unconditionally — verified that both
    /// flags together leave native apps (Calculator) intact. The earlier
    /// "tree wipe" observation was an inactive-Space measurement artifact.
    public static func enableAccessibility(appPID: pid_t) {
        let appElement = AXUIElementCreateApplication(appPID)
        let value = kCFBooleanTrue as CFTypeRef
        // Chromium honors AXEnhancedUserInterface; Electron honors
        // AXManualAccessibility. Set both, ignore which applies.
        AXUIElementSetAttributeValue(
            appElement, "AXEnhancedUserInterface" as CFString, value
        )
        AXUIElementSetAttributeValue(
            appElement, "AXManualAccessibility" as CFString, value
        )
    }

    /// True once the app's AX tree resolves any element at this point — used
    /// to detect lazily-built trees (Chromium builds one only after a query).
    /// Falls back to frame containment for occluded/other-Space windows where
    /// position hit-testing reports nothing.
    public static func hasElementAt(appPID: pid_t, x: CGFloat, y: CGFloat) -> Bool {
        let appElement = AXUIElementCreateApplication(appPID)
        var element: AXUIElement?
        if AXUIElementCopyElementAtPosition(appElement, Float(x), Float(y), &element) == .success,
           element != nil {
            return true
        }
        return windowContaining(appPID: appPID, x: x, y: y) != nil
    }

    /// Readiness probe that does not press a control. A window frame alone
    /// is not enough: Chromium may expose it before its page tree is ready.
    public static func hasPressableElementAt(appPID: pid_t, x: CGFloat, y: CGFloat, windowBounds: CGRect? = nil) -> Bool {
        guard let window = windowContaining(appPID: appPID, x: x, y: y, matching: windowBounds) else { return false }
        return searchPressable(window, x: x, y: y, depth: 0) != nil
    }

    /// False when the app exposes no AX windows. Such apps can ignore both
    /// AXPress and pid-routed synthetic events, so foreground delivery may be
    /// required.
    public static func hasAXWindows(appPID: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(appPID)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
           (value as? [AXUIElement])?.isEmpty == false { return true }
        var focused: CFTypeRef?
        return AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success
            && focused.map { CFGetTypeID($0) == AXUIElementGetTypeID() } == true
    }

    /// Minimized-or-not for one app window, used to tell a minimized (Dock)
    /// target — which background input cannot reach — apart from a window
    /// that merely sits on another Space (deliverable via AX / routed
    /// events, like any covered window). Returns nil when the state cannot
    /// be determined (AX untrusted, AX-hostile app, no matching window):
    /// callers must attempt delivery rather than report either outcome.
    public static func isWindowMinimized(appPID: pid_t, windowBounds: CGRect?) -> Bool? {
        let app = AXUIElementCreateApplication(appPID)
        var listed: [AXUIElement] = []
        var cfWindows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &cfWindows) == .success,
           let windows = cfWindows as? [AXUIElement] { listed = windows }
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let ref = focusedRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let focused = unsafeDowncast(ref, to: AXUIElement.self)
            if !listed.contains(where: { $0 == focused }) { listed.append(focused) }
        }
        guard !listed.isEmpty else { return nil }
        var candidates = listed
        if let bounds = windowBounds {
            let matched = listed.filter { window in
                guard let frame = axFrame(window) else { return false }
                return abs(frame.minX - bounds.minX) < 2 && abs(frame.minY - bounds.minY) < 2
                    && abs(frame.width - bounds.width) < 2 && abs(frame.height - bounds.height) < 2
            }
            if !matched.isEmpty { candidates = matched }
            else if listed.count != 1 { return nil }
        }
        var decided = false
        for window in candidates {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref) == .success,
                  let minimized = ref as? Bool else { continue }
            decided = true
            if !minimized { return false }
        }
        return decided ? true : nil
    }

    /// Human-readable dump of the AX element chain at a point (debugging).
    public static func describeElementAt(appPID: pid_t, x: CGFloat, y: CGFloat) -> String {
        let appElement = AXUIElementCreateApplication(appPID)
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(appElement, Float(x), Float(y), &element)
        guard err == .success, let start = element else {
            return "no element (err \(err.rawValue))"
        }
        var lines: [String] = []
        var current = start
        for depth in 0..<8 {
            let role = stringAttr(current, kAXRoleAttribute)
            let title = stringAttr(current, kAXTitleAttribute)
            let label = stringAttr(current, kAXDescriptionAttribute)
            var actions: CFArray?
            let acts = (AXUIElementCopyActionNames(current, &actions) == .success)
                ? ((actions as? [String])?.joined(separator: ",")) ?? "" : "err"
            lines.append("\(depth): role=\(role) title='\(title)' desc='\(label)' actions=[\(acts)]")
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            current = unsafeDowncast(p, to: AXUIElement.self)
        }
        return lines.joined(separator: "\n")
    }

    private static func stringAttr(_ el: AXUIElement, _ name: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success,
              let s = v as? String else { return "" }
        return s
    }

    /// True background click: perform the AXPress action on the element under
    /// the point (walking ancestors when the hit surface itself isn't
    /// pressable). Works regardless of window focus or event routing.
    ///
    /// Position hit-testing fails for occluded/other-Space windows in many
    /// apps, so a miss falls back to walking the AX tree by frame — the tree
    /// is queryable even when the window isn't composited on top.
    @discardableResult
    public static func pressAt(appPID: pid_t, x: CGFloat, y: CGFloat, windowBounds: CGRect? = nil,
                               windowNumber: Int? = nil, bundleId: String? = nil, ownerName: String? = nil) -> Bool {
        if let windowBounds {
            if let window = windowContaining(appPID: appPID, x: x, y: y, matching: windowBounds),
               let element = searchPressable(window, x: x, y: y, depth: 0),
               pressAncestorChain(from: element) {
                return true
            }
            // Live tree miss (e.g. window on another Space: kAXWindows goes
            // empty). Fall back to an exact ref primed while the window was
            // visible — never to an arbitrary sibling.
            if let windowNumber,
               pressCachedButton(windowNumber: windowNumber, pid: appPID, x: x, y: y,
                                 expectedFrame: windowBounds, bundleId: bundleId, ownerName: ownerName) {
                return true
            }
            return false
        }
        let appElement = AXUIElementCreateApplication(appPID)
        var element: AXUIElement?
        if AXUIElementCopyElementAtPosition(appElement, Float(x), Float(y), &element) == .success,
           let start = element,
           pressAncestorChain(from: start) {
            return true
        }

        // Cached element from a previous tree-walk at (roughly) this point?
        let cacheKey = CacheKey(pid: appPID, cx: Int(x / 8), cy: Int(y / 8))
        cacheLock.lock()
        let cached = elementCache[cacheKey]
        cacheLock.unlock()
        if let cached {
            if pressAncestorChain(from: cached) { return true }
            cacheLock.lock()
            elementCache[cacheKey] = nil
            cacheLock.unlock()
        }

        guard let found = treeWalkPressable(appPID: appPID, x: x, y: y),
              pressAncestorChain(from: found) else { return false }
        cacheLock.lock()
        elementCache[cacheKey] = found
        cacheLock.unlock()
        return true
    }

    private struct CacheKey: Hashable {
        let pid: pid_t
        let cx: Int
        let cy: Int
    }

    private static let cacheLock = NSLock()
    private static var elementCache: [CacheKey: AXUIElement] = [:]

    // MARK: - Exact-window AX reference cache (off-Space delivery)

    /// A live AX window/button pair captured while the window was on the
    /// current Space (recording click, target pick). macOS drops
    /// non-focused windows from kAXWindows on other Spaces, but a retained
    /// AXUIElementRef keeps resolving (verified native probe: AXPress on a
    /// cached ref succeeds with the covering app fullscreen).
    private struct CachedAXButton {
        let element: AXUIElement
        let frame: CGRect
        let seq: UInt64
    }

    private struct CachedAXWindow {
        let window: AXUIElement
        let frame: CGRect
        let bundleId: String?
        let ownerName: String
        let title: String
        var buttons: [CachedAXButton]
        var seq: UInt64
    }

    private static let axWindowCacheLock = NSLock()
    private static var axWindowCache: [String: CachedAXWindow] = [:]
    private static var axWindowCacheSeq: UInt64 = 0
    private static let axWindowCacheMaxWindows = 32
    private static let axWindowCacheMaxButtons = 16

    private static func axWindowCacheKey(pid: pid_t, windowNumber: Int) -> String {
        "\(pid):\(windowNumber)"
    }

    private static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    /// Prime the cache from a live user click (or target pick) while the AX
    /// tree is queryable. Resolution order: real click hit → focused window
    /// with matching frame → frame-unique kAXWindows match. Anything
    /// ambiguous primes nothing. No-ops silently when AX is unavailable.
    /// Dedicated serial queue for cache priming: slow AX tree queries (e.g.
    /// Brave) must never block the CG event-tap callback — a stalled tap
    /// corrupts Date-based hold measurement (short click misread as hold)
    /// — nor the main UI. Values captured are plain Sendables; the shared
    /// cache is NSLock-protected. Prime itself stays synchronous for
    /// contexts that explicitly need it.
    private static let axPrimeQueue = DispatchQueue(label: "com.luseefor.automater.ax-prime",
                                                    qos: .userInitiated)

    /// Async enqueue wrapper for event-tap / UI call sites. Record → Save →
    /// Space leaves ~1s for prep; if priming is slow or unavailable the
    /// existing honest cache-miss stop applies at play time.
    public static func enqueuePrimeWindowCache(windowNumber: Int, pid: pid_t, bundleId: String?,
                                               ownerName: String, title: String, at point: CGPoint,
                                               windowBounds: CGRect) {
        guard pid > 0, kill(pid, 0) == 0 else { return }
        axPrimeQueue.async {
            primeWindowCache(windowNumber: windowNumber, pid: pid, bundleId: bundleId,
                             ownerName: ownerName, title: title, at: point,
                             windowBounds: windowBounds)
        }
    }

    public static func primeWindowCache(windowNumber: Int, pid: pid_t, bundleId: String?,
                                        ownerName: String, title: String, at point: CGPoint,
                                        windowBounds: CGRect) {
        guard pid > 0, kill(pid, 0) == 0 else { return }
        let app = AXUIElementCreateApplication(pid)
        var windowRef: AXUIElement?
        var element: AXUIElement?
        if AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success,
           let start = element {
            windowRef = ancestorWindow(of: start)
        }
        if windowRef == nil {
            let candidates = axWindows(of: app).filter { w in
                guard let f = axFrame(w) else { return false }
                return framesMatch(f, windowBounds)
            }
            if candidates.count == 1 { windowRef = candidates.first }
        }
        guard let windowRef, let liveFrame = axFrame(windowRef),
              framesMatch(liveFrame, windowBounds) else { return }
        let button: CachedAXButton?
        if let found = searchPressable(windowRef, x: point.x, y: point.y, depth: 0),
           let bf = axFrame(found) {
            axWindowCacheLock.lock()
            axWindowCacheSeq += 1
            let seq = axWindowCacheSeq
            axWindowCacheLock.unlock()
            button = CachedAXButton(element: found, frame: bf, seq: seq)
        } else { button = nil }
        axWindowCacheLock.lock()
        defer { axWindowCacheLock.unlock() }
        axWindowCacheSeq += 1
        let seq = axWindowCacheSeq
        let key = axWindowCacheKey(pid: pid, windowNumber: windowNumber)
        // A reused key (PID+windowID recycled by relaunch, or a new record
        // over the same ids) must reset to the CURRENT prime identity —
        // retaining the old owner's entry (or ignoring the valid new
        // record) would serve stale buttons to a different app. Callers
        // still enforce the exact current CG identity; consult re-verifies.
        var stored = axWindowCache[key]
        if let e = stored,
           e.bundleId != bundleId || e.ownerName.caseInsensitiveCompare(ownerName) != .orderedSame {
            stored = nil
        }
        var buttons = stored?.buttons ?? []
        if let button {
            // Replace any stored button at the same frame with the fresh
            // handle: re-recording after a UI rebuild must not keep a dead
            // button that happens to share the old rect.
            buttons.removeAll(where: { framesMatch($0.frame, button.frame, tolerance: 1) })
            buttons.append(button)
            if buttons.count > axWindowCacheMaxButtons {
                buttons.sort { $0.seq < $1.seq }
                buttons.removeFirst(buttons.count - axWindowCacheMaxButtons)
            }
        }
        axWindowCache[key] = CachedAXWindow(window: windowRef, frame: liveFrame, bundleId: bundleId,
                               ownerName: ownerName, title: title, buttons: buttons, seq: seq)
        if axWindowCache.count > axWindowCacheMaxWindows,
           let oldest = axWindowCache.min(by: { $0.value.seq < $1.value.seq })?.key {
            axWindowCache.removeValue(forKey: oldest)
        }
    }

    private static func ancestorWindow(of start: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = start
        for _ in 0..<8 {
            guard let el = current else { return nil }
            if stringAttr(el, kAXRoleAttribute) == "AXWindow" { return el }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success,
                  let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
            current = unsafeDowncast(p, to: AXUIElement.self)
        }
        return nil
    }

    private static func axWindows(of app: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var cf: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &cf) == .success,
           let list = cf as? [AXUIElement] { out = list }
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let ref = focusedRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let focused = unsafeDowncast(ref, to: AXUIElement.self)
            if !out.contains(where: { $0 == focused }) { out.append(focused) }
        }
        return out
    }

    private static func dropCachedWindow(key: String) {
        axWindowCacheLock.lock()
        axWindowCache.removeValue(forKey: key)
        axWindowCacheLock.unlock()
    }

    /// The cached button for this exact (pid, window) whose live frame still
    /// matches the current CG bounds and contains the point. Nil unless every
    /// check passes — never a sibling or a stale ref.
    private static func cachedButton(windowNumber: Int, pid: pid_t, x: CGFloat, y: CGFloat,
                                     expectedFrame: CGRect, bundleId: String?,
                                     ownerName: String?) -> AXUIElement? {
        let key = axWindowCacheKey(pid: pid, windowNumber: windowNumber)
        axWindowCacheLock.lock()
        let entry = axWindowCache[key]
        axWindowCacheLock.unlock()
        guard let entry else { return nil }
        if let bundleId {
            guard entry.bundleId == bundleId else { dropCachedWindow(key: key); return nil }
        } else if let ownerName,
                  entry.ownerName.caseInsensitiveCompare(ownerName) != .orderedSame {
            dropCachedWindow(key: key)
            return nil
        }
        guard let liveFrame = axFrame(entry.window),
              framesMatch(liveFrame, expectedFrame) else {
            dropCachedWindow(key: key)
            return nil
        }
        let point = CGPoint(x: x, y: y)
        for b in entry.buttons.reversed() {
            // Match on the CURRENT live frame only: the stored absolute
            // frame goes stale when the window moves further than a button
            // width, which would wrongly retire a valid cached ref.
            guard let bf = axFrame(b.element), bf.contains(point) else { continue }
            // The button must still belong to the cached window: a rebuilt
            // UI can reparent a stale ref under a different (sibling) window.
            guard let owner = ancestorWindow(of: b.element),
                  owner == entry.window else { continue }
            return b.element
        }
        // Fallback: re-walk the verified window's live subtree. Off-Space
        // the cached window ref still vends fresh children (probe: full
        // button list, AXPress 0) even when stored buttons miss — UI
        // rebuild, large move, >16 points, or a center-point prime with no
        // button. Window identity, live frame and ancestry are verified
        // above; the search stays inside THIS window only, never a sibling.
        // (Not stored back: the next prime refreshes handles.)
        if let fresh = searchPressable(entry.window, x: point.x, y: point.y, depth: 0),
           let ff = axFrame(fresh), ff.contains(point),
           let owner = ancestorWindow(of: fresh), owner == entry.window {
            return fresh
        }
        return nil
    }

    private static func pressCachedButton(windowNumber: Int, pid: pid_t, x: CGFloat, y: CGFloat,
                                          expectedFrame: CGRect, bundleId: String?,
                                          ownerName: String?) -> Bool {
        guard let element = cachedButton(windowNumber: windowNumber, pid: pid, x: x, y: y,
                                         expectedFrame: expectedFrame, bundleId: bundleId,
                                         ownerName: ownerName) else { return false }
        return pressAncestorChain(from: element)
    }

    /// Non-pressing counterpart for readiness probes and the unreachable
    /// off-Space error gate.
    public static func hasCachedPressable(windowNumber: Int, pid: pid_t, x: CGFloat, y: CGFloat,
                                          expectedFrame: CGRect, bundleId: String?,
                                          ownerName: String?) -> Bool {
        cachedButton(windowNumber: windowNumber, pid: pid, x: x, y: y,
                     expectedFrame: expectedFrame, bundleId: bundleId,
                     ownerName: ownerName) != nil
    }

    /// True when the live AX tree currently exposes a window for this point.
    public static func hasQueryableWindow(appPID: pid_t, x: CGFloat, y: CGFloat,
                                           windowBounds: CGRect?) -> Bool {
        windowContaining(appPID: appPID, x: x, y: y, matching: windowBounds) != nil
    }

    /// Performs AXPress on the element, walking up to 8 ancestors for the
    /// first one that supports the action.
    private static func pressAncestorChain(from start: AXUIElement) -> Bool {
        var current = start
        for _ in 0..<8 {
            var actions: CFArray?
            if AXUIElementCopyActionNames(current, &actions) == .success,
               let list = actions as? [String], list.contains("AXPress") {
                return AXUIElementPerformAction(current, kAXPressAction as CFString) == .success
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            current = unsafeDowncast(p, to: AXUIElement.self)
        }
        return false
    }

    /// Used only by explicit foreground macro playback.
    @discardableResult
    static func focusWindow(_ window: WindowInfo) -> Bool {
        let app = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        let matches = windows.filter {
            guard let frame = axFrame($0) else { return false }
            return abs(frame.minX - window.bounds.minX) < 3 && abs(frame.minY - window.bounds.minY) < 3
                && abs(frame.width - window.bounds.width) < 3 && abs(frame.height - window.bounds.height) < 3
        }
        guard matches.count == 1, let target = matches.first else { return false }
        // Re-raising an already focused window between a shortcut and typing
        // can disturb its field editor and selection.
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused, CFEqual(focused, target) { return true }
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, target)
        return AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
    }

    // MARK: occluded-window tree walk

    private static func axFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
            let pos = posRef,
            AXValueGetType(pos as! AXValue) == .cgPoint,
            AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
            let size = sizeRef,
            AXValueGetType(size as! AXValue) == .cgSize
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Topmost AX window of the app whose frame contains the point.
    ///
    /// Chromium browsers (Brave/Chrome) on modern macOS expose no usable
    /// kAXWindowsAttribute — the real window hangs off AXFocusedWindow
    /// (per-app state, works even when the app is covered), so it joins the
    /// candidates. Windows with live children are preferred over dummies.
    private static func windowContaining(appPID: pid_t, x: CGFloat, y: CGFloat, matching bounds: CGRect? = nil) -> AXUIElement? {
        let app = AXUIElementCreateApplication(appPID)
        let point = CGPoint(x: x, y: y)
        var candidates: [AXUIElement] = []

        var cfWindows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &cfWindows) == .success,
           let windows = cfWindows as? [AXUIElement] {
            for window in windows.reversed() {  // last = topmost
                if let f = axFrame(window), f.contains(point) { candidates.append(window) }
            }
        }

        var focusedRef: CFTypeRef?
        var focusedWindow: AXUIElement?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let ref = focusedRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            focusedWindow = unsafeDowncast(ref, to: AXUIElement.self)
        }
        if let fw = focusedWindow,
           let f = axFrame(fw), f.contains(point),
           !candidates.contains(where: { $0 == fw }) {
            candidates.append(fw)
        }

        if let bounds {
            candidates = candidates.filter { window in
                guard let frame = axFrame(window) else { return false }
                return abs(frame.minX - bounds.minX) < 2 && abs(frame.minY - bounds.minY) < 2
                    && abs(frame.width - bounds.width) < 2 && abs(frame.height - bounds.height) < 2
            }
            // Identical overlapping frames are ambiguous; use window-routed
            // events rather than pressing a control in the wrong window.
            guard candidates.count == 1 else { return nil }
        }
        for window in candidates {
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &kids) == .success,
               let children = kids as? [AXUIElement], !children.isEmpty {
                return window
            }
        }
        return candidates.first
    }

    /// Depth-limited search for the deepest pressable element containing the
    /// point, starting from a window. Later children are checked first
    /// (they render on top).
    private static func treeWalkPressable(appPID: pid_t, x: CGFloat, y: CGFloat) -> AXUIElement? {
        guard let window = windowContaining(appPID: appPID, x: x, y: y) else { return nil }
        return searchPressable(window, x: x, y: y, depth: 0)
    }

    private static func searchPressable(_ el: AXUIElement, x: CGFloat, y: CGFloat, depth: Int) -> AXUIElement? {
        if depth > 12 { return nil }
        guard let f = axFrame(el), f.contains(CGPoint(x: x, y: y)) else { return nil }

        var kids: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
           let children = kids as? [AXUIElement] {
            for child in children.reversed() {
                if let hit = searchPressable(child, x: x, y: y, depth: depth + 1) { return hit }
            }
        }
        var actions: CFArray?
        if AXUIElementCopyActionNames(el, &actions) == .success,
           let list = actions as? [String], list.contains("AXPress") {
            return el
        }
        return nil
    }
}
