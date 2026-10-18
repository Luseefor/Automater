import CoreGraphics
import Foundation
import AppKit
import Darwin

/// Posts synthetic CG events — globally (HID tap) or targeted at one process
/// and window, which is what makes background clicking work without moving
/// the physical pointer.
public struct EventPoster: Sendable {

    // CoreGraphics has no public setter for the window-local part of a
    // pid-routed event. Resolve this compatibility symbol optionally; the
    // engine retains Accessibility delivery when it is unavailable.
    private typealias WindowLocationSetter = @convention(c) (CGEvent, CGPoint) -> Void
    private static let windowLocationSetter: WindowLocationSetter? = {
        guard let image = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(image) }
        guard let symbol = dlsym(image, "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: WindowLocationSetter.self)
    }()
    static var canRouteWindowBursts: Bool { windowLocationSetter != nil }

    private var eventSink: (@Sendable (CGEvent, pid_t?) -> Void)?

    public init() {}
    init(eventSink: @escaping @Sendable (CGEvent, pid_t?) -> Void) { self.eventSink = eventSink }

    func post(_ event: CGEvent, pid: pid_t? = nil) {
        if let eventSink { eventSink(event, pid) }
        else if let pid { event.postToPid(pid) }
        else { event.post(tap: .cghidEventTap) }
    }

    // MARK: - Mouse

    /// Posts a two-axis scroll in line units (schema dx = horizontal,
    /// dy = vertical.
    public func scroll(
        dx: Int,
        dy: Int,
        pid: pid_t? = nil,
        windowNumber: Int? = nil
    ) {
        guard dx != 0 || dy != 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: Int32(clamping: dy),
            wheel2: Int32(clamping: dx),
            wheel3: 0
        ) else { return }
        if let windowNumber {
            event.setIntegerValueField(
                .windowUnderMousePointer, value: Int64(windowNumber)
            )
            event.setIntegerValueField(
                .windowUnderMousePointerHandler, value: Int64(windowNumber)
            )
        }
        post(event, pid: pid)
    }

    public func postMouseEvent(
        _ type: CGEventType,
        x: Double,
        y: Double,
        button: MouseButton = .left,
        pid: pid_t? = nil,
        clickState: Int = 1,
        windowNumber: Int? = nil
    ) {
        // hidSystemState makes posted events report the same source state as
        // real hardware input — apps that filter synthetic events by source
        // accept these.
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: CGPoint(x: x, y: y),
            mouseButton: button.cgButton
        ) else { return }

        event.location = CGPoint(x: x, y: y)
        // Keep the event's button payload explicit.  Some targets inspect
        // this field rather than inferring it from the event type.
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.cgButton.rawValue))
        event.setIntegerValueField(.clickState, value: Int64(clickState))
        if let windowNumber {
            event.setIntegerValueField(
                .windowUnderMousePointer, value: Int64(windowNumber)
            )
            event.setIntegerValueField(
                .windowUnderMousePointerHandler, value: Int64(windowNumber)
            )
        }
        post(event, pid: pid)
    }

    public func moveCursor(
        x: Double, y: Double,
        pid: pid_t? = nil,
        windowNumber: Int? = nil
    ) {
        postMouseEvent(
            .mouseMoved, x: x, y: y, button: .left,
            pid: pid, clickState: 0, windowNumber: windowNumber
        )
    }

    private static func downUp(for button: MouseButton) -> (CGEventType, CGEventType) {
        switch button {
        case .right:
            return (.rightMouseDown, .rightMouseUp)
        case .middle:
            return (.otherMouseDown, .otherMouseUp)
        case .left:
            return (.leftMouseDown, .leftMouseUp)
        }
    }

    /// Full press/release series for a click kind at one point.
    public func click(
        x: Double, y: Double,
        button: MouseButton = .left,
        kind: ClickKind = .single,
        pid: pid_t? = nil,
        windowNumber: Int? = nil
    ) {
        let (downType, upType) = Self.downUp(for: button)

        for press in 1...kind.presses {
            postMouseEvent(downType, x: x, y: y, button: button,
                           pid: pid, clickState: press, windowNumber: windowNumber)
            Thread.sleep(forTimeInterval: 0.012)
            postMouseEvent(upType, x: x, y: y, button: button,
                           pid: pid, clickState: press, windowNumber: windowNumber)
            if press < kind.presses {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    /// Physically relocates the system pointer (foreground delivery only).
    public func warpCursor(x: Double, y: Double) {
        guard eventSink == nil else { return }
        CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Foreground click: warp first so the HID click can't land stale.
    public func foregroundClick(
        x: Double, y: Double,
        button: MouseButton = .left,
        kind: ClickKind = .single
    ) {
        warpCursor(x: x, y: y)
        Thread.sleep(forTimeInterval: 0.02)
        moveCursor(x: x, y: y)
        click(x: x, y: y, button: button, kind: kind)
    }

    /// Burst raw click: one balanced down/up per press, no hover-settling,
    /// no sleeps. Same event fields and click counts as click(); speed is
    /// the only difference. No hard timing guarantee is made.
    public func burstClick(
        x: Double, y: Double,
        button: MouseButton = .left,
        kind: ClickKind = .single,
        pid: pid_t? = nil,
        windowNumber: Int? = nil
    ) {
        let (downType, upType) = Self.downUp(for: button)
        for press in 1...kind.presses {
            postMouseEvent(downType, x: x, y: y, button: button,
                           pid: pid, clickState: press, windowNumber: windowNumber)
            postMouseEvent(upType, x: x, y: y, button: button,
                           pid: pid, clickState: press, windowNumber: windowNumber)
        }
    }

    /// Foreground burst: relocate the pointer (intended for foreground
    /// delivery), then a sleep-free balanced click.
    public func burstForegroundClick(
        x: Double, y: Double,
        button: MouseButton = .left,
        kind: ClickKind = .single
    ) {
        warpCursor(x: x, y: y)
        moveCursor(x: x, y: y)
        burstClick(x: x, y: y, button: button, kind: kind)
    }

    /// Background click straight into one process+window; pointer untouched.
    public func backgroundClick(
        x: Double, y: Double,
        pid: pid_t,
        childPIDs: [pid_t] = [],
        windowNumber: Int? = nil,
        button: MouseButton = .left,
        kind: ClickKind = .single
    ) {
        var targets = [pid]
        for child in childPIDs where !targets.contains(child) {
            targets.append(child)
        }
        for target in targets {
            moveCursor(x: x, y: y, pid: target, windowNumber: windowNumber)
            // Hover-settling: renderers arm hover state lazily — a press in
            // the same instant as the first move hits elements that aren't
            // interactive yet (hover-revealed menus/buttons on the web).
            Thread.sleep(forTimeInterval: 0.04)
            moveCursor(x: x, y: y, pid: target, windowNumber: windowNumber)
            click(x: x, y: y, button: button, kind: kind,
                  pid: target, windowNumber: windowNumber)
        }
    }

    /// Background burst straight into one process+window; pointer untouched,
    /// no hover-settling, no sleeps. Balanced down/up per press.
    public func burstBackgroundClick(
        x: Double, y: Double,
        pid: pid_t,
        childPIDs: [pid_t] = [],
        windowNumber: Int? = nil,
        button: MouseButton = .left,
        kind: ClickKind = .single,
        windowBounds: CGRect? = nil
    ) {
        var targets = [pid]
        for child in childPIDs where !targets.contains(child) {
            targets.append(child)
        }
        for target in targets {
            if let windowNumber, let bounds = windowBounds {
                // CGEventPostToPid does not assign NSEvent.windowNumber.
                // Construct a public AppKit event for the exact window with
                // window-local coordinates, then bridge it for delivery.
                let local = NSPoint(x: x - bounds.minX, y: bounds.maxY - y)
                let types: (NSEvent.EventType, NSEvent.EventType) = button == .right
                    ? (.rightMouseDown, .rightMouseUp) : button == .middle
                    ? (.otherMouseDown, .otherMouseUp) : (.leftMouseDown, .leftMouseUp)
                for press in 1...kind.presses {
                    for type in [types.0, types.1] {
                        guard let native = NSEvent.mouseEvent(with: type, location: local,
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: windowNumber, context: nil, eventNumber: 0,
                            clickCount: press, pressure: type == types.0 ? 1 : 0),
                              let event = native.cgEvent else { continue }
                        event.location = CGPoint(x: x, y: y)
                        Self.windowLocationSetter?(event, CGPoint(x: x - bounds.minX, y: y - bounds.minY))
                        event.setIntegerValueField(.windowUnderMousePointer, value: Int64(windowNumber))
                        event.setIntegerValueField(.windowUnderMousePointerHandler, value: Int64(windowNumber))
                        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.cgButton.rawValue))
                        post(event, pid: target)
                    }
                }
            } else {
                burstClick(x: x, y: y, button: button, kind: kind,
                           pid: target, windowNumber: windowNumber)
            }
        }
    }

    /// AXPress-based background click: no synthetic events at all.
    /// Returns true when at least one press actually landed on an element.
    @discardableResult
    public func axClick(
        x: Double, y: Double,
        pid: pid_t,
        button: MouseButton = .left,
        kind: ClickKind = .single,
        windowNumber: Int? = nil,
        bundleId: String? = nil,
        ownerName: String? = nil
    ) -> Bool {
        guard button == .left else { return false }
        let bounds: CGRect?
        if let windowNumber {
            guard let window = WindowScanner.windows(pid: pid, minSize: CGSize(width: 2, height: 2)).first(where: { $0.windowId == windowNumber }) else { return false }
            bounds = window.bounds
        } else { bounds = nil }
        var delivered = false
        for _ in 0..<kind.presses {
            if AXBridge.pressAt(appPID: pid, x: x, y: y, windowBounds: bounds, windowNumber: windowNumber,
                                bundleId: bundleId, ownerName: ownerName) {
                delivered = true
            }
            if kind.presses > 1 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return delivered
    }

    // MARK: - Keyboard

    /// Posts a key or chord ("cmd+c") to a process. Returns false when any
    /// part has no virtual keycode so callers can fall back.
    @discardableResult
    public func keyCombo(
        _ combo: String,
        pid: pid_t?
    ) -> Bool {
        guard let events = Self.keyboardEvents(for: combo) else { return false }
        for event in events {
            if event.type == .keyUp { Thread.sleep(forTimeInterval: 0.008) }
            post(event, pid: pid)
        }
        return true
    }

    /// Build the complete balanced sequence before sending any of it.
    static func keyboardEvents(for combo: String) -> [CGEvent]? {
        guard let chord = KeyChord(combo) else { return nil }
        let source = CGEventSource(stateID: .hidSystemState)
        var flags: CGEventFlags = []
        var events: [CGEvent] = []
        func append(_ code: UInt16, down: Bool) -> Bool {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code,
                                      keyDown: down) else { return false }
            event.flags = flags
            events.append(event)
            return true
        }
        for code in chord.modifiers {
            flags.insert(Self.flag(forVirtual: code))
            guard append(code, down: true) else { return nil }
        }
        guard append(chord.key, down: true), append(chord.key, down: false) else { return nil }
        for code in chord.modifiers.reversed() {
            flags.remove(Self.flag(forVirtual: code))
            guard append(code, down: false) else { return nil }
        }
        return events
    }

    /// Routes either the press or release side of a simple key/chord to a
    /// process, preserving recorded key_down/key_up macro semantics.
    @discardableResult
    public func keyPhase(_ combo: String, pid: pid_t, keyDown: Bool) -> Bool {
        let parts = combo.split(separator: "+").map { $0.lowercased() }
        guard let tailName = parts.last, let tail = KeyCodeMap.keycode(for: tailName) else { return false }
        let mods = parts.dropLast().compactMap { KeyCodeMap.keycode(for: String($0)) }
        let source = CGEventSource(stateID: .hidSystemState)
        let codes = keyDown ? Array(mods) + [tail] : [tail] + mods.reversed()
        for code in codes {
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown)?.postToPid(pid)
        }
        return true
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

    // MARK: - Cursor query

    public static var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}

extension MouseButton {
    /// CG counterpart for synthetic event construction.
    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }
}
