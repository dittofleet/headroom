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

    /// Everything the icon is drawn from. Equal specs draw the same image.
    struct Spec: Equatable {
        var rows: [Row]
        /// A dot: an update is installed and waiting for a restart.
        var badge: Bool
        /// The percentage after each bar.
        var numbers: Bool
    }

    @MainActor
    static func spec(engine: Engine, chrome: MenuChrome, now: Date) -> Spec {
        let rows = engine.providers.map { provider -> Row in
            let snapshot = engine.state(provider).snapshot
            return Row(
                glyph: provider.glyph,
                percent: snapshot?.headline(at: now)?.percent(at: now),
                stale: snapshot?.isStale(at: now) ?? true
            )
        }
        return Spec(rows: rows, badge: chrome.updateReady, numbers: chrome.showNumbers)
    }

    static func image(_ spec: Spec) -> NSImage {
        let rows = spec.rows
        let rowHeight: CGFloat = rows.count > 1 ? 10 : 14
        let fontSize: CGFloat = rows.count > 1 ? 9 : 11
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let glyphWidth: CGFloat = 9, barWidth: CGFloat = 22, gap: CGFloat = 3
        let badgeWidth: CGFloat = spec.badge ? 7 : 0
        let texts = rows.map { row in row.percent.map { "\(Format.wholePercent($0))" } ?? "–" }
        let textSizes = texts.map { ($0 as NSString).size(withAttributes: [.font: font]) }
        // Sized to the widest number showing, so a "9" sits as close to its
        // bar as a "74" does. The width only moves when a digit comes or goes.
        let numberWidth: CGFloat = spec.numbers ? gap + ceil(textSizes.map(\.width).max() ?? 0) : 0
        let size = NSSize(width: glyphWidth + barWidth + numberWidth + badgeWidth, height: rowHeight * CGFloat(max(rows.count, 1)))
        let levels = rows.map { Level(percent: $0.percent ?? 0) }
        // What the system would tint the icon, for when it can't. The drawing
        // handler runs again whenever the menu bar turns light or dark.
        let plain = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
        }

        let image = NSImage(size: size, flipped: false) { _ in
            for (index, row) in rows.enumerated() {
                let y = size.height - rowHeight * CGFloat(index + 1)
                let color = levels[index].color ?? plain
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

                if spec.numbers {
                    (texts[index] as NSString).draw(at: NSPoint(x: track.maxX + gap, y: y + (rowHeight - textSizes[index].height) / 2), withAttributes: attributes)
                }
            }
            if spec.badge {
                plain.setFill()
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
    /// The pace tick on each bar.
    static var showPace: Bool {
        get { flag("showPace") }
        set { UserDefaults.standard.set(newValue, forKey: "showPace") }
    }

    /// The percentages in the menu bar icon.
    static var showNumbers: Bool {
        get { flag("showNumbers") }
        set { UserDefaults.standard.set(newValue, forKey: "showNumbers") }
    }

    /// On unless switched off.
    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

/// One line of the menu. The app turns these into NSMenuItems and --render
/// draws them, so the two can't drift apart.
enum MenuEntry {
    case view(NSView)
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
        entries.append(.view(SeparatorView()))
    }
    entries.append(.action(title: "Refresh Now", selector: #selector(AppDelegate.refreshNow), key: "r"))
    for (index, provider) in engine.providers.enumerated() {
        entries.append(.action(title: "Open \(provider.name) Usage Page", selector: #selector(AppDelegate.openUsagePage(_:)), tag: index))
    }
    entries.append(.view(SeparatorView()))
    entries.append(.action(title: "Show Pace Marker", selector: #selector(AppDelegate.toggleShowPace), checked: chrome.showPace))
    entries.append(.action(title: "Show Numbers in Menu Bar", selector: #selector(AppDelegate.toggleShowNumbers), checked: chrome.showNumbers))
    entries.append(.action(title: "Start at Login", selector: #selector(AppDelegate.toggleStartAtLogin), checked: chrome.startAtLogin))
    entries.append(.view(SeparatorView()))
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

/// A divider drawn by the app rather than the system, so it spans the same
/// width as the rows around it. The system separator is indented to where
/// menu item titles start, which is past where the rows begin.
final class SeparatorView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 11))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: MenuMetrics.inset, y: 5, width: bounds.width - MenuMetrics.inset * 2, height: 1).fill()
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
        let detailWidth = detail.size().width
        detail.draw(at: NSPoint(x: bounds.width - MenuMetrics.inset - detailWidth, y: 4))
        // A long plan name gives way to the freshness rather than running into it.
        let titleWidth = bounds.width - MenuMetrics.inset * 2 - detailWidth - 8
        title.draw(with: NSRect(x: MenuMetrics.inset, y: 3, width: titleWidth, height: title.size().height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
