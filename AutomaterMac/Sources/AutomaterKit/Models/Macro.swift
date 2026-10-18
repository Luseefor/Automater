import Foundation

/// A saved macro: ordered steps plus playback defaults.
public struct Macro: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var steps: [MacroStep]
    /// 0 = loop forever until stopped.
    public var loopCount: Int
    public var speed: Double
    public var targetAppBundleId: String?
    public var targetAppName: String?
    public var targetWindowTitle: String?
    public var activateBeforePlay: Bool
    /// Nil keeps the legacy preference until the macro is loaded and saved.
    public var backgroundPlayback: Bool?

    public init(
        id: String = UUID().uuidString.prefix(12).description,
        name: String,
        steps: [MacroStep] = [],
        loopCount: Int = 1,
        speed: Double = 1.0,
        targetAppBundleId: String? = nil,
        targetAppName: String? = nil,
        targetWindowTitle: String? = nil,
        activateBeforePlay: Bool = true,
        backgroundPlayback: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.steps = steps
        self.loopCount = loopCount
        self.speed = speed
        self.targetAppBundleId = targetAppBundleId
        self.targetAppName = targetAppName
        self.targetWindowTitle = targetWindowTitle
        self.activateBeforePlay = activateBeforePlay
        self.backgroundPlayback = backgroundPlayback
    }

    enum CodingKeys: String, CodingKey {
        case id, name, steps, speed
        case loopCount = "loop_count"
        case targetAppBundleId = "target_app_bundle_id"
        case targetAppName = "target_app_name"
        case targetWindowTitle = "target_window_title"
        case activateBeforePlay = "activate_before_play"
        case backgroundPlayback = "background_playback"
    }

    /// Lenient decode for persisted macro files.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? UUID().uuidString.prefix(12).description
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        self.steps = try c.decodeIfPresent([MacroStep].self, forKey: .steps) ?? []
        self.loopCount = try c.decodeIfPresent(Int.self, forKey: .loopCount) ?? 1
        self.speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        self.targetAppBundleId = try c.decodeIfPresent(String.self, forKey: .targetAppBundleId)
        self.targetAppName = try c.decodeIfPresent(String.self, forKey: .targetAppName)
        self.targetWindowTitle = try c.decodeIfPresent(String.self, forKey: .targetWindowTitle)
        self.activateBeforePlay = try c.decodeIfPresent(Bool.self, forKey: .activateBeforePlay) ?? true
        self.backgroundPlayback = try c.decodeIfPresent(Bool.self, forKey: .backgroundPlayback)
    }
}

/// A stored multi-point entry (screen or window-local).
public struct PointSpec: Codable, Equatable, Sendable {
    public var x: Int?
    public var y: Int?
    public var coordSpace: CoordSpace
    public var localX: Double?
    public var localY: Double?
    public var appBundleId: String?
    public var appName: String?
    public var windowTitle: String?
    public var pid: Int?
    public var windowId: Int?

    public init(
        x: Int? = nil,
        y: Int? = nil,
        coordSpace: CoordSpace = .screen,
        localX: Double? = nil,
        localY: Double? = nil,
        appBundleId: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        pid: Int? = nil,
        windowId: Int? = nil
    ) {
        self.x = x
        self.y = y
        self.coordSpace = coordSpace
        self.localX = localX
        self.localY = localY
        self.appBundleId = appBundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.pid = pid
        self.windowId = windowId
    }
}

/// Full clicker run configuration handed to the engine.
public struct ClickerConfig: Sendable, Equatable {
    public enum Action: String, CaseIterable, Sendable {
        case mouseClick, keyPress
    }

    public enum Mode: String, Sendable {
        case currentCursor, fixedPoint, multipoint
    }

    /// How background clicks reach the target process.
    public enum DeliveryMode: String, Sendable {
        case events        // CGEventPostToPid + window routing
        case accessibility // AXPress on the element under the point
    }

    public var intervalMs: Int
    public var action: Action
    public var keyCombo: String
    public var jitterMs: Int
    public var button: MouseButton
    public var clickKind: ClickKind
    /// 0 = infinite until stopped.
    public var repeatCount: Int
    public var mode: Mode

    // Fixed-point specifics
    public var fixedScreenX: Int
    public var fixedScreenY: Int
    public var fixedCoordSpace: CoordSpace
    public var fixedLocalX: Double
    public var fixedLocalY: Double
    public var fixedWindowId: Int?

    // Target identity used for background delivery & window-space points
    public var appBundleId: String?
    public var appName: String?
    public var windowTitle: String?
    /// Explicit background-target pin; wins over identity lookup when set.
    public var targetPid: Int?
    public var targetWindowId: Int?

    public var multipoints: [PointSpec]
    public var backgroundToApp: Bool
    public var deliveryMode: DeliveryMode

    public init(
        intervalMs: Int = 100,
        jitterMs: Int = 0,
        button: MouseButton = .left,
        clickKind: ClickKind = .single,
        repeatCount: Int = 0,
        mode: Mode = .currentCursor,
        fixedScreenX: Int = 0,
        fixedScreenY: Int = 0,
        fixedCoordSpace: CoordSpace = .screen,
        fixedLocalX: Double = 0,
        fixedLocalY: Double = 0,
        fixedWindowId: Int? = nil,
        appBundleId: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        multipoints: [PointSpec] = [],
        backgroundToApp: Bool = false,
        deliveryMode: DeliveryMode = .events,
        action: Action = .mouseClick,
        keyCombo: String = "space"
    ) {
        self.intervalMs = intervalMs
        self.action = action
        self.keyCombo = keyCombo
        self.jitterMs = jitterMs
        self.button = button
        self.clickKind = clickKind
        self.repeatCount = repeatCount
        self.mode = mode
        self.fixedScreenX = fixedScreenX
        self.fixedScreenY = fixedScreenY
        self.fixedCoordSpace = fixedCoordSpace
        self.fixedLocalX = fixedLocalX
        self.fixedLocalY = fixedLocalY
        self.fixedWindowId = fixedWindowId
        self.appBundleId = appBundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.multipoints = multipoints
        self.backgroundToApp = backgroundToApp
        self.deliveryMode = deliveryMode
    }
}
