import AppKit
import HeadroomCore

/// Draws the menu bar icon and the menu's rows into a PNG, from the cached
/// state. For docs and for checking the look on a machine you can't see.
@MainActor
enum Render {
    static func png(engine: Engine, to url: URL, dark: Bool, updateReady: Bool = false, now: Date = Date()) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var chrome = AppDelegate(engine: engine).chrome
        if updateReady { (chrome.updateReady, chrome.about) = (true, chrome.about + " · v0.0.2 is ready") }
        let entries = menuEntries(engine: engine, chrome: chrome, now: now)
        let icon = StatusIcon.image(StatusIcon.spec(engine: engine, chrome: chrome, now: now))
        func height(_ entry: MenuEntry) -> CGFloat {
            switch entry {
            case .view(let view): return view.frame.height
            case .info, .action, .submenu: return 22
            case .separator: return 11
            }
        }

        let barHeight: CGFloat = 24, padding: CGFloat = 6
        let size = NSSize(width: MenuMetrics.width, height: barHeight + padding * 2 + entries.reduce(0) { $0 + height($1) })
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
            // Standard items are approximated; the custom rows are the
            // app's own views, drawn by their own code.
            let font = NSFont.menuFont(ofSize: 13)
            func text(_ string: String, x: CGFloat, color: NSColor, rightAligned: Bool = false) {
                let drawn = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
                drawn.draw(at: NSPoint(x: rightAligned ? x - drawn.size().width : x, y: y + (22 - drawn.size().height) / 2))
            }
            // Checked items live in Settings, which isn't drawn, and AppKit
            // leaves no checkmark column in a menu without any.
            let textX = MenuMetrics.inset
            for entry in entries {
                y -= height(entry)
                switch entry {
                case .view(let view):
                    let transform = NSAffineTransform()
                    transform.translateX(by: 0, yBy: y)
                    NSGraphicsContext.saveGraphicsState()
                    transform.concat()
                    view.draw(view.bounds)
                    NSGraphicsContext.restoreGraphicsState()
                case .info(let string, _):
                    text(string, x: textX, color: .tertiaryLabelColor)
                case .action(let title, _, let key, _, _):
                    text(title, x: textX, color: .labelColor)
                    if !key.isEmpty { text("⌘\(key.uppercased())", x: size.width - MenuMetrics.inset, color: .tertiaryLabelColor, rightAligned: true) }
                case .separator:
                    NSColor.separatorColor.setFill()
                    NSRect(x: MenuMetrics.inset, y: y + 5, width: size.width - MenuMetrics.inset * 2, height: 1).fill()
                case .submenu(let title, _):
                    text(title, x: textX, color: .labelColor)
                    text("›", x: size.width - MenuMetrics.inset, color: .secondaryLabelColor, rightAligned: true)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
