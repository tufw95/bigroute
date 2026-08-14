import Foundation
import Observation
import OSLog
#if SWIFT_PACKAGE
import BigrouteCore
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
@Observable
final class QuotaMonitor {
    private static let widgetKind = "CustomProviderQuotaWidget"
    private static let automaticWidgetReloadInterval: TimeInterval = 5 * 60
    private static let widgetLogger = Logger(
        subsystem: "com.routerquota.app",
        category: "WidgetSync"
    )
    private static let routingLogger = Logger(
        subsystem: "com.routerquota.app",
        category: "ManualRouting"
    )
    private static let importLogger = Logger(
        subsystem: "com.routerquota.app",
        category: "AccountImport"
    )

    var configuration: BigrouteConfiguration
    var snapshot: BigrouteSnapshot
    var selectedProviderID: UUID?
    var isRefreshing = false
    var isRunningManualAction = false
    var isImportingAccounts = false
    var errorMessage: String?

    private let credentialStore = CredentialStore()
    private let snapshotStore = SharedQuotaStore()
    private var timer: Timer?
    private var pendingWidgetReloadTimer: Timer?
    private var lastWidgetReloadAt: Date?

    init() {
        configuration = credentialStore.load()
        snapshot = snapshotStore.load()
            ?? snapshotStore.loadLegacySnapshot()
            ?? BigrouteSnapshot(providers: [])
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
        pendingWidgetReloadTimer?.invalidate()
        pendingWidgetReloadTimer = nil
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

    func runManualAction(
        _ action: NineRouterAccountAction,
        provider: CustomQuotaProvider
    ) async throws -> NineRouterRoutingResult {
        guard !isRunningManualAction else {
            throw ManualActionError("Another account action is already running.")
        }
        isRunningManualAction = true
        defer { isRunningManualAction = false }
        let startedAt = Date()
        do {
            let result = try await NineRouterManualRoutingService().applyCached(
                action: action,
                provider: provider
            )
            applyManualRoutingResult(result, providerID: provider.id)
            refresh(force: true)
            let elapsed = Date().timeIntervalSince(startedAt)
            Self.routingLogger.info(
                "Manual action \(action.rawValue, privacy: .public) completed in \(elapsed, privacy: .public) seconds; changed=\(result.changedCount, privacy: .public) skipped=\(result.skippedCount, privacy: .public)"
            )
            return result
        } catch {
            let elapsed = Date().timeIntervalSince(startedAt)
            Self.routingLogger.error(
                "Manual action \(action.rawValue, privacy: .public) failed in \(elapsed, privacy: .public) seconds: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    func importAccounts(
        from urls: [URL],
        provider: CustomQuotaProvider
    ) async throws -> NineRouterAccountImportResult {
        guard !isImportingAccounts, !isRunningManualAction else {
            throw AccountImportStateError("Another 9Router account operation is already running.")
        }
        isImportingAccounts = true
        defer { isImportingAccounts = false }

        do {
            let result = try await NineRouterAccountImportService().importFiles(
                urls,
                provider: provider
            )
            Self.importLogger.info(
                "Account import completed; imported=\(result.importedCount, privacy: .public) skipped=\(result.skippedCount, privacy: .public) failed=\(result.failedCount, privacy: .public)"
            )
            if result.importedCount > 0 {
                refresh(force: true)
            }
            return result
        } catch {
            Self.importLogger.error(
                "Account import failed safely: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    private func applyManualRoutingResult(
        _ result: NineRouterRoutingResult,
        providerID: UUID
    ) {
        let states = result.accountStates(providerID: providerID)
        guard !states.isEmpty else { return }

        let providers = snapshot.providers.map { provider -> ProviderQuotaSnapshot in
            guard provider.id == providerID else { return provider }
            let accounts = provider.accounts.map { account in
                states[account.id].map(account.withActiveState) ?? account
            }
            return ProviderQuotaSnapshot(
                id: provider.id,
                name: provider.name,
                accounts: accounts,
                updatedAt: provider.updatedAt,
                lastError: provider.lastError
            )
        }
        snapshot = BigrouteSnapshot(
            providers: providers,
            generatedAt: Date(),
            sortOrder: configuration.sortOrder
        )
        do {
            try snapshotStore.save(snapshot)
            reloadWidget(force: true)
        } catch {
            Self.routingLogger.error(
                "Could not persist manual action state: \(error.localizedDescription, privacy: .public)"
            )
        }
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

            snapshot = BigrouteSnapshot(
                providers: snapshots,
                generatedAt: now,
                sortOrder: configuration.sortOrder
            )
            do {
                try snapshotStore.save(snapshot)
                Self.widgetLogger.info(
                    "Saved widget snapshot with \(self.snapshot.providers.count, privacy: .public) providers and \(self.snapshot.accounts.count, privacy: .public) accounts"
                )
                // Freshness and reset countdowns are widget content too, even
                // when the numeric quota values have not changed.
                reloadWidget(force: force)
            } catch {
                errorMessage = error.localizedDescription
                Self.widgetLogger.error("Could not save widget snapshot: \(error.localizedDescription, privacy: .public)")
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

    private func reloadWidget(force: Bool) {
        #if canImport(WidgetKit)
        let now = Date()
        if force {
            pendingWidgetReloadTimer?.invalidate()
            pendingWidgetReloadTimer = nil
            performWidgetReload(at: now)
            return
        }

        guard let lastWidgetReloadAt else {
            performWidgetReload(at: now)
            return
        }

        let elapsed = now.timeIntervalSince(lastWidgetReloadAt)
        guard elapsed < Self.automaticWidgetReloadInterval else {
            pendingWidgetReloadTimer?.invalidate()
            pendingWidgetReloadTimer = nil
            performWidgetReload(at: now)
            return
        }

        guard pendingWidgetReloadTimer == nil else { return }
        let delay = Self.automaticWidgetReloadInterval - elapsed
        pendingWidgetReloadTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingWidgetReloadTimer = nil
                self.performWidgetReload(at: Date())
            }
        }
        Self.widgetLogger.info("Coalesced WidgetKit reload scheduled in \(delay, privacy: .public) seconds")
        #endif
    }

    private func performWidgetReload(at date: Date) {
        #if canImport(WidgetKit)
        lastWidgetReloadAt = date
        WidgetCenter.shared.reloadAllTimelines()
        Self.widgetLogger.info("Requested WidgetKit reload for \(Self.widgetKind, privacy: .public)")
        #endif
    }

    private func validate(_ configuration: BigrouteConfiguration) throws {
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

private struct ManualActionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct AccountImportStateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
