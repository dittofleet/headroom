import HeadroomCore
import SwiftUI
import WidgetKit

// The widgets' views live here rather than in the extension, so the app
// can draw them too, for the demo renders.

/// What every widget draws from: the signed-in accounts' numbers, as of
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

    /// The limit the account leads with, as the Mac menu bar picks it.
    func headline(_ row: Row) -> Limit? {
        row.snapshot?.headline(at: date, preferring: settings.limits[row.id])
    }

    /// The weekly limit under the headline, when Stacked is chosen.
    func stackedWeekly(_ row: Row) -> Limit? {
        guard settings.limits[row.id] == stackedChoice else { return nil }
        return row.snapshot?.stackedWeekly(at: date)
    }

    /// Every limit, the headline first.
    func limitsLeadingWithHeadline(_ row: Row) -> [Limit] {
        let all = row.snapshot?.limits ?? []
        guard let headline = headline(row) else { return all }
        return [headline] + all.filter { $0 != headline }
    }

    /// For the widget gallery, before any sign-in: one account per service,
    /// or with more `accounts`, a second of each.
    static func sample(accounts: Int = 2) -> UsageEntry {
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
        let claude2 = Snapshot(limits: [
            limit(.session, "Session", 71, resetsIn: 3600, window: 5 * 3600),
            limit(.weekly, "Weekly", 44, resetsIn: 5 * 86400, window: 7 * 86400),
        ], plan: "Pro", fetchedAt: now)
        let codex2 = Snapshot(limits: [
            limit(.session, "Session", 5, resetsIn: 4.5 * 3600, window: 5 * 3600),
            limit(.weekly, "Weekly", 22, resetsIn: 6 * 86400, window: 7 * 86400),
        ], plan: "Plus", fetchedAt: now)
        let shown = [(Service.claude, claude), (.codex, codex), (.claude, claude2), (.codex, codex2)].prefix(accounts)
        let rows = Service.allCases.flatMap { service in
            let snapshots = shown.filter { $0.0 == service }.map(\.1)
            return snapshots.enumerated().map { index, snapshot in
                let account = Account(service: service, number: index + 1, of: snapshots.count)
                return Row(id: account.id, name: account.name, glyph: account.glyph, snapshot: snapshot)
            }
        }
        return UsageEntry(date: now, rows: rows, settings: WidgetSettings(limits: [Service.claude.id(1): stackedChoice]))
    }
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

    /// The Mac menu bar icon: per account a glyph, the bar of the limit
    /// it leads with (Stacked adds a weekly limit under it),
    /// and the number unless numbers are off.
    private var rectangular: some View {
        // Wider for numbered glyphs, and closer together past two accounts.
        let glyphWidth: CGFloat = entry.rows.contains { $0.glyph.count > 1 } ? 18 : 12
        return VStack(alignment: .leading, spacing: entry.rows.count > 2 ? 2 : 6) {
            ForEach(entry.rows, id: \.id) { row in
                let headline = entry.headline(row)
                let weekly = entry.stackedWeekly(row)
                HStack(spacing: 6) {
                    Text(row.glyph).font(.caption.weight(.bold)).frame(width: glyphWidth, alignment: .leading)
                    // Stacked: the session, and the weekly limit in a
                    // thinner lane under it, like the Mac menu bar.
                    VStack(spacing: 1) {
                        UsageBar(
                            percent: headline?.percent(at: entry.date) ?? 0,
                            pace: entry.settings.showPace ? headline?.elapsedFraction(at: entry.date) : nil,
                            tint: .primary,
                            height: weekly == nil ? 5 : 3.5
                        )
                        if let weekly {
                            UsageBar(percent: weekly.percent(at: entry.date), tint: .primary, height: 2.5)
                        }
                    }
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

    /// Per account: the limit it leads with, and the next one. Past two
    /// accounts, just the one it leads with, under the account's name.
    private var small: some View {
        VStack(alignment: .leading, spacing: entry.rows.count > 2 ? 10 : 8) {
            ForEach(entry.rows, id: \.id) { row in
                if entry.rows.count > 2 {
                    limits(row, max: 1, showReset: false, font: .caption2, headlineFirst: true, title: row.name)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).font(.caption.weight(.semibold))
                        limits(row, max: 2, showReset: false, font: .caption2, headlineFirst: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// A column per account, up to three limits each, with countdowns when
    /// there is room. Four accounts take two rows of two.
    private var medium: some View {
        let count = entry.rows.count
        let roomForResets = count <= 2 && entry.rows.allSatisfy { ($0.snapshot?.limits.count ?? 0) <= 2 }
        return VStack(alignment: .leading, spacing: 0) {
            grid(columns: count <= 3 ? count : 2, spacing: 10) { row in
                VStack(alignment: .leading, spacing: count > 3 ? 4 : 6) {
                    // Three columns leave no room for the plan.
                    header(row, showPlan: count != 3)
                    limits(row, max: count > 3 ? 2 : 3, showReset: roomForResets, font: .caption2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Everything, like the Mac menu. Past two accounts, in two columns.
    private var large: some View {
        let count = entry.rows.count
        return VStack(alignment: .leading, spacing: 0) {
            grid(columns: count <= 2 ? 1 : 2, spacing: count <= 2 ? 10 : 12) { row in
                VStack(alignment: .leading, spacing: 6) {
                    header(row)
                    limits(row, max: count <= 2 ? 4 : 3, showReset: true, font: count <= 2 ? .caption : .caption2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The accounts `columns` to a row, each column as wide as the others.
    private func grid(columns: Int, spacing: CGFloat, @ViewBuilder cell: @escaping (UsageEntry.Row) -> some View) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .topLeading), count: columns), alignment: .leading, spacing: spacing) {
            ForEach(entry.rows, id: \.id, content: cell)
        }
    }

    private func header(_ row: UsageEntry.Row, showPlan: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(row.name).font(.caption.weight(.semibold)).lineLimit(1).layoutPriority(1)
            if showPlan, let plan = row.snapshot?.plan {
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
    /// `title` names the first limit in place of its label.
    private func limits(_ row: UsageEntry.Row, max count: Int, showReset: Bool, font: Font, headlineFirst: Bool = false, title: String? = nil) -> some View {
        if let snapshot = row.snapshot {
            let limits = headlineFirst ? entry.limitsLeadingWithHeadline(row) : snapshot.limits
            ForEach(Array(limits.prefix(count).enumerated()), id: \.offset) { index, limit in
                LimitRow(limit: limit, title: index == 0 ? title : nil, now: entry.date, dimmed: entry.isDimmed(row), showPace: entry.settings.showPace, showReset: showReset, font: font, barHeight: 4)
            }
        } else {
            Text([title, row.error ?? "No data yet"].compactMap { $0 }.joined(separator: ": ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// One limit of one account as a ring, for the lock screen.
struct GaugeFace: View {
    var entry: UsageEntry
    /// Nil for the first account, until one is picked.
    var accountID: String?
    var limit: LimitChoice

    var body: some View {
        let row = if let accountID { entry.rows.first { $0.id == accountID } } else { entry.rows.first }
        let shown = row.flatMap { entry.limit(limit, of: $0) }
        let percent = shown?.percent(at: entry.date)
        Gauge(value: (percent ?? 0) / 100) {
            Text(row?.glyph ?? accountID.map { String($0.prefix(1)).uppercased() } ?? "")
        } currentValueLabel: {
            Text(percent.map { "\(Format.wholePercent($0))" } ?? "–").monospacedDigit()
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }
}
