import Foundation
import Observation
#if SWIFT_PACKAGE
import RouterQuotaCore
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
@Observable
final class QuotaMonitor {
    var configuration: RouterQuotaConfiguration
    var snapshot: RouterQuotaSnapshot
    var selectedProviderID: UUID?
    var isRefreshing = false
    var errorMessage: String?

    private let credentialStore = CredentialStore()
    private let snapshotStore = SharedQuotaStore()
    private var timer: Timer?

    init() {
        configuration = credentialStore.load()
        snapshot = snapshotStore.load()
            ?? snapshotStore.loadLegacySnapshot()
            ?? RouterQuotaSnapshot(providers: [])
        if snapshot.sortOrder != configuration.sortOrder {
            snapshot = snapshot.withSortOrder(configuration.sortOrder)
            try? snapshotStore.save(snapshot)
        }
        selectedProviderID = configuration.providers.first(where: \.isEnabled)?.id
            ?? snapshot.providers.first?.id
        if snapshotStore.load() == nil, !snapshot.providers.isEmpty {
            try? snapshotStore.save(snapshot)
        }
    }

    var enabledProviders: [CustomQuotaProvider] {
        configuration.providers.filter(\.isEnabled)
    }

    func start() {
        scheduleTimer()
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func upsertProvider(_ provider: CustomQuotaProvider) {
        if let index = configuration.providers.firstIndex(where: { $0.id == provider.id }) {
            configuration.providers[index] = provider
        } else {
            configuration.providers.append(provider)
        }
        selectedProviderID = provider.isEnabled ? provider.id : enabledProviders.first?.id
        saveConfiguration()
    }

    func removeProvider(id: UUID) {
        configuration.providers.removeAll { $0.id == id }
        if selectedProviderID == id {
            selectedProviderID = enabledProviders.first?.id
        }
        saveConfiguration()
    }

    func saveConfiguration() {
        configuration.refreshIntervalMinutes = min(60, max(1, configuration.refreshIntervalMinutes))
        do {
            try validate(configuration)
            try credentialStore.save(configuration)
            snapshot = snapshot.withSortOrder(configuration.sortOrder)
            try snapshotStore.save(snapshot)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
            errorMessage = nil
            if !enabledProviders.contains(where: { $0.id == selectedProviderID }) {
                selectedProviderID = enabledProviders.first?.id
            }
            scheduleTimer()
            refresh(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectProvider(id: UUID) {
        guard enabledProviders.contains(where: { $0.id == id }) else { return }
        selectedProviderID = id
    }

    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let providers = enabledProviders
        let previousSnapshot = snapshot

        Task {
            let results = await Self.load(providers: providers, force: force)
            let now = Date()
            let snapshots = providers.map { provider -> ProviderQuotaSnapshot in
                guard let result = results.first(where: { $0.provider.id == provider.id }) else {
                    return ProviderQuotaSnapshot(
                        id: provider.id,
                        name: provider.name,
                        accounts: previousSnapshot.accounts(for: provider.id),
                        updatedAt: previousSnapshot.provider(id: provider.id)?.updatedAt,
                        lastError: "\(provider.name): refresh did not complete."
                    )
                }
                if let accounts = result.accounts {
                    return ProviderQuotaSnapshot(
                        id: provider.id,
                        name: provider.name,
                        accounts: accounts,
                        updatedAt: now,
                        lastError: nil
                    )
                }
                return ProviderQuotaSnapshot(
                    id: provider.id,
                    name: provider.name,
                    accounts: previousSnapshot.accounts(for: provider.id),
                    updatedAt: previousSnapshot.provider(id: provider.id)?.updatedAt,
                    lastError: result.error
                )
            }

            snapshot = RouterQuotaSnapshot(
                providers: snapshots,
                generatedAt: now,
                sortOrder: configuration.sortOrder
            )
            do {
                try snapshotStore.save(snapshot)
                #if canImport(WidgetKit)
                WidgetCenter.shared.reloadAllTimelines()
                #endif
            } catch {
                errorMessage = error.localizedDescription
            }

            let errors = snapshots.compactMap(\.lastError)
            errorMessage = errors.isEmpty ? nil : errors.joined(separator: " · ")
            isRefreshing = false
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let seconds = TimeInterval(max(1, configuration.refreshIntervalMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func validate(_ configuration: RouterQuotaConfiguration) throws {
        for provider in configuration.providers {
            guard !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationError("Provider name cannot be empty.")
            }
            _ = try RouterEndpoint.normalizedURL(from: provider.endpoint)
        }
    }

    private struct FetchResult: Sendable {
        let provider: CustomQuotaProvider
        let accounts: [CodexQuotaAccount]?
        let error: String?
    }

    nonisolated private static func load(
        providers: [CustomQuotaProvider],
        force: Bool
    ) async -> [FetchResult] {
        await withTaskGroup(of: FetchResult.self, returning: [FetchResult].self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let accounts = try await CustomQuotaService().fetch(provider: provider, forceRefresh: force)
                        return FetchResult(provider: provider, accounts: accounts, error: nil)
                    } catch {
                        return FetchResult(
                            provider: provider,
                            accounts: nil,
                            error: "\(provider.name): \(error.localizedDescription)"
                        )
                    }
                }
            }
            var results: [FetchResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }
}

private struct ConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
