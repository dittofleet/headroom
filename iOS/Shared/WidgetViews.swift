import HeadroomCore
import SwiftUI
import WidgetKit

// The widgets' views live here rather than in the extension, so the app
// can draw them too, for the demo renders.

/// What every widget draws from: the signed-in providers' numbers, as of
/// the entry's date.
struct UsageEntry: TimelineEntry {
    struct Row {
        var id: String
        var name: String
        var glyph: String
        var snapshot: Snapshot?
        var error: String?
    }

    var date: Date
    var rows: [Row]
    var settings: WidgetSettings

    func isDimmed(_ row: Row) -> Bool {
        row.snapshot?.isStale(at: date, after: Shared.staleAfter) ?? true
    }

    /// The limit the provider leads with, as the Mac menu bar picks it.
    func headline(_ row: Row) -> Limit? {
        row.snapshot?.headline(at: date, preferring: settings.limits[row.id])
    }

    /// The weekly limits drawn behind the headline, when Stacked is chosen.
    func behind(_ row: Row) -> [Limit] {
        guard settings.limits[row.id] == stackedChoice else { return [] }
        return row.snapshot?.stackedBehindHeadline(at: date) ?? []
    }

    /// Every limit, the headline first.
    func limitsLeadingWithHeadline(_ row: Row) -> [Limit] {
        let all = row.snapshot?.limits ?? []
        guard let headline = headline(row) else { return all }
        return [headline] + all.filter { $0 != headline }
    }

    /// For the widget gallery, before any sign-in.
    static let sample: UsageEntry = {
        let now = Date()
        func limit(_ kind: Limit.Kind, _ label: String, _ percent: Double, resetsIn: TimeInterval, window: TimeInterval) -> Limit {
            Limit(kind: kind, label: label, percent: percent, resetsAt: now.addingTimeInterval(resetsIn), windowSeconds: window)
        }
        let claude = Snapshot(limits: [
            limit(.session, "Session", 42, resetsIn: 2 * 3600, window: 5 * 3600),
            limit(.weekly, "Weekly", 30, resetsIn: 3 * 86400, window: 7 * 86400),
            limit(.weekly, "Fable Weekly", 63, resetsIn: 3 * 86400, window: 7 * 86400),
        ], plan: "Max 20x", fetchedAt: now)
        let codex = Snapshot(limits: [
            limit(.session, "Session", 13, resetsIn: 4 * 3600, window: 5 * 3600),
            limit(.weekly, "Weekly", 78, resetsIn: 86400, window: 7 * 86400),
        ], plan: "Pro", fetchedAt: now)
        return UsageEntry(date: now, rows: [
            Row(id: "claude", name: "Claude", glyph: "C", snapshot: claude),
            Row(id: "codex", name: "Codex", glyph: "X", snapshot: codex),
        ], settings: WidgetSettings(limits: ["claude": stackedChoice]))
    }()
}

extension UsageEntry.Row {
    init(_ provider: any Provider, _ state: ProviderState) {
        self.init(id: provider.id, name: provider.name, glyph: provider.glyph, snapshot: state.snapshot, error: state.lastError)
    }
}

/// The limit a single-number widget shows.
enum LimitChoice: String, CaseIterable, Sendable {
    /// Whatever the provider leads with in the app's settings.
    case asInApp
    case session, weekly
}

extension UsageEntry {
    /// The limit a single-number widget shows for `choice`.
    func limit(_ choice: LimitChoice, of row: Row) -> Limit? {
        let limits = row.snapshot?.limits ?? []
        switch choice {
        case .asInApp: return headline(row)
        case .session: return limits.first { $0.kind == .session } ?? headline(row)
        case .weekly: return limits.first { $0.kind == .weekly && $0.label == "Weekly" } ?? limits.first { $0.kind == .weekly }
        }
    }
}

struct UsageView: View {
    var entry: UsageEntry
    /// Set to draw a family outside a widget, as the demo renders do.
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily

    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    var body: some View {
        if entry.rows.isEmpty {
            signInPrompt
        } else {
            switch family {
            case .accessoryInline: inline
            case .accessoryRectangular: rectangular
            case .systemSmall: small
            case .systemMedium: medium
            default: large
            }
        }
    }

    @ViewBuilder
    private var signInPrompt: some View {
        switch family {
        case .accessoryInline: Text("Headroom: sign in")
        case .accessoryRectangular: Text("Sign in to Claude or Codex in Headroom").font(.caption)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text("Headroom").font(.headline)
                Text("Sign in to Claude or Codex in the app.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// "C 42%, X 13%"
    private var inline: some View {
        let parts = entry.rows.map { row in
            "\(row.glyph) \(entry.headline(row).map { Format.percent($0.percent(at: entry.date)) } ?? "–")"
        }
        return Text(parts.joined(separator: ", "))
    }

    /// The Mac menu bar icon: per provider a letter, the bar of the limit
    /// it leads with (Stacked draws the weekly limits lighter behind it),
    /// and the number unless numbers are off.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entry.rows, id: \.id) { row in
                let headline = entry.headline(row)
                let behind = entry.behind(row)
                HStack(spacing: 6) {
                    Text(row.glyph).font(.caption.weight(.bold)).frame(width: 12)
                    UsageBar(
                        percent: headline?.percent(at: entry.date) ?? 0,
                        pace: entry.settings.showPace ? headline?.elapsedFraction(at: entry.date) : nil,
                        backdrop: behind.map { $0.percent(at: entry.date) },
                        tint: .primary
                    )
                    .widgetAccentable()
                    if entry.settings.showNumbers {
                        Text(headline.map { Format.percent($0.percent(at: entry.date)) } ?? "–")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// Per provider: the limit it leads with, and the next one.
    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entry.rows, id: \.id) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.caption.weight(.semibold))
                    limits(row, max: 2, showReset: false, font: .caption2, headlineFirst: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// A column per provider, up to three limits each, with countdowns.
    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(entry.rows, id: \.id) { row in
                VStack(alignment: .leading, spacing: 6) {
                    header(row)
                    // Countdowns too, when the column has room for them.
                    limits(row, max: 3, showReset: entry.rows.allSatisfy { ($0.snapshot?.limits.count ?? 0) <= 2 }, font: .caption2)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Everything, like the Mac menu.
    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(entry.rows, id: \.id) { row in
                VStack(alignment: .leading, spacing: 6) {
                    header(row)
                    limits(row, max: 4, showReset: true, font: .caption)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func header(_ row: UsageEntry.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(row.name).font(.caption.weight(.semibold))
            if let plan = row.snapshot?.plan {
                Text(plan).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let snapshot = row.snapshot {
                Text(Format.age(snapshot.fetchedAt, now: entry.date))
                    .font(.caption2)
                    .foregroundStyle(entry.isDimmed(row) ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func limits(_ row: UsageEntry.Row, max count: Int, showReset: Bool, font: Font, headlineFirst: Bool = false) -> some View {
        if let snapshot = row.snapshot {
            let limits = headlineFirst ? entry.limitsLeadingWithHeadline(row) : snapshot.limits
            ForEach(Array(limits.prefix(count).enumerated()), id: \.offset) { _, limit in
                LimitRow(limit: limit, now: entry.date, dimmed: entry.isDimmed(row), showPace: entry.settings.showPace, showReset: showReset, font: font, barHeight: 4)
            }
        } else {
            Text(row.error ?? "No data yet").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// One limit of one provider as a ring, for the lock screen.
struct GaugeFace: View {
    var entry: UsageEntry
    var providerID: String
    var limit: LimitChoice

    var body: some View {
        let row = entry.rows.first { $0.id == providerID }
        let shown = row.flatMap { entry.limit(limit, of: $0) }
        let percent = shown?.percent(at: entry.date)
        Gauge(value: (percent ?? 0) / 100) {
            Text(row?.glyph ?? String(providerID.prefix(1)).uppercased())
        } currentValueLabel: {
            Text(percent.map { "\(Format.wholePercent($0))" } ?? "–").monospacedDigit()
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }
}
