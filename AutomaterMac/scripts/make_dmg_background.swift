import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "background.png")
let size = NSSize(width: 680, height: 420)
let image = NSImage(size: size)
image.lockFocus()
let rect = NSRect(origin: .zero, size: size)
let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.06, green: 0.05, blue: 0.18, alpha: 1),
                                    NSColor(calibratedRed: 0.16, green: 0.09, blue: 0.40, alpha: 1)])!
gradient.draw(in: rect, angle: -30)
let title = "A little less repetition"
let subtitle = "Drag Tandem to Applications — then click less, do more."
let titleStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: NSColor.white]
let subStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.78)]
title.draw(at: NSPoint(x: 218, y: 350), withAttributes: titleStyle)
subtitle.draw(at: NSPoint(x: 185, y: 324), withAttributes: subStyle)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 280, y: 185)); arrow.line(to: NSPoint(x: 405, y: 185)); arrow.line(to: NSPoint(x: 385, y: 205)); arrow.move(to: NSPoint(x: 405, y: 185)); arrow.line(to: NSPoint(x: 385, y: 165))
NSColor(calibratedRed: 0.30, green: 0.96, blue: 1, alpha: 0.9).setStroke(); arrow.lineWidth = 5; arrow.lineCapStyle = .round; arrow.stroke()
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { fatalError("Could not create DMG background") }
try png.write(to: output)
