import AppKit
import HeadroomCore

enum Level {
    case normal, warning, critical

    init(percent: Double) {
        self = percent >= 90 ? .critical : percent >= 75 ? .warning : .normal
    }

    var color: NSColor? {
        switch self {
        case .normal: return nil
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

/// The menu bar icon: one row per provider with its letter, a bar, and the
/// headline percentage. Two stacked rows keep it narrow enough for notched
/// displays.
enum StatusIcon {
    struct Row {
        var glyph: String
        /// nil when there is no data at all.
        var percent: Double?
        var stale: Bool
    }

    static func image(rows: [Row]) -> NSImage {
        let rowHeight: CGFloat = rows.count > 1 ? 10 : 14
        let fontSize: CGFloat = rows.count > 1 ? 9 : 11
        let glyphWidth: CGFloat = 9, barWidth: CGFloat = 22, numberWidth: CGFloat = fontSize * 2.1
        let size = NSSize(width: glyphWidth + barWidth + 4 + numberWidth, height: rowHeight * CGFloat(max(rows.count, 1)))
        let levels = rows.map { Level(percent: $0.percent ?? 0) }

        let image = NSImage(size: size, flipped: false) { _ in
            for (index, row) in rows.enumerated() {
                let y = size.height - rowHeight * CGFloat(index + 1)
                let color = levels[index].color ?? .black
                let alpha: CGFloat = row.stale || row.percent == nil ? 0.45 : 1
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: color.withAlphaComponent(alpha),
                ]

                let glyph = NSAttributedString(string: row.glyph, attributes: attributes)
                glyph.draw(at: NSPoint(x: 0, y: y + (rowHeight - glyph.size().height) / 2))

                let barHeight: CGFloat = rows.count > 1 ? 5 : 6
                let track = NSRect(x: glyphWidth, y: y + (rowHeight - barHeight) / 2, width: barWidth, height: barHeight)
                color.withAlphaComponent(0.25 * alpha).setFill()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                if let percent = row.percent, percent > 0 {
                    var fill = track
                    fill.size.width = max(track.width * percent / 100, 2)
                    color.withAlphaComponent(alpha).setFill()
                    NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
                }

                let text = row.percent.map { "\(Int($0.rounded(.down)))" } ?? "–"
                let number = NSAttributedString(string: text, attributes: attributes)
                number.draw(at: NSPoint(x: size.width - number.size().width, y: y + (rowHeight - number.size().height) / 2))
            }
            return true
        }
        // A template image follows the menu bar's light/dark tint exactly;
        // give that up only when there is a warning color to show.
        image.isTemplate = levels.allSatisfy { $0 == .normal }
        return image
    }
}

/// Provider heading inside the menu: name and plan on the left, freshness on
/// the right.
final class HeaderView: NSView {
    private let title: NSAttributedString
    private let detail: NSAttributedString

    init(name: String, plan: String?, detail: String, detailIsProblem: Bool) {
        let title = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        if let plan {
            title.append(NSAttributedString(string: "  \(plan)", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        self.title = title
        self.detail = NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: detailIsProblem ? NSColor.systemOrange : NSColor.tertiaryLabelColor,
        ])
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 24))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        title.draw(at: NSPoint(x: MenuMetrics.inset, y: 3))
        detail.draw(at: NSPoint(x: bounds.width - MenuMetrics.inset - detail.size().width, y: 4))
    }
}

/// One limit: label, percentage, a bar with a pace tick, and the reset time.
final class LimitRowView: NSView {
    private let limit: Limit
    private let now: Date
    private let stale: Bool

    init(limit: Limit, now: Date, stale: Bool) {
        self.limit = limit
        self.now = now
        self.stale = stale
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 44))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let percent = limit.percent(at: now)
        let accent = Level(percent: percent).color ?? .controlAccentColor
        let inset = MenuMetrics.inset

        let label = NSAttributedString(string: limit.label, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
        ])
        label.draw(at: NSPoint(x: inset, y: 26))

        let value = NSAttributedString(string: Format.percent(percent), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: stale ? NSColor.secondaryLabelColor : (Level(percent: percent).color ?? .labelColor),
        ])
        value.draw(at: NSPoint(x: bounds.width - inset - value.size().width, y: 26))

        let track = NSRect(x: inset, y: 18, width: bounds.width - inset * 2, height: 5)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        if percent > 0 {
            var fill = track
            fill.size.width = max(track.width * percent / 100, 5)
            accent.withAlphaComponent(stale ? 0.5 : 1).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
        }
        // Pace tick: how far through the window we are. Fill past the tick
        // means usage is running ahead of the clock.
        if let elapsed = limit.elapsedFraction(at: now) {
            let x = track.minX + track.width * elapsed
            NSColor.labelColor.withAlphaComponent(0.7).setFill()
            NSRect(x: x - 0.75, y: track.minY - 2, width: 1.5, height: track.height + 4).fill()
        }

        let reset = NSAttributedString(string: Format.reset(limit.resetsAt, now: now), attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        reset.draw(at: NSPoint(x: inset, y: 2))
    }
}

enum MenuMetrics {
    static let width: CGFloat = 270
    static let inset: CGFloat = 14
}
