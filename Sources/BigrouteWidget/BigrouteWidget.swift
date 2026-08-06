#if SWIFT_PACKAGE
import BigrouteCore
#endif
import AppKit
import AppIntents
import OSLog
import SwiftUI
import WidgetKit

private let widgetTimelineLogger = Logger(
    subsystem: "com.routerquota.app.widget",
    category: "Timeline"
)

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

struct BigrouteEntry: TimelineEntry {
    let date: Date
    let snapshot: BigrouteSnapshot
    let providerID: UUID?
}

struct BigrouteTimelineProvider: AppIntentTimelineProvider {
    private let store = SharedQuotaStore()

    func placeholder(in context: Context) -> BigrouteEntry {
        BigrouteEntry(
            date: Date(),
            snapshot: .preview,
            providerID: BigrouteSnapshot.preview.providers.first?.id
        )
    }

    func snapshot(for configuration: ProviderWidgetIntent, in context: Context) async -> BigrouteEntry {
        entry(configuration: configuration)
    }

    func timeline(for configuration: ProviderWidgetIntent, in context: Context) async -> Timeline<BigrouteEntry> {
        let now = Date()
        let currentEntry = entry(configuration: configuration, date: now)
        widgetTimelineLogger.info(
            "Built timeline with \(currentEntry.snapshot.providers.count, privacy: .public) providers and \(currentEntry.snapshot.accounts.count, privacy: .public) accounts"
        )
        return Timeline(
            entries: [currentEntry],
            policy: .after(now.addingTimeInterval(5 * 60))
        )
    }

    private func entry(
        configuration: ProviderWidgetIntent,
        date: Date = Date()
    ) -> BigrouteEntry {
        let snapshot: BigrouteSnapshot
        if let storedSnapshot = store.load() {
            snapshot = storedSnapshot
            widgetTimelineLogger.info(
                "Read snapshot generated at \(snapshot.generatedAt.timeIntervalSince1970, privacy: .public) from \(store.fileURL.path, privacy: .public)"
            )
        } else {
            snapshot = BigrouteSnapshot(providers: [])
            widgetTimelineLogger.error("Could not read snapshot from \(store.fileURL.path, privacy: .public)")
        }
        let configuredID = configuration.provider.flatMap { UUID(uuidString: $0.id) }
        let providerID = configuredID.flatMap { snapshot.provider(id: $0)?.id }
            ?? snapshot.providers.first?.id
        return BigrouteEntry(date: date, snapshot: snapshot, providerID: providerID)
    }
}

private extension BigrouteSnapshot {
    static let previewProviderID = UUID(uuidString: "468BFBD1-2FE1-4306-9CB8-6F9A48F10B89")!
    static let preview = BigrouteSnapshot(providers: [
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
    let entry: BigrouteEntry
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
                Text("Open Bigroute to add or refresh a provider.")
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
            BigrouteMark(size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider?.name ?? "Bigroute")
                    .font(.headline)
                    .lineLimit(1)
                if let provider {
                    providerStatus(provider)
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
            Link(destination: URL(string: "bigroute://refresh")!) {
                Image(systemName: "arrow.clockwise")
            }
            .font(.caption)
            .accessibilityLabel("Refresh quota")
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
        guard let id = provider?.id else { return URL(string: "bigroute://settings") }
        return URL(string: "bigroute://provider/\(id.uuidString)")
    }

    private func providerStatus(_ provider: ProviderQuotaSnapshot) -> Text {
        let count = accounts.count > accountLimit
            ? "Showing \(accountLimit) of \(accounts.count) accounts"
            : "\(accounts.count) accounts"
        guard let updatedAt = provider.updatedAt else { return Text("\(count) · Not updated yet") }
        return Text("\(count) · Updated ") + Text(updatedAt, style: .relative)
    }
}

private struct BigrouteMark: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let markURL = Bundle.main.url(forResource: "BigrouteMark", withExtension: "svg"),
               let image = NSImage(contentsOf: markURL) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
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
                    .foregroundStyle(valueTint)
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
        switch QuotaIndicatorBand(remaining: account.primaryQuota?.remaining) {
        case .unavailable: .secondary
        case .critical: .red
        case .warning: .yellow
        case .healthy: .green
        }
    }

    private var valueTint: Color {
        QuotaIndicatorBand(remaining: account.primaryQuota?.remaining) == .warning ? .primary : tint
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
struct BigrouteWidgetBundle: WidgetBundle {
    var body: some Widget {
        BigrouteWidget()
    }
}

struct BigrouteWidget: Widget {
    let kind = "CustomProviderQuotaWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: ProviderWidgetIntent.self,
            provider: BigrouteTimelineProvider()
        ) { entry in
            ProviderWidgetView(entry: entry)
        }
        .configurationDisplayName("Bigroute")
        .description("Track quota for any configured provider.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
