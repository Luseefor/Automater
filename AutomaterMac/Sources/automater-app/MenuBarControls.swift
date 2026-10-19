import AppKit
import Combine
import AutomaterKit

/// A native status menu with stable rows, so state updates do not interrupt tracking.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()
    enum Action: Int { case panel = 1, repeatAction, record, play, stop, settings, quit, clipboard }
    private var statusItem: NSStatusItem?
    private weak var state: AppState?
    private weak var pocket: PocketController?
    private var showPanel: (() -> Void)?
    private var showSettings: (() -> Void)?
    private var showClipboard: (() -> Void)?
    private var preferences: AnyCancellable?
    private var refreshTimer: Timer?
    private weak var trackingMenu: NSMenu?
    private var shortcuts: [String: MenuShortcut]?

    func configure(state: AppState, pocket: PocketController, showPanel: @escaping () -> Void,
                   showClipboard: @escaping () -> Void, showSettings: @escaping () -> Void) {
        self.state = state
        self.pocket = pocket
        self.showPanel = showPanel
        self.showSettings = showSettings
        self.showClipboard = showClipboard
        if preferences == nil {
            preferences = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateVisibility() }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = UserDefaults.standard.object(forKey: "general.showMenuBarIcon") as? Bool ?? true
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "AutomaterMainStatusItem"
            if let button = item.button {
                button.image = AutomaterBrand.menuBarIcon
                button.imagePosition = .imageOnly
                button.toolTip = "Tandem"
                button.setAccessibilityLabel("Tandem")
            }
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !visible, let item = statusItem {
            refreshTimer?.invalidate()
            refreshTimer = nil
            trackingMenu = nil
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let state else { return }
        updateMenu(menu, state: state, pocket: pocket)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        trackingMenu = menu
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let menu = self.trackingMenu else { return }
                HotkeyManager.shared.dispatchPendingHotkeys()
                self.menuNeedsUpdate(menu)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        trackingMenu = nil
        shortcuts = nil
    }

    /// Also used by the menu tests without installing a second status item.
    func updateMenu(_ menu: NSMenu, state: AppState, pocket: PocketController? = nil) {
        if menu.item(withTag: 100) == nil {
            menu.autoenablesItems = false
            menu.minimumWidth = 228
            menu.font = .menuFont(ofSize: 13)
            let header = NSMenuItem(title: "Tandem", action: nil, keyEquivalent: "")
            header.tag = 100
            header.view = StatusMenuHeader()
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
            add("Open Tandem", action: .panel, symbol: "macwindow", to: menu)
            add("Clipboard History", action: .clipboard, symbol: "doc.on.clipboard", to: menu)
            menu.addItem(.separator())
            add("Repeat Clicks", action: .repeatAction, symbol: "cursorarrow.click", to: menu)
            add("Record Macro", action: .record, symbol: "record.circle", to: menu)
            add("Play Macro", action: .play, symbol: "play", to: menu)
            add("Stop All", action: .stop, symbol: "stop", to: menu)
            menu.addItem(.separator())
            add("Settings…", action: .settings, symbol: "gearshape", to: menu, shortcut: MenuShortcut(key: ",", modifiers: .command))
            add("Quit Tandem", action: .quit, symbol: "power", to: menu, shortcut: MenuShortcut(key: "q", modifiers: .command))
        }
        if shortcuts == nil {
            let settings = Storage.loadSettings()
            shortcuts = Dictionary(uniqueKeysWithValues: HotkeyCoordinator.bindings.compactMap { binding in
                guard let shortcut = MenuShortcut(settings[binding.setting] as? String ?? binding.fallback) else { return nil }
                return (binding.setting, shortcut)
            })
        }
        let picking = state.isPicking || state.isCapturingFixedPoint || state.isCapturingMacroPoint
        let capturing = picking || state.isRecording
        let active = state.isClicking || state.isRecording || state.playingMacro || picking || pocket?.isRunning == true
        let status: String
        if pocket?.isRunning == true { status = pocket?.runStatus ?? "Pasting…" }
        else if state.isRecording { status = "Recording" }
        else if picking { status = "Picking a point" }
        else if state.playingMacro { status = "Playing macro" }
        else if state.isClicking { status = "Repeating" }
        else {
            let quiet = ["Idle", "Stopped", "Playback finished", "Playback stopped", "Macro deleted", "Recording cleared", "Point capture cancelled"]
            status = quiet.contains(state.status) ? "Ready" : state.status
        }
        (menu.item(withTag: 100)?.view as? StatusMenuHeader)?.update(
            status: status, active: active, recording: state.isRecording, detail: state.status
        )
        update(.repeatAction, in: menu,
               title: state.isClicking ? "Stop Repeating" : state.repeatAction == .keyPress ? "Repeat Key" : "Repeat Clicks",
               symbol: state.isClicking ? "stop.circle" : state.repeatAction == .keyPress ? "keyboard" : "cursorarrow.click",
               enabled: state.isClicking || !capturing, setting: "hotkey_toggle")
        update(.record, in: menu, title: state.isRecording ? "Stop Recording" : "Record Macro",
               symbol: state.isRecording ? "stop.circle" : "record.circle",
               enabled: !picking, setting: "hotkey_record")
        update(.play, in: menu, title: state.playingMacro ? "Stop Playback" : "Play Macro",
               symbol: state.playingMacro ? "stop.circle" : "play",
               enabled: state.playingMacro || (!capturing && !state.displaySteps.isEmpty), setting: "hotkey_play")
        update(.stop, in: menu, title: "Stop All", symbol: "stop", enabled: active, setting: "hotkey_stop")
        if let item = menu.item(withTag: Action.clipboard.rawValue) {
            apply(shortcuts?["hotkey_clipboard"], to: item)
        }
        menu.item(withTag: Action.play.rawValue)?.toolTip = state.displaySteps.isEmpty
            ? "Record or add steps in Macros first" : state.currentMacro.name
    }

    private func add(_ title: String, action: Action, symbol: String, to menu: NSMenu, shortcut: MenuShortcut? = nil) {
        let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = action.rawValue
        item.identifier = NSUserInterfaceItemIdentifier("tandem-status-\(action.rawValue)")
        item.image = image(symbol)
        apply(shortcut, to: item)
        menu.addItem(item)
    }

    private func update(_ action: Action, in menu: NSMenu, title: String, symbol: String, enabled: Bool, setting: String) {
        guard let item = menu.item(withTag: action.rawValue) else { return }
        if item.title != title { item.title = title; item.image = image(symbol) }
        if item.isEnabled != enabled { item.isEnabled = enabled }
        apply(shortcuts?[setting], to: item)
    }

    private func image(_ symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    private func apply(_ shortcut: MenuShortcut?, to item: NSMenuItem) {
        let key = shortcut?.key ?? "", modifiers = shortcut?.modifiers ?? []
        if item.keyEquivalent != key { item.keyEquivalent = key }
        if item.keyEquivalentModifierMask != modifiers { item.keyEquivalentModifierMask = modifiers }
    }

    @objc private func performAction(_ item: NSMenuItem) {
        guard let action = Action(rawValue: item.tag) else { return }
        switch action {
        case .panel: present(showPanel, title: "Tandem")
        case .repeatAction: state?.toggleClicker()
        case .record: state?.toggleRecording()
        case .play: state?.playToggle()
        case .stop: state?.stopAll()
        case .settings: present(showSettings, title: nil)
        case .quit:
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.terminate(nil)
            }
        case .clipboard: openClipboard()
        }
    }

    /// Finish menu tracking before activating the app and asking SwiftUI to
    /// present a scene. This also restores an existing ordered-out window.
    private func present(_ request: (() -> Void)?, title: String?) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            request?()
            if let title {
                DispatchQueue.main.async {
                    NSApp.windows.first { $0.title == title && $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
    func openClipboard() { present(showClipboard, title: "Clipboard") }

}

struct MenuShortcut {
    let key: String
    let modifiers: NSEvent.ModifierFlags
    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key; self.modifiers = modifiers
    }
    init?(_ binding: String) {
        guard let chord = KeyChord(binding), let name = KeyCodeMap.name(for: chord.key) else { return nil }
        let special: [UInt16: Int] = [49: 32, 36: 13, 48: 9, 53: 27, 51: 8, 117: NSDeleteFunctionKey,
                                     126: NSUpArrowFunctionKey, 125: NSDownArrowFunctionKey,
                                     123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
                                     115: NSHomeFunctionKey, 119: NSEndFunctionKey,
                                     116: NSPageUpFunctionKey, 121: NSPageDownFunctionKey]
        if let code = special[chord.key], let scalar = UnicodeScalar(code) { key = String(scalar) }
        else if name.hasPrefix("f"), let number = Int(name.dropFirst()), (1...12).contains(number) {
            key = String(UnicodeScalar(NSF1FunctionKey + number - 1)!)
        } else if name.count == 1 { key = name }
        else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for code in chord.modifiers {
            switch code {
            case 55, 54: flags.insert(.command)
            case 59, 62: flags.insert(.control)
            case 58, 61: flags.insert(.option)
            case 56, 60: flags.insert(.shift)
            default: break
            }
        }
        modifiers = flags
    }
}

@MainActor
private final class StatusMenuHeader: NSView {
    private let subtitle = NSTextField(labelWithString: "Ready")
    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 228, height: 48))
        let icon = NSImageView(image: AutomaterBrand.icon(side: 56))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        let title = NSTextField(labelWithString: "Tandem")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(text)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        autoresizingMask = [.width]
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(status: String, active: Bool, recording: Bool, detail: String) {
        if subtitle.stringValue != status { subtitle.stringValue = status }
        let color: NSColor = recording ? .systemRed : active ? .systemGreen : .secondaryLabelColor
        if subtitle.textColor != color { subtitle.textColor = color }
        if toolTip != detail { toolTip = detail }
    }
}
