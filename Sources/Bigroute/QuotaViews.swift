import AppKit
#if SWIFT_PACKAGE
import BigrouteCore
#endif
import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @Environment(QuotaMonitor.self) private var monitor
    @Environment(UpdateController.self) private var updateController
    @AppStorage("hideInactiveAccounts") private var hideInactiveAccounts = false
    @State private var manualActionError: String?
    @State private var manualActionMessage: String?
    @State private var isShowingAccountImporter = false

    private let contentWidth: CGFloat = 700
    private let minimumHeight: CGFloat = 220
    private let maximumHeight: CGFloat = 790
    private let columns = [
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if monitor.enabledProviders.count > 1 {
                providerPicker
            }
            if supportsManualRouting {
                manualRoutingBar
                Divider().opacity(0.35)
            }
            if accounts.isEmpty {
                ContentUnavailableView(
                    emptyStateTitle,
                    systemImage: emptyStateIcon,
                    description: Text(emptyStateDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if needsAccountScroll {
                ScrollView {
                    accountGrid
                        .padding(.bottom, 8)
                }
            } else {
                accountGrid
                Spacer(minLength: 8)
            }
            footer
        }
        .frame(width: contentWidth, height: preferredHeight)
        .background(.regularMaterial)
        .animation(.snappy(duration: 0.2), value: preferredHeight)
        .onChange(of: monitor.selectedProviderID) { _, _ in
            manualActionError = nil
            manualActionMessage = nil
        }
        .fileImporter(
            isPresented: $isShowingAccountImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true
        ) { result in
            handleAccountImportSelection(result)
        }
    }

    private var googleAccounts: [CodexQuotaAccount] {
        accounts.filter(\.isGoogleAntigravity)
    }

    private var chatGPTAccounts: [CodexQuotaAccount] {
        accounts.filter { !$0.isGoogleAntigravity }
    }

    private var accountGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !googleAccounts.isEmpty && !chatGPTAccounts.isEmpty {
                sectionBlock(
                    title: "Google Antigravity",
                    systemImage: "sparkles",
                    isGoogle: true,
                    accounts: googleAccounts
                )
                sectionBlock(
                    title: "ChatGPT (Codex)",
                    systemImage: "bubble.left.and.bubble.right",
                    isGoogle: false,
                    accounts: chatGPTAccounts
                )
            } else if !googleAccounts.isEmpty {
                sectionBlock(
                    title: "Google Antigravity",
                    systemImage: "sparkles",
                    isGoogle: true,
                    accounts: googleAccounts
                )
            } else {
                sectionBlock(
                    title: "ChatGPT (Codex)",
                    systemImage: "bubble.left.and.bubble.right",
                    isGoogle: false,
                    accounts: chatGPTAccounts
                )
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func sectionBlock(title: String, systemImage: String, isGoogle: Bool, accounts: [CodexQuotaAccount]) -> some View {
        let allProviderAccounts = currentProvider.map { monitor.snapshot.accounts(for: $0.id) } ?? []
        let sectionAll = allProviderAccounts.filter { isGoogle ? $0.isGoogleAntigravity : !$0.isGoogleAntigravity }
        let activeCount = sectionAll.filter(\.isRoutingActive).count
        let totalCount = sectionAll.count

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                Text("(\(activeCount)/\(totalCount))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                ForEach(accounts) { account in
                    QuotaAccountCard(account: account)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private var preferredHeight: CGFloat {
        guard !accounts.isEmpty else {
            let providerPickerHeight: CGFloat = monitor.enabledProviders.count > 1 ? 44 : 0
            let routingHeight: CGFloat = supportsManualRouting ? 45 : 0
            return 280 + providerPickerHeight + routingHeight
        }
        return min(maximumHeight, max(minimumHeight, naturalContentHeight))
    }

    private var needsAccountScroll: Bool {
        naturalContentHeight > maximumHeight
    }

    private func gridHeight(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let rowCount = CGFloat((count + columns.count - 1) / columns.count)
        let rowGaps = CGFloat(max(0, Int(rowCount) - 1)) * 5
        return (rowCount * 36) + rowGaps
    }

    private var naturalContentHeight: CGFloat {
        guard !accounts.isEmpty else {
            let providerPickerHeight: CGFloat = monitor.enabledProviders.count > 1 ? 44 : 0
            let routingHeight: CGFloat = supportsManualRouting ? 45 : 0
            return 280 + providerPickerHeight + routingHeight
        }
        let hasGoogle = !googleAccounts.isEmpty
        let hasChatGPT = !chatGPTAccounts.isEmpty
        let isSplit = hasGoogle && hasChatGPT

        let headerHeights: CGFloat = isSplit ? (28 * 2 + 14) : (hasGoogle ? 28 : 7)
        let totalGridHeight = headerHeights + gridHeight(for: googleAccounts.count) + gridHeight(for: chatGPTAccounts.count) + 8
        let providerPickerHeight: CGFloat = monitor.enabledProviders.count > 1 ? 44 : 0
        let routingHeight: CGFloat = supportsManualRouting ? 45 : 0
        let chromeHeight: CGFloat = 65 + 1 + providerPickerHeight + routingHeight + 38
        return chromeHeight + totalGridHeight
    }

    private var currentProvider: CustomQuotaProvider? {
        guard let id = monitor.selectedProviderID else { return monitor.enabledProviders.first }
        return monitor.enabledProviders.first(where: { $0.id == id }) ?? monitor.enabledProviders.first
    }

    private var supportsManualRouting: Bool {
        currentProvider?.apiKind == .nineRouter
    }

    private var manualRoutingBar: some View {
        HStack(spacing: 8) {
            Group {
                if let manualActionError {
                    Label(manualActionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(manualActionError)
                } else if let manualActionMessage {
                    Label(manualActionMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("9Router account tools", systemImage: "hand.tap")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)

            if monitor.isRunningManualAction || monitor.isImportingAccounts {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                manualActionError = nil
                manualActionMessage = nil
                isShowingAccountImporter = true
            } label: {
                Label("Import JSON…", systemImage: "doc.badge.plus")
            }
            .help("Import ChatGPT account JSON files into 9Router")
            Button {
                runManualAction(.turnOffEmpty)
            } label: {
                Label("Turn Off Empty (0%)", systemImage: NineRouterAccountAction.turnOffEmpty.systemImage)
            }
            .tint(.red)
            Button {
                runManualAction(.turnOnAvailable)
            } label: {
                Label("Turn On Available (>0%)", systemImage: NineRouterAccountAction.turnOnAvailable.systemImage)
            }
            .tint(.green)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(monitor.isRunningManualAction || monitor.isImportingAccounts)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func handleAccountImportSelection(_ selection: Result<[URL], Error>) {
        switch selection {
        case let .success(urls):
            guard let provider = currentProvider, !urls.isEmpty else { return }
            Task {
                do {
                    manualActionError = nil
                    manualActionMessage = nil
                    let result = try await monitor.importAccounts(from: urls, provider: provider)
                    if result.importedCount == 0, result.skippedCount > 0, result.failedCount == 0 {
                        manualActionMessage = "No new accounts · \(result.skippedCount) duplicate\(result.skippedCount == 1 ? "" : "s") skipped"
                    } else {
                        var parts = ["\(result.importedCount) imported"]
                        if result.skippedCount > 0 { parts.append("\(result.skippedCount) skipped") }
                        if result.failedCount > 0 { parts.append("\(result.failedCount) failed") }
                        manualActionMessage = parts.joined(separator: " · ")
                    }
                } catch {
                    manualActionMessage = nil
                    manualActionError = error.localizedDescription
                }
            }
        case let .failure(error):
            if (error as? CocoaError)?.code != .userCancelled {
                manualActionMessage = nil
                manualActionError = error.localizedDescription
            }
        }
    }

    private func runManualAction(_ action: NineRouterAccountAction) {
        guard let provider = currentProvider else { return }
        Task {
            do {
                manualActionError = nil
                manualActionMessage = nil
                let result = try await monitor.runManualAction(action, provider: provider)
                if result.changedCount == 0, result.skippedCount > 0 {
                    manualActionMessage = "No changes · \(result.skippedCount) skipped"
                } else if result.changedCount == 0 {
                    manualActionMessage = "Already up to date"
                } else if result.skippedCount > 0 {
                    manualActionMessage = "\(result.changedCount) updated · \(result.skippedCount) skipped"
                } else {
                    manualActionMessage = "\(result.changedCount) account\(result.changedCount == 1 ? "" : "s") updated"
                }
            } catch {
                manualActionMessage = nil
                manualActionError = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            BigrouteMark(size: 21)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bigroute").font(.headline)
                Group {
                    if let provider = currentProvider {
                        Text("\(accountCountDescription) \(provider.name) accounts · \(monitor.configuration.sortOrder.title)")
                    } else {
                        Text("Add a provider in Settings")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                hideInactiveAccounts.toggle()
            } label: {
                Image(systemName: hideInactiveAccounts ? "eye.slash" : "eye")
                    .foregroundStyle(hideInactiveAccounts ? .secondary : .primary)
            }
            .buttonStyle(.borderless)
            .help(hideInactiveAccounts ? "Show inactive accounts (Off)" : "Hide inactive accounts (Off)")
            .accessibilityLabel(hideInactiveAccounts ? "Show inactive accounts" : "Hide inactive accounts")
            Button {
                monitor.refresh(force: true)
            } label: {
                if monitor.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Retry the 9Router quota check; cached values stay visible if the server is unavailable")
            .accessibilityLabel("Refresh quota")
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(15)
    }

    private var providerPicker: some View {
        HStack {
            Spacer(minLength: 0)
            Picker("Provider", selection: selectedProviderBinding) {
                ForEach(monitor.enabledProviders) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 430)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var selectedProviderBinding: Binding<UUID> {
        Binding(
            get: { monitor.selectedProviderID ?? monitor.enabledProviders.first?.id ?? UUID() },
            set: { monitor.selectProvider(id: $0) }
        )
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if monitor.isRefreshing {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                Group {
                    if currentProviderSnapshot?.accounts.isEmpty == false {
                        Text("Checking 9Router · showing cached quota")
                    } else {
                        Text("Checking 9Router…")
                    }
                }
                .lineLimit(1)
            } else if let error = currentProviderSnapshot?.lastError ?? monitor.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                if let updatedAt = currentProviderSnapshot?.updatedAt,
                   currentProviderSnapshot?.accounts.isEmpty == false {
                    Text("Cached quota · Updated \(EnglishRelativeTime.string(from: updatedAt)) · 9Router unavailable")
                        .lineLimit(1)
                        .help(error)
                } else {
                    Text(error).lineLimit(1)
                }
            } else if let updatedAt = currentProviderSnapshot?.updatedAt {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Updated \(EnglishRelativeTime.string(from: updatedAt))")
            } else {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("Waiting for the first update")
            }
            Spacer()
            if updateController.isUpdateAvailable {
                Button("Update available") {
                    updateController.checkForUpdates()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }

    private var currentProviderSnapshot: ProviderQuotaSnapshot? {
        currentProvider.flatMap { monitor.snapshot.provider(id: $0.id) }
    }

    private var accountCountDescription: String {
        guard let provider = currentProvider else { return "0" }
        let total = monitor.snapshot.accounts(for: provider.id).count
        if hideInactiveAccounts {
            return "\(accounts.count) active / \(total) total"
        }
        let activeCount = monitor.snapshot.accounts(for: provider.id).filter(\.isRoutingActive).count
        return "\(activeCount) active / \(total) total"
    }

    private var accounts: [CodexQuotaAccount] {
        guard let id = currentProvider?.id else { return [] }
        let allAccounts = monitor.snapshot.accounts(for: id)
        let filtered = hideInactiveAccounts ? allAccounts.filter(\.isRoutingActive) : allAccounts
        return monitor.configuration.sortOrder.sorted(filtered)
    }

    private var emptyStateTitle: String {
        if monitor.enabledProviders.isEmpty { return "No providers configured" }
        if hideInactiveAccounts { return "No active accounts" }
        return "No quota data"
    }

    private var emptyStateIcon: String {
        if monitor.enabledProviders.isEmpty { return "plus.circle" }
        if hideInactiveAccounts { return "eye.slash" }
        return "gauge.with.dots.needle.0percent"
    }

    private var emptyStateDescription: String {
        if monitor.enabledProviders.isEmpty {
            return "Open Settings to add a quota provider."
        }
        if hideInactiveAccounts {
            return "All accounts are currently turned off. Click the eye icon to view inactive accounts or use Turn On Available."
        }
        return "Check the endpoint and API key in Settings."
    }
}

struct QuotaAccountCard: View {
    let account: CodexQuotaAccount
    private var quota: CodexQuotaWindow? { account.primaryQuota }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 3.5)
                if let rem = quota?.remaining, rem > 0 {
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, rem / 100)))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(quota.map { "\(Int($0.remaining.rounded()))" } ?? "–")
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
            .frame(width: 36, height: 36)
            .opacity(account.isRoutingActive ? 1.0 : 0.6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(account.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if !account.isRoutingActive {
                        Text("Off")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if !account.plan.isEmpty {
                        Text(account.plan)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(quota.map { "\(Int($0.remaining.rounded()))%" } ?? "N/A")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(valueTint)
                .opacity(account.isRoutingActive ? 1.0 : 0.6)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.06))
        }
    }

    private var tint: Color {
        switch QuotaIndicatorBand(remaining: quota?.remaining) {
        case .unavailable: .secondary
        case .critical: .red
        case .warning: .yellow
        case .healthy: .green
        }
    }

    private var valueTint: Color {
        QuotaIndicatorBand(remaining: quota?.remaining) == .warning ? .primary : tint
    }

    private var resetText: String {
        guard let raw = quota?.resetAt, let date = QuotaDateParser.date(from: raw) else {
            return account.status.capitalized
        }
        if date <= Date() { return "Refresh pending" }
        return "Refreshes \(EnglishRelativeTime.string(from: date))"
    }
}

enum QuotaDateParser {
    static func date(from value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum EnglishRelativeTime {
    static func string(from date: Date, relativeTo reference: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}

struct SettingsView: View {
    @Environment(QuotaMonitor.self) private var monitor
    @Environment(UpdateController.self) private var updateController
    @State private var editingProvider: CustomQuotaProvider?
    @State private var providerToDelete: CustomQuotaProvider?

    var body: some View {
        @Bindable var monitor = monitor
        Form {
            Section {
                if monitor.configuration.providers.isEmpty {
                    Text("Add a provider to start tracking quota.")
                        .foregroundStyle(.secondary)
                }
                ForEach(monitor.configuration.providers) { provider in
                    HStack {
                        Button {
                            editingProvider = provider
                        } label: {
                            ProviderSettingsRow(provider: provider)
                        }
                        .buttonStyle(.plain)
                        Button(role: .destructive) {
                            providerToDelete = provider
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete provider")
                    }
                }
                Button {
                    editingProvider = CustomQuotaProvider()
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("API keys are stored in Keychain. Scheduled refreshes and widgets are always read-only; 9Router changes and credential imports happen only after an explicit menu-bar action.")
            }

            Section("Display") {
                Picker("Sort accounts by", selection: $monitor.configuration.sortOrder) {
                    ForEach(AccountSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                Text("Changes apply immediately to the menu bar and every widget. Accounts without the selected value stay at the end.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                Stepper(
                    "App checks every \(monitor.configuration.refreshIntervalMinutes) minutes",
                    value: $monitor.configuration.refreshIntervalMinutes,
                    in: 1...60
                )
                Text("The app refreshes widget data on the selected schedule and asks WidgetKit to redraw at most every 5 minutes. Requests inside that window are queued, Refresh Now asks for an immediate redraw, and the widget has a 5-minute fallback. macOS may still delay the exact timing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Save and Refresh Now") { monitor.saveConfiguration() }
                        .buttonStyle(.borderedProminent)
                }
            }

            Section("Updates") {
                LabeledContent("Installed version", value: versionDescription)
                HStack {
                    Text("Bigroute checks GitHub Releases automatically and installs signed updates in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for Updates…") {
                        updateController.checkForUpdates()
                    }
                }
            }

            if let error = monitor.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onChange(of: monitor.configuration.sortOrder) { _, _ in
            monitor.saveConfiguration()
        }
        .navigationTitle("Bigroute")
        .sheet(item: $editingProvider) { provider in
            ProviderEditorView(provider: provider) { updated in
                monitor.upsertProvider(updated)
            }
        }
        .confirmationDialog(
            "Delete \(providerToDelete?.name ?? "provider")?",
            isPresented: Binding(
                get: { providerToDelete != nil },
                set: { if !$0 { providerToDelete = nil } }
            )
        ) {
            Button("Delete Provider", role: .destructive) {
                if let id = providerToDelete?.id { monitor.removeProvider(id: id) }
                providerToDelete = nil
            }
            Button("Cancel", role: .cancel) { providerToDelete = nil }
        } message: {
            Text("Its saved API key and cached widget data will be removed.")
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
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

private struct ProviderSettingsRow: View {
    let provider: CustomQuotaProvider

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name.isEmpty ? "Unnamed provider" : provider.name)
                    .font(.body.weight(.medium))
                Text(provider.endpoint.isEmpty ? "Endpoint not configured" : provider.endpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(provider.isEnabled ? .green : .secondary)
                .frame(width: 7, height: 7)
        }
        .contentShape(Rectangle())
    }
}

private struct ProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuotaMonitor.self) private var monitor
    @State private var provider: CustomQuotaProvider
    @State private var validationMessage: String?
    let onSave: (CustomQuotaProvider) -> Void

    init(provider: CustomQuotaProvider, onSave: @escaping (CustomQuotaProvider) -> Void) {
        _provider = State(initialValue: provider)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Provider") {
                    TextField("Name", text: $provider.name, prompt: Text("My Router"))
                    Picker("Provider type", selection: $provider.apiKind) {
                        ForEach(QuotaAPIKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    TextField("Endpoint", text: $provider.endpoint, prompt: Text("https://router.example.com"))
                    SecureField("API key", text: $provider.apiKey)
                    Toggle("Enabled", isOn: $provider.isEnabled)
                }
                Section {
                    Text("Endpoint can be a base URL or the complete /v1/quota or /api/usage/quota URL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Choose 9Router to enable the two manual account actions. Auto-detect and OmniRouter remain quota-monitoring only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save and Test") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480, height: 440)
        .environment(monitor)
    }

    private func save() {
        do {
            guard !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EditorError("Enter a provider name.")
            }
            _ = try RouterEndpoint.normalizedURL(from: provider.endpoint)
            guard !provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EditorError("Enter an API key.")
            }
            onSave(provider)
            if monitor.errorMessage == nil { dismiss() }
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}

private struct EditorError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
