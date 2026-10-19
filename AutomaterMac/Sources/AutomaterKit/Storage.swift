import Foundation
import os

/// JSON persistence for Automater's on-disk layout:
/// ~/Library/Application Support/AutomaterMac/{settings.json,macros/*.json}
public enum Storage {
    private static let log = Logger(
        subsystem: "com.luseefor.automater", category: "storage"
    )

    public static let appDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AutomaterMac", isDirectory: true)
    public static let macrosDir = appDir.appendingPathComponent("macros", isDirectory: true)
    public static let settingsURL = appDir.appendingPathComponent("settings.json")

    public static func ensureDirs() {
        do {
            try FileManager.default.createDirectory(at: macrosDir, withIntermediateDirectories: true)
        } catch {
            log.error("creating \(self.appDir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Settings

    public static func loadSettings() -> [String: Any] {
        ensureDirs()
        guard let data = try? Data(contentsOf: settingsURL) else {
            return defaults // first launch / no file yet
        }
        do {
            let raw = try JSONSerialization.jsonObject(with: data)
            guard let dict = raw as? [String: Any] else {
                throw StorageError.notADictionary
            }
            return defaults.merging(dict) { _, new in new }
        } catch {
            log.warning("corrupt settings.json, using defaults: \(error.localizedDescription, privacy: .public)")
            return defaults
        }
    }

    public static func saveSettings(_ dict: [String: Any]) {
        ensureDirs()
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            log.error("writing settings.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static let defaults: [String: Any] = [
        "click_interval_h": 0,
        "click_interval_m": 0,
        "click_interval_s": 0,
        "click_interval_ms": 100,
        "jitter_ms": 0,
        "repeat_count": 0,
        "mouse_button": "left",
        "click_kind": "single",
        "repeat_action": "mouseClick",
        "repeat_key": "space",
        "mode": "multipoint",
        "background_to_app": false,
        "delivery_mode": "accessibility",
        "hotkey_toggle": "ctrl+alt+a",
        "hotkey_record": "ctrl+alt+r",
        "hotkey_stop": "ctrl+alt+s",
        "hotkey_grab": "ctrl+alt+g",
    ]

    // MARK: - Macros

    public static func listMacros() -> [Macro] {
        ensureDirs()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: macrosDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(Macro.self, from: data)
            } catch {
                log.warning("skipping corrupt macro \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.sorted { $0.name < $1.name }
    }

    @discardableResult
    public static func saveMacro(_ macro: Macro) -> Bool {
        ensureDirs()
        let url = macrosDir.appendingPathComponent("\(macro.id).json")
        do {
            let data = try JSONEncoder().encode(macro)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log.error("saving macro \(macro.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    public static func deleteMacro(id: String) -> Bool {
        do {
            try FileManager.default.removeItem(
                at: macrosDir.appendingPathComponent("\(id).json")
            )
            return true
        } catch where (error as NSError).code == NSFileNoSuchFileError {
            return true // already gone
        } catch {
            log.error("deleting macro \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Delivery memory (per-target tier knowledge)

    /// targetKey ("bundle:id" or "pid:N") → "ax" | "events".
    /// Targets that ignored AXPress skip straight to synthetic events next
    /// session — faster clicks, no wasted AX probes.
    public static var deliveryMemoryURL: URL {
        appDir.appendingPathComponent("delivery_memory.json")
    }

    /// Local-only, redacted operational diagnostics; retained at most 200 entries.
    public static var diagnosticsURL: URL {
        appDir.appendingPathComponent("diagnostics.json")
    }

    public static func loadDeliveryMemory() -> [String: String] {
        ensureDirs()
        guard let data = try? Data(contentsOf: deliveryMemoryURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict
    }

    public static func saveDeliveryMemory(_ dict: [String: String]) {
        ensureDirs()
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
            try data.write(to: deliveryMemoryURL, options: .atomic)
        } catch {
            log.error("writing delivery memory: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private enum StorageError: LocalizedError {
    case notADictionary
    var errorDescription: String? {
        switch self {
        case .notADictionary: return "settings.json is not a JSON object"
        }
    }
}
