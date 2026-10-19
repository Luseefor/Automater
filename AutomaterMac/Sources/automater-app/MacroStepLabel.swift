import Foundation
import AutomaterKit

/// Compact human-readable labels for recorded and authored steps.
struct MacroStepLabel {
    let title: String
    let detail: String
    let icon: String

    init(_ step: MacroStep) {
        let button = (step.button ?? "left").capitalized
        var details: [String] = []
        switch step.type {
        case "click":
            title = step.clickKind == "double" ? "Double-click" : step.clickKind == "triple" ? "Triple-click" : "\(button) click"
            icon = "cursorarrow.click"
        case "hold": title = "Hold \(button.lowercased()) button"; icon = "hand.point.up.left"
        case "drag": title = "Drag"; icon = "arrow.up.left.and.arrow.down.right"
        case "move": title = "Move cursor"; icon = "cursorarrow"
        case "key", "key_down", "key_up":
            let suffix = step.type == "key_down" ? " down" : step.type == "key_up" ? " up" : ""
            title = Self.keyTitle(step.key ?? "?") + suffix; icon = "keyboard"
        case "type": title = "Type text"; icon = "text.cursor"
            details.append(String((step.text ?? "").replacingOccurrences(of: "\n", with: " ↵ ").prefix(80)))
        case "delay": title = "Wait \(Self.duration(step.delayMs))"; icon = "clock"
        case "scroll":
            title = "Scroll"; icon = "scroll"
            if let dy = step.dy, dy != 0 { details.append("\(dy < 0 ? "↑" : "↓") \(dy.magnitude) lines") }
            if let dx = step.dx, dx != 0 { details.append("\(dx < 0 ? "←" : "→") \(dx.magnitude) lines") }
        case "swipe": title = "Swipe"; icon = "hand.draw"
        default: title = step.type.capitalized; icon = "circle"
        }
        if ["click", "hold", "drag", "move"].contains(step.type) {
            if step.coordSpace == "window", let x = step.localX, let y = step.localY {
                details.append("Window \(Self.coordinate(x)), \(Self.coordinate(y))")
            } else if let x = step.x, let y = step.y {
                details.append("\(x), \(y)")
            }
            if step.type == "drag" {
                if step.coordSpace == "window", let x = step.endLocalX, let y = step.endLocalY {
                    details.append("→ \(Self.coordinate(x)), \(Self.coordinate(y))")
                } else if let x = step.endX, let y = step.endY { details.append("→ \(x), \(y)") }
            }
            if let app = step.appName, !app.isEmpty { details.append(app) }
            if let title = step.windowTitle, !title.isEmpty { details.append(title) }
        }
        if step.type != "delay", step.delayMs > 0 { details.append("\(Self.duration(step.delayMs)) delay") }
        if step.holdMs > 0 { details.append("\(Self.duration(step.holdMs)) hold") }
        detail = details.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func duration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        return (Double(ms) / 1000).formatted(.number.precision(.fractionLength(0...2))) + " s"
    }
    private static func coordinate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
    static func keyTitle(_ value: String) -> String {
        let names = ["space": "Space", "return": "Return ↩", "tab": "Tab ⇥", "escape": "Escape ⎋", "backspace": "⌫", "delete": "⌦", "up": "↑", "down": "↓", "left": "←", "right": "→"]
        return value.lowercased().split(separator: "+").map { raw in
            let part = String(raw)
            switch part {
            case "cmd", "command", "right_cmd": return "⌘"
            case "ctrl", "control", "right_ctrl": return "⌃"
            case "alt", "option", "right_alt": return "⌥"
            case "shift", "right_shift": return "⇧"
            default: return names[part] ?? part.uppercased()
            }
        }.joined()
    }
}
