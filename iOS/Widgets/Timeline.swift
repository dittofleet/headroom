import HeadroomCore
import WidgetKit

/// One engine for the whole extension process, so widgets reloading
/// together share a fetch instead of each spending one.
@MainActor
enum WidgetData {
    private static let engine = Shared.engine()

    /// The cached numbers, after fetching whatever is due.
    static func rows(refresh: Bool) async -> [UsageEntry.Row] {
        engine.reload()
        if refresh { await engine.refreshAndWait() }
        return engine.providers.filter(Shared.isSignedIn).map { UsageEntry.Row($0, engine.state($0)) }
    }

    /// What a snapshot for the widget gallery shows: the sample until
    /// something is signed in.
    static func entry(rows: [UsageEntry.Row], isPreview: Bool) -> UsageEntry {
        rows.isEmpty && isPreview ? .sample : UsageEntry(date: Date(), rows: rows, settings: .current)
    }

    /// Entries ahead of time: pace ticks move and windows reset without a
    /// fetch, so the widget keeps up even when WidgetKit is slow to reload.
    static func timeline(rows: [UsageEntry.Row], now: Date) -> Timeline<UsageEntry> {
        let horizon: TimeInterval = 3 * 3600
        let steps = stride(from: 0, through: horizon, by: 15 * 60).map { now.addingTimeInterval($0) }
        let resets = rows.compactMap(\.snapshot).flatMap(\.limits).compactMap(\.resetsAt)
            .filter { $0 > now && $0 < now.addingTimeInterval(horizon) }
        let settings = WidgetSettings.current
        let entries = Set(steps + resets).sorted().map { UsageEntry(date: $0, rows: rows, settings: settings) }
        // WidgetKit treats this as a floor, and spaces reloads out further
        // on its own budget.
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60)))
    }
}
