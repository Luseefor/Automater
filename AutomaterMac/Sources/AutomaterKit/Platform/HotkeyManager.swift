import Foundation
import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey — no Input Monitoring
/// permission required.
public final class HotkeyManager {
    public static let shared = HotkeyManager()
    private var hotkeys: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextId: UInt32 = 1

    private init() {}

    /// binding like "ctrl+alt+a"; returns false when unparsable/unregistered.
    @discardableResult
    public func register(_ binding: String, handler: @escaping () -> Void) -> Bool {
        guard let (mods, keyCode) = Self.parse(binding) else { return false }
        let hotKeyID = EventHotKeyID(signature: OSType(0x41555448 /*AUTH*/), id: nextId)
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(
            keyCode, mods, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard err == noErr else { return false }
        hotkeys[nextId] = handler
        refs.append(ref)
        nextId += 1
        return true
    }

    public func unregisterAll() {
        for r in refs { if let r { UnregisterEventHotKey(r) } }
        refs.removeAll()
        hotkeys.removeAll()
    }

    private var installOnce: Bool = false
    public func installDispatcher() {
        guard !installOnce else { return }
        installOnce = true
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, _ in
            var id = EventHotKeyID()
            if let event, GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id
            ) == noErr {
                HotkeyManager.shared.dispatch(id: id.id)
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType, nil, nil
        )
    }

    /// AppKit's menu tracking loop can leave Carbon hotkeys queued until
    /// tracking ends. Drain only hotkey presses during that loop, using the
    /// same registered dispatcher as ordinary application event processing.
    public func dispatchPendingHotkeys() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        for _ in 0..<16 {
            var event: EventRef?
            guard ReceiveNextEvent(1, &type, 0, true, &event) == noErr, let event else { return }
            SendEventToEventTarget(event, GetApplicationEventTarget())
            ReleaseEvent(event)
        }
    }

    fileprivate func dispatch(id: UInt32) {
        hotkeys[id]?()
    }

    /// "ctrl+alt+a" → (mods, virtual keycode)
    static func parse(_ binding: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var key: UInt32?
        let tokens = binding.split(separator: "+", omittingEmptySubsequences: false)
        guard !tokens.isEmpty else { return nil }
        for raw in tokens {
            let token = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                .lowercased()
            switch token {
            case "ctrl", "control", "right_ctrl": mods |= UInt32(controlKey)
            case "alt", "opt", "option", "right_alt": mods |= UInt32(optionKey)
            case "shift", "right_shift": mods |= UInt32(shiftKey)
            case "cmd", "command", "right_cmd": mods |= UInt32(cmdKey)
            default:
                guard key == nil, let code = KeyCodeMap.keycode(for: token) else { return nil }
                key = UInt32(code)
            }
        }
        guard let key else { return nil }
        return (mods, key)
    }

    /// Canonical form: mods in ctrl,alt,shift,cmd order + key, lowercased —
    /// lets the recorder recognize its own app's hotkey chords.
    public static func normalized(_ combo: String) -> String {
        var mods: Set<String> = []
        var tail: String?
        for raw in combo.split(separator: "+") {
            let token = raw.trimmingCharacters(in: .whitespaces).lowercased()
            switch token {
            case "ctrl", "control", "right_ctrl": mods.insert("ctrl")
            case "alt", "opt", "option", "right_alt": mods.insert("alt")
            case "shift", "right_shift": mods.insert("shift")
            case "cmd", "command", "right_cmd": mods.insert("cmd")
            default: tail = token
            }
        }
        return (["ctrl", "alt", "shift", "cmd"].filter { mods.contains($0) }
                + [tail ?? ""]).joined(separator: "+")
    }
}
