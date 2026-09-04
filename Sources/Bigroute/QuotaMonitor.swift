import Foundation
import Observation
import OSLog
#if SWIFT_PACKAGE
import BigrouteCore
#endif

@MainActor
@Observable
final class QuotaMonitor {
    private static let routingLogger = Logger(
        subsystem: "com.routerquota.app",
        category: "ManualRouting"
    )
    private static let importLogger = Logger(
        subsystem: "com.routerquota.app",
        category: "AccountImport"
    )
    private static let quotaLogger = Logger(
        subsystem: "com.routerquota.app",
        category: "QuotaRefresh"
    )
    private static let automaticRefreshMinimumInterval: TimeInterval = 15

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
    private var lastRefreshAttemptAt: Date?

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
        } catch {
            Self.routingLogger.error(
                "Could not persist manual action state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func refresh(force: Bool = false) {
        let now = Date()
        guard !isRefreshing else { return }
        if !force {
            if let lastRefreshAttemptAt,
               now.timeIntervalSince(lastRefreshAttemptAt) < Self.automaticRefreshMinimumInterval {
                return
            }
        }
        isRefreshing = true
        lastRefreshAttemptAt = now
        let providers = enabledProviders
        let previousSnapshot = snapshot
        Self.quotaLogger.info(
            "Refresh started providers=\(providers.count, privacy: .public) forced=\(force, privacy: .public)"
        )

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
                    let previousAccounts = previousSnapshot.accounts(for: provider.id)
                    let previousAccountsByID = Dictionary(
                        previousAccounts.map { ($0.id, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let mergedAccounts = accounts.map { account -> CodexQuotaAccount in
                        let prefixedID = "\(provider.id.uuidString):\(account.id)"
                        let previous = previousAccountsByID[prefixedID] ?? previousAccountsByID[account.id]
                        if account.quotas.isEmpty, let previous, !previous.quotas.isEmpty {
                            return CodexQuotaAccount(
                                id: account.id,
                                provider: account.provider,
                                label: account.label,
                                plan: (account.plan.isEmpty || account.plan == "unknown") ? previous.plan : account.plan,
                                limitReached: account.limitReached,
                                quotas: previous.quotas,
                                resetCredits: account.resetCredits,
                                status: account.status,
                                errorCode: account.errorCode,
                                isActive: account.isActive
                            )
                        }
                        return account
                    }
                    return ProviderQuotaSnapshot(
                        id: provider.id,
                        name: provider.name,
                        accounts: mergedAccounts,
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
            var persistenceError: String?
            do {
                try snapshotStore.save(snapshot)
            } catch {
                persistenceError = error.localizedDescription
                errorMessage = persistenceError
            }

            var errors = snapshots.compactMap(\.lastError)
            if let persistenceError {
                errors.append(persistenceError)
            }
            errorMessage = errors.isEmpty ? nil : errors.joined(separator: " · ")
            Self.quotaLogger.info(
                "Refresh finished errors=\(errors.count, privacy: .public) cachedAccounts=\(self.snapshot.accounts.count, privacy: .public)"
            )
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
