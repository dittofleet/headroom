// Draws the app icon and writes AppIcon.icns. Run from the repo root:
//   swift scripts/make-icon.swift
// The icon is the app in miniature: two usage bars, each with its pace tick.
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let unit = size / 1024

    // The standard macOS icon shape: 824pt rounded square on a 1024pt canvas.
    let body = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * unit, yRadius: 185 * unit)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * unit)
    shadow.shadowBlurRadius = 24 * unit
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(white: 0.24, alpha: 1), ending: NSColor(white: 0.11, alpha: 1))!.draw(in: shape, angle: -90)

    func bar(y: CGFloat, fill: CGFloat, color: NSColor, tick: CGFloat) {
        let track = NSRect(x: 232 * unit, y: y * unit, width: 560 * unit, height: 96 * unit)
        let radius = track.height / 2
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        var filled = track
        filled.size.width = track.width * fill
        color.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
        NSColor.white.setFill()
        let tickRect = NSRect(x: track.minX + track.width * tick - 9 * unit, y: track.minY - 30 * unit, width: 18 * unit, height: track.height + 60 * unit)
        NSBezierPath(roundedRect: tickRect, xRadius: 9 * unit, yRadius: 9 * unit).fill()
    }
    bar(y: 560, fill: 0.72, color: NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1), tick: 0.5)
    bar(y: 368, fill: 0.34, color: NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1), tick: 0.8)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
// No 512@2x: the 1024px rendition alone would outweigh the app's binary,
// and nothing shows a menu bar app's icon that large.
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] where points * scale <= 512 {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let png = draw(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
