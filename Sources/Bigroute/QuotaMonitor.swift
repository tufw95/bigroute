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

    var configuration: BigrouteConfiguration {
        didSet { if oldValue.sortOrder != configuration.sortOrder { rebuildAccountOrder() } }
    }
    var snapshot: BigrouteSnapshot {
        didSet { rebuildAccountOrder() }
    }
    private var orderedAccounts: [UUID: [CodexQuotaAccount]] = [:]
    private(set) var bridgeError: String?
    var selectedProviderID: UUID?
    var isRefreshing = false
    var isRunningManualAction = false
    var isImportingAccounts = false
    var isSwitchingAntigravityBridge = false
    private(set) var isLoadingConfiguration = true
    var errorMessage: String?
    private(set) var configurationLoadError: String?
    private var persistedConfiguration: BigrouteConfiguration?
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var accountRevision = 0

    private let credentialStore = CredentialStore()
    private let snapshotStore = SharedQuotaStore()
    private var timer: Timer?
    private var lastRefreshAttemptAt: Date?
    private var startupTask: Task<Void, Never>?

    init() {
        // Keychain reads can wait on securityd. Do not perform them while the
        // main actor is constructing the app delegate; startup continues and
        // the persisted configuration is hydrated asynchronously in start().
        configuration = credentialStore.loadMetadata()
        snapshot = snapshotStore.load()
            ?? snapshotStore.loadLegacySnapshot()
            ?? BigrouteSnapshot(providers: [])
        selectedProviderID = snapshot.providers.first?.id
        rebuildAccountOrder()
    }

    private func rebuildAccountOrder() {
        orderedAccounts = Dictionary(snapshot.providers.map { ($0.id, configuration.sortOrder.sorted($0.accounts)) }, uniquingKeysWith: { first, _ in first })
    }

    func sortedAccounts(for providerID: UUID) -> [CodexQuotaAccount] { orderedAccounts[providerID] ?? [] }

    var enabledProviders: [CustomQuotaProvider] {
        configuration.providers.filter(\.isEnabled)
    }

    func start() {
        guard startupTask == nil else { return }
        isLoadingConfiguration = true
        configurationLoadError = nil
        let manager = AntigravityBridgeManager.shared
        // Restore the local listener without waiting for a Keychain dialog and
        // without restarting Antigravity or disconnecting an active remote user.
        let restoreTask = Task {
            if configuration.antigravityBridge.isEnabled {
                try? await manager.restoreBridgeForStartup()
            }
        }
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer { startupTask = nil; isLoadingConfiguration = false }
            do {
                let store = credentialStore
                let loaded = try await Task.detached(priority: .userInitiated) { try store.load() }.value
                guard !Task.isCancelled else { return }
                persistedConfiguration = loaded
                applyLoadedConfiguration(loaded)
                scheduleTimer()
                isLoadingConfiguration = false
                refresh()
                await restoreTask.value
                if configuration.antigravityBridge.isEnabled {
                    await synchronizeBridgeConfiguration()
                } else if manager.isCurrentlyPointedToBridge {
                    try await manager.restoreOfficialEndpoint()
                    await manager.stopProxy()
                }
            } catch {
                // A denied/locked Keychain is not an empty key. Keep metadata
                // intact and require a successful reload before any save.
                configurationLoadError = error.localizedDescription
                errorMessage = error.localizedDescription
            }
        }
    }

    private var bridgeProvider: CustomQuotaProvider? {
        enabledProviders.first(where: { $0.apiKind == .nineRouter })
    }

    private func synchronizeBridgeConfiguration() async {
        guard !isSwitchingAntigravityBridge else { return }
        isSwitchingAntigravityBridge = true
        defer { isSwitchingAntigravityBridge = false }
        do {
            guard let provider = bridgeProvider else {
                try await AntigravityBridgeManager.shared.setBridgeEnabled(false, nineRouterUrl: "", apiKey: "", modelMode: .keepOfficial, customModelsText: "")
                configuration.antigravityBridge.isEnabled = false
                try credentialStore.save(configuration, previous: persistedConfiguration)
                persistedConfiguration = configuration
                throw ConfigurationError("Bridge disabled because no enabled 9Router provider is configured.")
            }
            let bridge = configuration.antigravityBridge
            let manager = AntigravityBridgeManager.shared
            try await manager.saveBridgeConfig(nineRouterUrl: provider.endpoint, apiKey: provider.apiKey, modelMode: bridge.modelMode, customModelsText: bridge.customModelsText)
            try await manager.restoreBridgeForStartup()
            try await manager.validateAntigravityConnection()
            bridgeError = nil
        } catch {
            bridgeError = error.localizedDescription
        }
    }

    private func applyLoadedConfiguration(_ loadedConfiguration: BigrouteConfiguration) {
        configuration = loadedConfiguration
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

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequested = false
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

    func saveConfiguration(refresh shouldRefresh: Bool = true) {
        guard !isLoadingConfiguration, let previous = persistedConfiguration else { return }
        configuration.refreshIntervalMinutes = min(60, max(1, configuration.refreshIntervalMinutes))
        do {
            try validate(configuration)
            try credentialStore.save(configuration, previous: previous)
            persistedConfiguration = configuration
            let enabledIDs = Set(enabledProviders.map(\.id))
            snapshot = BigrouteSnapshot(providers: snapshot.providers.filter { enabledIDs.contains($0.id) }, generatedAt: snapshot.generatedAt, sortOrder: configuration.sortOrder)
            try snapshotStore.save(snapshot)
            errorMessage = nil
            if !enabledProviders.contains(where: { $0.id == selectedProviderID }) {
                selectedProviderID = enabledProviders.first?.id
            }
            scheduleTimer()
            if shouldRefresh { refresh(force: true) }
            if configuration.antigravityBridge.isEnabled {
                Task { await synchronizeBridgeConfiguration() }
            }
        } catch {
            configuration = persistedConfiguration ?? previous
            errorMessage = error.localizedDescription
        }
    }

    func selectProvider(id: UUID) {
        guard enabledProviders.contains(where: { $0.id == id }) else { return }
        selectedProviderID = id
    }

    func setAntigravityBridgeEnabled(_ enabled: Bool) async {
        guard !isLoadingConfiguration, !isSwitchingAntigravityBridge, let previous = persistedConfiguration else { return }
        isSwitchingAntigravityBridge = true
        defer { isSwitchingAntigravityBridge = false }
        do {
            if enabled && bridgeProvider == nil { throw ConfigurationError("Enable a provider configured as 9Router before turning on the bridge.") }
            let provider = bridgeProvider
            let bridge = configuration.antigravityBridge
            let manager = AntigravityBridgeManager.shared
            try await manager.setBridgeEnabled(enabled, nineRouterUrl: provider?.endpoint ?? "", apiKey: provider?.apiKey ?? "", modelMode: bridge.modelMode, customModelsText: bridge.customModelsText)
            configuration.antigravityBridge.isEnabled = enabled
            // API keys do not change when toggling the bridge; skip Keychain IO.
            try credentialStore.save(configuration, previous: previous)
            persistedConfiguration = configuration
            errorMessage = nil
            bridgeError = nil
            do {
                try await manager.relaunchAntigravityApp()
                if enabled {
                    try await Task.sleep(for: .seconds(2))
                    try await manager.validateAntigravityConnection()
                }
            } catch {
                bridgeError = "Bridge settings saved. \(error.localizedDescription)"
            }
        } catch {
            // Show the actual endpoint state even if persistence fails.
            configuration.antigravityBridge = previous.antigravityBridge
            configuration.antigravityBridge.isEnabled = AntigravityBridgeManager.shared.isCurrentlyPointedToBridge
            bridgeError = error.localizedDescription
        }
    }

    func runManualAction(
        _ action: NineRouterAccountAction,
        provider: CustomQuotaProvider
    ) async throws -> NineRouterRoutingResult {
        guard !isLoadingConfiguration, persistedConfiguration != nil, !isRunningManualAction, !isImportingAccounts else {
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
        guard !isLoadingConfiguration, persistedConfiguration != nil, !isImportingAccounts, !isRunningManualAction else {
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
        accountRevision += 1

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
        guard !isLoadingConfiguration, persistedConfiguration != nil else { return }
        if isRefreshing {
            refreshRequested = refreshRequested || force
            return
        }
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
        let revision = accountRevision
        Self.quotaLogger.info(
            "Refresh started providers=\(providers.count, privacy: .public) forced=\(force, privacy: .public)"
        )

        refreshTask = Task {
            let results = await Self.load(providers: providers, force: force)
            guard !Task.isCancelled else { isRefreshing = false; return }
            // A request started before a manual action cannot undo its result.
            if accountRevision != revision {
                isRefreshing = false
                refreshTask = nil
                refreshRequested = false
                refresh(force: true)
                return
            }
            let now = Date()
            let snapshots = enabledProviders.map { provider -> ProviderQuotaSnapshot in
                guard let result = results.first(where: { $0.provider == provider }) else {
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
            refreshTask = nil
            if refreshRequested {
                refreshRequested = false
                refresh(force: true)
            }
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
