import AppKit
import HeadroomCore

/// Draws the menu bar icon and the menu's rows into a PNG, from the cached
/// state. For docs and for checking the look on a machine you can't see.
@MainActor
enum Render {
    static func png(engine: Engine, to url: URL, dark: Bool, badge: Bool = false, now: Date = Date()) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let views = menuViews(engine: engine, now: now).flatMap { $0 }
        let icon = StatusIcon.image(rows: StatusIcon.rows(engine: engine, now: now), badge: badge)

        let barHeight: CGFloat = 24, padding: CGFloat = 6
        let size = NSSize(width: MenuMetrics.width, height: barHeight + padding * 2 + views.reduce(0) { $0 + $1.frame.height })
        let scale: CGFloat = 2
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()

            // Fake menu bar strip with the icon, tinted the way the system
            // tints a template image.
            let bar = NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            bar.fill()
            let iconRect = NSRect(
                x: bar.maxX - icon.size.width - MenuMetrics.inset, y: bar.midY - icon.size.height / 2,
                width: icon.size.width, height: icon.size.height)
            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                if icon.isTemplate {
                    NSColor.labelColor.setFill()
                    rect.fill(using: .sourceAtop)
                }
                return true
            }
            tinted.draw(in: iconRect)

            var y = bar.minY - padding
            for view in views {
                y -= view.frame.height
                let transform = NSAffineTransform()
                transform.translateX(by: 0, yBy: y)
                NSGraphicsContext.saveGraphicsState()
                transform.concat()
                view.draw(view.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
