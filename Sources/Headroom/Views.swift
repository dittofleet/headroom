import AppKit
import HeadroomCore

enum Level {
    case normal, warning, critical

    init(percent: Double) {
        self = percent >= Limit.criticalPercent ? .critical : percent >= Limit.warningPercent ? .warning : .normal
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
    struct Row: Equatable {
        var glyph: String
        /// nil when there is no data at all.
        var percent: Double?
        var stale: Bool
    }

    @MainActor
    static func rows(engine: Engine, now: Date) -> [Row] {
        engine.providers.map { provider in
            let snapshot = engine.state(provider).snapshot
            return Row(
                glyph: provider.glyph,
                percent: snapshot?.headline(at: now)?.percent(at: now),
                stale: snapshot?.isStale(at: now) ?? true
            )
        }
    }

    /// `badge` adds a dot: an update is installed and waiting for a restart.
    /// `numbers` puts the percentage after each bar.
    static func image(rows: [Row], badge: Bool = false, numbers: Bool = true) -> NSImage {
        let rowHeight: CGFloat = rows.count > 1 ? 10 : 14
        let fontSize: CGFloat = rows.count > 1 ? 9 : 11
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let glyphWidth: CGFloat = 9, barWidth: CGFloat = 22, gap: CGFloat = 3
        let badgeWidth: CGFloat = badge ? 7 : 0
        let texts = rows.map { row in row.percent.map { "\(Format.wholePercent($0))" } ?? "–" }
        // Sized to the widest number showing, so a "9" sits as close to its
        // bar as a "74" does. The width only moves when a digit comes or goes.
        let numberWidth: CGFloat = numbers
            ? gap + ceil(texts.map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }.max() ?? 0)
            : 0
        let size = NSSize(width: glyphWidth + barWidth + numberWidth + badgeWidth, height: rowHeight * CGFloat(max(rows.count, 1)))
        let levels = rows.map { Level(percent: $0.percent ?? 0) }

        let image = NSImage(size: size, flipped: false) { _ in
            for (index, row) in rows.enumerated() {
                let y = size.height - rowHeight * CGFloat(index + 1)
                let color = levels[index].color ?? .black
                let alpha: CGFloat = row.stale || row.percent == nil ? 0.45 : 1
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color.withAlphaComponent(alpha),
                ]

                let glyph = NSAttributedString(string: row.glyph, attributes: attributes)
                glyph.draw(at: NSPoint(x: 0, y: y + (rowHeight - glyph.size().height) / 2))

                let barHeight: CGFloat = rows.count > 1 ? 5 : 6
                let track = NSRect(x: glyphWidth, y: y + (rowHeight - barHeight) / 2, width: barWidth, height: barHeight)
                drawBar(in: track, percent: row.percent ?? 0, track: color.withAlphaComponent(0.25 * alpha), fill: color.withAlphaComponent(alpha), minFill: 2)

                if numbers {
                    let number = NSAttributedString(string: texts[index], attributes: attributes)
                    number.draw(at: NSPoint(x: track.maxX + gap, y: y + (rowHeight - number.size().height) / 2))
                }
            }
            if badge {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: size.width - 4, y: (size.height - 4) / 2, width: 4, height: 4)).fill()
            }
            return true
        }
        // A template image follows the menu bar's light/dark tint exactly;
        // give that up only when there is a warning color to show.
        image.isTemplate = levels.allSatisfy { $0 == .normal }
        return image
    }
}

/// A rounded track with a fill that never shrinks below a visible nub.
private func drawBar(in track: NSRect, percent: Double, track trackColor: NSColor, fill fillColor: NSColor, minFill: CGFloat? = nil) {
    let radius = track.height / 2
    trackColor.setFill()
    NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
    guard percent > 0 else { return }
    var fill = track
    fill.size.width = max(track.width * percent / 100, minFill ?? track.height)
    fillColor.setFill()
    NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
}

enum Preferences {
    /// The pace tick on each bar. On unless switched off.
    static var showPace: Bool {
        get { UserDefaults.standard.object(forKey: "showPace") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showPace") }
    }

    /// The percentages in the menu bar icon. On unless switched off.
    static var showNumbers: Bool {
        get { UserDefaults.standard.object(forKey: "showNumbers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showNumbers") }
    }
}

/// One line of the menu. The app turns these into NSMenuItems and --render
/// draws them, so the two can't drift apart.
enum MenuEntry {
    case view(NSView)
    case separator
    case info(String, toolTip: String? = nil)
    case action(title: String, selector: Selector, key: String = "", checked: Bool = false, tag: Int = 0)
}

/// The parts of the menu that don't come from the engine.
struct MenuChrome {
    var about: String
    var aboutDetail: String?
    var updateReady: Bool
    var canUpdate: Bool
    var startAtLogin: Bool
    var showPace: Bool
    var showNumbers: Bool
}

@MainActor
func menuEntries(engine: Engine, chrome: MenuChrome, now: Date) -> [MenuEntry] {
    var entries: [MenuEntry] = []
    for group in menuViews(engine: engine, now: now, showPace: chrome.showPace) {
        entries += group.map(MenuEntry.view)
        entries.append(.separator)
    }
    entries.append(.action(title: "Refresh Now", selector: #selector(AppDelegate.refreshNow), key: "r"))
    for (index, provider) in engine.providers.enumerated() {
        entries.append(.action(title: "Open \(provider.name) Usage Page", selector: #selector(AppDelegate.openUsagePage(_:)), tag: index))
    }
    entries.append(.separator)
    entries.append(.action(title: "Show Pace", selector: #selector(AppDelegate.toggleShowPace), checked: chrome.showPace))
    entries.append(.action(title: "Show Numbers in Menu Bar", selector: #selector(AppDelegate.toggleShowNumbers), checked: chrome.showNumbers))
    entries.append(.action(title: "Start at Login", selector: #selector(AppDelegate.toggleStartAtLogin), checked: chrome.startAtLogin))
    entries.append(.separator)
    entries.append(.info(chrome.about, toolTip: chrome.aboutDetail))
    if chrome.updateReady {
        entries.append(.action(title: "Restart to Update", selector: #selector(AppDelegate.restartToUpdate)))
    } else if chrome.canUpdate {
        entries.append(.action(title: "Check for Updates", selector: #selector(AppDelegate.checkForUpdates)))
    }
    entries.append(.action(title: "Quit Headroom", selector: #selector(AppDelegate.quit), key: "q"))
    return entries
}

/// Everything the menu shows above its actions, one group per provider: a
/// heading, its limits, and the reason when the last refresh failed.
@MainActor
func menuViews(engine: Engine, now: Date, showPace: Bool) -> [[NSView]] {
    engine.providers.map { provider -> [NSView] in
        let state = engine.state(provider)
        let fetching = engine.isFetching(provider)
        let stale = state.snapshot?.isStale(at: now) ?? true
        let detail = fetching ? "Updating…" : state.snapshot.map { Format.age($0.fetchedAt, now: now) } ?? "No data"

        var views: [NSView] = [HeaderView(name: provider.name, plan: state.snapshot?.plan, detail: detail, detailIsProblem: stale && !fetching)]
        views += (state.snapshot?.limits ?? []).map { LimitRowView(limit: $0, now: now, stale: stale, showPace: showPace) }
        if let error = state.lastError {
            let wait = state.nextFetchAt.timeIntervalSince(now)
            views.append(NoticeView(text: wait > 0 ? "\(error) · retry in \(Format.duration(wait))" : error))
        }
        return views
    }
}

/// Why the numbers above it are not fresh. Wraps, since reasons run long.
final class NoticeView: NSView {
    // Measured and drawn with the same options, or the last line clips.
    private static let drawing: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
    private let text: NSAttributedString

    init(text: String) {
        self.text = NSAttributedString(string: "⚠ \(text)", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemOrange,
        ])
        let width = MenuMetrics.width - MenuMetrics.inset * 2
        let height = ceil(self.text.boundingRect(with: NSSize(width: width, height: 200), options: Self.drawing).height)
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: height + 10))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(with: bounds.insetBy(dx: MenuMetrics.inset, dy: 4), options: Self.drawing)
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
    private let showPace: Bool

    init(limit: Limit, now: Date, stale: Bool, showPace: Bool) {
        self.limit = limit
        self.now = now
        self.stale = stale
        self.showPace = showPace
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 44))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let percent = limit.percent(at: now)
        let level = Level(percent: percent)
        let accent = level.color ?? .controlAccentColor
        let inset = MenuMetrics.inset

        let label = NSAttributedString(string: limit.label, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
        ])
        label.draw(at: NSPoint(x: inset, y: 26))

        let value = NSAttributedString(string: Format.percent(percent), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: stale ? NSColor.secondaryLabelColor : (level.color ?? .labelColor),
        ])
        value.draw(at: NSPoint(x: bounds.width - inset - value.size().width, y: 26))

        let track = NSRect(x: inset, y: 18, width: bounds.width - inset * 2, height: 5)
        drawBar(in: track, percent: percent, track: NSColor.labelColor.withAlphaComponent(0.12), fill: accent.withAlphaComponent(stale ? 0.5 : 1))
        // Pace tick: how far through the window we are. Fill past the tick
        // means usage is running ahead of the clock.
        if showPace, let elapsed = limit.elapsedFraction(at: now) {
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
