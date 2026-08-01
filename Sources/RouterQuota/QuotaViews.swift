import AppKit
#if SWIFT_PACKAGE
import RouterQuotaCore
#endif
import SwiftUI

struct DashboardView: View {
    @Environment(QuotaMonitor.self) private var monitor
    @Environment(UpdateController.self) private var updateController

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
            if accounts.isEmpty {
                ContentUnavailableView(
                    monitor.enabledProviders.isEmpty ? "No providers configured" : "No quota data",
                    systemImage: monitor.enabledProviders.isEmpty
                        ? "plus.circle"
                        : "gauge.with.dots.needle.0percent",
                    description: Text(monitor.enabledProviders.isEmpty
                        ? "Open Settings to add a quota provider."
                        : "Check the endpoint and API key in Settings.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                    ForEach(accounts) { account in
                        QuotaAccountCard(account: account)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 7)
                Spacer(minLength: 8)
            }
            footer
        }
        .frame(width: 760, height: 790)
        .background(.regularMaterial)
    }

    private var currentProvider: CustomQuotaProvider? {
        guard let id = monitor.selectedProviderID else { return monitor.enabledProviders.first }
        return monitor.enabledProviders.first(where: { $0.id == id }) ?? monitor.enabledProviders.first
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text("Router Quota").font(.headline)
                Group {
                    if let provider = currentProvider {
                        Text("\(accounts.count) \(provider.name) accounts · sorted by quota")
                    } else {
                        Text("Add a provider in Settings")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
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
            .help("Refresh now")
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
            if let error = monitor.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(1)
            } else if let updatedAt = currentProvider.flatMap({ monitor.snapshot.provider(id: $0.id)?.updatedAt }) {
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

    private var accounts: [CodexQuotaAccount] {
        guard let id = currentProvider?.id else { return [] }
        return monitor.snapshot.accounts(for: id).sorted(by: Self.quotaDescending)
    }

    static func quotaDescending(_ lhs: CodexQuotaAccount, _ rhs: CodexQuotaAccount) -> Bool {
        let left = lhs.primaryQuota?.remaining ?? -1
        let right = rhs.primaryQuota?.remaining ?? -1
        if left == right {
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
        return left > right
    }
}

struct QuotaAccountCard: View {
    let account: CodexQuotaAccount
    private var quota: CodexQuotaWindow? { account.primaryQuota }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: max(0, min(1, (quota?.remaining ?? 0) / 100)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(quota.map { "\(Int($0.remaining.rounded()))" } ?? "–")
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(account.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
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
                .foregroundStyle(quota == nil ? .secondary : tint)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.primary.opacity(0.06))
        }
    }

    private var tint: Color {
        guard let remaining = quota?.remaining else { return .secondary }
        if remaining <= 15 { return .red }
        if remaining <= 35 { return .orange }
        return .green
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
                Text("The app automatically recognizes 9Router and OmniRouter quota responses. API keys are stored in Keychain.")
            }

            Section("Refresh") {
                Stepper(
                    "App checks every \(monitor.configuration.refreshIntervalMinutes) minutes",
                    value: $monitor.configuration.refreshIntervalMinutes,
                    in: 1...60
                )
                Text("The widget reads the latest app snapshot and requests a timeline refresh every 5 minutes. macOS may delay widget redraws, so the exact timing is controlled by WidgetKit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Save and Refresh") { monitor.saveConfiguration() }
                        .buttonStyle(.borderedProminent)
                }
            }

            Section("Updates") {
                LabeledContent("Installed version", value: versionDescription)
                HStack {
                    Text("Router Quota checks GitHub Releases automatically and installs signed updates in the background.")
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
        .navigationTitle("Router Quota")
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
                    TextField("Endpoint", text: $provider.endpoint, prompt: Text("https://router.example.com"))
                    SecureField("API key", text: $provider.apiKey)
                    Toggle("Enabled", isOn: $provider.isEnabled)
                }
                Section {
                    Text("Endpoint can be a base URL or the complete /v1/quota or /api/usage/quota URL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Automatic detection supports the standard 9Router and OmniRouter response formats.")
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
