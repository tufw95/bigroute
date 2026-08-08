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
    private static let automationLogger = Logger(
        subsystem: "com.routerquota.app",
        category: "AccountRouting"
    )

    var configuration: BigrouteConfiguration
    var snapshot: BigrouteSnapshot
    var selectedProviderID: UUID?
    var isRefreshing = false
    var errorMessage: String?

    private let credentialStore = CredentialStore()
    private let snapshotStore = SharedQuotaStore()
    private var timer: Timer?
    private var pendingWidgetReloadTimer: Timer?
    private var lastWidgetReloadAt: Date?
    private var automationCooldownUntil: [UUID: Date] = [:]
    private var automationServices: [UUID: NineRouterAutomationService] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

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
        cancelRefresh()
        timer?.invalidate()
        timer = nil
        pendingWidgetReloadTimer?.invalidate()
        pendingWidgetReloadTimer = nil
    }

    func upsertProvider(_ provider: CustomQuotaProvider) {
        var candidate = configuration
        if let index = candidate.providers.firstIndex(where: { $0.id == provider.id }) {
            candidate.providers[index] = provider
        } else {
            candidate.providers.append(provider)
        }
        _ = persistConfiguration(
            candidate,
            preferredProviderID: provider.isEnabled ? provider.id : selectedProviderID
        ) {
            // A saved edit is the explicit retry path after authentication
            // failure and may require a new endpoint/password session.
            automationCooldownUntil.removeValue(forKey: provider.id)
            automationServices.removeValue(forKey: provider.id)
        }
    }

    func removeProvider(id: UUID) {
        var candidate = configuration
        candidate.providers.removeAll { $0.id == id }
        _ = persistConfiguration(candidate, preferredProviderID: selectedProviderID == id ? nil : selectedProviderID) {
            automationCooldownUntil.removeValue(forKey: id)
            automationServices.removeValue(forKey: id)
        }
    }

    func saveConfiguration() {
        _ = persistConfiguration(configuration, preferredProviderID: selectedProviderID)
    }

    @discardableResult
    private func persistConfiguration(
        _ proposedConfiguration: BigrouteConfiguration,
        preferredProviderID: UUID?,
        onCommit: () -> Void = {}
    ) -> Bool {
        var candidate = proposedConfiguration
        candidate.refreshIntervalMinutes = min(60, max(1, candidate.refreshIntervalMinutes))
        var cancelledRefresh: Task<Void, Never>?
        do {
            try validate(candidate)
            cancelledRefresh = cancelRefresh()
            try credentialStore.save(candidate)
            let updatedSnapshot = snapshot.withSortOrder(candidate.sortOrder)

            configuration = candidate
            snapshot = updatedSnapshot
            let enabledProviderIDs = Set(candidate.providers.filter(\.isEnabled).map(\.id))
            if let preferredProviderID, enabledProviderIDs.contains(preferredProviderID) {
                selectedProviderID = preferredProviderID
            } else if let selectedProviderID, enabledProviderIDs.contains(selectedProviderID) {
                self.selectedProviderID = selectedProviderID
            } else {
                selectedProviderID = candidate.providers.first(where: \.isEnabled)?.id
            }
            onCommit()
            errorMessage = nil
            do {
                try snapshotStore.save(updatedSnapshot)
            } catch {
                // Provider credentials are already committed. Keep the app and
                // disk configuration aligned; the forced refresh retries the
                // shared snapshot write immediately.
                Self.widgetLogger.error(
                    "Settings were saved, but the widget snapshot could not be updated: \(error.localizedDescription, privacy: .public)"
                )
            }
            scheduleTimer()
            refresh(force: true, waitingFor: cancelledRefresh)
            return true
        } catch {
            errorMessage = error.localizedDescription
            if let cancelledRefresh {
                refresh(force: false, waitingFor: cancelledRefresh)
            }
            return false
        }
    }

    func selectProvider(id: UUID) {
        guard enabledProviders.contains(where: { $0.id == id }) else { return }
        selectedProviderID = id
    }

    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        refresh(force: force, waitingFor: nil)
    }

    private func refresh(
        force: Bool,
        waitingFor predecessor: Task<Void, Never>?
    ) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let generation = refreshGeneration

        let task = Task { [weak self] in
            guard let self else { return }
            if let predecessor {
                await predecessor.value
            }
            guard !Task.isCancelled, generation == refreshGeneration else { return }

            // Read configuration and ownership after any cancelled refresh has
            // fully unwound, so a new run cannot start from a stale state copy.
            let providers = enabledProviders
            let previousSnapshot = snapshot
            let routingStore = credentialStore
            for provider in providers where provider.isAutomaticAccountRoutingEnabled
                && provider.apiKind == .nineRouter
                && automationServices[provider.id] == nil {
                automationServices[provider.id] = NineRouterAutomationService()
            }
            let routingServices = automationServices
            let automationStates = Dictionary(providers.map {
                ($0.id, Self.scopedAutomationState(
                    credentialStore.loadNineRouterAutomationState(for: $0.id),
                    provider: $0
                ))
            }, uniquingKeysWith: { first, _ in first })
            let cooldowns = automationCooldownUntil
            let results = await Self.load(
                providers: providers,
                force: force,
                automationStates: automationStates,
                cooldowns: cooldowns,
                credentialStore: routingStore,
                automationServices: routingServices
            )
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            let now = Date()
            var stateErrors: [String] = []
            var snapshotError: String?
            for result in results {
                if result.activatedCount > 0 || result.deactivatedCount > 0 {
                    Self.automationLogger.info(
                        "Account routing activated \(result.activatedCount, privacy: .public) and deactivated \(result.deactivatedCount, privacy: .public) accounts for provider \(result.provider.id.uuidString, privacy: .private(mask: .hash))"
                    )
                }
                if let state = result.automationState {
                    do {
                        try credentialStore.saveNineRouterAutomationState(
                            state,
                            for: result.provider.id,
                            expectedProvider: result.provider
                        )
                    } catch {
                        stateErrors.append("\(result.provider.name): could not save automatic routing state.")
                    }
                }
                if let cooldown = result.automationCooldownUntil {
                    automationCooldownUntil[result.provider.id] = cooldown
                } else if result.automationSucceeded {
                    automationCooldownUntil.removeValue(forKey: result.provider.id)
                }
            }
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
                    let visibleAccounts = Self.mergingAutomatedAccounts(
                        current: accounts,
                        previous: previousSnapshot.accounts(for: provider.id),
                        observations: result.automationObservations,
                        retainedPublicAccountIDs: result.retainedPublicAccountIDs
                    )
                    return ProviderQuotaSnapshot(
                        id: provider.id,
                        name: provider.name,
                        accounts: visibleAccounts,
                        updatedAt: now,
                        lastError: result.error
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
                snapshotError = error.localizedDescription
                errorMessage = snapshotError
                Self.widgetLogger.error("Could not save widget snapshot: \(error.localizedDescription, privacy: .public)")
            }

            var errors = snapshots.compactMap(\.lastError) + stateErrors
            if let snapshotError { errors.append(snapshotError) }
            errorMessage = errors.isEmpty ? nil : errors.joined(separator: " · ")
            isRefreshing = false
            refreshTask = nil
        }
        refreshTask = task
    }

    @discardableResult
    private func cancelRefresh() -> Task<Void, Never>? {
        refreshGeneration &+= 1
        let cancelledTask = refreshTask
        cancelledTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        return cancelledTask
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
        guard Set(configuration.providers.map(\.id)).count == configuration.providers.count else {
            throw ConfigurationError("Each provider must have a unique identifier.")
        }
        for provider in configuration.providers {
            guard !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationError("Provider name cannot be empty.")
            }
            _ = try RouterEndpoint.normalizedURL(from: provider.endpoint)
            if provider.isAutomaticAccountRoutingEnabled {
                guard provider.apiKind == .nineRouter else {
                    throw ConfigurationError("Automatic account routing requires the provider type to be 9Router.")
                }
                guard !provider.dashboardPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigurationError("Enter the 9Router dashboard password before enabling automatic account routing.")
                }
            }
        }
        if !NineRouterAutomationService.conflictingAutomationProviderIDs(
            in: configuration.providers
        ).isEmpty {
            throw ConfigurationError(
                "Only one enabled automatic-routing provider can control each 9Router endpoint."
            )
        }
    }

    private struct FetchResult: Sendable {
        let provider: CustomQuotaProvider
        let accounts: [CodexQuotaAccount]?
        let error: String?
        let automationState: NineRouterAutomationState?
        let automationCooldownUntil: Date?
        let automationSucceeded: Bool
        let automationObservations: [NineRouterAccountObservation]
        let retainedPublicAccountIDs: Set<String>
        let activatedCount: Int
        let deactivatedCount: Int
    }

    nonisolated private static func load(
        providers: [CustomQuotaProvider],
        force: Bool,
        automationStates: [UUID: NineRouterAutomationState],
        cooldowns: [UUID: Date],
        credentialStore: CredentialStore,
        automationServices: [UUID: NineRouterAutomationService]
    ) async -> [FetchResult] {
        let conflictingProviderIDs = NineRouterAutomationService
            .conflictingAutomationProviderIDs(in: providers)
        return await withTaskGroup(of: FetchResult.self, returning: [FetchResult].self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let requiresFreshQuota = provider.isAutomaticAccountRoutingEnabled
                            && provider.apiKind == .nineRouter
                            && !conflictingProviderIDs.contains(provider.id)
                        let accounts = try await CustomQuotaService().fetch(
                            provider: provider,
                            forceRefresh: force || requiresFreshQuota,
                            requireFreshResponse: requiresFreshQuota
                        )
                        if conflictingProviderIDs.contains(provider.id) {
                            return FetchResult(
                                provider: provider,
                                accounts: accounts,
                                error: "\(provider.name): automatic routing is paused because another enabled provider controls the same 9Router endpoint.",
                                automationState: nil,
                                automationCooldownUntil: nil,
                                automationSucceeded: false,
                                automationObservations: [],
                                retainedPublicAccountIDs: publicAccountIDs(
                                    from: automationStates[provider.id] ?? .empty
                                ),
                                activatedCount: 0,
                                deactivatedCount: 0
                            )
                        }
                        guard provider.isAutomaticAccountRoutingEnabled else {
                            return FetchResult(
                                provider: provider,
                                accounts: accounts,
                                error: nil,
                                automationState: nil,
                                automationCooldownUntil: nil,
                                automationSucceeded: false,
                                automationObservations: [],
                                retainedPublicAccountIDs: [],
                                activatedCount: 0,
                                deactivatedCount: 0
                            )
                        }
                        guard provider.apiKind == .nineRouter else {
                            return FetchResult(
                                provider: provider,
                                accounts: accounts,
                                error: "\(provider.name): automatic routing is available only for 9Router providers.",
                                automationState: nil,
                                automationCooldownUntil: nil,
                                automationSucceeded: false,
                                automationObservations: [],
                                retainedPublicAccountIDs: [],
                                activatedCount: 0,
                                deactivatedCount: 0
                            )
                        }
                        if let cooldown = cooldowns[provider.id], cooldown > Date() {
                            let retainedIDs = publicAccountIDs(
                                from: automationStates[provider.id] ?? .empty
                            )
                            let message = cooldown == .distantFuture
                                ? "\(provider.name): automatic routing is paused. Open the provider settings, verify the dashboard password, and save to retry."
                                : "\(provider.name): automatic routing is temporarily paused after a 9Router rate limit."
                            return FetchResult(
                                provider: provider,
                                accounts: accounts,
                                error: message,
                                automationState: nil,
                                automationCooldownUntil: cooldown,
                                automationSucceeded: false,
                                automationObservations: [],
                                retainedPublicAccountIDs: retainedIDs,
                                activatedCount: 0,
                                deactivatedCount: 0
                            )
                        }

                        do {
                            let baseURL = try RouterEndpoint.normalizedURL(from: provider.endpoint)
                            guard let automationService = automationServices[provider.id] else {
                                throw NineRouterAutomationError.invalidResponse
                            }
                            let report = try await automationService.reconcile(
                                baseURL: baseURL,
                                managementPassword: provider.dashboardPassword,
                                activeQuota: accounts,
                                state: automationStates[provider.id] ?? .empty,
                                persistState: { state in
                                    try credentialStore.saveNineRouterAutomationState(
                                        state,
                                        for: provider.id,
                                        expectedProvider: provider
                                    )
                                }
                            )
                            let activated = report.changes.filter { $0.kind == .activated }.count
                            let deactivated = report.changes.filter { $0.kind == .deactivated }.count
                            let warning = report.warnings.first.map {
                                "\(provider.name): quota updated, but automatic routing reported \(report.warnings.count) warning(s): \($0.error.localizedDescription)"
                            }
                            let cooldown = cooldownDate(for: report.warnings.map(\.error))
                            return FetchResult(
                                provider: provider,
                                accounts: accounts,
                                error: warning,
                                automationState: report.updatedState,
                                automationCooldownUntil: cooldown,
                                automationSucceeded: cooldown == nil,
                                automationObservations: report.observations,
                                retainedPublicAccountIDs: publicAccountIDs(from: report.updatedState),
                                activatedCount: activated,
                                deactivatedCount: deactivated
                            )
                        } catch is CancellationError {
                            return cancelledFetchResult(provider: provider)
                        } catch {
                            let automationError = error as? NineRouterAutomationError
                            return FetchResult(
                                provider: provider,
                                accounts: accounts,
                                error: "\(provider.name): quota updated, but automatic routing failed: \(error.localizedDescription)",
                                automationState: nil,
                                automationCooldownUntil: automationError.flatMap { cooldownDate(for: [$0]) },
                                automationSucceeded: false,
                                automationObservations: [],
                                retainedPublicAccountIDs: publicAccountIDs(
                                    from: automationStates[provider.id] ?? .empty
                                ),
                                activatedCount: 0,
                                deactivatedCount: 0
                            )
                        }
                    } catch is CancellationError {
                        return cancelledFetchResult(provider: provider)
                    } catch {
                        return FetchResult(
                            provider: provider,
                            accounts: nil,
                            error: "\(provider.name): \(error.localizedDescription)",
                            automationState: nil,
                            automationCooldownUntil: nil,
                            automationSucceeded: false,
                            automationObservations: [],
                            retainedPublicAccountIDs: [],
                            activatedCount: 0,
                            deactivatedCount: 0
                        )
                    }
                }
            }
            var results: [FetchResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    nonisolated private static func cooldownDate(
        for errors: [NineRouterAutomationError]
    ) -> Date? {
        if errors.contains(.unauthorized)
            || errors.contains(.forbidden)
            || errors.contains(.invalidAuthenticationResponse)
            || errors.contains(.mustChangePassword) {
            // Do not make repeated password attempts; editing and saving the
            // provider is the only retry path until the app restarts.
            return .distantFuture
        }
        if errors.contains(.rateLimited) {
            return Date().addingTimeInterval(60 * 60)
        }
        return nil
    }

    nonisolated private static func cancelledFetchResult(
        provider: CustomQuotaProvider
    ) -> FetchResult {
        FetchResult(
            provider: provider,
            accounts: nil,
            error: nil,
            automationState: nil,
            automationCooldownUntil: nil,
            automationSucceeded: false,
            automationObservations: [],
            retainedPublicAccountIDs: [],
            activatedCount: 0,
            deactivatedCount: 0
        )
    }

    nonisolated private static func mergingAutomatedAccounts(
        current: [CodexQuotaAccount],
        previous: [CodexQuotaAccount],
        observations: [NineRouterAccountObservation],
        retainedPublicAccountIDs: Set<String>
    ) -> [CodexQuotaAccount] {
        guard !observations.isEmpty || !retainedPublicAccountIDs.isEmpty else { return current }
        var merged = current
        var visiblePublicIDs = Set(current.compactMap(publicAccountID(from:)))
        let previousByPublicID = Dictionary(
            previous.compactMap { account -> (String, CodexQuotaAccount)? in
                guard let publicID = publicAccountID(from: account) else { return nil }
                return (publicID, account)
            },
            uniquingKeysWith: { first, _ in first }
        )

        for observation in observations {
            guard !observation.measurement.unlimited,
                  observation.measurement.remaining.isFinite,
                  !visiblePublicIDs.contains(observation.publicAccountID),
                  let prior = previousByPublicID[observation.publicAccountID] else {
                continue
            }
            merged.append(prior.withQuotaMeasurement(observation.measurement))
            visiblePublicIDs.insert(observation.publicAccountID)
        }
        for publicID in retainedPublicAccountIDs {
            guard !visiblePublicIDs.contains(publicID),
                  let prior = previousByPublicID[publicID] else { continue }
            merged.append(prior)
            visiblePublicIDs.insert(publicID)
        }
        return merged
    }

    nonisolated private static func publicAccountIDs(
        from state: NineRouterAutomationState
    ) -> Set<String> {
        Set(state.autoDisabledConnectionIDs.map(NineRouterAutomationService.publicAccountID(for:)))
    }

    nonisolated private static func scopedAutomationState(
        _ state: NineRouterAutomationState,
        provider: CustomQuotaProvider
    ) -> NineRouterAutomationState {
        guard let endpoint = try? RouterEndpoint.normalizedURL(from: provider.endpoint),
              let management = try? NineRouterAutomationService.managementBaseURL(from: endpoint) else {
            // An invalid endpoint cannot establish ownership for any account.
            return .empty
        }
        let identity = management.absoluteString
        // Unscoped legacy state and ownership from another endpoint are both
        // unsafe to adopt because they could refer to manually disabled accounts.
        guard state.managementEndpointIdentity == identity else {
            return NineRouterAutomationState(managementEndpointIdentity: identity)
        }
        return state
    }

    nonisolated private static func publicAccountID(
        from account: CodexQuotaAccount
    ) -> String? {
        let candidate = account.id.split(separator: ":").last.map(String.init) ?? account.id
        guard candidate.count == 16, candidate.allSatisfy(\.isHexDigit) else { return nil }
        return candidate.lowercased()
    }
}

private extension CodexQuotaAccount {
    func withQuotaMeasurement(_ measurement: NineRouterQuotaMeasurement) -> CodexQuotaAccount {
        let clamped = min(max(measurement.remaining, 0), 100)
        let primaryKey = primaryQuota?.key ?? "session"
        var updatedQuotas = quotas
        let observedByKey = Dictionary(
            measurement.windows.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        if observedByKey.isEmpty,
           let index = updatedQuotas.firstIndex(where: { $0.key == primaryKey }) {
            updatedQuotas[index] = updatedQuotas[index].withRemaining(clamped, resetAt: nil)
        } else {
            for index in updatedQuotas.indices {
                guard let observed = observedByKey[updatedQuotas[index].key] else { continue }
                updatedQuotas[index] = updatedQuotas[index].withRemaining(
                    observed.remaining,
                    resetAt: observed.resetAt
                )
            }
            let knownKeys = Set(updatedQuotas.map(\.key))
            for observed in measurement.windows where !knownKeys.contains(observed.key) {
                updatedQuotas.append(CodexQuotaWindow(
                    key: observed.key,
                    used: 100 - observed.remaining,
                    total: 100,
                    remaining: observed.remaining,
                    resetAt: observed.resetAt,
                    unlimited: false
                ))
            }
        }
        if updatedQuotas.isEmpty {
            updatedQuotas = [CodexQuotaWindow(
                key: primaryKey,
                used: 100 - clamped,
                total: 100,
                remaining: clamped,
                resetAt: nil,
                unlimited: false
            )]
        }
        return CodexQuotaAccount(
            id: id,
            provider: provider,
            label: label,
            plan: plan,
            limitReached: clamped <= 0,
            quotas: updatedQuotas,
            resetCredits: resetCredits,
            status: "available",
            errorCode: nil
        )
    }
}

private extension CodexQuotaWindow {
    func withRemaining(_ remaining: Double, resetAt newResetAt: String?) -> CodexQuotaWindow {
        let clamped = min(max(remaining, 0), 100)
        let effectiveTotal = total > 0 ? total : 100
        return CodexQuotaWindow(
            key: key,
            used: effectiveTotal * (100 - clamped) / 100,
            total: effectiveTotal,
            remaining: clamped,
            resetAt: newResetAt ?? resetAt,
            unlimited: false
        )
    }
}

private struct ConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
