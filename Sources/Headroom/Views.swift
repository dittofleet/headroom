import AppKit
import HeadroomCore
import HeadroomMac

extension Level {
    var color: NSColor? {
        switch self {
        case .normal: return nil
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

/// The menu bar icon: one row per provider with its letter, a bar, and the
/// percentage of the limit chosen for it. Rows stack two to a column, which
/// keeps it narrow enough for notched displays, and a third starts another.
enum StatusIcon {
    struct Row: Equatable {
        /// The provider's, for reading the icon out.
        var name: String
        var glyph: String
        /// The limit showing, and how much of it is used. nil when there is
        /// no data at all.
        var label: String?
        var percent: Double?
        /// A weekly limit in its own lane under the bar, when Stacked.
        var weekly: Lane?
        var stale: Bool
    }

    struct Lane: Equatable {
        var label: String
        var percent: Double
        /// A model's own weekly, like Fable's, in place of the general one.
        var dotted: Bool
    }

    /// Everything the icon is drawn from. Equal specs draw the same image.
    struct Spec: Equatable {
        var rows: [Row]
        /// A dot: an update is installed and waiting for a restart.
        var badge: Bool
        /// The percentage after each bar.
        var numbers: Bool
        /// Counting down what is left, rather than up with what is used.
        var remaining: Bool
    }

    /// A row per provider, but for those that have never had numbers and
    /// failed to get any, such as one whose CLI isn't signed in. Their
    /// reason is in the menu.
    @MainActor
    static func spec(engine: Engine, chrome: MenuChrome, now: Date) -> Spec {
        let shown = engine.providers.filter { engine.state($0).snapshot != nil || engine.state($0).lastError == nil }
        let rows = (shown.isEmpty ? engine.providers : shown).map { provider -> Row in
            let snapshot = engine.state(provider).snapshot
            let choice = chrome.menuBarLimits[provider.id]
            let headline = snapshot?.headline(at: now, preferring: choice)
            let stack = choice == stackedChoice ? snapshot?.stacked(at: now) : nil
            return Row(
                name: provider.name,
                glyph: provider.glyph,
                label: headline?.label,
                percent: headline?.percent(at: now),
                weekly: stack.map { Lane(label: $0.bottom.label, percent: $0.bottom.percent(at: now), dotted: $0.replacesWeekly) },
                stale: snapshot?.isStale(at: now) ?? true
            )
        }
        return Spec(rows: rows, badge: chrome.updateReady, numbers: chrome.showNumbers, remaining: chrome.showRemaining)
    }

    static func image(_ spec: Spec) -> NSImage {
        let rows = spec.rows
        let rowHeight: CGFloat = rows.count > 1 ? 10 : 14
        let fontSize: CGFloat = rows.count > 1 ? 9 : 11
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let glyphWidth: CGFloat = 9, barWidth: CGFloat = 22, gap: CGFloat = 3, columnGap: CGFloat = 6
        let badgeWidth: CGFloat = spec.badge ? 7 : 0
        let texts = rows.map { row in row.percent.map { "\(Format.wholePercent($0, remaining: spec.remaining))" } ?? "–" }
        let textSizes = texts.map { ($0 as NSString).size(withAttributes: [.font: font]) }
        let perColumn = 2
        // Where each column starts. Numbers are sized to the widest in their
        // column, so a "9" sits as close to its bar as a "74" does. The width
        // only moves when a digit comes or goes.
        var columnX: [CGFloat] = [], width: CGFloat = 0
        for start in stride(from: 0, to: rows.count, by: perColumn) {
            if start > 0 { width += columnGap }
            columnX.append(width)
            let widest = textSizes[start..<min(start + perColumn, rows.count)].map(\.width).max() ?? 0
            width += glyphWidth + barWidth + (spec.numbers ? gap + ceil(widest) : 0)
        }
        let size = NSSize(width: width + badgeWidth, height: rowHeight * CGFloat(max(min(rows.count, perColumn), 1)))
        let levels = rows.map { Level(percent: $0.percent ?? 0) }
        let weeklyLevels = rows.compactMap(\.weekly).map { Level(percent: $0.percent) }
        func isDark(_ appearance: NSAppearance) -> Bool {
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        // What the system would tint the icon, for when it can't. The drawing
        // handler runs again whenever the menu bar turns light or dark.
        let plain = NSColor(name: nil) { isDark($0) ? .white : .black }
        // A warning stays close to the plain ink, with only a hint of its hue.
        func ink(_ level: Level) -> NSColor {
            guard let warning = level.color else { return plain }
            return NSColor(name: nil) { appearance in
                warning.blended(withFraction: 0.65, of: isDark(appearance) ? .white : .black) ?? plain
            }
        }

        let image = NSImage(size: size, flipped: false) { _ in
            for (index, row) in rows.enumerated() {
                let x = columnX[index / perColumn], y = size.height - rowHeight * CGFloat(index % perColumn + 1)
                let color = ink(levels[index])
                let alpha: CGFloat = row.stale || row.percent == nil ? 0.45 : 1
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color.withAlphaComponent(alpha),
                ]

                let glyph = NSAttributedString(string: row.glyph, attributes: attributes)
                glyph.draw(at: NSPoint(x: x, y: y + (rowHeight - glyph.size().height) / 2))

                let barHeight: CGFloat = rows.count > 1 ? 5 : 6
                let track = NSRect(x: x + glyphWidth, y: y + (rowHeight - barHeight) / 2, width: barWidth, height: barHeight)
                func drawLane(_ lane: NSRect, percent: Double?, color: NSColor, dotted: Bool = false) {
                    drawBar(lane, percent: percent, remaining: spec.remaining, trackColor: color.withAlphaComponent(0.25 * alpha), fillColor: color.withAlphaComponent(alpha), minFill: 2, dotted: dotted)
                }
                if let weekly = row.weekly {
                    // Stacked: the top limit on the top half, the weekly
                    // limit in a thinner lane below.
                    let laneHeight = track.height / 2
                    drawLane(NSRect(x: track.minX, y: track.maxY - laneHeight, width: track.width, height: laneHeight), percent: row.percent, color: color)
                    drawLane(NSRect(x: track.minX, y: track.minY, width: track.width, height: laneHeight - 1), percent: weekly.percent, color: ink(Level(percent: weekly.percent)), dotted: weekly.dotted)
                } else {
                    drawLane(track, percent: row.percent, color: color)
                }

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
        image.isTemplate = (levels + weeklyLevels).allSatisfy { $0 == .normal }
        return image
    }
}

/// A rounded track and its fill, which never shrinks below a visible nub
/// while there is any. A dotted fill is a row of short dashes. `percent`
/// is the share used, filled as what is left when `remaining`, and nil
/// leaves the track empty.
private func drawBar(_ track: NSRect, percent: Double?, remaining: Bool, trackColor: NSColor, fillColor: NSColor, minFill: CGFloat? = nil, dotted: Bool = false) {
    let radius = track.height / 2
    trackColor.setFill()
    NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
    let shown = Format.fill(percent, remaining: remaining)
    guard shown > 0 else { return }
    var fill = track
    fill.size.width = max(track.width * shown / 100, minFill ?? track.height)
    fillColor.setFill()
    if dotted {
        for x in stride(from: fill.minX, to: fill.maxX, by: 3) {
            let dash = NSRect(x: x, y: fill.minY, width: min(2, fill.maxX - x), height: fill.height)
            NSBezierPath(roundedRect: dash, xRadius: radius, yRadius: radius).fill()
        }
    } else {
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
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

    /// Counting down what is left. Off unless switched on.
    static var showRemaining: Bool {
        get { UserDefaults.standard.bool(forKey: "showRemaining") }
        set { UserDefaults.standard.set(newValue, forKey: "showRemaining") }
    }

    /// The label of the limit each provider shows in the menu bar icon, by
    /// provider id, or `stackedChoice`. A provider without one shows its
    /// session.
    static var menuBarLimits: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "menuBarLimits") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "menuBarLimits") }
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
    case action(title: String, selector: Selector, key: String = "", tag: Int = 0)
}

/// The parts of the menu that don't come from the engine.
struct MenuChrome {
    var updateStatus: String?
    var updateDetail: String?
    var updateReady: Bool
    var canUpdate: Bool
    var showPace: Bool
    var showNumbers: Bool
    var showRemaining: Bool
    var menuBarLimits: [String: String]
}

@MainActor
func menuEntries(engine: Engine, chrome: MenuChrome, now: Date) -> [MenuEntry] {
    var entries: [MenuEntry] = []
    for group in menuViews(engine: engine, now: now, showPace: chrome.showPace, remaining: chrome.showRemaining) {
        entries += group.map(MenuEntry.view)
        entries.append(.view(SeparatorView()))
    }
    for (index, provider) in engine.providers.enumerated() where provider.usageURL != nil {
        entries.append(.action(title: "Open \(provider.name) Usage Page", selector: #selector(AppDelegate.openUsagePage(_:)), tag: index))
    }
    entries.append(.action(title: "Settings…", selector: #selector(AppDelegate.openSettings), key: ","))
    entries.append(.view(SeparatorView()))
    entries.append(.view(AboutView(status: chrome.updateStatus, detail: chrome.updateDetail)))
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
func menuViews(engine: Engine, now: Date, showPace: Bool, remaining: Bool) -> [[NSView]] {
    engine.providers.map { provider -> [NSView] in
        let state = engine.state(provider)
        let fetching = engine.isFetching(provider)
        let stale = state.snapshot?.isStale(at: now) ?? true
        let detail: HeaderView.Detail = fetching ? .text("Updating…") : state.snapshot.map { .age(since: $0.fetchedAt) } ?? .text("No data")

        var views: [NSView] = [HeaderView(name: provider.name, plan: state.snapshot?.plan, detail: detail, now: now, detailIsProblem: stale && !fetching)]
        views += (state.snapshot?.limits ?? []).map { LimitRowView(limit: $0, now: now, stale: stale, showPace: showPace, remaining: remaining) }
        if let notice = state.notice(at: now) {
            views.append(NoticeView(text: notice))
        }
        return views
    }
}

/// A row that draws from the time, moved forward every second while the
/// menu is open.
@MainActor
protocol Ticking: AnyObject {
    var now: Date { get set }
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
        let font = NSFont.systemFont(ofSize: 11)
        let sign = "⚠ "
        // Further lines hang under the text rather than the sign. Line
        // separators keep it one paragraph, which the indent applies to.
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = (sign as NSString).size(withAttributes: [.font: font]).width
        self.text = NSAttributedString(string: sign + text.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: [
            .font: font, .foregroundColor: NSColor.systemOrange, .paragraphStyle: paragraph,
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

/// The app's version on the left and how updating is going on the right,
/// laid out like a provider heading.
final class AboutView: NSView {
    private let version: NSAttributedString
    private let status: NSAttributedString?

    init(status: String?, detail: String?) {
        version = NSAttributedString(string: "Headroom \(appVersion)", attributes: [
            .font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.disabledControlTextColor,
        ])
        self.status = status.map {
            NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
        }
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 22))
        toolTip = detail
        // Drawn rather than titled, so VoiceOver needs telling what it says.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([version.string, status].compactMap { $0 }.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let left = version.size()
        version.draw(at: NSPoint(x: MenuMetrics.inset, y: (bounds.height - left.height) / 2))
        if let status {
            let right = status.size()
            status.draw(at: NSPoint(x: bounds.width - MenuMetrics.inset - right.width, y: (bounds.height - right.height) / 2))
        }
    }
}

/// Provider heading inside the menu: name and plan on the left, freshness on
/// the right.
final class HeaderView: NSView, Ticking {
    enum Detail {
        case text(String)
        case age(since: Date)
    }

    private let title: NSAttributedString
    private let detail: Detail
    private let detailAttributes: [NSAttributedString.Key: Any]
    var now: Date { didSet { needsDisplay = true } }

    init(name: String, plan: String?, detail: Detail, now: Date, detailIsProblem: Bool) {
        let title = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        if let plan {
            title.append(NSAttributedString(string: "  \(plan)", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        self.title = title
        self.detail = detail
        self.detailAttributes = [
            // Even digits, so a ticking age doesn't wobble.
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: detailIsProblem ? NSColor.systemOrange : NSColor.tertiaryLabelColor,
        ]
        self.now = now
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 24))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let text: String
        switch detail {
        case .text(let string): text = string
        case .age(let date): text = Format.age(date, now: now)
        }
        let drawn = NSAttributedString(string: text, attributes: detailAttributes)
        let detailWidth = drawn.size().width
        drawn.draw(at: NSPoint(x: bounds.width - MenuMetrics.inset - detailWidth, y: 4))
        // A long plan name gives way to the freshness rather than running into it.
        let titleWidth = bounds.width - MenuMetrics.inset * 2 - detailWidth - 8
        title.draw(with: NSRect(x: MenuMetrics.inset, y: 3, width: titleWidth, height: title.size().height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// One limit: label, percentage, a bar with a pace tick, and the reset time.
final class LimitRowView: NSView, Ticking {
    private let limit: Limit
    var now: Date { didSet { needsDisplay = true } }
    private let stale: Bool
    private let showPace: Bool
    private let remaining: Bool

    init(limit: Limit, now: Date, stale: Bool, showPace: Bool, remaining: Bool) {
        self.limit = limit
        self.now = now
        self.stale = stale
        self.showPace = showPace
        self.remaining = remaining
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

        let value = NSAttributedString(string: Format.percent(percent, remaining: remaining), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: stale ? NSColor.secondaryLabelColor : (level.color ?? .labelColor),
        ])
        value.draw(at: NSPoint(x: bounds.width - inset - value.size().width, y: 26))

        let track = NSRect(x: inset, y: 18, width: bounds.width - inset * 2, height: 5)
        drawBar(track, percent: percent, remaining: remaining, trackColor: NSColor.labelColor.withAlphaComponent(0.12), fillColor: accent.withAlphaComponent(stale ? 0.5 : 1))
        // Pace tick: how far through the window we are, or how much of it
        // is left. Fill past the tick, or short of it when counting down,
        // means usage is running ahead of the clock.
        if showPace, let elapsed = limit.elapsedFraction(at: now) {
            let x = track.minX + track.width * (remaining ? 1 - elapsed : elapsed)
            NSColor.labelColor.withAlphaComponent(0.7).setFill()
            NSRect(x: x - 0.75, y: track.minY - 2, width: 1.5, height: track.height + 4).fill()
        }

        let reset = NSAttributedString(string: Format.reset(limit.resetsAt, now: now), attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        reset.draw(at: NSPoint(x: inset, y: 2))
        if let countdown = Format.countdown(limit.resetsAt, now: now) {
            let drawn = NSAttributedString(string: countdown, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            drawn.draw(at: NSPoint(x: bounds.width - inset - drawn.size().width, y: 2))
        }
    }
}

enum MenuMetrics {
    static let width: CGFloat = 270
    static let inset: CGFloat = 14
}
