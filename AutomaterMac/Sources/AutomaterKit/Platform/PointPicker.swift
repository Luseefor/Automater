import CoreGraphics
import AppKit
import Foundation

/// Click-to-capture mode: while active, every left/right click's position is
/// reported and swallowed (doesn't reach other apps). Clicks on this app's
/// own windows pass through untouched (so "Finish Picking" finishes).
/// Escape ends the pick.
public final class PointPicker {
    public var onPoint: ((CGPoint) -> Void)?
    /// `finished` is true for explicit completion (button/Esc), false when
    /// the tap couldn't be created at all (missing permission).
    public var onFinish: ((_ finished: Bool) -> Void)?
    public private(set) var count = 0
    /// When true, the first captured point ends the pick (fixed-point grab).
    public var singleShot = false {
        didSet { if singleShot { count = 0 } }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowedButtons = Set<UInt32>()
    private var finishing = false

    public var active: Bool { tap != nil }

    private static let escapeKeyCode: UInt16 = 53

    public init() {}

    public func start() {
        guard tap == nil else { return }
        count = 0
        swallowedButtons.removeAll()
        finishing = false

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let picker = Unmanaged<PointPicker>.fromOpaque(refcon).takeUnretainedValue()
            return picker.handle(type: type, event: event)
        }

        func maskBit(_ t: CGEventType) -> UInt64 { 1 << t.rawValue }
        let mask: CGEventMask =
            maskBit(.leftMouseDown) | maskBit(.rightMouseDown)
            | maskBit(.leftMouseUp) | maskBit(.rightMouseUp) | maskBit(.keyDown)

        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            onFinish?(false)
            return
        }
        tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    public func stop(finished: Bool = false) {
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
            }
        }
        tap = nil
        runLoopSource = nil
        swallowedButtons.removeAll()
        finishing = false
        onFinish?(finished)
    }

    // MARK: - Event handling

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable after system-imposed timeouts so picking never dies silently.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == Int64(Self.escapeKeyCode) {
            finishAfterEvent()
            return nil // return the swallowed event before disabling its tap
        }

        switch type {
        case .leftMouseDown, .rightMouseDown:
            // Our own UI must stay clickable while picking.
            if WindowScanner.ownsPoint(cgLocation: event.location) {
                return Unmanaged.passUnretained(event)
            }
            swallowedButtons.insert(type.rawValue)
            if !singleShot || count == 0 {
                count += 1
                onPoint?(event.location)
            }
            return nil
        case .leftMouseUp, .rightMouseUp:
            let down: CGEventType = type == .leftMouseUp ? .leftMouseDown : .rightMouseDown
            guard swallowedButtons.remove(down.rawValue) != nil else { return Unmanaged.passUnretained(event) }
            if singleShot { finishAfterEvent() }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
    private func finishAfterEvent() {
        guard !finishing else { return }
        finishing = true
        // Disabling a tap inside its callback can release the event we meant
        // to swallow. Finish on the next turn, after the full click pair.
        DispatchQueue.main.async { [weak self] in self?.stop(finished: true) }
    }

}
