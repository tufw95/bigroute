#if SWIFT_PACKAGE
import RouterQuotaCore
#endif
import AppIntents
import SwiftUI
import WidgetKit

struct ProviderWidgetEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Quota Provider")
    static let defaultQuery = ProviderWidgetQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ProviderWidgetQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ProviderWidgetEntity] {
        entities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ProviderWidgetEntity] {
        entities()
    }

    func defaultResult() async -> ProviderWidgetEntity? {
        entities().first
    }

    private func entities() -> [ProviderWidgetEntity] {
        (SharedQuotaStore().load()?.providers ?? []).map {
            ProviderWidgetEntity(id: $0.id.uuidString, name: $0.name)
        }
    }
}

struct ProviderWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Quota Provider"
    static let description = IntentDescription("Choose the provider shown by this widget.")

    @Parameter(title: "Provider")
    var provider: ProviderWidgetEntity?
}

struct RouterQuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: RouterQuotaSnapshot
    let providerID: UUID?
}

struct RouterQuotaTimelineProvider: AppIntentTimelineProvider {
    private let store = SharedQuotaStore()

    func placeholder(in context: Context) -> RouterQuotaEntry {
        RouterQuotaEntry(
            date: Date(),
            snapshot: .preview,
            providerID: RouterQuotaSnapshot.preview.providers.first?.id
        )
    }

    func snapshot(for configuration: ProviderWidgetIntent, in context: Context) async -> RouterQuotaEntry {
        entry(configuration: configuration)
    }

    func timeline(for configuration: ProviderWidgetIntent, in context: Context) async -> Timeline<RouterQuotaEntry> {
        let now = Date()
        return Timeline(
            entries: [entry(configuration: configuration, date: now)],
            policy: .after(now.addingTimeInterval(5 * 60))
        )
    }

    private func entry(
        configuration: ProviderWidgetIntent,
        date: Date = Date()
    ) -> RouterQuotaEntry {
        let snapshot = store.load() ?? RouterQuotaSnapshot(providers: [])
        let configuredID = configuration.provider.flatMap { UUID(uuidString: $0.id) }
        let providerID = configuredID.flatMap { snapshot.provider(id: $0)?.id }
            ?? snapshot.providers.first?.id
        return RouterQuotaEntry(date: date, snapshot: snapshot, providerID: providerID)
    }
}

private extension RouterQuotaSnapshot {
    static let previewProviderID = UUID(uuidString: "468BFBD1-2FE1-4306-9CB8-6F9A48F10B89")!
    static let preview = RouterQuotaSnapshot(providers: [
        ProviderQuotaSnapshot(
            id: previewProviderID,
            name: "My Router",
            accounts: [
                previewAccount("work@router", remaining: 82, resetAt: "2026-08-03T00:00:00Z"),
                previewAccount("team@router", remaining: 61, resetAt: "2026-08-02T00:00:00Z"),
                previewAccount("backup@router", remaining: 34, resetAt: "2026-08-01T00:00:00Z")
            ],
            updatedAt: Date(),
            lastError: nil
        )
    ])

    static func previewAccount(_ label: String, remaining: Double, resetAt: String) -> CodexQuotaAccount {
        CodexQuotaAccount(
            id: "preview:\(label)",
            provider: previewProviderID.uuidString,
            label: label,
            plan: "Pro",
            limitReached: false,
            quotas: [CodexQuotaWindow(
                key: "session",
                used: 100 - remaining,
                total: 100,
                remaining: remaining,
                resetAt: resetAt,
                unlimited: false
            )],
            resetCredits: .init(availableCount: 0),
            status: "valid",
            errorCode: nil
        )
    }
}

struct ProviderWidgetView: View {
    let entry: RouterQuotaEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            if let provider, !accounts.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: rowSpacing) {
                    ForEach(Array(accounts.prefix(accountLimit))) { account in
                        WidgetAccountRow(account: account)
                    }
                }
                Spacer(minLength: 0)
                if let error = provider.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            } else {
                Text("Open Router Quota to add or refresh a provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .widgetURL(widgetURL)
        .containerBackground(.ultraThinMaterial, for: .widget)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider?.name ?? "Router Quota")
                    .font(.headline)
                    .lineLimit(1)
                if let provider {
                    Text(providerStatus(provider))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            Spacer(minLength: 4)
            if provider?.lastError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var provider: ProviderQuotaSnapshot? {
        entry.providerID.flatMap { entry.snapshot.provider(id: $0) }
    }

    private var accounts: [CodexQuotaAccount] {
        entry.snapshot.sortOrder.sorted(provider?.accounts ?? [])
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
    }

    private var columnCount: Int {
        switch family {
        case .systemMedium, .systemLarge: 2
        case .systemExtraLarge: 3
        default: 1
        }
    }

    private var accountLimit: Int {
        switch family {
        case .systemSmall: 3
        case .systemMedium: 8
        case .systemLarge: 30
        case .systemExtraLarge: 45
        default: 3
        }
    }

    private var rowSpacing: CGFloat {
        family == .systemLarge || family == .systemExtraLarge ? 2 : 5
    }

    private var widgetURL: URL? {
        guard let id = provider?.id else { return URL(string: "routerquota://settings") }
        return URL(string: "routerquota://provider/\(id.uuidString)")
    }

    private func providerStatus(_ provider: ProviderQuotaSnapshot) -> String {
        let count = accounts.count > accountLimit
            ? "Showing \(accountLimit) of \(accounts.count) accounts"
            : "\(accounts.count) accounts"
        guard let updatedAt = provider.updatedAt else { return "\(count) · Not updated yet" }
        return "\(count) · Updated \(ageDescription(updatedAt))"
    }

    private func ageDescription(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(max(1, seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(seconds / 3_600) hr ago" }
        return "\(seconds / 86_400) d ago"
    }
}

private struct WidgetAccountRow: View {
    let account: CodexQuotaAccount

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(account.label)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 2)
            if let quota = account.primaryQuota {
                Text("\(Int(quota.remaining.rounded()))%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                if let date = date(from: quota.resetAt) {
                    Text(timeRemaining(until: date))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("N/A").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(height: 16)
    }

    private var tint: Color {
        guard let remaining = account.primaryQuota?.remaining else { return .secondary }
        if remaining <= 15 { return .red }
        if remaining <= 35 { return .orange }
        return .green
    }

    private func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func timeRemaining(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds >= 86_400 { return "\(seconds / 86_400)d" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h" }
        return "\(max(1, seconds / 60))m"
    }
}

@main
struct RouterQuotaWidgetBundle: WidgetBundle {
    var body: some Widget {
        RouterQuotaWidget()
    }
}

struct RouterQuotaWidget: Widget {
    let kind = "CustomProviderQuotaWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: ProviderWidgetIntent.self,
            provider: RouterQuotaTimelineProvider()
        ) { entry in
            ProviderWidgetView(entry: entry)
        }
        .configurationDisplayName("Router Quota")
        .description("Track quota for any configured provider.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
