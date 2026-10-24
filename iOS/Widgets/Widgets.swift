import AppIntents
import HeadroomCore
import SwiftUI
import WidgetKit

@main
struct HeadroomWidgets: WidgetBundle {
    var body: some Widget {
        UsageWidget()
        GaugeWidget()
    }
}

// MARK: Usage: the signed-in accounts, or one service's

enum ServiceChoice: String, AppEnum {
    case all, claude, codex

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Service"
    static let caseDisplayRepresentations: [ServiceChoice: DisplayRepresentation] = [.all: "All", .claude: "Claude", .codex: "Codex"]

    func includes(_ row: UsageEntry.Row) -> Bool {
        self == .all || Service(rawValue: rawValue)?.number(row.id) != nil
    }
}

struct UsageIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage"
    static let description = IntentDescription("Which services the widget shows.")

    @Parameter(title: "Service", default: .all)
    var service: ServiceChoice
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Usage", intent: UsageIntent.self, provider: UsageTimeline()) { entry in
            UsageView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Usage")
        .description("Claude and Codex limits, with a pace tick on each bar.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

struct UsageTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        .sample()
    }

    func snapshot(for configuration: UsageIntent, in context: Context) async -> UsageEntry {
        await WidgetData.entry(rows: WidgetData.rows(refresh: false).filter(configuration.service.includes), isPreview: context.isPreview)
    }

    func timeline(for configuration: UsageIntent, in context: Context) async -> Timeline<UsageEntry> {
        let rows = await WidgetData.rows(refresh: true).filter(configuration.service.includes)
        return await WidgetData.timeline(rows: rows, now: Date())
    }
}

// MARK: Gauge: one limit of one account, for the lock screen

struct AccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static let defaultQuery = AccountQuery()

    var id: String
    var name: String
    var email: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: email.map { "\($0)" })
    }
}

struct AccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AccountEntity] {
        Shared.accounts().map { AccountEntity(id: $0.id, name: $0.name, email: $0.email) }
    }

    func defaultResult() async -> AccountEntity? {
        try? await suggestedEntities().first
    }
}

extension LimitChoice: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Limit"
    static let caseDisplayRepresentations: [LimitChoice: DisplayRepresentation] = [
        .asInApp: DisplayRepresentation(title: "As in App", subtitle: "The limit chosen for this service in Headroom"),
        .session: "Session",
        .weekly: "Weekly",
    ]
}

struct GaugeIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Limit"
    static let description = IntentDescription("Which limit the gauge shows.")

    @Parameter(title: "Account")
    var account: AccountEntity?

    @Parameter(title: "Limit", default: .asInApp)
    var limit: LimitChoice
}

struct GaugeEntry: TimelineEntry {
    var usage: UsageEntry
    var configuration: GaugeIntent
    var date: Date { usage.date }
}

struct GaugeTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GaugeEntry {
        GaugeEntry(usage: .sample(), configuration: GaugeIntent())
    }

    func snapshot(for configuration: GaugeIntent, in context: Context) async -> GaugeEntry {
        await GaugeEntry(usage: WidgetData.entry(rows: WidgetData.rows(refresh: false), isPreview: context.isPreview), configuration: configuration)
    }

    func timeline(for configuration: GaugeIntent, in context: Context) async -> Timeline<GaugeEntry> {
        let usage = await WidgetData.timeline(rows: WidgetData.rows(refresh: true), now: Date())
        return Timeline(entries: usage.entries.map { GaugeEntry(usage: $0, configuration: configuration) }, policy: usage.policy)
    }
}

struct GaugeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Gauge", intent: GaugeIntent.self, provider: GaugeTimeline()) { entry in
            GaugeView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Gauge")
        .description("One limit as a ring.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct GaugeView: View {
    var entry: GaugeEntry

    var body: some View {
        GaugeFace(entry: entry.usage, accountID: entry.configuration.account?.id, limit: entry.configuration.limit)
    }
}
