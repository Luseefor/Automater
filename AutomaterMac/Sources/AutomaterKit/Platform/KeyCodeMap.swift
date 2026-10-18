import Foundation

/// A single key, optionally preceded by modifiers. Reject malformed chords
/// before any events are posted, so a typo cannot send a different shortcut.
public struct KeyChord: Equatable, Sendable {
    public let modifiers: [UInt16]
    public let key: UInt16

    public init?(_ binding: String) {
        let parts = binding.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let last = parts.last, !KeyCodeMap.isModifier(name: last),
              let key = KeyCodeMap.keycode(for: last) else { return nil }
        var modifiers: [UInt16] = []
        for part in parts.dropLast() {
            guard KeyCodeMap.isModifier(name: part),
                  let code = KeyCodeMap.keycode(for: part) else { return nil }
            if !modifiers.contains(code) { modifiers.append(code) }
        }
        self.modifiers = modifiers
        self.key = key
    }
}

/// macOS ANSI virtual keycodes.
public enum KeyCodeMap {

    public static let modifiers: [String: UInt16] = [
        "cmd": 55, "command": 55, "right_cmd": 54,
        "ctrl": 59, "control": 59, "right_ctrl": 62,
        "alt": 58, "option": 58, "opt": 58, "right_alt": 61,
        "shift": 56, "right_shift": 60,
    ]

    private static let letters: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    private static let digits: [String: UInt16] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
    ]

    private static let punctuation: [String: UInt16] = [
        "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41,
        "'": 39, ",": 43, ".": 47, "/": 44, "`": 50,
    ]

    private static let specials: [String: UInt16] = [
        "space": 49, "esc": 53, "escape": 53, "tab": 48,
        "enter": 36, "return": 36, "backspace": 51, "delete": 117,
        "forwarddelete": 117, "home": 115, "end": 119,
        "page_up": 116, "page_down": 121, "caps_lock": 57,
        "up": 126, "down": 125, "left": 123, "right": 124,
    ]

    private static let functionKeys: [String: UInt16] = [
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    private static let all: [String: UInt16] =
        letters.merging(digits) { a, _ in a }
            .merging(punctuation) { a, _ in a }
            .merging(specials) { a, _ in a }
            .merging(functionKeys) { a, _ in a }
            .merging(modifiers) { a, _ in a }

    /// keycode → canonical name (first writer wins).
    public static let allNames: [String: UInt16] = all

    /// Virtual keycode for a key name or single character; nil when unknown.
    public static func keycode(for name: String) -> UInt16? {
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        return all[lowered]
    }

    private static let namesByKeycode: [UInt16: String] = {
        var reverse: [UInt16: String] = [:]
        for (name, code) in all {
            if let existing = reverse[code] {
                if name.count < existing.count { reverse[code] = name }
            } else {
                reverse[code] = name
            }
        }
        return reverse
    }()

    /// Canonical name for a virtual keycode; nil when unknown.
    public static func name(for keycode: UInt16) -> String? {
        namesByKeycode[keycode]
    }

    public static func isModifier(name: String) -> Bool {
        modifiers[name.trimmingCharacters(in: .whitespaces).lowercased()] != nil
    }
}
