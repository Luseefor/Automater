// Generates the app icon from the same vector artwork used in the app.
// Run scripts/make_icon.sh from any directory.
import AppKit
import Foundation

@main
struct IconBuilder {
    static func main() throws {
        let assets = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = assets.appendingPathComponent("Automater.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries: [(Int, String)] = [
            (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
        ]
        for (size, name) in entries {
            let image = AutomaterBrand.icon(side: CGFloat(size))
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
        }
        print("Generated \(entries.count) icon sizes")
    }
}
