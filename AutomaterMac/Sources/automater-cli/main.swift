import CoreGraphics
import Foundation
import AutomaterKit

// automater-cli — debug/driver entrypoint for the E2E harness.
//
// Commands:
//   --version
//   cursor
//   click-fixed --x N --y N [--interval MS] [--repeat N] [--kind K]
//               [--button B] [--bg] [--app-name S] [--window-title S]
//   multipoint (--point X,Y [--point-pid P])... [--interval MS] [--repeat N]
//              [--bg]

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
    exit(2)
}

struct FlagReader {
    let args: [String]

    init(args: [String]) {
        self.args = args
    }

    func next(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: "--" + flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func has(_ flag: String) -> Bool {
        args.contains("--" + flag)
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    print("automater-cli 0.2.1")
    exit(0)
}
var flags = FlagReader(args: Array(argv.dropFirst()))

switch command {

case "--version":
    print("automater-cli 0.2.1")
    exit(0)

case "cursor":
    let loc = EventPoster.cursorLocation
    print("\(Int(loc.x)),\(Int(loc.y))")
    exit(0)

case "trusted":
    print(AXBridge.isTrustedForAccessibility ? "yes" : "no")
    exit(0)

case "axprobe":
    guard let pid = flags.next("pid").flatMap(Int.init),
          let xs = flags.next("x"), let x = Double(xs),
          let ys = flags.next("y"), let y = Double(ys)
    else { fail("axprobe needs --pid --x --y") }
    print(AXBridge.describeElementAt(appPID: pid_t(pid), x: x, y: y))
    exit(0)

case "click-fixed":
    guard let xs = flags.next("x"), let x = Int(xs),
          let ys = flags.next("y"), let y = Int(ys)
    else { fail("click-fixed needs --x and --y") }

    var config = ClickerConfig()
    config.mode = .fixedPoint
    config.fixedScreenX = x
    config.fixedScreenY = y
    config.intervalMs = Int(flags.next("interval") ?? "") ?? 100
    config.repeatCount = Int(flags.next("repeat") ?? "") ?? 1
    config.clickKind = ClickKind(rawValue: flags.next("kind") ?? "single") ?? .single
    config.button = MouseButton(rawValue: flags.next("button") ?? "left") ?? .left
    config.appName = flags.next("app-name")
    config.windowTitle = flags.next("window-title")
    config.backgroundToApp = flags.has("bg")

    // Explicit background target pinning (skips fuzzy name resolution).
    config.targetPid = flags.next("pid").flatMap(Int.init)
    config.targetWindowId = flags.next("window-id").flatMap(Int.init)
    if let dm = flags.next("delivery") {
        config.deliveryMode = ClickerConfig.DeliveryMode(rawValue: dm) ?? .events
    }

    if config.backgroundToApp,
       config.appName == nil && config.windowTitle == nil && config.targetPid == nil {
        fail("background delivery needs --app-name, --window-title, or --pid")
    }

    // Window-space fixed points come as --local-x/--local-y + window identity.
    if let lx = flags.next("local-x"), let ly = flags.next("local-y") {
        config.fixedCoordSpace = .window
        config.fixedLocalX = Double(lx) ?? 0
        config.fixedLocalY = Double(ly) ?? 0
        if let wid = flags.next("window-id") { config.fixedWindowId = Int(wid) }
    }

    let engine = ClickerEngine()
    let done = DispatchSemaphore(value: 0)
    let runConfig = config
    Task {
        await engine.start(config: runConfig) { msg in
            FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
        }
        while await engine.isBusy { try? await Task.sleep(nanoseconds: 50_000_000) }
        let n = await engine.clicksPerformed
        FileHandle.standardError.write(("performed=" + String(n) + "\n").data(using: .utf8)!)
        done.signal()
    }
    done.wait()
    exit(0)

case "multipoint":
    var specs: [PointSpec] = []
    var index = 0
    while index < argv.count {
        guard argv[index] == "--point", index + 1 < argv.count else {
            index += 1
            continue
        }
        let parts = argv[index + 1].split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { fail("bad --point \(argv[index + 1])") }
        // Optional trailing "--point-pid <n>"
        var pid: Int?
        if index + 3 < argv.count, argv[index + 2] == "--point-pid",
           let parsed = Int(argv[index + 3]) {
            pid = parsed
            index += 2
        }
        specs.append(PointSpec(x: Int(parts[0]), y: Int(parts[1]), pid: pid))
        index += 2
    }
    guard !specs.isEmpty else { fail("multipoint needs at least one --point") }

    var config = ClickerConfig()
    config.mode = .multipoint
    config.multipoints = specs
    config.intervalMs = Int(flags.next("interval") ?? "") ?? 100
    config.repeatCount = Int(flags.next("repeat") ?? "") ?? specs.count
    config.clickKind = ClickKind(rawValue: flags.next("kind") ?? "single") ?? .single
    config.backgroundToApp = flags.has("bg")
    if let dm = flags.next("delivery") {
        config.deliveryMode = ClickerConfig.DeliveryMode(rawValue: dm) ?? .events
    }

    let engine = ClickerEngine()
    let done = DispatchSemaphore(value: 0)
    let runConfig = config
    Task {
        await engine.start(config: runConfig) { msg in
            FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
        }
        while await engine.isBusy { try? await Task.sleep(nanoseconds: 50_000_000) }
        let n = await engine.clicksPerformed
        FileHandle.standardError.write(("performed=" + String(n) + "\n").data(using: .utf8)!)
        done.signal()
    }
    done.wait()
    exit(0)

case "gestures":
    // Diagnostic: dump the raw gesture stream (event types 29/31) with all
    // candidate fields — used to tune the recorder's swipe mapping.
    let mask: CGEventMask = (1 << 29) | (1 << 31)
    let callback: CGEventTapCallBack = { _, type, event, _ in
        var line = "type=\(type.rawValue)"
        for field in 100...140 {
            guard let f = CGEventField(rawValue: UInt32(field)) else { continue }
            let v = event.getIntegerValueField(f)
            if v != 0 { line += " f\(field)=\(v)" }
        }
        let d = event.getDoubleValueField(CGEventField(rawValue: 123) ?? .scrollWheelEventScrollPhase)
        if d != 0 { line += String(format: " f123d=%.2f", d) }
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        return Unmanaged.passUnretained(event)
    }
    guard let port = CGEvent.tapCreate(
        tap: .cghidEventTap, place: .headInsertEventTap,
        options: .listenOnly, eventsOfInterest: mask,
        callback: callback, userInfo: nil
    ) else { fail("gestures needs Accessibility permission") }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    CGEvent.tapEnable(tap: port, enable: true)
    FileHandle.standardError.write("listening 30s — do a three-finger swipe now\n".data(using: .utf8)!)
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { exit(0) }
    dispatchMain()

case "resolve":
    // Debug: show what a background target resolves to.
    let pid = flags.next("pid").flatMap(Int.init)
    let target = ClickerEngine.resolveBackgroundTarget(
        pid: pid,
        bundleId: flags.next("bundle-id"),
        appName: flags.next("app-name"),
        title: flags.next("window-title"),
        windowId: flags.next("window-id").flatMap(Int.init)
    )
    print("pid=\(target.pid.map(String.init) ?? "nil") "
        + "window=\(target.windowNumber.map(String.init) ?? "nil")")
    exit(0)

default:
    fail("unknown command \(command)")
}
